require "tmpdir"
require "stringio"
require "rbconfig"
require "open3"
require_relative "../lib/factory"

RSpec.configure do |config|
  config.order = :random
end
