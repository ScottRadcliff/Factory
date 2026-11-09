require "spec_helper"

RSpec.describe Factory::Verifier do
  around do |example|
    Dir.mktmpdir("factory-verification") do |directory|
      @directory = directory
      @repo = File.join(directory, "app")
      Dir.mkdir(@repo)
      example.run
    end
  end

  def task_with(commands, cleanup: nil, cleanup_timeout: 60)
    data = YAML.safe_load_file(File.join(__dir__, "fixtures", "task.yml"))
    data["repository"] = @repo
    data["verification"] = commands.each_with_index.map { |command, i| {"name" => "check-#{i}", "command" => command, "timeout_seconds" => 1} }
    if cleanup
      data["verification"].each { |check| check.merge!("cleanup" => cleanup, "cleanup_timeout_seconds" => cleanup_timeout) }
    end
    path = File.join(@directory, "task.yml")
    File.write(path, YAML.dump(data))
    Factory::TaskSpec.load(path)
  end

  def verify(commands)
    task = task_with(commands)
    @store = Factory::RunStore.new(task: task, root: File.join(@directory, "runs"))
    described_class.new(task: task, store: @store).verify({"path" => @repo}, attempt: 0)
  end

  it "runs every check in order inside the worktree and preserves failed diagnostics" do
    results = verify([[RbConfig.ruby, "-e", 'File.write("marker", "created"); warn "failure details"; exit 2'],
                      [RbConfig.ruby, "-e", 'exit(File.exist?("marker") ? 0 : 1)']])
    expect(results.map { |result| result.fetch("exit_code") }).to eq([2, 0])
    expect(File.read(results.first.fetch("stderr_path"))).to include("failure details")
    attempt = @store.snapshot.fetch("verification_attempts").first
    expect(attempt).to include("complete" => true, "success" => false, "checks" => results)
  end

  it "records passing suites" do
    verify([[RbConfig.ruby, "-e", "exit 0"]])
    expect(@store.snapshot.fetch("verification_attempts").first).to include("complete" => true, "success" => true)
  end

  it "records missing commands as execution errors" do
    results = verify([[File.join(@directory, "missing")]])
    expect(results.first.fetch("error").fetch("class")).to eq("Errno::ENOENT")
    expect(@store.snapshot.fetch("verification_attempts").first.fetch("success")).to be(false)
  end

  it "enforces check timeouts" do
    results = verify([[RbConfig.ruby, "-e", "sleep 30"]])
    expect(results.first).to include("state" => "timed_out", "timed_out" => true, "success" => false)
  end

  it "retains already completed checks when a later check is interrupted" do
    task = task_with([[RbConfig.ruby, "-e", "exit 0"], ["second"]])
    store = Factory::RunStore.new(task: task, root: File.join(@directory, "runs"))
    commands = Factory::CommandRunner.new(store: store)
    allow(commands).to receive(:call).with([RbConfig.ruby, "-e", "exit 0"], anything).and_call_original
    allow(commands).to receive(:call).with(["second"], anything).and_raise(Interrupt)
    expect { described_class.new(task: task, store: store, command_runner: commands).verify({"path" => @repo}, attempt: 0) }.to raise_error(Interrupt)
    expect(store.snapshot.fetch("verification_attempts").first).to include("complete" => false, "success" => false)
    expect(store.snapshot.fetch("verification_attempts").first.fetch("checks").length).to eq(1)
  end

  def verify_task(task)
    @store = Factory::RunStore.new(task: task, root: File.join(@directory, "runs"))
    described_class.new(task: task, store: @store).verify({"path" => @repo}, attempt: 0)
  end

  [0, 1].each do |exit_code|
    it "expands run IDs and runs cleanup after check exit #{exit_code}" do
      task = task_with([[RbConfig.ruby, "-e", "File.write('project', ARGV.fetch(0)); exit #{exit_code}", "factory-{{run_id}}"]],
                       cleanup: [RbConfig.ruby, "-e", "File.write('cleaned', ARGV.fetch(0))", "factory-{{run_id}}"])
      results = verify_task(task)
      project = "factory-#{@store.snapshot.fetch('run_id')}"
      expect(File.read(File.join(@repo, "project"))).to eq(project)
      expect(File.read(File.join(@repo, "cleaned"))).to eq(project)
      expect(results.first.fetch("cleanup")).to include("success" => true)
      expect(results.first.fetch("success")).to eq(exit_code.zero?)
    end
  end

  it "cleans up after a timeout" do
    task = task_with([[RbConfig.ruby, "-e", "sleep 30"]], cleanup: [RbConfig.ruby, "-e", "File.write('cleaned', 'yes')"])
    results = verify_task(task)
    expect(results.first).to include("timed_out" => true)
    expect(File.read(File.join(@repo, "cleaned"))).to eq("yes")
  end

  it "fails cleanup errors without masking the original check result or allowing repair" do
    task = task_with([[RbConfig.ruby, "-e", "exit 1"]], cleanup: [RbConfig.ruby, "-e", 'warn "cleanup failed"; exit 2'])
    expect { verify_task(task) }.to raise_error(Factory::VerificationError, /cleanup failed/)
    attempt = @store.snapshot.fetch("verification_attempts").first
    expect(attempt.fetch("complete")).to be(false)
    expect(attempt.fetch("checks").first).to include("exit_code" => 1)
    expect(attempt.fetch("checks").first.fetch("cleanup")).to include("exit_code" => 2)
  end

  it "bounds cleanup execution with its own timeout" do
    task = task_with([[RbConfig.ruby, "-e", "exit 0"]], cleanup: [RbConfig.ruby, "-e", "sleep 30"], cleanup_timeout: 1)
    expect { verify_task(task) }.to raise_error(Factory::VerificationError, /cleanup failed/)
    expect(@store.snapshot.fetch("verification_attempts").first.fetch("checks").first.fetch("cleanup")).to include("timed_out" => true)
  end

  it "cleans up and preserves interruption" do
    task = task_with([["interrupted"]], cleanup: [RbConfig.ruby, "-e", "File.write('cleaned', 'yes')"])
    store = Factory::RunStore.new(task: task, root: File.join(@directory, "runs"))
    commands = Factory::CommandRunner.new(store: store)
    allow(commands).to receive(:call).and_call_original
    allow(commands).to receive(:call).with(["interrupted"], anything).and_raise(Interrupt)
    expect { described_class.new(task: task, store: store, command_runner: commands).verify({"path" => @repo}, attempt: 0) }.to raise_error(Interrupt)
    expect(File.read(File.join(@repo, "cleaned"))).to eq("yes")
    expect(store.snapshot.fetch("verification_attempts").first.fetch("checks").first).to include("state" => "interrupted")
  end
end
