require "json"

module Factory
  class CLI
    USAGE = "Usage: factory validate TASK.yml".freeze

    def self.run(argv, out: $stdout, err: $stderr)
      if argv == ["--help"] || argv == ["-h"]
        out.puts USAGE
        return 0
      end
      unless argv.length == 2 && argv.first == "validate"
        err.puts USAGE
        return 2
      end

      task = TaskSpec.load(argv.last)
      out.puts JSON.pretty_generate({"valid" => true, "source_path" => task.source_path, "task" => task.to_h})
      0
    rescue InvalidTaskSpec => e
      err.puts "Invalid task specification: #{e.message}"
      1
    end
  end
end
