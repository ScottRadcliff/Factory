module Factory
  class Runner
    def initialize(task:, store:, agent: CodexAgent.new(task: task, store: store))
      @store, @agent = store, agent
      @workspace = GitWorkspace.new(task: task, store: store)
    end

    def run
      workspace = @workspace.prepare
      @store.transition("implementing")
      begin
        agent_result = @agent.implement(workspace)
        @workspace.verify_identity(workspace)
        @store.transition("implemented", "agent" => agent_result)
      rescue Interrupt
        @store.transition("interrupted", "failed_stage" => "implementing")
        raise
      rescue AgentError, WorkspaceError, SystemCallError => e
        @store.transition("failed", "failed_stage" => "implementing", "error" => e.message)
        raise AgentError, "#{e.message}; results: #{File.join(@store.directory, 'result.json')}"
      end
    end
  end
end
