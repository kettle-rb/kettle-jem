# frozen_string_literal: true

require "set"

module Kettle
  module Jem
    module PrismGemfile
      # Named contract for Gemfile-local sibling override metadata (`local_gems`
      # and the adjacent `VENDORED_GEMS` export comment).
      module LocalOverridePolicy
        LOCAL_GEMS_ARRAY_RE = /^(?<indent>[ \t]*)local_gems\s*=\s*%w\[(?<body>.*?)\](?<suffix>[ \t]*(?:#.*)?)$/m
        VENDORED_GEMS_EXPORT_RE = /^(?<prefix>[ \t]*#\s*export\s+VENDORED_GEMS=)(?<body>[^\n]*)$/

        module_function

        def merge(content, destination_content, excluded_gems: [])
          merged_local_gems_match = local_gems_array_match(content)
          destination_local_gems_match = local_gems_array_match(destination_content)
          merged_vendored_match = vendored_gems_export_match(content)
          destination_vendored_match = vendored_gems_export_match(destination_content)

          return content unless merged_local_gems_match || destination_local_gems_match || merged_vendored_match || destination_vendored_match

          excluded = excluded_words_set(excluded_gems)
          merged_words = local_gems_words_from_match(merged_local_gems_match)
          destination_words = local_gems_words_from_match(destination_local_gems_match)
          vendored_words = vendored_gems_words_from_match(merged_vendored_match) | vendored_gems_words_from_match(destination_vendored_match)

          words = (destination_words + merged_words + vendored_words).uniq.reject { |word| excluded.include?(word) }
          out = content.dup

          if merged_local_gems_match
            out.sub!(merged_local_gems_match[0], rebuild_local_gems_array(merged_local_gems_match, words))
          elsif destination_local_gems_match
            out = "#{rebuild_local_gems_array(destination_local_gems_match, words)}\n#{out}" unless words.empty?
          end

          export_line = rebuild_vendored_gems_export_line(merged_vendored_match || destination_vendored_match, words)
          array_match = merged_local_gems_match || destination_local_gems_match
          if merged_vendored_match
            out.sub!(merged_vendored_match[0], export_line)
          elsif export_line && array_match && !out.include?(export_line)
            array_text = rebuild_local_gems_array(array_match, words)
            insertion = out.index(array_text)
            if insertion
              out.sub!(array_text, "#{array_text}\n\n#{export_line}")
            end
          end

          out
        end

        def merge_bootstrap(source_content, destination_content, excluded_gems: [])
          source_local_match = local_gems_array_match(source_content)
          source_export_match = vendored_gems_export_match(source_content)
          return destination_content unless source_local_match || source_export_match

          destination_local_match = local_gems_array_match(destination_content)
          destination_export_match = vendored_gems_export_match(destination_content)
          excluded = excluded_words_set(excluded_gems)
          words = (
            local_gems_words_from_match(destination_local_match) +
            local_gems_words_from_match(source_local_match) +
            vendored_gems_words_from_match(destination_export_match) +
            vendored_gems_words_from_match(source_export_match)
          ).uniq.reject { |word| excluded.include?(word) }

          out = destination_content.dup
          template_local_match = destination_local_match || source_local_match
          return destination_content unless template_local_match

          local_text = rebuild_local_gems_array(template_local_match, words)
          if destination_local_match
            out.sub!(destination_local_match[0], local_text)
          else
            out = "#{local_text}\n\n#{out}" unless words.empty?
          end

          export_template = destination_export_match || source_export_match
          return out unless export_template

          export_text = rebuild_vendored_gems_export_line(export_template, words)
          if destination_export_match
            out.sub!(destination_export_match[0], export_text)
          elsif out.include?(local_text)
            out.sub!(local_text, "#{local_text}\n\n#{export_text}")
          else
            out = "#{export_text}\n#{out}"
          end

          out
        end

        def remove_word_from_local_gems_array(content, gem_name)
          gem_word = gem_name.to_s.strip
          return content if gem_word.empty?

          content.gsub(LOCAL_GEMS_ARRAY_RE) do
            match = Regexp.last_match
            words = match[:body].split(/\s+/).reject(&:empty?)
            filtered = words.reject { |word| word == gem_word }
            next match[0] if filtered == words

            indent = match[:indent]
            suffix = match[:suffix].to_s
            multiline = match[:body].include?("\n")

            if multiline
              rebuilt_body = if filtered.empty?
                ""
              else
                "\n" + filtered.map { |word| "#{indent}  #{word}" }.join("\n") + "\n#{indent}"
              end
              "#{indent}local_gems = %w[#{rebuilt_body}]#{suffix}"
            else
              joined = filtered.join(" ")
              "#{indent}local_gems = %w[#{joined}]#{suffix}"
            end
          end
        end

        def remove_word_from_vendored_gems_export_comment(content, gem_name)
          gem_word = gem_name.to_s.strip
          return content if gem_word.empty?

          content.gsub(VENDORED_GEMS_EXPORT_RE) do
            match = Regexp.last_match
            words = match[:body].split(",").map(&:strip).reject(&:empty?)
            filtered = words.reject { |word| word == gem_word }
            next match[0] if filtered == words

            "#{match[:prefix]}#{filtered.join(",")}"
          end
        end

        def local_gems_array_match(content)
          content.to_s.match(LOCAL_GEMS_ARRAY_RE)
        end

        def local_gems_words_from_match(match)
          return [] unless match

          match[:body].to_s.split(/\s+/).reject(&:empty?)
        end

        def vendored_gems_export_match(content)
          content.to_s.match(VENDORED_GEMS_EXPORT_RE)
        end

        def vendored_gems_words_from_match(match)
          return [] unless match

          match[:body].to_s.split(",").map(&:strip).reject(&:empty?)
        end

        def excluded_words_set(excluded_gems)
          Array(excluded_gems).map { |name| name.to_s.strip }.reject(&:empty?).to_set
        end

        def rebuild_local_gems_array(match, words)
          indent = match[:indent].to_s
          suffix = match[:suffix].to_s
          multiline = match[:body].to_s.include?("\n") || words.length > 1

          if multiline
            rebuilt_body = if words.empty?
              ""
            else
              "\n" + words.map { |word| "#{indent}  #{word}" }.join("\n") + "\n#{indent}"
            end
            "#{indent}local_gems = %w[#{rebuilt_body}]#{suffix}"
          else
            "#{indent}local_gems = %w[#{words.join(" ")}]#{suffix}"
          end
        end

        def rebuild_vendored_gems_export_line(match, words)
          return unless match

          "#{match[:prefix]}#{words.join(",")}"
        end

        private_class_method :remove_word_from_local_gems_array,
          :remove_word_from_vendored_gems_export_comment,
          :local_gems_array_match,
          :local_gems_words_from_match,
          :vendored_gems_export_match,
          :vendored_gems_words_from_match,
          :excluded_words_set,
          :rebuild_local_gems_array,
          :rebuild_vendored_gems_export_line
      end
    end
  end
end
