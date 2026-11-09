require "json"

module Factory
  class AgentError < StandardError; end

  class CodexAgent
    def initialize(task:, store:, command_runner: CommandRunner.new(store: store), executable: "codex")
      @task, @store, @command_runner, @executable = task.to_h, store, command_runner, executable
    end

    def implement(workspace)
      summary = File.join(@store.directory, "agent-summary.txt")
      # Precreate privately; Codex writes its final response outside the checkout.
      File.write(summary, "", perm: 0o600)
      result = @command_runner.call(
        [@executable, "exec", "--sandbox", "workspace-write", "--config", 'approval_policy="never"',
         "--json", "--color", "never", "--output-last-message", summary, "-"],
        chdir: workspace.fetch("path"), timeout: @task.fetch("limits").fetch("agent_timeout_seconds"), stdin: prompt,
        on_stdout_line: @store.method(:codex_activity))
      unless result.fetch("success")
        raise AgentError, "Codex command #{result.fetch('state')}; see #{result.fetch('stderr_path')}"
      end
      validate_events!(result.fetch("stdout_path"))
      raise AgentError, "Codex did not produce a final summary; see #{summary}" if File.read(summary).strip.empty?
      {"command_id" => result.fetch("id"), "summary_path" => summary,
       "events_path" => result.fetch("stdout_path"), "verification" => "pending"}
    end

    private

    def prompt
      <<~PROMPT
        Implement the task below in the current worktree. Follow the repository's AGENTS.md instructions.
        Work as a single coding agent. Keep changes focused on the task and add appropriate tests.
        The orchestrator owns Git and publication: do not commit, change branches, reset HEAD,
        push, merge, create pull requests, or modify another checkout or shared Git configuration.
        Do not weaken or remove checks to claim success. If blocked, explain the blocker in your summary.
        Summarize changes, checks you ran, and remaining issues. The orchestrator will independently verify later.

        Task specification (JSON):
        #{JSON.pretty_generate(@task)}
      PROMPT
    end

    def validate_events!(path)
      completed = false
      File.foreach(path) do |line|
        next if line.strip.empty?
        event = JSON.parse(line)
        raise AgentError, "Invalid Codex event; see #{path}" unless event.is_a?(Hash) && event["type"].is_a?(String)
        if %w[turn.failed error].include?(event["type"])
          raise AgentError, "Codex reported #{event['type']}; see #{path}"
        end
        completed = true if event["type"] == "turn.completed"
      end
      raise AgentError, "Codex exited without a completed turn; see #{path}" unless completed
    rescue JSON::ParserError
      raise AgentError, "Invalid Codex JSON event output; see #{path}"
    end
  end
end
