require "json"
require "fileutils"
require "securerandom"
require "time"
require "yaml"

module Factory
  # Single-writer storage. Recovery/resumption is intentionally a later increment.
  class RunStore
    attr_reader :directory

    def initialize(task:, root: nil, progress: nil)
      @progress = progress
      spec = task.to_h
      repository = File.realpath(spec.fetch("repository"))
      root ||= File.join(File.dirname(repository), ".factory", File.basename(repository))
      root = canonical_path(root)
      if root == repository || root.start_with?(repository + File::SEPARATOR)
        raise ArgumentError, "Run artifacts must be outside the target repository"
      end
      @directory = File.join(root, "#{spec.fetch('id')}-#{SecureRandom.uuid}")
      FileUtils.mkdir_p(directory, mode: 0o700)
      FileUtils.mkdir_p(File.join(directory, "commands"), mode: 0o700)
      @data = {"version" => 1, "run_id" => File.basename(directory), "state" => "pending",
               "created_at" => timestamp, "source_path" => task.source_path, "task" => spec, "commands" => []}
      File.write(File.join(directory, "task.yml"), YAML.dump(spec), perm: 0o600)
      record_event("run_created")
    end

    def start_command(argv:, chdir:, timeout:)
      id = format("%03d", @data.fetch("commands").length + 1)
      command_dir = File.join(directory, "commands", id)
      Dir.mkdir(command_dir, 0o700)
      command = {"id" => id, "argv" => argv.dup, "chdir" => chdir, "timeout_seconds" => timeout,
                 "state" => "running", "started_at" => timestamp,
                 "stdout_path" => File.join(command_dir, "stdout.log"),
                 "stderr_path" => File.join(command_dir, "stderr.log"),
                 "stdin_path" => File.join(command_dir, "stdin.txt")}
      @data.fetch("commands") << command
      record_event("command_started", "command_id" => id)
      copy(command)
    end

    def finish_command(id, attributes)
      command = @data.fetch("commands").find { |entry| entry.fetch("id") == id }
      raise ArgumentError, "Unknown command: #{id}" unless command
      command.merge!(attributes).merge!("finished_at" => timestamp)
      record_event("command_finished", "command_id" => id, "state" => command.fetch("state"))
      copy(command)
    end

    def snapshot
      copy(@data)
    end

    def command_waiting(command, elapsed)
      @progress&.waiting(command, elapsed)
    end

    def codex_activity(line)
      @progress&.codex_event(JSON.parse(line))
    rescue JSON::ParserError
      # Live rendering is best effort; CodexAgent validates the complete log later.
      nil
    end

    def transition(state, attributes = {})
      allowed = {"pending" => %w[preparing], "preparing" => %w[prepared failed interrupted],
                 "prepared" => %w[preflighting implementing], "preflighting" => %w[implementing failed interrupted],
                 "implementing" => %w[implemented failed interrupted],
                 "implemented" => %w[verifying], "verifying" => %w[verified repairing failed interrupted],
                 "repairing" => %w[verifying failed interrupted], "verified" => %w[committing],
                 "committing" => %w[committed no_changes failed interrupted],
                 "committed" => %w[publishing], "publishing" => %w[awaiting_review failed interrupted]}
      unless allowed.fetch(@data.fetch("state"), []).include?(state)
        raise ArgumentError, "Invalid run transition: #{@data.fetch('state')} -> #{state}"
      end
      @data.merge!(copy(attributes)).merge!("state" => state)
      record_event("run_transition", {"state" => state}.merge(@data.slice("repair_attempts", "max_repairs")))
      snapshot
    end

    def record_workspace(workspace)
      @data["workspace"] = copy(workspace)
      record_event("workspace_recorded")
    end

    def record_commit(sha)
      @data["commit"] = sha
      record_event("commit_created", "commit" => sha)
    end

    def record_publication(attributes)
      @data["publication"] = (@data["publication"] || {}).merge(copy(attributes))
      record_event("publication_updated")
    end

    def record_agent(result, phase:, attempt:)
      @data["agent"] = copy(result)
      (@data["agent_attempts"] ||= []) << copy(result.merge("phase" => phase, "attempt" => attempt))
      record_event("agent_attempt_finished", "phase" => phase, "attempt" => attempt)
    end

    def record_verification(attempt, checks, complete: false)
      attempts = (@data["verification_attempts"] ||= [])
      entry = {"attempt" => attempt, "complete" => complete, "checks" => copy(checks),
               "success" => complete && checks.all? { |check| check.fetch("success") }}
      index = attempts.index { |previous| previous.fetch("attempt") == attempt }
      index ? attempts[index] = entry : attempts << entry
      record_event("verification_recorded", "attempt" => attempt)
    end

    def verification_event(name, state, attempt:)
      record_event("verification_check", "name" => name, "state" => state, "attempt" => attempt)
    end

    private

    def canonical_path(path)
      path = File.expand_path(path)
      return File.realpath(path) if File.exist?(path)
      File.join(canonical_path(File.dirname(path)), File.basename(path))
    end

    def copy(value)
      JSON.parse(JSON.generate(value))
    end

    def timestamp
      Time.now.utc.iso8601(6)
    end

    def record_event(type, attributes = {})
      event = {"type" => type, "at" => timestamp}.merge(attributes)
      File.open(File.join(directory, "events.jsonl"), "a", 0o600) { |file| file.puts JSON.generate(event) }
      temporary = File.join(directory, "result.json.tmp")
      File.open(temporary, "w", 0o600) do |file|
        file.write(JSON.pretty_generate(@data))
        file.flush
        file.fsync
      end
      File.rename(temporary, File.join(directory, "result.json"))
      @progress&.event(event)
    end
  end
end
