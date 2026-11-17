# frozen_string_literal: true

module Soundalike
  # Minimal .env reader so the app needs no extra gem for configuration.
  # Existing environment variables always win over the file.
  module Env
    LINE = /\A\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*\z/

    def self.load(path, env: ENV)
      return [] unless File.file?(path)

      File.readlines(path, chomp: true).filter_map do |line|
        next if line.strip.empty? || line.strip.start_with?("#")

        match = LINE.match(line) or next
        key = match[1]
        value = unquote(match[2])
        next if env.key?(key)

        env[key] = value
        key
      end
    end

    def self.unquote(value)
      if value.length >= 2 && value[0] == value[-1] && ['"', "'"].include?(value[0])
        value[1..-2]
      else
        value.sub(/\s+#.*\z/, "")
      end
    end
  end
end
