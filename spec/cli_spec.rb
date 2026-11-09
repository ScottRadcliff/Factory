require "spec_helper"

RSpec.describe Factory::CLI do
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:example_path) { File.expand_path("../examples/task.yml", __dir__) }

  it "prints a normalized task as JSON" do
    status = described_class.run(["validate", example_path], out: out, err: err)
    expect(status).to eq(0)
    expect(JSON.parse(out.string)).to include("valid" => true, "source_path" => example_path)
    expect(err.string).to be_empty
  end

  it "reports invalid files without a stack trace or success output" do
    status = described_class.run(["validate", "/missing-factory-task.yml"], out: out, err: err)
    expect(status).to eq(1)
    expect(err.string).to start_with("Invalid task specification:")
    expect(out.string).to be_empty
  end

  [[], ["run"], ["validate"], ["validate", "a", "b"]].each do |argv|
    it "returns usage error for #{argv.inspect}" do
      expect(described_class.run(argv, out: out, err: err)).to eq(2)
      expect(err.string).to include("Usage:")
    end
  end

  it "shows help successfully" do
    expect(described_class.run(["--help"], out: out, err: err)).to eq(0)
    expect(out.string).to include("Usage:")
    expect(err.string).to be_empty
  end

  it "runs the actual executable from another working directory" do
    executable = File.expand_path("../bin/factory", __dir__)
    Dir.mktmpdir do |directory|
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, executable, "validate", example_path, chdir: directory)
      expect(status.exitstatus).to eq(0)
      expect(stderr).to be_empty
      expect(JSON.parse(stdout).fetch("task").fetch("repository")).to eq(File.expand_path("..", __dir__))
      expect(Dir.children(directory)).to be_empty
    end
  end
end
