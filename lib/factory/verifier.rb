module Factory
  class VerificationError < StandardError; end

  class Verifier
    def initialize(task:, store:, command_runner: CommandRunner.new(store: store))
      @checks, @store, @command_runner = task.to_h.fetch("verification"), store, command_runner
    end

    def verify(workspace, attempt:)
      results = []
      @store.record_verification(attempt, results)
      @checks.each do |check|
        @store.verification_event(check.fetch("name"), "running", attempt: attempt)
        result = @command_runner.call(check.fetch("command"), chdir: workspace.fetch("path"),
                                      timeout: check.fetch("timeout_seconds"))
        results << result.merge("name" => check.fetch("name"))
        @store.record_verification(attempt, results)
        @store.verification_event(check.fetch("name"), result.fetch("state"), attempt: attempt)
      end
      @store.record_verification(attempt, results, complete: true)
      results
    end
  end
end
