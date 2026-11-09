module Factory
  class CommandRunner
    def initialize(store:)
      @store = store
    end

    def call(argv, chdir:, timeout:, stdin: "")
      validate!(argv, timeout, stdin)
      command = @store.start_command(argv: argv, chdir: File.expand_path(chdir), timeout: timeout)
      started = monotonic_time
      status = nil
      timed_out = false
      state = "failed"
      error = nil
      pid = nil
      begin
        File.write(command.fetch("stdin_path"), stdin, perm: 0o600)
        File.open(command.fetch("stdin_path"), "rb") do |input|
          File.open(command.fetch("stdout_path"), "wb", 0o600) do |out|
            File.open(command.fetch("stderr_path"), "wb", 0o600) do |err|
              # Explicit executable/argv form prevents Ruby's single-string shell fallback.
              pid = Process.spawn([argv.first, argv.first], *argv.drop(1),
                                  chdir: command.fetch("chdir"), in: input, out: out, err: err, pgroup: true)
              loop do
                waited, status = Process.waitpid2(pid, Process::WNOHANG)
                break if waited
                if monotonic_time - started >= timeout
                  timed_out = true
                  break
                end
                sleep 0.02
              end
            end
          end
        end
        state = timed_out ? "timed_out" : (status.success? ? "succeeded" : "failed")
      rescue SystemCallError => e
        error = {"class" => e.class.name, "message" => e.message}
      rescue Interrupt
        state = "interrupted"
        raise
      ensure
        if pid
          cleanup_status = terminate_group(pid)
          status ||= cleanup_status
          _, status = Process.waitpid2(pid) unless status
        end
        result = @store.finish_command(command.fetch("id"),
          "state" => state, "success" => state == "succeeded", "timed_out" => timed_out,
          "exit_code" => status&.exitstatus, "signal" => status&.termsig,
          "duration_seconds" => (monotonic_time - started).round(6), "error" => error)
      end
      result
    end

    private

    def validate!(argv, timeout, stdin)
      unless argv.is_a?(Array) && !argv.empty? && argv.all? { |arg| arg.is_a?(String) && !arg.include?("\0") } && !argv.first.empty?
        raise ArgumentError, "argv must be a nonempty argument array without NUL bytes"
      end
      unless timeout.is_a?(Numeric) && timeout.finite? && timeout.positive?
        raise ArgumentError, "timeout must be a finite positive number"
      end
      raise ArgumentError, "stdin must be a string" unless stdin.is_a?(String)
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def terminate_group(pid)
      signal_group("TERM", pid)
      sleep 0.1
      # Reap an exited leader before signaling again. macOS may report EPERM
      # when a process group contains only an unreaped zombie.
      reaped = begin
        Process.waitpid2(pid, Process::WNOHANG)&.last
      rescue Errno::ECHILD
        nil
      end
      signal_group("KILL", pid)
      reaped
    end

    def signal_group(signal, pid)
      Process.kill(signal, -pid)
    rescue Errno::ESRCH
      # The process group has already exited.
    end
  end
end
