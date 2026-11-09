require "yaml"

module Factory
  class InvalidTaskSpec < StandardError; end

  class TaskSpec
    TOP_LEVEL_KEYS = %w[version id repository base_branch title description acceptance_criteria verification limits].freeze
    LIMIT_DEFAULTS = {"max_repairs" => 2, "agent_timeout_seconds" => 1800}.freeze

    attr_reader :source_path

    def self.load(path)
      source_path = File.expand_path(path)
      yaml = File.read(source_path, encoding: "UTF-8")
      # Psych otherwise silently keeps the last value for duplicate mapping keys.
      stream = Psych.parse_stream(yaml)
      raise InvalidTaskSpec, "Task file must contain exactly one YAML document" unless stream.children.length == 1
      reject_duplicate_keys!(stream)
      data = YAML.safe_load(yaml, permitted_classes: [], permitted_symbols: [], aliases: false)
      new(data, source_path: source_path)
    rescue Psych::Exception, ArgumentError, EncodingError, SystemCallError, IOError => e
      raise InvalidTaskSpec, "Cannot load task specification: #{e.message}"
    end

    def self.reject_duplicate_keys!(node)
      if node.is_a?(Psych::Nodes::Mapping)
        keys = node.children.each_slice(2).map(&:first)
        unless keys.all? { |key| key.is_a?(Psych::Nodes::Scalar) }
          raise InvalidTaskSpec, "YAML mapping keys must be simple strings"
        end
        duplicate = keys.map(&:value).tally.find { |_key, count| count > 1 }
        raise InvalidTaskSpec, "Duplicate YAML key: #{duplicate.first}" if duplicate
      end
      (node.children || []).each { |child| reject_duplicate_keys!(child) }
    end
    private_class_method :reject_duplicate_keys!

    def initialize(data, source_path:)
      @source_path = source_path.freeze
      mapping!(data, "task", TOP_LEVEL_KEYS)
      integer!(data["version"], "version", 1..1)
      %w[id repository base_branch title description].each { |key| string!(data[key], key) }
      unless data["id"].match?(/\A[a-z0-9][a-z0-9-]{0,63}\z/)
        invalid!("id must contain 1–64 lowercase letters, digits, or hyphens and start with a letter or digit")
      end
      if data["base_branch"].start_with?("-")
        invalid!("base_branch must not start with '-'")
      end
      string_list!(data["acceptance_criteria"], "acceptance_criteria")
      list!(data["verification"], "verification")
      names = []
      checks = data["verification"].each_with_index.map do |check, index|
        field = "verification[#{index}]"
        mapping!(check, field, %w[name command timeout_seconds])
        string!(check["name"], "#{field}.name")
        invalid!("Verification names must be unique: #{check['name']}") if names.include?(check["name"])
        names << check["name"]
        string_list!(check["command"], "#{field}.command")
        integer!(check["timeout_seconds"], "#{field}.timeout_seconds", 1..86_400)
        check
      end
      limits = data.fetch("limits", {})
      mapping!(limits, "limits", LIMIT_DEFAULTS.keys)
      limits = LIMIT_DEFAULTS.merge(limits)
      integer!(limits["max_repairs"], "limits.max_repairs", 0..10)
      integer!(limits["agent_timeout_seconds"], "limits.agent_timeout_seconds", 1..86_400)
      repository = File.expand_path(data["repository"], File.dirname(source_path))
      invalid!("repository must be an existing directory: #{repository}") unless File.directory?(repository)
      @data = deep_freeze(data.merge("repository" => repository, "verification" => checks, "limits" => limits))
    end

    # Return a copy so callers cannot mutate the validated specification.
    def to_h
      Marshal.load(Marshal.dump(@data))
    end

    private

    def invalid!(message)
      raise InvalidTaskSpec, message
    end

    def mapping!(value, field, allowed)
      invalid!("#{field} must be a mapping") unless value.is_a?(Hash)
      invalid!("#{field} keys must be strings") unless value.keys.all? { |key| key.is_a?(String) }
      unknown = value.keys - allowed
      invalid!("Unknown #{field} fields: #{unknown.join(', ')}") unless unknown.empty?
    end

    def string!(value, field)
      unless value.is_a?(String) && !value.strip.empty? && !value.include?("\0")
        invalid!("#{field} must be a nonblank string without NUL bytes")
      end
    end

    def list!(value, field)
      invalid!("#{field} must be a nonempty list") unless value.is_a?(Array) && !value.empty?
    end

    def string_list!(value, field)
      list!(value, field)
      value.each_with_index { |entry, index| string!(entry, "#{field}[#{index}]") }
    end

    def integer!(value, field, range)
      invalid!("#{field} must be an integer in #{range}") unless value.is_a?(Integer) && range.cover?(value)
    end

    def deep_freeze(value)
      case value
      when Hash then value.each { |key, entry| deep_freeze(key); deep_freeze(entry) }
      when Array then value.each { |entry| deep_freeze(entry) }
      end
      value.freeze
    end
  end
end
