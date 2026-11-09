module Factory
  class CommandRunner
    def initialize(store:)
      @store = store
    end

    def call(argv, chdir:, timeout:, stdin: "", on_stdout_line: nil)
      validate!(argv, timeout, stdin)
      command = @store.start_command(argv: argv, chdir: File.expand_path(chdir), timeout: timeout)
      started = monotonic_time
      status = nil
      timed_out = false
      state = "failed"
      error = nil
      pid = nil
      tail = nil
      begin
        File.write(command.fetch("stdin_path"), stdin, perm: 0o600)
        File.open(command.fetch("stdin_path"), "rb") do |input|
          File.open(command.fetch("stdout_path"), "wb", 0o600) do |out|
            File.open(command.fetch("stderr_path"), "wb", 0o600) do |err|
              # Explicit executable/argv form prevents Ruby's single-string shell fallback.
              pid = Process.spawn([argv.first, argv.first], *argv.drop(1),
                                  chdir: command.fetch("chdir"), in: input, out: out, err: err, pgroup: true)
              tail = OutputTail.new(command.fetch("stdout_path"), on_stdout_line) if on_stdout_line
              loop do
                tail&.drain
                waited, status = Process.waitpid2(pid, Process::WNOHANG)
                break if waited
                @store.command_waiting(command, monotonic_time - started)
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
        if tail
          tail.drain until tail.eof?
          tail.close
        end
        result = @store.finish_command(command.fetch("id"),
          "state" => state, "success" => state == "succeeded", "timed_out" => timed_out,
          "exit_code" => status&.exitstatus, "signal" => status&.termsig,
          "duration_seconds" => (monotonic_time - started).round(6), "error" => error)
      end
      result
    end

    private

    # Read the durable output file without pipes or buffering unlimited lines.
    # Oversized lines are skipped for live display; the raw log remains intact.
    class OutputTail
      def initialize(path, callback)
        @file, @callback = File.open(path, "rb"), callback
        @buffer = "".b
        @discarding = false
      end

      def drain
        4.times do
          chunk = @file.read(16_384)
          break unless chunk
          chunk.each_line do |fragment|
            @buffer << fragment unless @discarding
            if @buffer.bytesize > 65_536
              @buffer.clear
              @discarding = true
            end
            next unless fragment.end_with?("\n")
            notify(@buffer) unless @discarding
            @buffer = "".b
            @discarding = false
          end
        end
      end

      def eof?
        @file.eof?
      end

      def close
        notify(@buffer) unless @discarding || @buffer.empty?
        @file.close
      end

      def notify(line)
        @callback.call(line.force_encoding("UTF-8").scrub)
      rescue StandardError
        # Progress observers must not affect process execution or its raw output.
        nil
      end
    end

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
