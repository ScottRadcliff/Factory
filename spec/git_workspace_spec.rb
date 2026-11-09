require "spec_helper"

RSpec.describe Factory::GitWorkspace do
  include_context "temporary Git repository"

  let(:store) { Factory::RunStore.new(task: task) }
  let(:workspace) { described_class.new(task: task, store: store) }

  it "creates a new branch and worktree at the exact base SHA and records it" do
    sha = git("rev-parse", "main")
    result = workspace.prepare
    expect(result).to include("base_sha" => sha, "base_branch" => "main")
    expect(File.read(File.join(result.fetch("path"), "app.txt"))).to eq("original\n")
    head, _, status = Open3.capture3("git", "-C", result.fetch("path"), "symbolic-ref", "--short", "HEAD")
    expect(status.success?).to be(true)
    expect(head.strip).to eq(result.fetch("branch"))
    expect(store.snapshot).to include("state" => "prepared", "workspace" => result)
    expect(store.snapshot.fetch("commands")).to all(include("success" => true))
  end

  it "preserves the original branch, HEAD, staged, unstaged, and untracked changes" do
    git("switch", "-c", "development")
    File.write(File.join(@repository, "app.txt"), "staged\n")
    git("add", "app.txt")
    File.write(File.join(@repository, "app.txt"), "unstaged\n")
    File.write(File.join(@repository, "untracked.txt"), "untracked\n")
    before = [git("rev-parse", "HEAD"), git("symbolic-ref", "HEAD"), git("status", "--porcelain"), git("diff"), git("diff", "--cached")]
    result = workspace.prepare
    expect([git("rev-parse", "HEAD"), git("symbolic-ref", "HEAD"), git("status", "--porcelain"), git("diff"), git("diff", "--cached")]).to eq(before)
    expect(File.read(File.join(result.fetch("path"), "app.txt"))).to eq("original\n")
    expect(File.exist?(File.join(result.fetch("path"), "untracked.txt"))).to be(false)
  end

  it "creates independent worktrees for repeated task runs" do
    first = workspace.prepare
    second_store = Factory::RunStore.new(task: task)
    second = described_class.new(task: task, store: second_store).prepare
    expect(second.fetch("branch")).not_to eq(first.fetch("branch"))
    expect(second.fetch("path")).not_to eq(first.fetch("path"))
  end

  it "fails for a missing local base branch and retains diagnostic logs" do
    git("branch", "-m", "different")
    expect { workspace.prepare }.to raise_error(Factory::WorkspaceError, /results:/)
    expect(store.snapshot).to include("state" => "failed", "failed_stage" => "preparing")
    expect(store.snapshot.fetch("commands").last.fetch("success")).to be(false)
    expect(git("branch", "--list", "factory/*")).to be_empty
  end

  it "rejects a repository subdirectory" do
    subdirectory = File.join(@repository, "subdirectory")
    Dir.mkdir(subdirectory)
    data = YAML.safe_load_file(@task_path).merge("repository" => subdirectory)
    File.write(@task_path, YAML.dump(data))
    expect { workspace.prepare }.to raise_error(Factory::WorkspaceError, /repository root/)
    expect(store.snapshot.fetch("state")).to eq("failed")
  end

  it "rejects an ordinary directory that is not a repository" do
    @repository = File.join(@directory, "not-git")
    Dir.mkdir(@repository)
    data = YAML.safe_load_file(@task_path).merge("repository" => @repository)
    File.write(@task_path, YAML.dump(data))
    expect { workspace.prepare }.to raise_error(Factory::WorkspaceError, /Git command failed/)
    expect(store.snapshot.fetch("state")).to eq("failed")
  end

  it "rejects invalid Git branch syntax before creating a worktree" do
    File.write(@task_path, YAML.dump(YAML.safe_load_file(@task_path).merge("base_branch" => "bad..branch")))
    expect { workspace.prepare }.to raise_error(Factory::WorkspaceError, /check-ref-format/)
    expect(File.exist?(File.join(store.directory, "worktree"))).to be(false)
  end

  it "preserves an existing branch on collision and records the intended workspace" do
    branch = "factory/#{store.snapshot.fetch('run_id')}"
    git("branch", branch)
    sha = git("rev-parse", branch)
    expect { workspace.prepare }.to raise_error(Factory::WorkspaceError, /worktree/)
    expect(git("rev-parse", branch)).to eq(sha)
    expect(store.snapshot.fetch("workspace").fetch("branch")).to eq(branch)
    expect(store.snapshot.fetch("state")).to eq("failed")
  end

  it "records interruption without deleting artifacts" do
    command = instance_double(Factory::CommandRunner)
    allow(command).to receive(:call).and_raise(Interrupt)
    expect { described_class.new(task: task, store: store, command_runner: command).prepare }.to raise_error(Interrupt)
    expect(store.snapshot).to include("state" => "interrupted", "failed_stage" => "preparing")
    expect(File.exist?(File.join(store.directory, "result.json"))).to be(true)
  end

  it "refuses to prepare an already prepared run again" do
    workspace.prepare
    expect { workspace.prepare }.to raise_error(ArgumentError, /Invalid run transition/)
    expect(store.snapshot.fetch("state")).to eq("prepared")
  end
end
