require "spec_helper"

RSpec.describe Factory::CLI do
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:example_path) { File.expand_path("fixtures/task.yml", __dir__) }

  it "prints a normalized task as JSON" do
    status = described_class.run(["validate", example_path], out: out, err: err)
    expect(status).to eq(0)
    expect(JSON.parse(out.string)).to include("valid" => true, "source_path" => example_path)
    expect(err.string).to be_empty
  end

  it "reports invalid files without a stack trace or success output" do
    status = described_class.run(["validate", "/missing-factory-task.yml"], out: out, err: err)
    expect(status).to eq(1)
    expect(err.string).to start_with("Invalid task specification:")
    expect(out.string).to be_empty
  end

  [[], ["run"], ["validate"], ["validate", "a", "b"]].each do |argv|
    it "returns usage error for #{argv.inspect}" do
      expect(described_class.run(argv, out: out, err: err)).to eq(2)
      expect(err.string).to include("Usage:")
    end
  end

  it "shows help successfully" do
    expect(described_class.run(["--help"], out: out, err: err)).to eq(0)
    expect(out.string).to include("Usage:")
    expect(err.string).to be_empty
  end

  it "rejects invalid submission flags" do
    expect(described_class.run(["submit", "--unknown", "task.yml"], out: out, err: err)).to eq(2)
    expect(err.string).to include("invalid option", "Usage:")
  end

  it "runs the actual executable from another working directory" do
    executable = File.expand_path("../bin/factory", __dir__)
    Dir.mktmpdir do |directory|
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, executable, "validate", example_path, chdir: directory)
      expect(status.exitstatus).to eq(0)
      expect(stderr).to be_empty
      expect(JSON.parse(stdout).fetch("task").fetch("repository")).to eq(File.expand_path("..", __dir__))
      expect(Dir.children(directory)).to be_empty
    end
  end

  context "workspace preparation" do
    include_context "temporary Git repository"

    it "prepares a worktree through the executable and prints its paths" do
      executable = File.expand_path("../bin/factory", __dir__)
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, executable, "prepare", @task_path)
      expect(status.exitstatus).to eq(0)
      expect(stderr).to include("Preparing worktree", "Worktree prepared")
      result = JSON.parse(stdout)
      expect(result.fetch("state")).to eq("prepared")
      expect(File.directory?(result.fetch("workspace").fetch("path"))).to be(true)
      expect(JSON.parse(File.read(result.fetch("result_path"))).fetch("state")).to eq("prepared")
      expect(git("symbolic-ref", "--short", "HEAD")).to eq("main")
    end

    it "returns a concise error and nonzero exit when preparation fails" do
      git("branch", "-m", "other")
      expect(described_class.run(["prepare", @task_path], out: out, err: err)).to eq(1)
      expect(out.string).to be_empty
      expect(err.string).to include("Cannot prepare workspace:", "result.json")
    end

    it "reports interruption with a conventional exit status" do
      allow_any_instance_of(Factory::GitWorkspace).to receive(:prepare).and_raise(Interrupt)
      expect(described_class.run(["prepare", @task_path], out: out, err: err)).to eq(130)
      expect(err.string).to include("interrupted", "retained artifacts:")
      expect(out.string).to be_empty
    end

    it "implements a task through a simulated Codex executable" do
      fake_codex
      executable = File.expand_path("../bin/factory", __dir__)
      stdout, stderr, status = Open3.capture3({"PATH" => "#{@directory}:#{ENV.fetch('PATH')}"}, RbConfig.ruby, executable, "implement", @task_path)
      expect(status.exitstatus).to eq(0)
      expect(stderr).to include("results and logs:")
      expect(stderr).to include("Preparing worktree", "Implementing task with Codex", "Codex: turn completed", "verification pending")
      result = JSON.parse(stdout)
      expect(result.fetch("state")).to eq("implemented")
      expect(result.fetch("agent").fetch("verification")).to eq("pending")
      expect(git("status", "--porcelain")).to be_empty
    end

    it "prints agent failures without a Ruby stack trace" do
      allow_any_instance_of(Factory::Runner).to receive(:run).and_raise(Factory::AgentError, "agent failed")
      expect(described_class.run(["implement", @task_path], out: out, err: err)).to eq(1)
      expect(err.string).to include("Cannot implement task: agent failed")
      expect(out.string).to be_empty
    end

    it "runs implementation and verification through the CLI" do
      data = YAML.safe_load_file(@task_path)
      data["verification"] = [{"name" => "content", "command" => [RbConfig.ruby, "-e", 'exit(File.read("app.txt").include?("implemented") ? 0 : 1)'], "timeout_seconds" => 5}]
      File.write(@task_path, YAML.dump(data))
      fake_codex
      executable = File.expand_path("../bin/factory", __dir__)
      stdout, stderr, status = Open3.capture3({"PATH" => "#{@directory}:#{ENV.fetch('PATH')}"}, RbConfig.ruby, executable, "run", @task_path)
      expect(status.exitstatus).to eq(0)
      expect(JSON.parse(stdout)).to include("state" => "verified", "repair_attempts" => 0)
      expect(stderr).to include("Verification content: running", "Verification content: succeeded", "Verification passed")
    end

    it "returns a nonzero status for verification failures" do
      allow_any_instance_of(Factory::Runner).to receive(:run).and_raise(Factory::VerificationError, "exhausted repairs")
      expect(described_class.run(["run", @task_path], out: out, err: err)).to eq(1)
      expect(err.string).to include("Verification failed: exhausted repairs")
      expect(out.string).to be_empty
    end

    it "submits a verified commit locally without requiring GitHub" do
      data = YAML.safe_load_file(@task_path)
      data["verification"] = [{"name" => "specs", "command" => [RbConfig.ruby, "-e", "exit 0"], "timeout_seconds" => 5}]
      File.write(@task_path, YAML.dump(data))
      fake_codex
      executable = File.expand_path("../bin/factory", __dir__)
      stdout, stderr, status = Open3.capture3({"PATH" => "#{@directory}:#{ENV.fetch('PATH')}"}, RbConfig.ruby, executable, "submit", "--no-publish", @task_path)
      expect(status.exitstatus).to eq(0)
      expect(JSON.parse(stdout)).to include("state" => "committed", "verification" => "passed")
      expect(stderr).to include("Committing verified changes", "committed locally")
      expect(git("status", "--porcelain")).to be_empty
    end

    it "returns a nonzero status for publication failures" do
      allow_any_instance_of(Factory::Runner).to receive(:run).and_raise(Factory::PublicationError, "push failed")
      expect(described_class.run(["submit", @task_path], out: out, err: err)).to eq(1)
      expect(err.string).to include("Submission failed: push failed")
      expect(out.string).to be_empty
    end
  end
end
