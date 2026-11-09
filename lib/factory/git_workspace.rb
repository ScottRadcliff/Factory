module Factory
  class WorkspaceError < StandardError; end

  class GitWorkspace
    def initialize(task:, store:, command_runner: CommandRunner.new(store: store))
      @task, @store, @command_runner = task.to_h, store, command_runner
      @repository = File.realpath(@task.fetch("repository"))
    end

    def prepare
      @store.transition("preparing")
      begin
        root = git("rev-parse", "--show-toplevel").strip
        unless File.realpath(root) == @repository
          raise WorkspaceError, "repository must point to the Git repository root"
        end
        base = @task.fetch("base_branch")
        ref = "refs/heads/#{base}"
        git("check-ref-format", ref)
        sha = git("rev-parse", "--verify", "--end-of-options", "#{ref}^{commit}").strip
        workspace = {"repository" => @repository, "base_branch" => base, "base_sha" => sha,
                     "branch" => "factory/#{@store.snapshot.fetch('run_id')}",
                     "path" => File.join(@store.directory, "worktree")}
        # Record intended paths before Git mutates anything, including partial failures.
        @store.record_workspace(workspace)
        git("worktree", "add", "--no-track", "-b", workspace.fetch("branch"), workspace.fetch("path"), sha)
        @store.transition("prepared")
        workspace
      rescue Interrupt
        @store.transition("interrupted", "failed_stage" => "preparing")
        raise
      rescue WorkspaceError, SystemCallError => e
        @store.transition("failed", "failed_stage" => "preparing", "error" => e.message)
        raise WorkspaceError, "#{e.message}; results: #{File.join(@store.directory, 'result.json')}"
      end
    end

    private

    def git(*arguments)
      result = @command_runner.call(["git", *arguments], chdir: @repository, timeout: 60)
      unless result.fetch("success")
        raise WorkspaceError, "Git command failed: #{arguments.inspect}; see #{result.fetch('stderr_path')}"
      end
      File.read(result.fetch("stdout_path"))
    end
  end
end
