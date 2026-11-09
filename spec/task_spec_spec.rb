require "spec_helper"

RSpec.describe Factory::TaskSpec do
  around do |example|
    Dir.mktmpdir("factory-spec") do |directory|
      @directory = directory
      @path = File.join(directory, "task.yml")
      example.run
    end
  end

  let(:data) do
    {
      "version" => 1, "id" => "validate-names", "repository" => ".",
      "base_branch" => "main", "title" => "Validate names", "description" => "Reject blank names.",
      "acceptance_criteria" => ["Blank names produce an error."],
      "verification" => [{"name" => "specs", "command" => %w[bundle exec rspec], "timeout_seconds" => 600}]
    }
  end

  def load_data(value = data)
    File.write(@path, YAML.dump(value))
    described_class.load(@path)
  end

  it "normalizes the repository path and supplies limits" do
    task = load_data
    expect(task.source_path).to eq(@path)
    expect(task.to_h["repository"]).to eq(@directory)
    expect(task.to_h["limits"]).to eq("max_repairs" => 2, "agent_timeout_seconds" => 1800)
  end

  it "resolves paths from the task file rather than the caller's directory" do
    Dir.mkdir(File.join(@directory, "application"))
    data["repository"] = "application"
    expect(load_data.to_h["repository"]).to eq(File.join(@directory, "application"))
  end

  it "accepts absolute repository paths and explicit zero repairs" do
    data["repository"] = @directory
    data["limits"] = {"max_repairs" => 0, "agent_timeout_seconds" => 1}
    expect(load_data.to_h["limits"]["max_repairs"]).to eq(0)
  end

  it "returns independent copies of the validated data" do
    task = load_data
    task.to_h["verification"].first["command"] << "--unexpected"
    expect(task.to_h["verification"].first["command"]).to eq(%w[bundle exec rspec])
  end

  %w[version id repository base_branch title description acceptance_criteria verification].each do |key|
    it "rejects missing #{key}" do
      data.delete(key)
      expect { load_data }.to raise_error(Factory::InvalidTaskSpec, /#{key}/)
    end
  end

  {
    "unsupported schema version" => ["version", 2],
    "boolean version" => ["version", true],
    "unsafe task id" => ["id", "../task"],
    "blank title" => ["title", "  "],
    "NUL in description" => ["description", "bad\0text"],
    "missing directory" => ["repository", "missing"],
    "option-like base" => ["base_branch", "--help"],
    "empty acceptance criteria" => ["acceptance_criteria", []],
    "nonstring criterion" => ["acceptance_criteria", [true]],
    "empty verification" => ["verification", []],
    "null limits" => ["limits", nil],
    "unknown limit" => ["limits", {"retries" => 2}],
    "negative repairs" => ["limits", {"max_repairs" => -1}],
    "excessive repairs" => ["limits", {"max_repairs" => 11}],
    "string repairs" => ["limits", {"max_repairs" => "2"}],
    "zero agent timeout" => ["limits", {"agent_timeout_seconds" => 0}],
    "excessive agent timeout" => ["limits", {"agent_timeout_seconds" => 86_401}]
  }.each do |name, (key, value)|
    it "rejects #{name}" do
      data[key] = value
      expect { load_data }.to raise_error(Factory::InvalidTaskSpec)
    end
  end

  it "rejects a file as the repository" do
    data["repository"] = @path
    expect { load_data }.to raise_error(Factory::InvalidTaskSpec, /existing directory/)
  end

  it "rejects unknown top-level fields" do
    data["agent_count"] = 3
    expect { load_data }.to raise_error(Factory::InvalidTaskSpec, /Unknown task fields: agent_count/)
  end

  it "rejects nonstring keys" do
    data[42] = "value"
    expect { load_data }.to raise_error(Factory::InvalidTaskSpec, /keys must be strings/)
  end

  [nil, [], "task"].each do |value|
    it "rejects a #{value.inspect} root" do
      expect { load_data(value) }.to raise_error(Factory::InvalidTaskSpec, /mapping/)
    end
  end

  [nil, [], "bundle exec rspec", [""], [42], ["ruby", "bad\0argument"]].each do |value|
    it "rejects invalid command #{value.inspect}" do
      data["verification"].first["command"] = value
      expect { load_data }.to raise_error(Factory::InvalidTaskSpec, /command/)
    end
  end

  it "rejects unknown verification fields" do
    data["verification"].first["shell"] = true
    expect { load_data }.to raise_error(Factory::InvalidTaskSpec, /Unknown verification/)
  end

  it "rejects repeated verification names" do
    data["verification"] << {"name" => "specs", "command" => ["ruby", "--version"], "timeout_seconds" => 60}
    expect { load_data }.to raise_error(Factory::InvalidTaskSpec, /unique/)
  end

  [nil, 0, -1, 86_401, 1.5, "600", false].each do |timeout|
    it "rejects check timeout #{timeout.inspect}" do
      data["verification"].first["timeout_seconds"] = timeout
      expect { load_data }.to raise_error(Factory::InvalidTaskSpec, /timeout_seconds/)
    end
  end

  {
    "malformed YAML" => "title: [unfinished",
    "duplicate keys" => "version: 1\nversion: 2\n",
    "nested duplicate keys" => "limits:\n  max_repairs: 1\n  max_repairs: 2\n",
    "aliases" => "title: &title Something\ndescription: *title\n",
    "object deserialization" => "--- !ruby/object:Object {}",
    "multiple documents" => "---\nversion: 1\n---\nversion: 1\n",
    "empty document" => ""
  }.each do |name, yaml|
    it "rejects #{name}" do
      File.write(@path, yaml)
      expect { described_class.load(@path) }.to raise_error(Factory::InvalidTaskSpec)
    end
  end

  it "reports a missing file as a validation error" do
    expect { described_class.load(@path) }.to raise_error(Factory::InvalidTaskSpec, /Cannot load/)
  end
end
