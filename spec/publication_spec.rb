require "spec_helper"

RSpec.describe "Verified submission" do
  include_context "temporary Git repository"

  before do
    data = YAML.safe_load_file(@task_path)
    data["verification"] = [{"name" => "specs", "command" => [RbConfig.ruby, "-e", "exit 0"], "timeout_seconds" => 5}]
    File.write(@task_path, YAML.dump(data))
  end

  let(:store) { Factory::RunStore.new(task: task) }

  def runner(agent_body: nil, create_exit: 0, existing: false)
    agent = Factory::CodexAgent.new(task: task, store: store, executable: fake_codex(agent_body))
    publisher = Factory::GitHubPublisher.new(task: task, store: store, executable: fake_github(create_exit: create_exit, existing: existing))
    Factory::Runner.new(task: task, store: store, agent: agent, publisher: publisher)
  end

  def calls
    path = File.join(@directory, "gh-calls.jsonl")
    File.exist?(path) ? File.readlines(path).map { |line| JSON.parse(line) } : []
  end

  def remote_sha(branch)
    out, _, status = Open3.capture3("git", "--git-dir", @bare_remote, "rev-parse", "refs/heads/#{branch}")
    raise "Missing remote branch" unless status.success?
    out.strip
  end

  it "commits verified changes locally without needing a remote or invoking GitHub" do
    result = runner.run(verify: true, commit: true)
    expect(result.fetch("state")).to eq("committed")
    expect(result.fetch("commit")).to eq(git("rev-parse", result.fetch("workspace").fetch("branch")))
    expect(git("status", "--porcelain")).to be_empty
    expect(git("symbolic-ref", "--short", "HEAD")).to eq("main")
    expect(calls).to be_empty
  end

  it "pushes the exact verified commit and creates a draft PR in the selected repository" do
    add_bare_remote
    result = runner.run(verify: true, commit: true, publish: true)
    expect(result).to include("state" => "awaiting_review", "verification" => "passed")
    expect(result.fetch("publication")).to include("pushed" => true, "pull_request" => "https://github.com/factory/example/pull/42")
    expect(remote_sha(result.fetch("workspace").fetch("branch"))).to eq(result.fetch("commit"))
    create = calls.find { |args| args.first(2) == %w[pr create] }
    expect(create).to include("--draft", "--base", "main", "--head", result.fetch("workspace").fetch("branch"))
    expect(File.read(File.join(@directory, "published-body.md"))).to include("Acceptance criteria:", "specs: passed", "Human review and approval")
    expect(calls.flatten).not_to include("merge")
    expect(git("status", "--porcelain")).to be_empty
  end

  it "supports a remote name other than origin" do
    add_bare_remote
    git("remote", "rename", "origin", "gh")
    result = runner.run(verify: true, commit: true, publish: true, remote: "gh")
    expect(result.fetch("publication").fetch("remote")).to eq("gh")
    expect(result.fetch("state")).to eq("awaiting_review")
  end

  it "stops before Codex if the selected remote does not exist" do
    expect { runner.run(verify: true, commit: true, publish: true) }.to raise_error(Factory::PublicationError)
    expect(store.snapshot).to include("state" => "failed", "failed_stage" => "preflighting")
    expect(store.snapshot.fetch("commands").none? { |command| command.fetch("argv").first.end_with?("/codex") }).to be(true)
    expect(store.snapshot).not_to have_key("workspace")
    expect(git("worktree", "list", "--porcelain").scan(/^worktree /).length).to eq(1)
  end

  it "requires the base branch to exist on the selected remote before invoking Codex" do
    add_bare_remote
    _, stderr, status = Open3.capture3("git", "--git-dir", @bare_remote, "update-ref", "-d", "refs/heads/main")
    raise stderr unless status.success?
    expect { runner.run(verify: true, commit: true, publish: true) }.to raise_error(Factory::PublicationError)
    expect(store.snapshot.fetch("failed_stage")).to eq("preflighting")
    expect(store.snapshot.fetch("commands").none? { |command| command.fetch("argv").first.end_with?("/codex") }).to be(true)
  end

  it "rejects publication without verification and commit before creating a worktree" do
    expect { runner.run(publish: true) }.to raise_error(ArgumentError)
    expect(store.snapshot.fetch("state")).to eq("pending")
    expect(store.snapshot.fetch("commands")).to be_empty
  end

  it "does not commit or publish after failed verification" do
    add_bare_remote
    data = YAML.safe_load_file(@task_path)
    data["limits"] = {"max_repairs" => 0}
    data["verification"].first["command"] = [RbConfig.ruby, "-e", "exit 1"]
    File.write(@task_path, YAML.dump(data))
    expect { runner.run(verify: true, commit: true, publish: true) }.to raise_error(Factory::VerificationError)
    expect(store.snapshot).not_to have_key("commit")
    expect(calls.none? { |args| args.first == "pr" }).to be(true)
    expect(store.snapshot.fetch("commands").none? { |command| command.fetch("argv").first(2) == %w[git push] }).to be(true)
  end

  it "records no changes without creating an empty commit or PR" do
    body = 'File.write(ARGV.fetch(ARGV.index("--output-last-message") + 1), "No changes needed"); puts JSON.generate("type" => "turn.completed")'
    result = runner(agent_body: body).run(verify: true, commit: true)
    expect(result.fetch("state")).to eq("no_changes")
    expect(result).not_to have_key("commit")
    expect(calls).to be_empty
  end

  it "retains the commit and records a failed push without attempting a PR" do
    add_bare_remote
    hook = File.join(@bare_remote, "hooks", "pre-receive")
    File.write(hook, "#!/bin/sh\nexit 1\n")
    File.chmod(0o700, hook)
    expect { runner.run(verify: true, commit: true, publish: true) }.to raise_error(Factory::PublicationError)
    expect(store.snapshot).to include("state" => "failed", "failed_stage" => "publishing")
    expect(store.snapshot).to have_key("commit")
    expect(store.snapshot.fetch("publication").fetch("pushed")).to be(false)
    expect(calls.none? { |args| args.first == "pr" }).to be(true)
  end

  it "records a successful push even if PR creation fails" do
    add_bare_remote
    expect { runner(create_exit: 1).run(verify: true, commit: true, publish: true) }.to raise_error(Factory::PublicationError)
    result = store.snapshot
    expect(result).to include("state" => "failed", "failed_stage" => "publishing")
    expect(result.fetch("publication")).to include("pushed" => true, "pushed_commit" => result.fetch("commit"))
    expect(remote_sha(result.fetch("workspace").fetch("branch"))).to eq(result.fetch("commit"))
  end

  it "retains the push result if the PR lookup returns malformed data" do
    add_bare_remote
    job = runner
    executable = File.join(@directory, "gh")
    File.write(executable, File.read(executable).sub("puts JSON.generate([])", 'puts JSON.generate(["unexpected"])'))
    expect { job.run(verify: true, commit: true, publish: true) }.to raise_error(Factory::PublicationError, /Unexpected PR lookup/)
    expect(store.snapshot.fetch("publication").fetch("pushed")).to be(true)
    expect(store.snapshot.fetch("state")).to eq("failed")
  end

  it "reuses an open PR for the branch instead of creating a duplicate" do
    add_bare_remote
    result = runner(existing: true).run(verify: true, commit: true, publish: true)
    expect(result.fetch("state")).to eq("awaiting_review")
    expect(calls.none? { |args| args.first(2) == %w[pr create] }).to be(true)
  end

  it "does not publish when a commit hook changes the staged tree" do
    hook = File.join(@repository, ".git", "hooks", "pre-commit")
    File.write(hook, "#!/bin/sh\necho altered > app.txt\ngit add app.txt\n")
    File.chmod(0o700, hook)
    expect { runner.run(verify: true, commit: true) }.to raise_error(Factory::PublicationError, /Git state changed during commit/)
    expect(store.snapshot).to include("state" => "failed", "failed_stage" => "committing")
    expect(store.snapshot).to have_key("commit")
    expect(calls).to be_empty
  end

  it "retains staged changes if the commit is rejected by a hook" do
    hook = File.join(@repository, ".git", "hooks", "pre-commit")
    File.write(hook, "#!/bin/sh\nexit 1\n")
    File.chmod(0o700, hook)
    expect { runner.run(verify: true, commit: true) }.to raise_error(Factory::PublicationError)
    expect(store.snapshot).to include("state" => "failed", "failed_stage" => "committing")
    expect(store.snapshot).not_to have_key("commit")
  end
end
