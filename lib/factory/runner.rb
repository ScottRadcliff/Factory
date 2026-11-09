module Factory
  class Runner
    def initialize(task:, store:, agent: CodexAgent.new(task: task, store: store), verifier: Verifier.new(task: task, store: store))
      @store, @agent, @verifier = store, agent, verifier
      @max_repairs = task.to_h.fetch("limits").fetch("max_repairs")
      @workspace = GitWorkspace.new(task: task, store: store)
    end

    def run(verify: false)
      workspace = @workspace.prepare
      @store.transition("implementing")
      begin
        agent_result = @agent.implement(workspace)
        @store.record_agent(agent_result, phase: "implementing", attempt: 0)
        @workspace.verify_identity(workspace)
        @store.transition("implemented")
        verify ? verify_and_repair(workspace) : @store.snapshot
      rescue Interrupt
        @store.transition("interrupted", "failed_stage" => @store.snapshot.fetch("state"))
        raise
      rescue AgentError, WorkspaceError, VerificationError, SystemCallError => e
        @store.transition("failed", "failed_stage" => @store.snapshot.fetch("state"), "error" => e.message)
        if e.is_a?(VerificationError)
          raise VerificationError, "#{e.message}; results: #{File.join(@store.directory, 'result.json')}"
        end
        raise AgentError, "#{e.message}; results: #{File.join(@store.directory, 'result.json')}"
      end
    end

    private

    def verify_and_repair(workspace)
      repairs = 0
      loop do
        @store.transition("verifying", "repair_attempts" => repairs)
        checks = @verifier.verify(workspace, attempt: repairs)
        @workspace.verify_identity(workspace)
        if checks.all? { |check| check.fetch("success") }
          return @store.transition("verified", "verification" => "passed",
                                   "agent" => @store.snapshot.fetch("agent").merge("verification" => "passed"))
        end
        if checks.any? { |check| check["error"] }
          raise VerificationError, "Verification could not execute; inspect command errors before retrying"
        end
        if repairs >= @max_repairs
          raise VerificationError, "Verification failed; exhausted #{repairs} of #{@max_repairs} allowed repair attempts"
        end
        repairs += 1
        @store.transition("repairing", "repair_attempts" => repairs, "max_repairs" => @max_repairs)
        result = @agent.repair(workspace, checks: checks, attempt: repairs)
        @store.record_agent(result, phase: "repairing", attempt: repairs)
        @workspace.verify_identity(workspace)
      end
    end
  end
end
