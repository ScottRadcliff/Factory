require "tmpdir"
require "stringio"
require "rbconfig"
require "open3"
require_relative "../lib/factory"

RSpec.configure do |config|
  config.order = :random
end

RSpec.shared_context "temporary Git repository" do
  around do |example|
    Dir.mktmpdir("factory-git") do |directory|
      @directory = directory
      @repository = File.join(directory, "application with spaces")
      Dir.mkdir(@repository)
      git("init", "-b", "main")
      git("config", "user.name", "Factory Tests")
      git("config", "user.email", "factory@example.test")
      File.write(File.join(@repository, "app.txt"), "original\n")
      git("add", "app.txt")
      git("commit", "-m", "Initial commit")
      data = YAML.safe_load_file(File.join(__dir__, "fixtures", "task.yml"))
      data["repository"] = @repository
      @task_path = File.join(directory, "task.yml")
      File.write(@task_path, YAML.dump(data))
      example.run
    end
  end

  def git(*args)
    stdout, stderr, status = Open3.capture3("git", "-C", @repository, *args)
    raise "Git fixture failed: #{stderr}" unless status.success?
    stdout.strip
  end

  let(:task) { Factory::TaskSpec.load(@task_path) }

  def fake_codex(body = nil)
    executable = File.join(@directory, "codex")
    body ||= <<~RUBY
      File.write("app.txt", "implemented\\n")
      File.write(ARGV.fetch(ARGV.index("--output-last-message") + 1), "Implemented task; verification is pending.")
      puts JSON.generate("type" => "turn.completed", "usage" => {"input_tokens" => 10})
    RUBY
    File.write(executable, <<~RUBY)
      #!#{RbConfig.ruby}
      require "json"
      abort "expected exec" unless ARGV.first == "exec"
      abort "expected sandbox" unless ARGV[ARGV.index("--sandbox") + 1] == "workspace-write"
      abort "expected approval policy" unless ARGV.include?('approval_policy="never"')
      abort "expected JSON and stdin prompt" unless ARGV.include?("--json") && ARGV.last == "-"
      prompt = STDIN.read
      abort "missing task" unless prompt.include?("Task specification (JSON)")
      #{body}
    RUBY
    File.chmod(0o700, executable)
    executable
  end
end
