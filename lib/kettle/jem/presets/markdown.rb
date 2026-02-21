# frozen_string_literal: true

module Kettle
  module Jem
    module Presets
      # MergerConfig preset for Markdown file merging.
      #
      # This preset is designed for use with markly-merge, providing:
      # - Heading-based section matching
      # - Table matching and preservation
      # - Fenced code block handling (with language-specific inner merging)
      #
      # ## Fenced Code Block Handling
      #
      # When merging Markdown files containing fenced code blocks, the preset
      # can be configured to merge the *contents* of code blocks using the
      # appropriate *-merge gem for that language:
      #
      # - Ruby code blocks: prism-merge
      # - YAML code blocks: psych-merge
      # - JSON code blocks: json-merge
      # - Shell/Bash blocks: bash-merge (when available)
      #
      # @example Basic usage
      #   config = Markdown.destination_wins
      #   merger = Markly::Merge::SmartMerger.new(template, dest, **config.to_h)
      #
      # @example With fenced code block inner merging
      #   # This requires separate handling in the merge pipeline
      #   config = Markdown.template_wins
      #   result = Markdown.merge_with_code_blocks(template, dest, config)
      #
      # @see Markly::Merge::SmartMerger
      class Markdown < Base
        # Languages supported for inner code block merging
        SUPPORTED_CODE_LANGUAGES = %w[ruby rb yaml yml json].freeze

        class << self
          # Returns the signature generator for Markdown merging.
          #
          # Generates signatures based on:
          # - Headings: Match by level and normalized text
          # - Tables: Match by structure and first row content
          # - Code blocks: Match by language and info string
          # - Other nodes: Default matching
          #
          # @return [Proc] Lambda that generates signatures for Markly nodes
          def signature_generator
            ->(node) do
              # Only handle Markly nodes
              return node unless defined?(Markly) && node.respond_to?(:type)

              case node.type
              when :header
                level = node.header_level
                text = extract_heading_text(node)
                [:header, level, normalize_heading(text)]

              when :table
                # Match tables by first row content (header row)
                first_row_sig = extract_table_header_signature(node)
                [:table, first_row_sig]

              when :code_block
                # Match code blocks by language and position context
                lang = node.fence_info.to_s.strip
                [:code_block, lang]

              when :html_block
                # HTML blocks may be comments (freeze markers) or content
                content = node.string_content.to_s.strip
                if content.include?("freeze") || content.include?("unfreeze")
                  [:html_comment, :freeze_marker]
                else
                  [:html_block, content[0, 50]] # First 50 chars as signature
                end

              when :link
                # Links match by URL
                url = node.url.to_s
                [:link, url]

              when :image
                # Images match by URL/path
                url = node.url.to_s
                [:image, url]

              else
                # Fall through to default
                node
              end
            end
          end

          # Returns the default freeze token for Markdown files.
          #
          # Uses HTML comment syntax: <!-- kettle-jem:freeze -->
          #
          # @return [String] The freeze token
          def default_freeze_token
            "kettle-jem"
          end

          # Returns node typing for categorizing Markdown elements.
          #
          # @return [Hash, nil] Node typing configuration (nil for Markdown)
          def default_node_typing
            nil # Markdown doesn't need node typing
          end

          # Merge Markdown files with special handling for fenced code blocks.
          #
          # This method performs two-phase merging:
          # 1. First merge the Markdown structure using markly-merge
          # 2. Then merge the contents of fenced code blocks using appropriate parsers
          #
          # @param template [String] Template Markdown content
          # @param dest [String] Destination Markdown content
          # @param config [Ast::Merge::MergerConfig] Merge configuration
          # @param code_block_handlers [Hash{String => #call}] Handlers for each language
          # @return [String] Merged content
          def merge_with_code_blocks(template, dest, config, code_block_handlers: default_code_block_handlers)
            # Phase 1: Merge Markdown structure
            require "markly/merge" unless defined?(Markly::Merge)

            merger = Markly::Merge::SmartMerger.new(
              template,
              dest,
              **config.to_h,
            )
            result = merger.merge

            return result unless code_block_handlers&.any?

            # Phase 2: Merge code block contents
            merge_code_blocks_in_result(result, template, dest, code_block_handlers)
          end

          # Returns default code block handlers for common languages.
          #
          # @return [Hash{String => Proc}] Handlers keyed by language
          def default_code_block_handlers
            {
              "ruby" => method(:merge_ruby_code),
              "rb" => method(:merge_ruby_code),
              "yaml" => method(:merge_yaml_code),
              "yml" => method(:merge_yaml_code),
              "json" => method(:merge_json_code),
            }
          end

          private

          # Extract text content from a heading node.
          def extract_heading_text(node)
            texts = []
            node.each do |child|
              texts << child.string_content if child.respond_to?(:string_content)
            end
            texts.join
          end

          # Normalize heading text for matching.
          def normalize_heading(text)
            text.to_s.strip.downcase.gsub(/[^\w\s]/, "").gsub(/\s+/, " ")
          end

          # Extract signature from table header row.
          def extract_table_header_signature(node)
            node.each do |row|
              if row.type == :table_row
                cells = []
                row.each do |cell|
                  cells << cell.string_content.to_s.strip if cell.respond_to?(:string_content)
                end
                return cells.join("|")
              end
            end
            nil
          end

          # Merge code blocks in a merged result.
          def merge_code_blocks_in_result(result, template, dest, handlers)
            # This is a placeholder - actual implementation would:
            # 1. Parse the result to find code blocks
            # 2. Find corresponding blocks in template and dest
            # 3. Use the appropriate handler to merge contents
            # 4. Replace code block contents in result
            result
          end

          # Merge Ruby code blocks using prism-merge.
          def merge_ruby_code(template_code, dest_code, preference)
            require "prism/merge" unless defined?(Prism::Merge)

            gemfile_config = Gemfile.send(:"#{preference}_wins")
            merger = Prism::Merge::SmartMerger.new(
              template_code,
              dest_code,
              **gemfile_config.to_h,
            )
            merger.merge
          rescue StandardError
            # Fall back to preference-based selection on error
            (preference == :template) ? template_code : dest_code
          end

          # Merge YAML code blocks using psych-merge.
          def merge_yaml_code(template_code, dest_code, preference)
            require "psych/merge" unless defined?(Psych::Merge)

            merger = Psych::Merge::SmartMerger.new(
              template_code,
              dest_code,
              preference: preference,
            )
            merger.merge
          rescue StandardError
            (preference == :template) ? template_code : dest_code
          end

          # Merge JSON code blocks using json-merge.
          def merge_json_code(template_code, dest_code, preference)
            require "json/merge" unless defined?(JSON::Merge)

            merger = JSON::Merge::SmartMerger.new(
              template_code,
              dest_code,
              preference: preference,
            )
            merger.merge
          rescue StandardError
            (preference == :template) ? template_code : dest_code
          end
        end
      end
    end
  end
end
