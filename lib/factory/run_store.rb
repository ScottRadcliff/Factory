require "json"
require "fileutils"
require "securerandom"
require "time"
require "yaml"

module Factory
  # Single-writer storage. Recovery/resumption is intentionally a later increment.
  class RunStore
    attr_reader :directory

    def initialize(task:, root: nil)
      spec = task.to_h
      repository = File.realpath(spec.fetch("repository"))
      root ||= File.join(File.dirname(repository), ".factory", File.basename(repository))
      root = canonical_path(root)
      if root == repository || root.start_with?(repository + File::SEPARATOR)
        raise ArgumentError, "Run artifacts must be outside the target repository"
      end
      @directory = File.join(root, "#{spec.fetch('id')}-#{SecureRandom.uuid}")
      FileUtils.mkdir_p(directory, mode: 0o700)
      FileUtils.mkdir_p(File.join(directory, "commands"), mode: 0o700)
      @data = {"version" => 1, "run_id" => File.basename(directory), "state" => "pending",
               "created_at" => timestamp, "source_path" => task.source_path, "task" => spec, "commands" => []}
      File.write(File.join(directory, "task.yml"), YAML.dump(spec), perm: 0o600)
      record_event("run_created")
    end

    def start_command(argv:, chdir:, timeout:)
      id = format("%03d", @data.fetch("commands").length + 1)
      command_dir = File.join(directory, "commands", id)
      Dir.mkdir(command_dir, 0o700)
      command = {"id" => id, "argv" => argv.dup, "chdir" => chdir, "timeout_seconds" => timeout,
                 "state" => "running", "started_at" => timestamp,
                 "stdout_path" => File.join(command_dir, "stdout.log"),
                 "stderr_path" => File.join(command_dir, "stderr.log"),
                 "stdin_path" => File.join(command_dir, "stdin.txt")}
      @data.fetch("commands") << command
      record_event("command_started", "command_id" => id)
      copy(command)
    end

    def finish_command(id, attributes)
      command = @data.fetch("commands").find { |entry| entry.fetch("id") == id }
      raise ArgumentError, "Unknown command: #{id}" unless command
      command.merge!(attributes).merge!("finished_at" => timestamp)
      record_event("command_finished", "command_id" => id, "state" => command.fetch("state"))
      copy(command)
    end

    def snapshot
      copy(@data)
    end

    private

    def canonical_path(path)
      path = File.expand_path(path)
      return File.realpath(path) if File.exist?(path)
      File.join(canonical_path(File.dirname(path)), File.basename(path))
    end

    def copy(value)
      JSON.parse(JSON.generate(value))
    end

    def timestamp
      Time.now.utc.iso8601(6)
    end

    def record_event(type, attributes = {})
      event = {"type" => type, "at" => timestamp}.merge(attributes)
      File.open(File.join(directory, "events.jsonl"), "a", 0o600) { |file| file.puts JSON.generate(event) }
      temporary = File.join(directory, "result.json.tmp")
      File.open(temporary, "w", 0o600) do |file|
        file.write(JSON.pretty_generate(@data))
        file.flush
        file.fsync
      end
      File.rename(temporary, File.join(directory, "result.json"))
    end
  end
end
