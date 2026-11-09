require "spec_helper"

RSpec.describe Factory::ProgressReporter do
  let(:output) { StringIO.new }
  let(:reporter) { described_class.new(io: output, clock: -> { Time.utc(2026, 11, 9, 15, 42, 1) }) }

  it "prints timestamped lifecycle changes" do
    reporter.event("type" => "run_transition", "state" => "implementing")
    reporter.event("type" => "run_transition", "state" => "implemented")
    expect(output.string).to include("[2026-11-09T15:42:01Z] Implementing task with Codex", "verification pending")
  end

  it "renders commands, changed paths, and agent messages without tool output" do
    reporter.codex_event("type" => "item.started", "item" => {"type" => "command_execution", "command" => "bundle exec rspec", "aggregated_output" => "secret output"})
    reporter.codex_event("type" => "item.completed", "item" => {"type" => "file_change", "changes" => [{"path" => "app/user.rb"}]})
    reporter.codex_event("type" => "item.completed", "item" => {"type" => "agent_message", "text" => "Adding coverage"})
    expect(output.string).to include("running command: bundle exec rspec", "changed app/user.rb", "Adding coverage")
    expect(output.string).not_to include("secret output")
  end

  it "ignores unsupported and malformed events" do
    [nil, [], {}, {"type" => "future.event"}, {"type" => "item.started", "item" => "bad"}].each { |event| reporter.codex_event(event) }
    expect(output.string).to be_empty
  end

  it "removes terminal escapes, collapses newlines, and bounds message size" do
    reporter.codex_event("type" => "item.completed", "item" => {"type" => "agent_message", "text" => "\e[31mhello\e[0m\nworld\r" + "a" * 1000})
    expect(output.string.lines.length).to eq(1)
    expect(output.string).to include("hello world")
    expect(output.string).not_to include("\e")
    expect(output.string.length).to be < 350
  end

  it "prints a heartbeat at most once per 30-second interval per command" do
    command = {"id" => "001", "argv" => ["/bin/codex"]}
    [1, 29, 30, 31, 59, 60].each { |elapsed| reporter.waiting(command, elapsed) }
    expect(output.string.lines.length).to eq(2)
    expect(output.string).to include("codex (30s elapsed)", "codex (60s elapsed)")
  end

  it "does not fail execution when stderr is closed" do
    output.close
    expect { reporter.event("type" => "run_transition", "state" => "preparing") }.not_to raise_error
  end

  it "shows verification outcomes and the repair budget" do
    reporter.event("type" => "verification_check", "name" => "specs", "state" => "failed", "attempt" => 0)
    reporter.event("type" => "run_transition", "state" => "repairing", "repair_attempts" => 1, "max_repairs" => 2)
    reporter.event("type" => "run_transition", "state" => "verified")
    expect(output.string).to include("Verification specs: failed", "Starting repair 1/2", "Verification passed")
  end
end
