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
end
