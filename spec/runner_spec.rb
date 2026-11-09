require "spec_helper"

RSpec.describe Factory::Runner do
  include_context "temporary Git repository"

  let(:store) { Factory::RunStore.new(task: task) }

  def runner(body = nil)
    agent = Factory::CodexAgent.new(task: task, store: store, executable: fake_codex(body))
    described_class.new(task: task, store: store, agent: agent)
  end

  it "prepares and implements without committing, publishing, or claiming verification" do
    result = runner.run
    expect(result).to include("state" => "implemented")
    expect(result.fetch("agent")).to include("verification" => "pending")
    expect(git("rev-parse", result.fetch("workspace").fetch("branch"))).to eq(result.fetch("workspace").fetch("base_sha"))
    expect(git("status", "--porcelain")).to be_empty
    expect(result.fetch("commands").map { |c| c.fetch("argv").first }).not_to include("gh", "bundle")
    states = File.readlines(File.join(store.directory, "events.jsonl")).map { |line| JSON.parse(line) }.select { |e| e["type"] == "run_transition" }.map { |e| e.fetch("state") }
    expect(states).to eq(%w[preparing prepared implementing implemented])
  end

  it "records agent failure and retains the worktree" do
    expect { runner('exit 1').run }.to raise_error(Factory::AgentError, /result.json/)
    expect(store.snapshot).to include("state" => "failed", "failed_stage" => "implementing")
    expect(File.directory?(store.snapshot.fetch("workspace").fetch("path"))).to be(true)
  end

  it "preserves preparation failures rather than labeling them agent failures" do
    git("branch", "-m", "other")
    expect { runner.run }.to raise_error(Factory::WorkspaceError)
    expect(store.snapshot).to include("state" => "failed", "failed_stage" => "preparing")
  end

  it "rejects an agent that changes branches" do
    agent = instance_double(Factory::CodexAgent)
    allow(agent).to receive(:implement) do |workspace|
      _, stderr, status = Open3.capture3("git", "-C", workspace.fetch("path"), "switch", "-c", "unexpected")
      raise stderr unless status.success?
      {}
    end
    expect { described_class.new(task: task, store: store, agent: agent).run }.to raise_error(Factory::AgentError, /branch or HEAD/)
    expect(store.snapshot.fetch("state")).to eq("failed")
  end

  it "rejects an agent that commits on the expected branch" do
    agent = instance_double(Factory::CodexAgent)
    allow(agent).to receive(:implement) do |workspace|
      _, stderr, status = Open3.capture3("git", "-C", workspace.fetch("path"), "commit", "--allow-empty", "-m", "Unauthorized")
      raise stderr unless status.success?
      {}
    end
    expect { described_class.new(task: task, store: store, agent: agent).run }.to raise_error(Factory::AgentError, /branch or HEAD/)
    expect(store.snapshot.fetch("state")).to eq("failed")
  end

  it "records interruption during implementation" do
    agent = instance_double(Factory::CodexAgent)
    allow(agent).to receive(:implement).and_raise(Interrupt)
    expect { described_class.new(task: task, store: store, agent: agent).run }.to raise_error(Interrupt)
    expect(store.snapshot).to include("state" => "interrupted", "failed_stage" => "implementing")
  end

  context "independent verification" do
    def configure_checks(code, max_repairs: 2, command: nil)
      data = YAML.safe_load_file(@task_path)
      data["limits"] = {"max_repairs" => max_repairs}
      data["verification"] = [{"name" => "regression", "command" => command || [RbConfig.ruby, "-e", code], "timeout_seconds" => 2}]
      File.write(@task_path, YAML.dump(data))
    end

    def repairable_body
      <<~RUBY
        File.write("app.txt", prompt.include?("Repair attempt") ? "fixed" : "broken")
        File.write(ARGV.fetch(ARGV.index("--output-last-message") + 1), "Finished agent attempt")
        puts JSON.generate("type" => "turn.completed")
      RUBY
    end

    it "marks a passing initial implementation verified without repairs" do
      configure_checks("exit 0")
      result = runner.run(verify: true)
      expect(result).to include("state" => "verified", "verification" => "passed", "repair_attempts" => 0)
      expect(result.fetch("agent").fetch("verification")).to eq("passed")
      expect(result.fetch("verification_attempts").length).to eq(1)
      expect(result.fetch("agent_attempts").length).to eq(1)
      expect(git("status", "--porcelain")).to be_empty
    end

    it "repairs a failure and independently verifies the repaired worktree" do
      configure_checks('warn "Expected fixed content"; exit(File.read("app.txt") == "fixed" ? 0 : 1)')
      data = YAML.safe_load_file(@task_path)
      data["verification"] << {"name" => "second", "command" => [RbConfig.ruby, "-e", 'File.open("check-count", "a") { |f| f.write("x") }'], "timeout_seconds" => 2}
      File.write(@task_path, YAML.dump(data))
      result = runner(repairable_body).run(verify: true)
      expect(result).to include("state" => "verified", "repair_attempts" => 1)
      expect(result.fetch("verification_attempts").map { |attempt| attempt.fetch("success") }).to eq([false, true])
      expect(result.fetch("verification_attempts").map { |attempt| attempt.fetch("checks").length }).to eq([2, 2])
      expect(File.read(File.join(result.fetch("workspace").fetch("path"), "check-count"))).to eq("xx")
      summaries = result.fetch("agent_attempts").map { |attempt| attempt.fetch("summary_path") }
      expect(summaries.uniq.length).to eq(2)
      expect(summaries).to all(satisfy { |path| File.exist?(path) })
      repair = result.fetch("commands").find { |command| File.read(command.fetch("stdin_path")).include?("Repair attempt 1") }
      expect(File.read(repair.fetch("stdin_path"))).to include("Expected fixed content", "untrusted diagnostic data", "regression")
      expect(git("rev-parse", result.fetch("workspace").fetch("branch"))).to eq(result.fetch("workspace").fetch("base_sha"))
    end

    it "stops after exactly the configured repair budget" do
      configure_checks("exit 1", max_repairs: 2)
      expect { runner(repairable_body).run(verify: true) }.to raise_error(Factory::VerificationError, /exhausted 2 of 2/)
      result = store.snapshot
      expect(result).to include("state" => "failed", "failed_stage" => "verifying", "repair_attempts" => 2)
      expect(result.fetch("agent_attempts").length).to eq(3)
      expect(result.fetch("verification_attempts").length).to eq(3)
    end

    it "honors zero repairs" do
      configure_checks("exit 1", max_repairs: 0)
      expect { runner.run(verify: true) }.to raise_error(Factory::VerificationError, /exhausted 0 of 0/)
      expect(store.snapshot.fetch("agent_attempts").length).to eq(1)
    end

    it "fails execution errors without asking the agent to repair the environment" do
      configure_checks(nil, command: [File.join(@directory, "missing")])
      expect { runner.run(verify: true) }.to raise_error(Factory::VerificationError, /could not execute/)
      expect(store.snapshot.fetch("repair_attempts")).to eq(0)
    end

    it "records a repair agent failure separately from verification exhaustion" do
      configure_checks("exit 1")
      body = 'exit 1 if prompt.include?("Repair attempt"); ' + repairable_body
      expect { runner(body).run(verify: true) }.to raise_error(Factory::AgentError)
      expect(store.snapshot).to include("state" => "failed", "failed_stage" => "repairing", "repair_attempts" => 1)
      expect(store.snapshot.fetch("verification_attempts").length).to eq(1)
    end

    it "checks Git identity after verification commands as well as agent execution" do
      configure_checks('system("git", "commit", "--allow-empty", "-m", "unexpected") or exit 1')
      expect { runner.run(verify: true) }.to raise_error(Factory::AgentError, /branch or HEAD/)
      expect(store.snapshot.fetch("failed_stage")).to eq("verifying")
    end

    it "records interruption during verification" do
      configure_checks("exit 0")
      verifier = instance_double(Factory::Verifier)
      allow(verifier).to receive(:verify).and_raise(Interrupt)
      agent = Factory::CodexAgent.new(task: task, store: store, executable: fake_codex)
      expect { described_class.new(task: task, store: store, agent: agent, verifier: verifier).run(verify: true) }.to raise_error(Interrupt)
      expect(store.snapshot).to include("state" => "interrupted", "failed_stage" => "verifying")
    end
  end
end
