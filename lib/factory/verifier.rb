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
        result = nil
        cleanup = nil
        begin
          command = expand(check.fetch("command"))
          result = @command_runner.call(command, chdir: workspace.fetch("path"), timeout: check.fetch("timeout_seconds"))
          results << result.merge("name" => check.fetch("name"))
        ensure
          if check["cleanup"]
            @store.verification_event(check.fetch("name"), "cleaning_up", attempt: attempt)
            cleanup = @command_runner.call(expand(check.fetch("cleanup")), chdir: workspace.fetch("path"),
                                          timeout: check.fetch("cleanup_timeout_seconds", 60))
            results.last["cleanup"] = cleanup if result
            # Interrupted checks have command records but no normal return value.
            unless result
              results << {"name" => check.fetch("name"), "state" => "interrupted", "success" => false, "cleanup" => cleanup}
            end
          end
          @store.record_verification(attempt, results)
        end
        if cleanup && !cleanup.fetch("success")
          raise VerificationError, "Verification cleanup failed for #{check.fetch('name')}; see #{cleanup.fetch('stderr_path')}"
        end
        @store.verification_event(check.fetch("name"), result.fetch("state"), attempt: attempt)
      end
      @store.record_verification(attempt, results, complete: true)
      results
    end

    private

    def expand(argv)
      run_id = @store.snapshot.fetch("run_id")
      argv.map { |argument| argument.gsub("{{run_id}}", run_id) }
    end
  end
end
