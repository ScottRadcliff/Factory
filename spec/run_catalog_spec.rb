require "spec_helper"

RSpec.describe Factory::RunCatalog do
  include_context "temporary Git repository"

  let(:store) { Factory::RunStore.new(task: task) }
  let(:catalog) { described_class.new(task: task) }

  def finished_run
    workspace = Factory::GitWorkspace.new(task: task, store: store).prepare
    store.transition("implementing")
    store.transition("implemented")
    workspace
  end

  def change_metadata
    path = File.join(store.directory, "result.json")
    data = JSON.parse(File.read(path))
    yield data
    File.write(path, JSON.pretty_generate(data))
  end

  it "lists status, Git state, and eligibility without modifying logs or Git" do
    workspace = finished_run
    before = File.binread(File.join(store.directory, "result.json"))
    files = Dir.children(store.directory).sort
    row = catalog.list.first
    expect(row).to include("state" => "implemented", "head" => workspace.fetch("base_sha"), "uncommitted_changes" => false, "eligible" => true)
    expect(File.binread(File.join(store.directory, "result.json"))).to eq(before)
    expect(Dir.children(store.directory).sort).to eq(files)
  end

  it "previews removals by default and never creates lock files during preview" do
    workspace = finished_run
    row = catalog.cleanup.first
    expect(row.fetch("action")).to eq("would_remove")
    expect(File.directory?(workspace.fetch("path"))).to be(true)
    expect(File.exist?(File.join(store.directory, "run.lock"))).to be(false)
  end

  it "removes only the worktree while retaining its branch, results, and command logs" do
    workspace = finished_run
    row = catalog.cleanup(dry_run: false).first
    expect(row.fetch("action")).to eq("removed")
    expect(File.exist?(workspace.fetch("path"))).to be(false)
    expect(git("rev-parse", workspace.fetch("branch"))).to eq(workspace.fetch("base_sha"))
    expect(File.directory?(File.join(store.directory, "commands"))).to be(true)
    data = JSON.parse(File.read(File.join(store.directory, "result.json")))
    expect(data.fetch("cleanup").fetch("state")).to eq("removed")
    expect(catalog.cleanup.first.fetch("action")).to eq("keep")
    expect(File.read(File.join(@repository, "app.txt"))).to eq("original\n")
  end

  ["staged", "unstaged", "untracked", "ignored"].each do |kind|
    it "preserves #{kind} work" do
      workspace = finished_run
      path = workspace.fetch("path")
      case kind
      when "staged", "unstaged"
        File.write(File.join(path, "app.txt"), "changed")
        Open3.capture3("git", "-C", path, "add", "app.txt") if kind == "staged"
      when "untracked"
        File.write(File.join(path, "notes.txt"), "keep")
      when "ignored"
        File.write(File.join(@repository, ".git", "info", "exclude"), "private.env\n")
        File.write(File.join(path, "private.env"), "keep")
      end
      row = catalog.cleanup(dry_run: false).first
      expect(row).to include("action" => "keep", "eligible" => false, "uncommitted_changes" => true)
      expect(File.directory?(path)).to be(true)
    end
  end

  it "preserves clean but unpublished commits" do
    workspace = finished_run
    _, _, status = Open3.capture3("git", "-C", workspace.fetch("path"), "commit", "--allow-empty", "-m", "Unpublished")
    expect(status.success?).to be(true)
    expect(catalog.cleanup(dry_run: false).first.fetch("reason")).to include("Unpublished")
    expect(File.directory?(workspace.fetch("path"))).to be(true)
  end

  it "preserves active, prepared, and Git-locked worktrees" do
    workspace = Factory::GitWorkspace.new(task: task, store: store).prepare
    expect(catalog.cleanup(dry_run: false).first.fetch("reason")).to include("prepared")
    store.transition("implementing")
    expect(catalog.cleanup.first.fetch("eligible")).to be(false)
    store.transition("implemented")
    git("worktree", "lock", workspace.fetch("path"))
    expect(catalog.cleanup(dry_run: false).first.fetch("reason")).to include("locked")
  end

  it "preserves even terminal runs while another process holds their run lock" do
    workspace = finished_run
    store.with_lock do
      expect(catalog.cleanup(dry_run: false).first.fetch("reason")).to include("in use")
    end
    expect(File.directory?(workspace.fetch("path"))).to be(true)
  end

  it "rejects tampered workspace paths, metadata, and symlinks" do
    workspace = finished_run
    original = File.read(File.join(store.directory, "result.json"))
    change_metadata { |data| data["workspace"]["path"] = @repository }
    expect(catalog.cleanup(dry_run: false).first.fetch("reason")).to include("does not match")
    File.write(File.join(store.directory, "result.json"), original)
    link = File.join(File.dirname(store.directory), "linked-run")
    File.symlink(store.directory, link)
    expect(catalog.cleanup(dry_run: false, run_id: "linked-run").first.fetch("reason")).to include("symlink")
    expect(File.directory?(workspace.fetch("path"))).to be(true)
  end

  it "preserves malformed records without aborting the whole listing" do
    finished_run
    File.write(File.join(store.directory, "result.json"), "broken json")
    expect(catalog.cleanup(dry_run: false).first.fetch("eligible")).to be(false)
  end

  it "preserves symlinked worktrees and log artifacts" do
    workspace = finished_run
    path = workspace.fetch("path")
    moved = File.join(store.directory, "moved-worktree")
    File.rename(path, moved)
    File.symlink(moved, path)
    expect(catalog.cleanup(dry_run: false).first.fetch("reason")).to include("symlink")
    expect(File.directory?(moved)).to be(true)
  end

  it "never forces removal if files change after inspection" do
    workspace = finished_run
    real_probe = Factory::GitProbe.new
    probe = instance_double(Factory::GitProbe)
    allow(probe).to receive(:call) do |arguments, directory:|
      output = real_probe.call(arguments, directory: directory)
      File.write(File.join(workspace.fetch("path"), "app.txt"), "new work") if arguments.first == "status"
      output
    end
    row = described_class.new(task: task, probe: probe).cleanup(dry_run: false).first
    expect(row.fetch("action")).to eq("error")
    expect(File.read(File.join(workspace.fetch("path"), "app.txt"))).to eq("new work")
    data = JSON.parse(File.read(File.join(store.directory, "result.json")))
    expect(data.fetch("cleanup").fetch("state")).to eq("failed")
    expect(data.fetch("commands").last.fetch("argv")).not_to include("--force")
  end

  it "only cleans a selected run when an ID is supplied" do
    workspace = finished_run
    expect(catalog.cleanup(run_id: store.snapshot.fetch("run_id")).length).to eq(1)
    expect { catalog.cleanup(run_id: "missing") }.to raise_error(Factory::RunCatalogError, /not found/)
    expect { catalog.cleanup(run_id: "../escape") }.to raise_error(Factory::RunCatalogError, /Invalid run ID/)
    expect(File.directory?(workspace.fetch("path"))).to be(true)
  end

  it "requires fresh remote proof for a recorded published commit" do
    workspace = finished_run
    path = workspace.fetch("path")
    _, _, status = Open3.capture3("git", "-C", path, "commit", "--allow-empty", "-m", "Published")
    expect(status.success?).to be(true)
    sha, = Open3.capture3("git", "-C", path, "rev-parse", "HEAD")
    sha = sha.strip
    add_bare_remote
    git("push", "origin", workspace.fetch("branch"))
    change_metadata do |data|
      data["commit"] = sha
      data["publication"] = {"pushed" => true, "pushed_commit" => sha, "push_url" => @bare_remote,
                             "pull_request" => "https://github.com/factory/example/pull/42"}
    end
    expect(catalog.list.first).to include("requires_remote_confirmation" => true, "pull_request" => "https://github.com/factory/example/pull/42")
    expect(catalog.cleanup.first.fetch("action")).to eq("would_remove")
    Open3.capture3("git", "--git-dir", @bare_remote, "update-ref", "refs/heads/#{workspace.fetch('branch')}", workspace.fetch("base_sha"))
    expect(catalog.cleanup(dry_run: false).first.fetch("eligible")).to be(false)
    expect(File.directory?(path)).to be(true)
    git("push", "origin", workspace.fetch("branch"))
    expect(catalog.cleanup(dry_run: false).first.fetch("action")).to eq("removed")
  end
end
