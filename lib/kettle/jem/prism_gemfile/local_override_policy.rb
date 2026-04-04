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
          merged_associated_export_match = associated_local_override_export_match(content, merged_local_gems_match, merged_vendored_match)
          destination_associated_export_match = associated_local_override_export_match(destination_content, destination_local_gems_match, destination_vendored_match)

          return content unless merged_local_gems_match || destination_local_gems_match || merged_vendored_match || destination_vendored_match

          excluded = excluded_words_set(excluded_gems)
          merged_words = local_gems_words_from_match(merged_local_gems_match)
          destination_words = local_gems_words_from_match(destination_local_gems_match)
          vendored_words = vendored_gems_words_from_match(merged_vendored_match) | vendored_gems_words_from_match(destination_vendored_match)

          if logically_equivalent_local_override_blocks?(
            content,
            merged_local_gems_match,
            merged_associated_export_match,
            destination_content,
            destination_local_gems_match,
            destination_associated_export_match,
            excluded,
          )
            # Gem lists are already equivalent — no list manipulation needed.
            # Return `content` (the apply_strategy result), NOT `destination_content`,
            # so that template-preference updates to non-list nodes (e.g. the
            # `require` line) are preserved rather than discarded.
            return content
          end

          words = if merged_local_gems_match || merged_vendored_match
            (merged_words + vendored_gems_words_from_match(merged_vendored_match)).uniq.reject { |word| excluded.include?(word) }
          else
            (destination_words + vendored_words).uniq.reject { |word| excluded.include?(word) }
          end
          out = content.dup
          block_export_template = nil

          if local_override_block_equivalent?(content, merged_local_gems_match, merged_associated_export_match, words)
            return content
          end

          if merged_local_gems_match
            block_export_template = merged_associated_export_match || destination_associated_export_match
            out = if block_export_template
              replace_local_override_block(
                out,
                merged_local_gems_match,
                block_export_template,
                words,
                replace_end_line: (merged_associated_export_match || {}).fetch(:line_number, merged_local_gems_match.fetch(:node).location.end_line),
              )
            else
              replace_local_gems_array(out, merged_local_gems_match, words)
            end
          elsif destination_local_gems_match
            block_export_template = destination_associated_export_match || merged_vendored_match || destination_vendored_match
            out = "#{rebuild_local_override_block(destination_local_gems_match, block_export_template, words)}\n#{out}" unless words.empty?
          end

          return out if block_export_template

          export_line = rebuild_vendored_gems_export_line(merged_vendored_match || destination_vendored_match, words)
          array_match = merged_local_gems_match || destination_local_gems_match
          if merged_vendored_match
            out = replace_vendored_gems_export_line(out, merged_vendored_match, export_line)
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
          source_associated_export_match = associated_local_override_export_match(source_content, source_local_match, source_export_match)
          return destination_content unless source_local_match || source_export_match

          destination_local_match = local_gems_array_match(destination_content)
          destination_export_match = vendored_gems_export_match(destination_content)
          destination_associated_export_match = associated_local_override_export_match(destination_content, destination_local_match, destination_export_match)
          excluded = excluded_words_set(excluded_gems)
          words = (
            local_gems_words_from_match(source_local_match) +
            vendored_gems_words_from_match(source_export_match)
          ).uniq.reject { |word| excluded.include?(word) }

          if local_override_block_equivalent?(destination_content, destination_local_match, destination_associated_export_match, words)
            return destination_content
          end

          out = destination_content.dup
          template_local_match = destination_local_match || source_local_match
          return destination_content unless template_local_match

          block_export_template = destination_associated_export_match || source_associated_export_match || destination_export_match || source_export_match
          local_text = rebuild_local_override_block(template_local_match, block_export_template, words)
          if destination_local_match
            out = if block_export_template
              replace_local_override_block(
                out,
                destination_local_match,
                block_export_template,
                words,
                replace_end_line: (destination_associated_export_match || {}).fetch(:line_number, destination_local_match.fetch(:node).location.end_line),
              )
            else
              replace_local_gems_array(out, destination_local_match, words)
            end
          else
            out = "#{local_text}\n\n#{out}" unless words.empty?
          end

          export_template = destination_export_match || source_export_match
          return out if block_export_template
          return out unless export_template

          export_text = rebuild_vendored_gems_export_line(export_template, words)
          if destination_export_match
            out = replace_vendored_gems_export_line(out, destination_export_match, export_text)
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
          content.to_s.each_line.with_index(1) do |line, line_number|
            match = line.match(VENDORED_GEMS_EXPORT_RE)
            next unless match

            return {
              line_number: line_number,
              text: match[0],
              prefix: match[:prefix],
              body: match[:body],
            }
          end

          nil
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

        def rebuild_local_override_block(match, export_match, words)
          local_text = rebuild_local_gems_array(match, words)
          export_text = rebuild_vendored_gems_export_line(export_match, words)
          return local_text unless export_text

          "#{local_text}\n\n#{export_text}"
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

        def replace_local_override_block(content, local_match, export_match, words, replace_end_line: nil)
          node = local_match.fetch(:node)
          replacement = rebuild_local_override_block(local_match, export_match, words)
          end_line = replace_end_line || node.location.end_line
          replacement += "\n" unless replacement.end_with?("\n")

          Ast::Merge::StructuralEdit::PlanSet.new(
            source: content,
            plans: [
              Ast::Merge::StructuralEdit::SplicePlan.new(
                source: content,
                replacement: replacement,
                replace_start_line: node.location.start_line,
                replace_end_line: end_line,
                metadata: {
                  source: :kettle_jem_prism_gemfile_local_override,
                  edit: :replace_local_override_block,
                  words: words,
                },
              ),
            ],
            metadata: {
              source: :kettle_jem_prism_gemfile_local_override,
              edit: :replace_local_override_block,
            },
          ).merged_content
        end

        def replace_vendored_gems_export_line(content, match, replacement)
          return content unless match && replacement

          replacement = replacement.end_with?("\n") ? replacement : "#{replacement}\n"

          Ast::Merge::StructuralEdit::PlanSet.new(
            source: content,
            plans: [
              Ast::Merge::StructuralEdit::SplicePlan.new(
                source: content,
                replacement: replacement,
                replace_start_line: match[:line_number],
                replace_end_line: match[:line_number],
                metadata: {
                  source: :kettle_jem_prism_gemfile_local_override,
                  edit: :replace_vendored_gems_export_line,
                },
              ),
            ],
            metadata: {
              source: :kettle_jem_prism_gemfile_local_override,
              edit: :replace_vendored_gems_export_line,
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

        def associated_local_override_export_match(content, local_match, export_match)
          return unless content && local_match && export_match

          local_end_line = local_match.fetch(:node).location.end_line
          export_line = export_match[:line_number]
          return if export_line <= local_end_line

          between_lines = content.to_s.lines[(local_end_line)...(export_line - 1)] || []
          return unless between_lines.all? { |line| line.to_s.strip.empty? }

          export_match
        end

        def local_override_block_equivalent?(content, local_match, export_match, words)
          return false unless content && local_match

          local_words = local_gems_words_from_match(local_match)
          return false unless local_words == words

          if export_match
            vendored_words_from_match = vendored_gems_words_from_match(export_match)
            return false unless vendored_words_from_match == words

            expected = rebuild_local_override_block(local_match, export_match, words) + "\n"
            actual = local_override_block_source(content, local_match, export_match)
            return actual == expected
          end

          rebuild_local_gems_array(local_match, words) + "\n" == local_override_block_source(content, local_match, nil)
        end

        def local_override_block_source(content, local_match, export_match)
          node = local_match.fetch(:node)
          start_line = node.location.start_line
          end_line = export_match ? export_match[:line_number] : node.location.end_line
          content.to_s.lines[(start_line - 1)...end_line].join
        end

        def logically_equivalent_local_override_blocks?(left_content, left_local_match, left_export_match, right_content, right_local_match, right_export_match, excluded)
          return false unless left_content && right_content && left_local_match && right_local_match

          left_words = local_gems_words_from_match(left_local_match).reject { |word| excluded.include?(word) }
          right_words = local_gems_words_from_match(right_local_match).reject { |word| excluded.include?(word) }
          return false unless left_words.to_set == right_words.to_set

          return true unless left_export_match || right_export_match
          return false unless left_export_match && right_export_match

          left_export_words = vendored_gems_words_from_match(left_export_match).reject { |word| excluded.include?(word) }
          right_export_words = vendored_gems_words_from_match(right_export_match).reject { |word| excluded.include?(word) }

          left_export_words.to_set == right_export_words.to_set
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
          :rebuild_local_override_block,
          :replace_local_gems_array,
          :replace_local_override_block,
          :replace_vendored_gems_export_line,
          :local_gems_array_assignment?,
          :local_gems_array_words,
          :local_gems_assignment_indent,
          :local_gems_assignment_suffix,
          :associated_local_override_export_match,
          :local_override_block_equivalent?,
          :local_override_block_source,
          :logically_equivalent_local_override_blocks?
      end
    end
  end
end
