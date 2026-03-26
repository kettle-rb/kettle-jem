# frozen_string_literal: true

require "set"

module Kettle
  module Jem
    module PrismGemfile
      # Named contract for Gemfile-local sibling override metadata (`local_gems`
      # and the adjacent `VENDORED_GEMS` export comment).
      module LocalOverridePolicy
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
            out = replace_local_gems_array(out, merged_local_gems_match, words)
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
            out = replace_local_gems_array(out, destination_local_match, words)
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

          payload = local_gems_array_match(content)
          return content unless payload

          words = local_gems_words_from_match(payload)
          filtered = words.reject { |word| word == gem_word }
          return content if filtered == words

          replace_local_gems_array(content, payload, filtered)
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
          source = content.to_s
          result = PrismUtils.parse_with_comments(source)
          return unless result.success?

          statements = PrismUtils.extract_statements(result.value.statements)
          node = statements.find { |statement| local_gems_array_assignment?(statement) }
          return unless node

          {
            node: node,
            indent: local_gems_assignment_indent(source, node),
            suffix: local_gems_assignment_suffix(source, node),
            multiline: node.location.start_line != node.location.end_line,
            words: local_gems_array_words(node),
          }
        end

        def local_gems_words_from_match(match)
          return [] unless match

          Array(match[:words]).map(&:to_s).reject(&:empty?)
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
          multiline = match[:multiline]

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

        def replace_local_gems_array(content, match, words)
          node = match.fetch(:node)
          replacement = rebuild_local_gems_array(match, words)

          Ast::Merge::StructuralEdit::PlanSet.new(
            source: content,
            plans: [
              Ast::Merge::StructuralEdit::SplicePlan.new(
                source: content,
                replacement: replacement,
                replace_start_line: node.location.start_line,
                replace_end_line: node.location.end_line,
                metadata: {
                  source: :kettle_jem_prism_gemfile_local_override,
                  edit: :replace_local_gems_array,
                  words: words,
                },
              ),
            ],
            metadata: {
              source: :kettle_jem_prism_gemfile_local_override,
              edit: :replace_local_gems_array,
            },
          ).merged_content
        end

        def local_gems_array_assignment?(statement)
          return false unless statement.is_a?(Prism::LocalVariableWriteNode)
          return false unless statement.name == :local_gems

          value = statement.value
          value.is_a?(Prism::ArrayNode) && value.opening_loc&.slice == "%w[" && value.elements.all? { |element| element.is_a?(Prism::StringNode) }
        end

        def local_gems_array_words(node)
          node.value.elements.map(&:unescaped)
        end

        def local_gems_assignment_indent(source, node)
          source.lines[node.location.start_line - 1].to_s[/^(\s*)/, 1].to_s
        end

        def local_gems_assignment_suffix(source, node)
          line = source.lines[node.location.end_line - 1].to_s
          line_start_offset = source.lines.take(node.location.end_line - 1).sum(&:bytesize)
          line_end_offset = line_start_offset + line.sub(/\r?\n\z/, "").bytesize
          suffix = source.byteslice(node.location.end_offset...line_end_offset).to_s
          suffix.empty? ? "" : suffix
        end

        private_class_method :remove_word_from_local_gems_array,
          :remove_word_from_vendored_gems_export_comment,
          :local_gems_array_match,
          :local_gems_words_from_match,
          :vendored_gems_export_match,
          :vendored_gems_words_from_match,
          :excluded_words_set,
          :rebuild_local_gems_array,
          :rebuild_vendored_gems_export_line,
          :replace_local_gems_array,
          :local_gems_array_assignment?,
          :local_gems_array_words,
          :local_gems_assignment_indent,
          :local_gems_assignment_suffix
      end
    end
  end
end
