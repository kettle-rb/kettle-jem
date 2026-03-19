# frozen_string_literal: true

require "yaml"

module Kettle
  module Jem
    # Bootstrap-safe helpers for backfilling .kettle-jem.yml token values.
    #
    # This module intentionally depends only on stdlib so it can be used from
    # the standalone executable before the full bundled runtime is available.
    module ConfigSeeder
      TOKEN_PLACEHOLDER_RE = /\{KJ\|[^}]+}/.freeze
      INLINE_ENV_RE = /ENV:\s*(KJ_[A-Z0-9_]+)\b/.freeze

      module_function

      def seed_kettle_config_content(content, token_values, env: ENV)
        token_values ||= {}

        updated_content, = backfill_kettle_config_token_lines(content.to_s, token_values, env: env)
        updated_content
      end

      def placeholder_or_blank_kettle_config_scalar?(raw_value)
        stripped = raw_value.to_s.strip
        return true if stripped.empty?

        parsed = begin
          YAML.safe_load(stripped, permitted_classes: [], aliases: false)
        rescue StandardError
          stripped.delete_prefix('"').delete_suffix('"').delete_prefix("'").delete_suffix("'")
        end

        value = parsed.is_a?(String) ? parsed : parsed.to_s
        value.to_s.strip.empty? || token_placeholder?(value)
      end

      def yaml_scalar_for_kettle_config_backfill(value, current_raw)
        stripped = current_raw.to_s.strip
        if stripped.start_with?("'") && stripped.end_with?("'")
          "'#{value.to_s.gsub("'", "''")}'"
        else
          value.to_s.dump
        end
      end

      def backfill_kettle_config_token_lines(content, token_values, env: ENV)
        in_tokens = false
        current_section = nil
        changed = false

        updated = content.lines.map do |line|
          stripped = line.lstrip
          indent = line[/\A\s*/].to_s.length

          if indent.zero? && stripped.match?(/\Atokens:\s*(?:#.*)?\z/)
            in_tokens = true
            current_section = nil
            next line
          elsif indent.zero? && stripped.match?(/\A[\w-]+:\s*(?:#.*)?\z/)
            in_tokens = false
            current_section = nil
          end

          next line unless in_tokens

          if indent == 2 && (match = stripped.match(/\A([a-z_]+):\s*(?:#.*)?\z/))
            current_section = match[1]
            next line
          end

          next line unless indent == 4 && current_section

          match = line.match(/\A(\s*)([a-z_]+):(\s*)([^#\n]*?)(\s*(?:#.*)?)?(\n?)\z/)
          next line unless match

          key = match[2]
          desired_value = token_values.dig(current_section, key)
          desired_value = env[inline_env_key(match[5])] if !present_string?(desired_value) && inline_env_key(match[5])
          next line unless present_string?(desired_value)
          next line unless placeholder_or_blank_kettle_config_scalar?(match[4])

          changed = true
          "#{match[1]}#{key}:#{match[3]}#{yaml_scalar_for_kettle_config_backfill(desired_value, match[4])}#{match[5]}#{match[6]}"
        end.join

        [updated, changed]
      end

      def inline_env_key(comment)
        comment.to_s[INLINE_ENV_RE, 1]
      end

      def present_string?(value)
        !value.to_s.strip.empty?
      end

      def token_placeholder?(value)
        value.to_s.match?(TOKEN_PLACEHOLDER_RE)
      end
    end
  end
end
