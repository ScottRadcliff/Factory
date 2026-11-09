require "spec_helper"
require "timeout"

RSpec.describe Factory::CommandRunner do
  around do |example|
    Dir.mktmpdir("factory-command") do |directory|
      @directory = directory
      example.run
    end
  end

  let(:task) { Factory::TaskSpec.load(File.expand_path("fixtures/task.yml", __dir__)) }
  let(:store) { Factory::RunStore.new(task: task, root: File.join(@directory, "runs")) }
  let(:runner) { described_class.new(store: store) }

  def run_ruby(code, **options)
    runner.call([RbConfig.ruby, "-e", code], chdir: @directory, timeout: 5, **options)
  end

  it "records success, working directory, stdin, and separate output streams" do
    result = run_ruby('puts Dir.pwd; puts STDIN.read; warn "diagnostic"', stdin: "task input")
    expect(result).to include("state" => "succeeded", "success" => true, "exit_code" => 0, "timed_out" => false)
    expect(File.read(result.fetch("stdout_path"))).to eq("#{File.realpath(@directory)}\ntask input\n")
    expect(File.read(result.fetch("stderr_path"))).to eq("diagnostic\n")
    expect(result.fetch("duration_seconds")).to be >= 0
    expect(store.snapshot.fetch("commands").first).to eq(result)
  end

  it "records nonzero exit codes without raising" do
    expect(run_ruby('warn "failure"; exit 7')).to include("state" => "failed", "success" => false, "exit_code" => 7)
  end

  it "records missing executables and leaves logs for inspection" do
    result = runner.call([File.join(@directory, "missing")], chdir: @directory, timeout: 1)
    expect(result).to include("state" => "failed", "exit_code" => nil)
    expect(result.fetch("error").fetch("class")).to eq("Errno::ENOENT")
    expect(File.exist?(result.fetch("stderr_path"))).to be(true)
  end

  it "records an invalid working directory as a spawn failure" do
    result = runner.call([RbConfig.ruby, "--version"], chdir: File.join(@directory, "missing"), timeout: 1)
    expect(result).to include("state" => "failed", "success" => false)
    expect(result.fetch("error").fetch("class")).to eq("Errno::ENOENT")
  end

  it "passes shell metacharacters literally" do
    argument = "$(touch #{@directory}/injected); echo unsafe"
    result = runner.call([RbConfig.ruby, "-e", "print ARGV.fetch(0)", argument], chdir: @directory, timeout: 5)
    expect(File.read(result.fetch("stdout_path"))).to eq(argument)
    expect(File.exist?(File.join(@directory, "injected"))).to be(false)
  end

  it "does not interpret a single argument as a shell command" do
    result = runner.call(["echo hello > #{@directory}/injected"], chdir: @directory, timeout: 1)
    expect(result.fetch("state")).to eq("failed")
    expect(File.exist?(File.join(@directory, "injected"))).to be(false)
  end

  it "streams large output to files" do
    result = run_ruby('STDOUT.write("a" * 2_000_000); STDERR.write("b" * 2_000_000)')
    expect(result.fetch("success")).to be(true)
    expect(File.size(result.fetch("stdout_path"))).to eq(2_000_000)
    expect(File.size(result.fetch("stderr_path"))).to eq(2_000_000)
    expect(File.stat(result.fetch("stdout_path"))).to have_attributes(mode: satisfy { |mode| mode & 0o777 == 0o600 })
  end

  it "terminates commands that ignore TERM within the timeout bound" do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = run_ruby('trap("TERM") {}; STDOUT.sync = true; puts "started"; sleep 30', timeout: 0.3)
    expect(result).to include("state" => "timed_out", "success" => false, "timed_out" => true, "signal" => Signal.list.fetch("KILL"))
    expect(File.read(result.fetch("stdout_path"))).to eq("started\n")
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 3
  end

  it "terminates descendants even if their leader has already exited" do
    marker = File.join(@directory, "survived")
    result = run_ruby("fork { sleep 0.5; File.write(#{marker.inspect}, 'alive') }; exit 0")
    expect(result.fetch("success")).to be(true)
    sleep 0.6
    expect(File.exist?(marker)).to be(false)
  end

  it "records signal deaths" do
    result = run_ruby('Process.kill("KILL", Process.pid)')
    expect(result).to include("state" => "failed", "exit_code" => nil, "signal" => Signal.list.fetch("KILL"))
  end

  it "records interruption and re-raises it after cleaning up" do
    ready = File.join(@directory, "ready")
    worker = Thread.new do
      begin
        run_ruby("File.write(#{ready.inspect}, Process.pid.to_s); sleep 30")
      rescue Interrupt
        :interrupted
      end
    end
    begin
      Timeout.timeout(5) { sleep 0.01 until File.exist?(ready) }
      worker.raise(Interrupt)
      expect(worker.value).to eq(:interrupted)
      expect(store.snapshot.fetch("commands").last).to include("state" => "interrupted", "success" => false)
      expect { Process.kill(0, Integer(File.read(ready))) }.to raise_error(Errno::ESRCH)
    ensure
      worker.raise(Interrupt) if worker.alive?
      worker.join
    end
  end

  [0, -1, Float::INFINITY, Float::NAN, "1"].each do |timeout|
    it "rejects invalid timeout #{timeout.inspect} before allocating a command" do
      expect { run_ruby("exit", timeout: timeout) }.to raise_error(ArgumentError, /timeout/)
      expect(store.snapshot.fetch("commands")).to be_empty
    end
  end

  [[], "echo hello", [""], [nil], ["ruby", "bad\0argument"]].each do |argv|
    it "rejects invalid argv #{argv.inspect}" do
      expect { runner.call(argv, chdir: @directory, timeout: 1) }.to raise_error(ArgumentError, /argv/)
    end
  end
end
