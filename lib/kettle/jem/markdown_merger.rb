# frozen_string_literal: true

module Kettle
  module Jem
    # Merges README.md files using markly-merge with section-level
    # destination preservation.
    #
    # The template provides structure and boilerplate. Certain sections
    # are preserved from the destination:
    #   - The H1 line (title with emoji prefix)
    #   - "Synopsis"
    #   - "Configuration"
    #   - "Basic Usage"
    #   - Any "Note:*" section at any heading level
    #
    # @example
    #   merged = MarkdownMerger.merge(
    #     template_content: resolved,
    #     destination_content: existing,
    #   )
    module MarkdownMerger
      # Sections whose body content is preserved from the destination.
      # Matched by normalized heading text (lowercase, alphanumeric + spaces).
      PRESERVE_SECTIONS = %w[synopsis configuration basic\ usage].freeze

      # Pattern for "Note:" headings (any level) that are also preserved.
      NOTE_PATTERN = /\Anote:/i

      module_function

      # Merge README content by using the template as-is and replacing
      # designated sections with their destination counterparts.
      #
      # @param template_content [String] Template content (after token replacement)
      # @param destination_content [String, nil] Existing destination content
      # @param preset [Ast::Merge::Recipe::Preset, nil] Optional preset (reserved for future use)
      # @return [String] Merged content
      def merge(template_content:, destination_content:, preset: nil)
        return template_content if destination_content.nil? || destination_content.strip.empty?

        # Phase 1: Replace preserved sections with destination content
        merged = preserve_sections(template_content, destination_content)

        # Phase 2: Preserve entire H1 line from destination
        preserve_h1(merged, destination_content)
      end

      # Replace the body of designated sections in merged with their
      # destination counterparts (entire branch from heading to next
      # same-or-higher-level heading).
      #
      # @param merged [String] The SmartMerger output
      # @param destination [String] The original destination content
      # @return [String] Content with preserved sections restored
      def preserve_sections(merged, destination)
        dest_sections = parse_sections(destination)
        dest_lookup = build_section_lookup(dest_sections)

        src_sections = parse_sections(merged)
        preserve_targets = PRESERVE_SECTIONS.dup

        # Also preserve any "Note:*" sections found in the merged content
        src_sections[:sections].each do |sec|
          preserve_targets << sec[:base] if sec[:base] =~ NOTE_PATTERN
        end

        return merged if src_sections[:sections].empty?

        lines = src_sections[:lines].dup

        # Iterate in reverse to keep line indices valid
        src_sections[:sections].reverse_each.with_index do |sec, rev_i|
          next unless preserve_targets.include?(sec[:base])

          i = src_sections[:sections].length - 1 - rev_i
          src_end = branch_end(src_sections[:sections], i, src_sections[:line_count])

          dest_entry = dest_lookup[sec[:base]]
          new_body = dest_entry ? dest_entry[:body_branch] : "\n\n"
          new_block = [sec[:heading], new_body].join("\n")

          lines.slice!(sec[:start]..src_end)
          insert_lines = new_block.split("\n", -1)
          lines.insert(sec[:start], *insert_lines)
        end

        lines.join("\n")
      end

      # Preserve the entire H1 line from destination.
      #
      # @param merged [String] Current merged content
      # @param destination [String] Original destination content
      # @return [String] Content with H1 restored from destination
      def preserve_h1(merged, destination)
        dest_h1 = destination.lines.find { |ln| ln.match?(/^#\s+/) }
        return merged unless dest_h1

        lines = merged.split("\n", -1)
        h1_idx = lines.index { |ln| ln.match?(/^#\s+/) }
        return merged unless h1_idx

        lines[h1_idx] = dest_h1.chomp
        lines.join("\n")
      end

      # Parse Markdown into a sections structure.
      # Ignores headings inside fenced code blocks.
      #
      # @param md [String] Markdown content
      # @return [Hash] { lines:, sections:, line_count: }
      def parse_sections(md)
        return {lines: [], sections: [], line_count: 0} unless md

        lines = md.split("\n", -1)
        line_count = lines.length
        sections = []
        in_code = false
        fence_re = /^\s*```/

        lines.each_with_index do |ln, i|
          if ln&.match?(fence_re)
            in_code = !in_code
            next
          end
          next if in_code

          if (m = ln.match(/^(#+)\s+.+/))
            level = m[1].length
            base = ln.sub(/^#+\s+/, "").sub(/\A[^\p{Alnum}]+/u, "").strip.downcase
            sections << {start: i, level: level, heading: ln, base: base}
          end
        end

        {lines: lines, sections: sections, line_count: line_count}
      end

      # Build a lookup table from destination sections.
      # First occurrence of each base wins.
      #
      # @param parsed [Hash] Output of parse_sections
      # @return [Hash{String => Hash}] base => { body_branch:, level: }
      def build_section_lookup(parsed)
        lookup = {}
        return lookup unless parsed[:sections]

        parsed[:sections].each_with_index do |s, idx|
          next if lookup.key?(s[:base])

          be = branch_end(parsed[:sections], idx, parsed[:line_count])
          body_lines = parsed[:lines][(s[:start] + 1)..be] || []
          lookup[s[:base]] = {body_branch: body_lines.join("\n"), level: s[:level]}
        end

        lookup
      end

      # Compute the inclusive end line index for a section's branch
      # (everything until the next heading of same or higher level).
      #
      # @param sections [Array<Hash>] All parsed sections
      # @param idx [Integer] Index of the section
      # @param total_lines [Integer] Total line count
      # @return [Integer] Inclusive end line index
      def branch_end(sections, idx, total_lines)
        current = sections[idx]
        j = idx + 1
        while j < sections.length
          return sections[j][:start] - 1 if sections[j][:level] <= current[:level]
          j += 1
        end
        total_lines - 1
      end
    end
  end
end
