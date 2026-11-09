module Factory
  class Runner
    def initialize(task:, store:, agent: CodexAgent.new(task: task, store: store), verifier: Verifier.new(task: task, store: store), publisher: GitHubPublisher.new(task: task, store: store))
      @store, @agent, @verifier = store, agent, verifier
      @max_repairs = task.to_h.fetch("limits").fetch("max_repairs")
      @publisher = publisher
      @workspace = GitWorkspace.new(task: task, store: store)
    end

    def run(verify: false, commit: false, publish: false, remote: "origin")
      raise ArgumentError, "Commit requires verification; publication requires a commit" if (commit && !verify) || (publish && !commit)
      workspace = @workspace.prepare
      begin
        if publish
          @store.transition("preflighting")
          target = @publisher.preflight(workspace, remote: remote)
        end
        @store.transition("implementing")
        agent_result = @agent.implement(workspace)
        @store.record_agent(agent_result, phase: "implementing", attempt: 0)
        @workspace.verify_identity(workspace)
        @store.transition("implemented")
        verify_and_repair(workspace) if verify
        if commit
          @store.transition("committing")
          sha = @workspace.commit_verified(workspace)
          return @store.transition("no_changes") unless sha
          @store.transition("committed")
          if publish
            @store.transition("publishing")
            @publisher.publish(workspace, target: target)
            @store.transition("awaiting_review")
          end
        end
        @store.snapshot
      rescue Interrupt
        @store.transition("interrupted", "failed_stage" => @store.snapshot.fetch("state"))
        raise
      rescue AgentError, WorkspaceError, VerificationError, PublicationError, SystemCallError => e
        stage = @store.snapshot.fetch("state")
        @store.transition("failed", "failed_stage" => stage, "error" => e.message)
        if %w[preflighting committing publishing].include?(stage)
          raise PublicationError, "#{e.message}; results: #{File.join(@store.directory, 'result.json')}"
        end
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
