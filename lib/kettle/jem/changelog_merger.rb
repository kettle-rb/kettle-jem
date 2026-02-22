# frozen_string_literal: true

module Kettle
  module Jem
    # Merges CHANGELOG.md files following the Keep a Changelog convention.
    #
    # Strategy:
    #   1. Template header (title, intro text) replaces destination header
    #   2. Template's canonical Unreleased section structure is used
    #      (Added/Changed/Deprecated/Removed/Fixed/Security subheadings)
    #   3. Destination's existing Unreleased list items are preserved
    #   4. Destination's version history is fully preserved
    #
    # @example
    #   merged = ChangelogMerger.merge(
    #     template_content: resolved_template,
    #     destination_content: existing_changelog,
    #   )
    module ChangelogMerger
      # The six standard Keep-a-Changelog subheadings, in canonical order.
      STD_HEADS = [
        "### Added",
        "### Changed",
        "### Deprecated",
        "### Removed",
        "### Fixed",
        "### Security",
      ].freeze

      module_function

      # Merge CHANGELOG content.
      #
      # @param template_content [String] Template content (after token replacement)
      # @param destination_content [String, nil] Existing destination content
      # @return [String] Merged CHANGELOG content
      def merge(template_content:, destination_content:)
        return template_content if destination_content.nil? || destination_content.strip.empty?

        src_lines = template_content.split("\n", -1)
        tpl_unrel_idx = src_lines.index { |ln| ln.match?(/^##\s*\[\s*Unreleased\s*\]/i) }

        # If template has no Unreleased heading, fall back to normalizing only
        unless tpl_unrel_idx
          return normalize_release_headers(template_content)
        end

        # 1) Template header: everything before the Unreleased heading
        tpl_header_pre = src_lines[0...tpl_unrel_idx]
        tpl_unrel_heading = src_lines[tpl_unrel_idx]

        # 2) Extract destination Unreleased content
        dest_lines = destination_content.split("\n", -1)
        dest_unrel_idx = dest_lines.index { |ln| ln.match?(/^##\s*\[\s*Unreleased\s*\]/i) }
        dest_end_idx = find_section_end(dest_lines, dest_unrel_idx)
        dest_unrel_body = dest_unrel_idx ? (dest_lines[(dest_unrel_idx + 1)..dest_end_idx] || []) : []

        # 3) Parse destination list items per subheading
        dest_items = parse_items(dest_unrel_body)

        # 4) Build canonical Unreleased section with destination items
        new_unrel_block = [tpl_unrel_heading]
        STD_HEADS.each do |h|
          new_unrel_block << h
          new_unrel_block.concat(dest_items[h]) if dest_items[h]&.any?
        end

        # 5) Compose: template header + new unreleased + destination history
        tail_after_unrel = dest_unrel_idx ? (dest_lines[(dest_end_idx + 1)..] || []) : []

        # Normalize spacing between sections
        new_unrel_block.pop while new_unrel_block.any? && new_unrel_block.last.to_s.strip.empty?
        tail_after_unrel.shift while tail_after_unrel.any? && tail_after_unrel.first.to_s.strip.empty?

        merged_lines = tpl_header_pre + new_unrel_block
        merged_lines << "" if tail_after_unrel.any?
        merged_lines.concat(tail_after_unrel)

        normalize_release_headers(merged_lines.join("\n"))
      end

      # Find the end index of the Unreleased section (exclusive).
      #
      # @param lines [Array<String>] All CHANGELOG lines
      # @param unrel_idx [Integer, nil] Index of the Unreleased heading
      # @return [Integer, nil] End index (inclusive)
      def find_section_end(lines, unrel_idx)
        return unless unrel_idx

        j = unrel_idx + 1
        while j < lines.length
          ln = lines[j]
          if ln.match?(/^##\s+\[/) || ln.match?(/^#\s+/) || ln.match?(/^##\s+[^\[]/)
            return j - 1
          end
          j += 1
        end
        lines.length - 1
      end

      # Parse Unreleased body into map of subheading => list items.
      # Each list item includes its continuation lines (indented, fenced, blank).
      #
      # @param body_lines [Array<String>] Lines of the Unreleased section body
      # @return [Hash{String => Array<String>}] Subheading => lines (including bullets)
      def parse_items(body_lines)
        result = {}
        cur = nil
        i = 0
        while i < body_lines.length
          ln = body_lines[i]

          if ln.start_with?("### ")
            cur = ln.strip
            result[cur] ||= []
            i += 1
            next
          end

          if (m = ln.match(/^(\s*)[-*]\s/))
            result[cur] ||= []
            base_indent = m[1].length
            result[cur] << ln.rstrip
            i += 1

            # Collect continuation lines
            in_fence = false
            while i < body_lines.length
              l2 = body_lines[i]

              # New bullet at same or lesser indent → stop
              if !in_fence && l2.match?(/^(\s*)[-*]\s/)
                break if l2[/^\s*/].length <= base_indent
              end
              break if !in_fence && l2.start_with?("### ")

              if l2&.match?(/^\s*```/)
                in_fence = !in_fence
                result[cur] << l2.rstrip
                i += 1
                next
              end

              if in_fence || l2.strip.empty? || l2[/^\s*/].length > base_indent
                result[cur] << l2.rstrip
                i += 1
                next
              end

              break
            end
            next
          end

          i += 1
        end
        result
      end

      # Collapse repeated whitespace in version-release header lines.
      #
      # @param text [String] CHANGELOG content
      # @return [String] Content with normalized release headers
      def normalize_release_headers(text)
        lines = text.split("\n", -1)
        lines.map! do |ln|
          ln.match?(/^##\s+\[.*\]/) ? ln.gsub(/[ \t]+/, " ") : ln
        end
        lines.join("\n")
      end
    end
  end
end
