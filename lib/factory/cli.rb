require "json"

module Factory
  class CLI
    USAGE = "Usage: factory <validate|prepare|implement|run> TASK.yml".freeze

    def self.run(argv, out: $stdout, err: $stderr)
      if argv == ["--help"] || argv == ["-h"]
        out.puts USAGE
        return 0
      end
      unless argv.length == 2 && %w[validate prepare implement run].include?(argv.first)
        err.puts USAGE
        return 2
      end

      task = TaskSpec.load(argv.last)
      if argv.first == "validate"
        out.puts JSON.pretty_generate({"valid" => true, "source_path" => task.source_path, "task" => task.to_h})
      else
        store = RunStore.new(task: task, progress: ProgressReporter.new(io: err))
        if argv.first == "prepare"
          GitWorkspace.new(task: task, store: store).prepare
        else
          err.puts "Implementing task; results and logs: #{store.directory}"
          Runner.new(task: task, store: store).run(verify: argv.first == "run")
        end
        result = store.snapshot.slice("state", "workspace", "agent", "verification", "verification_attempts", "repair_attempts")
        out.puts JSON.pretty_generate(result.merge("result_path" => File.join(store.directory, "result.json")))
      end
      0
    rescue InvalidTaskSpec => e
      err.puts "Invalid task specification: #{e.message}"
      1
    rescue WorkspaceError, SystemCallError => e
      err.puts "Cannot #{argv.first} workspace: #{e.message}"
      1
    rescue AgentError => e
      err.puts "Cannot implement task: #{e.message}"
      1
    rescue VerificationError => e
      err.puts "Verification failed: #{e.message}"
      1
    rescue Interrupt
      err.puts "Task execution interrupted; retained artifacts: #{store&.directory}"
      130
    end
  end
end
