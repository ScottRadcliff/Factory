require "spec_helper"

RSpec.describe Factory::RunStore do
  around do |example|
    Dir.mktmpdir("factory-store") do |directory|
      @root = directory
      example.run
    end
  end

  let(:task) { Factory::TaskSpec.load(File.expand_path("fixtures/task.yml", __dir__)) }
  let(:store) { described_class.new(task: task, root: @root) }

  it "creates unique private run directories and saves the effective task" do
    other = described_class.new(task: task, root: @root)
    expect(store.directory).not_to eq(other.directory)
    expect(File.stat(store.directory).mode & 0o777).to eq(0o700)
    expect(YAML.safe_load_file(File.join(store.directory, "task.yml"))).to eq(task.to_h)
    expect(JSON.parse(File.read(File.join(store.directory, "result.json")))).to include("state" => "pending", "task" => task.to_h)
  end

  it "persists command records and ordered events with an atomic snapshot" do
    command = store.start_command(argv: ["ruby", "--version"], chdir: @root, timeout: 1)
    store.finish_command(command.fetch("id"), "state" => "succeeded", "exit_code" => 0)
    snapshot = JSON.parse(File.read(File.join(store.directory, "result.json")))
    expect(snapshot.fetch("commands").first).to include("state" => "succeeded", "exit_code" => 0)
    events = File.readlines(File.join(store.directory, "events.jsonl")).map { |line| JSON.parse(line).fetch("type") }
    expect(events).to eq(%w[run_created command_started command_finished])
    expect(File.exist?(File.join(store.directory, "result.json.tmp"))).to be(false)
    expect(File.stat(File.join(store.directory, "result.json")).mode & 0o777).to eq(0o600)
  end

  it "returns snapshots that cannot mutate stored state" do
    store.snapshot["task"]["title"] = "changed"
    expect(store.snapshot["task"]["title"]).to eq(task.to_h["title"])
  end

  it "rejects artifact roots inside the target repository" do
    root = File.join(task.to_h.fetch("repository"), ".factory", "runs")
    expect { described_class.new(task: task, root: root) }.to raise_error(ArgumentError, /outside/)
  end

  it "rejects symlinks that lead back inside the target repository" do
    link = File.join(@root, "checkout")
    File.symlink(task.to_h.fetch("repository"), link)
    expect { described_class.new(task: task, root: File.join(link, "logs")) }.to raise_error(ArgumentError, /outside/)
  end
end
