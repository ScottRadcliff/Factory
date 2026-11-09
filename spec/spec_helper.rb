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

  def fake_github(create_exit: 0, existing: false)
    executable = File.join(@directory, "gh")
    calls = File.join(@directory, "gh-calls.jsonl")
    body = File.join(@directory, "published-body.md")
    File.write(executable, <<~RUBY)
      #!#{RbConfig.ruby}
      require "json"
      File.open(#{calls.inspect}, "a") { |file| file.puts(JSON.generate(ARGV)) }
      case ARGV.first(2)
      when ["repo", "view"]
        puts "https://github.com/factory/example"
      when ["auth", "status"]
        exit 0
      when ["pr", "list"]
        puts JSON.generate(#{existing ? '[{"url" => "https://github.com/factory/example/pull/42"}]' : '[]'})
      when ["pr", "create"]
        abort "draft required" unless ARGV.include?("--draft")
        abort "explicit repository required" unless ARGV[ARGV.index("--repo") + 1] == "https://github.com/factory/example"
        File.write(#{body.inspect}, File.read(ARGV.fetch(ARGV.index("--body-file") + 1)))
        exit #{create_exit} unless #{create_exit}.zero?
        puts "https://github.com/factory/example/pull/42"
      else
        abort "Unexpected GitHub command"
      end
    RUBY
    File.chmod(0o700, executable)
    executable
  end

  def add_bare_remote
    @bare_remote = File.join(@directory, "remote.git")
    _, stderr, status = Open3.capture3("git", "init", "--bare", "--initial-branch=main", @bare_remote)
    raise stderr unless status.success?
    git("remote", "add", "origin", @bare_remote)
    git("push", "origin", "main")
  end
end
