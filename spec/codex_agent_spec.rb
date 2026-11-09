require "spec_helper"

RSpec.describe Factory::CodexAgent do
  include_context "temporary Git repository"

  let(:store) { Factory::RunStore.new(task: task) }
  let(:workspace) { Factory::GitWorkspace.new(task: task, store: store).prepare }

  def agent(executable)
    described_class.new(task: task, store: store, executable: executable)
  end

  it "runs noninteractively in the worktree and retains the prompt, events, and summary" do
    result = agent(fake_codex).implement(workspace)
    command = store.snapshot.fetch("commands").last
    expect(command.fetch("chdir")).to eq(workspace.fetch("path"))
    expect(command.fetch("timeout_seconds")).to eq(1800)
    expect(File.read(command.fetch("stdin_path"))).to include(task.to_h.fetch("title"), "acceptance_criteria", "do not commit", "single coding agent")
    expect(File.read(result.fetch("summary_path"))).to include("verification is pending")
    expect(result.fetch("verification")).to eq("pending")
    expect(File.read(File.join(workspace.fetch("path"), "app.txt"))).to eq("implemented\n")
    expect(File.read(File.join(@repository, "app.txt"))).to eq("original\n")
  end

  it "reports a missing Codex executable" do
    expect { agent(File.join(@directory, "missing")).implement(workspace) }.to raise_error(Factory::AgentError, /Codex command failed/)
  end

  it "gives Codex the same expanded project name used by verification and cleanup" do
    data = YAML.safe_load_file(@task_path)
    data["verification"].first.merge!("command" => ["docker", "compose", "-p", "factory-{{run_id}}", "config"],
                                       "cleanup" => ["docker", "compose", "-p", "factory-{{run_id}}", "down"])
    File.write(@task_path, YAML.dump(data))
    agent(fake_codex).implement(workspace)
    input = File.read(store.snapshot.fetch("commands").last.fetch("stdin_path"))
    expect(input).to include("factory-#{store.snapshot.fetch('run_id')}")
    expect(input).not_to include("{{run_id}}")
  end

  it "sends bounded failed-check diagnostics and saves a distinct repair summary" do
    executable = fake_codex
    current = workspace
    check = Factory::CommandRunner.new(store: store).call(
      [RbConfig.ruby, "-e", 'STDOUT.write("x" * 20_000 + "diagnostic tail"); warn "expected valid name"; exit 1'],
      chdir: current.fetch("path"), timeout: 5).merge("name" => "specs")
    result = agent(executable).repair(current, checks: [check], attempt: 1)
    expect(File.basename(result.fetch("summary_path"))).to eq("agent-repair-001-summary.txt")
    input = File.read(store.snapshot.fetch("commands").last.fetch("stdin_path"))
    expect(input).to include("Repair attempt 1", "diagnostic tail", "expected valid name", "untrusted diagnostic data")
    expect(input).not_to include("x" * 8193)
    expect(File.size(check.fetch("stdout_path"))).to eq(20_015)
  end

  it "reports failed agent processes without retrying" do
    executable = fake_codex('warn "not authenticated"; exit 1')
    expect { agent(executable).implement(workspace) }.to raise_error(Factory::AgentError, /stderr.log/)
    expect(store.snapshot.fetch("commands").count { |c| c.fetch("argv").first == executable }).to eq(1)
  end

  it "enforces the task's agent timeout and retains the timed-out command" do
    data = YAML.safe_load_file(@task_path)
    data["limits"] = {"agent_timeout_seconds" => 1}
    File.write(@task_path, YAML.dump(data))
    executable = fake_codex("sleep 30")
    expect { agent(executable).implement(workspace) }.to raise_error(Factory::AgentError, /timed_out/)
    expect(store.snapshot.fetch("commands").last).to include("state" => "timed_out", "timeout_seconds" => 1)
  end

  {
    "failed turn" => 'puts JSON.generate("type" => "turn.failed")',
    "error event" => 'puts JSON.generate("type" => "error")',
    "incomplete stream" => 'puts JSON.generate("type" => "turn.started")',
    "malformed JSON" => 'puts "not json"',
    "nonobject event" => 'puts "[]"',
    "missing event type" => 'puts "{}"'
  }.each do |name, body|
    it "rejects a #{name} even when the process exits successfully" do
      expect { agent(fake_codex(body)).implement(workspace) }.to raise_error(Factory::AgentError)
    end
  end

  it "rejects a missing final summary" do
    executable = fake_codex('puts JSON.generate("type" => "turn.completed")')
    expect { agent(executable).implement(workspace) }.to raise_error(Factory::AgentError, /final summary/)
  end

  it "ignores unfamiliar event types but still requires turn completion" do
    executable = fake_codex(<<~RUBY)
      puts JSON.generate("type" => "future.event")
      puts JSON.generate("type" => "turn.completed")
      File.write(ARGV.fetch(ARGV.index("--output-last-message") + 1), "Done")
    RUBY
    expect(agent(executable).implement(workspace)).to include("verification" => "pending")
  end
end
