require "json"

module Factory
  class CLI
    USAGE = "Usage: factory <validate|prepare> TASK.yml".freeze

    def self.run(argv, out: $stdout, err: $stderr)
      if argv == ["--help"] || argv == ["-h"]
        out.puts USAGE
        return 0
      end
      unless argv.length == 2 && %w[validate prepare].include?(argv.first)
        err.puts USAGE
        return 2
      end

      task = TaskSpec.load(argv.last)
      if argv.first == "validate"
        out.puts JSON.pretty_generate({"valid" => true, "source_path" => task.source_path, "task" => task.to_h})
      else
        store = RunStore.new(task: task)
        workspace = GitWorkspace.new(task: task, store: store).prepare
        out.puts JSON.pretty_generate({"state" => "prepared", "workspace" => workspace,
                                       "result_path" => File.join(store.directory, "result.json")})
      end
      0
    rescue InvalidTaskSpec => e
      err.puts "Invalid task specification: #{e.message}"
      1
    rescue WorkspaceError, SystemCallError => e
      err.puts "Cannot prepare workspace: #{e.message}"
      1
    rescue Interrupt
      err.puts "Workspace preparation interrupted; retained artifacts: #{store&.directory}"
      130
    end
  end
end
