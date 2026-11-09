require "json"
require "optparse"

module Factory
  class CLI
    USAGE = "Usage: factory <validate|prepare|implement|run> TASK.yml\n       factory submit [--no-publish] [--remote NAME] TASK.yml\n       factory runs [--root DIR] TASK.yml\n       factory cleanup [--dry-run|--apply] [--run ID] [--root DIR] TASK.yml".freeze

    def self.run(argv, out: $stdout, err: $stderr)
      if argv == ["--help"] || argv == ["-h"]
        out.puts USAGE
        return 0
      end
      args = argv.dup
      action = args.shift
      options = {publish: true, remote: "origin", dry_run: true, cleanup_modes: []}
      if action == "submit"
        OptionParser.new do |opts|
          opts.on("--no-publish", "Commit verified changes locally without GitHub") { options[:publish] = false }
          opts.on("--remote NAME", "Git remote to publish to (default: origin)") { |value| options[:remote] = value }
        end.parse!(args)
      end
      if %w[runs cleanup].include?(action)
        OptionParser.new do |opts|
          opts.on("--root DIR", "Custom artifact root") { |value| options[:root] = value }
          if action == "cleanup"
            opts.on("--dry-run", "Preview only (default)") { options[:cleanup_modes] << :preview }
            opts.on("--apply", "Remove eligible worktrees; keep branches and logs") { options[:cleanup_modes] << :apply }
            opts.on("--run ID", "Only inspect or clean this run") { |value| options[:run_id] = value }
          end
        end.parse!(args)
        if options[:cleanup_modes].uniq.length > 1
          err.puts "Choose either --dry-run or --apply, not both.\n#{USAGE}"
          return 2
        end
        options[:dry_run] = !options[:cleanup_modes].include?(:apply)
      end
      unless args.length == 1 && %w[validate prepare implement run submit runs cleanup].include?(action)
        err.puts USAGE
        return 2
      end

      task = TaskSpec.load(args.first)
      if %w[runs cleanup].include?(action)
        catalog = RunCatalog.new(task: task, root: options[:root])
        rows = action == "runs" ? catalog.list : catalog.cleanup(dry_run: options[:dry_run], run_id: options[:run_id])
        out.puts JSON.pretty_generate({"runs" => rows, "dry_run" => options[:dry_run]})
        return rows.any? { |row| row["action"] == "error" } ? 1 : 0
      elsif action == "validate"
        out.puts JSON.pretty_generate({"valid" => true, "source_path" => task.source_path, "task" => task.to_h})
      else
        store = RunStore.new(task: task, progress: ProgressReporter.new(io: err))
        if action == "prepare"
          store.with_lock { GitWorkspace.new(task: task, store: store).prepare }
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
    rescue RunCatalogError, RunBusyError => e
      err.puts "Cannot #{action}: #{e.message}"
      1
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
