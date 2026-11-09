require "time"

module Factory
  class ProgressReporter
    STATES = {"preparing" => "Preparing worktree…", "prepared" => "Worktree prepared",
              "implementing" => "Implementing task with Codex…",
              "implemented" => "Implementation finished; verification pending",
              "verifying" => "Running independent verification…", "repairing" => "Repairing failed checks…",
              "verified" => "Verification passed; changes retained for review",
              "failed" => "Run failed; inspect retained logs", "interrupted" => "Run interrupted"}.freeze

    def initialize(io: $stderr, clock: -> { Time.now })
      @io, @clock = io, clock
      @heartbeat = {}
    end

    def event(event)
      if event["type"] == "run_transition"
        if event["state"] == "repairing"
          write("Starting repair #{event['repair_attempts']}/#{event['max_repairs']}…")
        else
          write(STATES[event["state"]])
        end
      elsif event["type"] == "verification_check"
        write("Verification #{event['name']}: #{event['state']} (attempt #{event['attempt']})")
      end
    end

    def waiting(command, elapsed)
      bucket = (elapsed / 30).floor
      return if bucket.zero? || @heartbeat[command.fetch("id")] == bucket
      @heartbeat[command.fetch("id")] = bucket
      write("Still running: #{File.basename(command.fetch('argv').first)} (#{elapsed.to_i}s elapsed)")
    end

    def codex_event(event)
      return unless event.is_a?(Hash)
      item = event["item"]
      case event["type"]
      when "turn.started" then write("Codex: working…")
      when "turn.completed" then write("Codex: turn completed; checking Git state…")
      when "turn.failed", "error" then write("Codex: reported an error; see event log")
      when "item.started", "item.completed"
        return unless item.is_a?(Hash)
        case item["type"]
        when "command_execution"
          verb = event["type"] == "item.started" ? "running" : "finished"
          write("Codex: #{verb} command: #{item['command']}")
        when "file_change"
          paths = Array(item["changes"]).filter_map { |change| change["path"] if change.is_a?(Hash) }
          write("Codex: changed #{paths.first(5).join(', ')}") unless paths.empty?
        when "agent_message"
          write("Codex: #{item['text']}") if event["type"] == "item.completed"
        end
      end
    end

    private

    def write(message)
      return unless message
      # Activity is untrusted text: keep each update on one bounded terminal line.
      clean = message.encode("UTF-8", invalid: :replace, undef: :replace)
                     .gsub(/\e\[[0-?]*[ -\/]*[@-~]/, "")
                     .gsub(/[[:cntrl:]]/, " ").gsub(/\s+/, " ").strip
      @io.puts "[#{@clock.call.iso8601}] #{clean[0, 300]}"
      @io.flush
    rescue IOError, SystemCallError
      # A closed progress stream must not stop task execution or logging.
      nil
    end
  end
end
