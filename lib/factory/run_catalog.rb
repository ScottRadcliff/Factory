require "tempfile"

module Factory
  class RunCatalogError < StandardError; end

  # Inspects local Git state without writing to the index or the run's logs.
  class GitProbe
    def call(arguments, directory:, timeout: 10)
      pid = status = nil
      Tempfile.create("factory-inspect-out") do |out|
        Tempfile.create("factory-inspect-err") do |err|
          begin
            pid = Process.spawn("git", "--no-optional-locks", "-c", "core.fsmonitor=false", "-C", directory,
                                *arguments, in: File::NULL, out: out, err: err, pgroup: true)
            started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            loop do
              waited, status = Process.waitpid2(pid, Process::WNOHANG)
              break if waited
              raise RunCatalogError, "Git inspection timed out; preserved worktree" if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started >= timeout
              sleep 0.02
            end
            raise RunCatalogError, "Git inspection failed (#{arguments.first}, exit #{status.exitstatus}); preserved worktree" unless status.success?
            raise RunCatalogError, "Git output too large to inspect safely" if out.size > 16 * 1024 * 1024
            out.rewind
            out.read
          ensure
            if pid && !status
              begin
                Process.kill("KILL", -pid)
              rescue Errno::ESRCH
                nil
              end
              Process.waitpid2(pid) rescue Errno::ECHILD
            end
          end
        end
      end
    end
  end

  class RunCatalog
    TERMINAL_STATES = %w[failed interrupted implemented verified committed awaiting_review no_changes].freeze

    def initialize(task:, root: nil, probe: GitProbe.new)
      @repository = File.realpath(task.to_h.fetch("repository"))
      @root = File.expand_path(root || RunStore.default_root(@repository))
      @root = File.realpath(@root) if File.exist?(@root)
      @probe = probe
      if @root == @repository || @root.start_with?(@repository + File::SEPARATOR)
        raise RunCatalogError, "Artifact root must be outside the target repository"
      end
    end

    def list
      scan
    end

    def cleanup(dry_run: true, run_id: nil)
      if run_id && !run_id.match?(/\A[a-z0-9][a-z0-9-]*\z/)
        raise RunCatalogError, "Invalid run ID"
      end
      rows = scan(cleanup: true, apply: !dry_run, run_id: run_id)
      raise RunCatalogError, "Run not found: #{run_id}" if run_id && rows.empty?
      rows
    end

    private

    def scan(cleanup: false, apply: false, run_id: nil)
      return [] unless File.directory?(@root)
      Dir.children(@root).sort.filter_map do |name|
        next if run_id && name != run_id
        directory = File.join(@root, name)
        next unless File.directory?(directory) || File.symlink?(directory)
        row = {"run_id" => name, "result_path" => File.join(directory, "result.json"), "action" => "keep"}
        begin
          raise RunCatalogError, "Run directory must not be a symlink" if File.symlink?(directory)
          with_lock(directory, create: apply) do
            %w[commands events.jsonl result.json.tmp].each do |entry|
              raise RunCatalogError, "Run artifacts must not be symlinks" if File.symlink?(File.join(directory, entry))
            end
            path = row.fetch("result_path")
            raise RunCatalogError, "Result file must not be a symlink" if File.symlink?(path)
            raise RunCatalogError, "Result file too large to inspect safely" if File.size(path) > 16 * 1024 * 1024
            data = JSON.parse(File.read(path))
            inspect_run(directory, data, row)
            if cleanup && row["eligible"]
              confirm_remote!(data, row) if row["requires_remote_confirmation"]
              if apply
                remove(directory, data, row)
              else
                row["action"] = "would_remove"
              end
            end
          end
        rescue RunCatalogError, SystemCallError, JSON::ParserError, KeyError, TypeError, ArgumentError => e
          row.merge!("eligible" => false, "reason" => e.message)
        end
        row
      end
    end

    def with_lock(directory, create:)
      path = File.join(directory, "run.lock")
      raise RunCatalogError, "Run lock must not be a symlink" if File.symlink?(path)
      return yield unless create || File.exist?(path)
      File.open(path, create ? File::RDWR | File::CREAT : File::RDONLY, 0o600) do |file|
        raise RunCatalogError, "Run is in use; preserved worktree" unless file.flock(File::LOCK_EX | File::LOCK_NB)
        yield
      end
    end

    def inspect_run(directory, data, row)
      pattern = /\A[a-z0-9][a-z0-9-]{0,63}-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
      unless data.is_a?(Hash) && data["version"].is_a?(Integer) && data["version"] == 1 &&
             data["run_id"] == File.basename(directory) && pattern.match?(data["run_id"])
        raise RunCatalogError, "Invalid run metadata"
      end
      task = data.fetch("task")
      raise RunCatalogError, "Invalid task or command metadata" unless task.is_a?(Hash) && data["commands"].is_a?(Array)
      raise RunCatalogError, "Run belongs to another repository" unless File.realpath(task.fetch("repository")) == @repository
      row.merge!(data.slice("state", "commit", "cleanup"))
      publication = data.fetch("publication", {})
      raise RunCatalogError, "Invalid publication metadata" unless publication.is_a?(Hash)
      row["pull_request"] = publication["pull_request"]
      workspace = data["workspace"]
      unless workspace
        row.merge!("eligible" => false, "reason" => "No worktree recorded")
        return
      end
      raise RunCatalogError, "Invalid workspace metadata" unless workspace.is_a?(Hash)
      expected = File.join(directory, "worktree")
      unless File.expand_path(workspace.fetch("path")) == expected && File.realpath(workspace.fetch("repository")) == @repository
        raise RunCatalogError, "Workspace path or repository does not match this run"
      end
      path = workspace.fetch("path")
      row.merge!("worktree" => path, "branch" => workspace.fetch("branch"))
      raise RunCatalogError, "Worktree must not be a symlink" if File.symlink?(path)
      unless File.directory?(path)
        row.merge!("eligible" => false, "reason" => "Worktree already removed or missing")
        return
      end
      unless TERMINAL_STATES.include?(data["state"])
        row.merge!("eligible" => false, "reason" => "Run is active, unfinished, or intentionally prepared")
        return
      end
      registry = git(%w[worktree list --porcelain -z]).split("\0\0").map { |block| block.split("\0") }
      entry = registry.find { |fields| fields.include?("worktree #{path}") }
      raise RunCatalogError, "Worktree is not registered in this repository" unless entry
      raise RunCatalogError, "Git worktree is locked; preserved worktree" if entry.any? { |field| field == "locked" || field.start_with?("locked ") }
      top = File.realpath(git(%w[rev-parse --show-toplevel], directory: path).strip)
      raise RunCatalogError, "Worktree root mismatch" unless top == path
      common = File.realpath(git(%w[rev-parse --path-format=absolute --git-common-dir], directory: path).strip)
      raise RunCatalogError, "Worktree Git repository mismatch" unless common == File.realpath(git(%w[rev-parse --path-format=absolute --git-common-dir]).strip)
      branch = git(%w[symbolic-ref --short HEAD], directory: path).strip
      raise RunCatalogError, "Worktree branch changed; preserved worktree" unless branch == workspace.fetch("branch") && branch == "factory/#{data.fetch('run_id')}"
      row["head"] = git(%w[rev-parse HEAD], directory: path).strip
      row["uncommitted_changes"] = !git(%w[status --porcelain --untracked-files=all --ignored], directory: path).empty?
      if row["uncommitted_changes"]
        row.merge!("eligible" => false, "reason" => "Uncommitted, untracked, or ignored files are present")
      elsif row["head"] == workspace.fetch("base_sha")
        row.merge!("eligible" => true, "reason" => "Clean worktree at its original base commit")
      elsif publication["pushed"] == true && publication["pushed_commit"] == row["head"] && data["commit"] == row["head"]
        row.merge!("eligible" => true, "requires_remote_confirmation" => true, "reason" => "Clean recorded published commit; cleanup will confirm remote branch")
      else
        row.merge!("eligible" => false, "reason" => "Unpublished or unexpected commits; preserved worktree")
      end
    end

    def confirm_remote!(data, row)
      publication = data.fetch("publication")
      url = publication.fetch("push_url")
      raise RunCatalogError, "Missing publication target" unless url.is_a?(String) && !url.empty? && !url.start_with?("-")
      remote = git(["ls-remote", "--exit-code", url, "refs/heads/#{row.fetch('branch')}"])
      sha, ref = remote.strip.split(/\s+/)
      unless sha == row.fetch("head") && ref == "refs/heads/#{row.fetch('branch')}"
        raise RunCatalogError, "Remote branch does not match the recorded commit; preserved worktree"
      end
    end

    def remove(directory, data, row)
      store = RunStore.open(directory)
      result = CommandRunner.new(store: store).call(["git", "worktree", "remove", "--", row.fetch("worktree")], chdir: @repository, timeout: 60)
      attributes = {"state" => result.fetch("success") ? "removed" : "failed", "at" => Time.now.utc.iso8601,
                    "head" => row.fetch("head"), "command_id" => result.fetch("id")}
      store.record_cleanup(attributes)
      if result.fetch("success")
        row.merge!("action" => "removed", "eligible" => false, "reason" => "Worktree removed; branch and logs retained")
      else
        row.merge!("action" => "error", "eligible" => false, "reason" => "Git refused worktree removal; see #{result.fetch('stderr_path')}")
      end
    end

    def git(arguments, directory: @repository)
      @probe.call(arguments, directory: directory)
    end
  end
end
