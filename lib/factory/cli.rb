require "json"
require "optparse"

module Factory
  class CLI
    USAGE = "Usage: factory <validate|prepare|implement|run> TASK.yml\n       factory submit [--no-publish] [--remote NAME] TASK.yml".freeze

    def self.run(argv, out: $stdout, err: $stderr)
      if argv == ["--help"] || argv == ["-h"]
        out.puts USAGE
        return 0
      end
      args = argv.dup
      action = args.shift
      options = {publish: true, remote: "origin"}
      if action == "submit"
        OptionParser.new do |opts|
          opts.on("--no-publish", "Commit verified changes locally without GitHub") { options[:publish] = false }
          opts.on("--remote NAME", "Git remote to publish to (default: origin)") { |value| options[:remote] = value }
        end.parse!(args)
      end
      unless args.length == 1 && %w[validate prepare implement run submit].include?(action)
        err.puts USAGE
        return 2
      end

      task = TaskSpec.load(args.first)
      if action == "validate"
        out.puts JSON.pretty_generate({"valid" => true, "source_path" => task.source_path, "task" => task.to_h})
      else
        store = RunStore.new(task: task, progress: ProgressReporter.new(io: err))
        if action == "prepare"
          GitWorkspace.new(task: task, store: store).prepare
        else
          err.puts "Implementing task; results and logs: #{store.directory}"
          Runner.new(task: task, store: store).run(verify: %w[run submit].include?(action),
                                                commit: action == "submit", publish: action == "submit" && options[:publish],
                                                remote: options[:remote])
        end
        result = store.snapshot.slice("state", "workspace", "agent", "verification", "verification_attempts", "repair_attempts", "commit", "publication")
        out.puts JSON.pretty_generate(result.merge("result_path" => File.join(store.directory, "result.json")))
      end
      0
    rescue OptionParser::ParseError => e
      err.puts "#{e.message}\n#{USAGE}"
      2
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
    rescue PublicationError => e
      err.puts "Submission failed: #{e.message}"
      1
    rescue Interrupt
      err.puts "Task execution interrupted; retained artifacts: #{store&.directory}"
      130
    end
  end
end
