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
    # === Migration note (Phase 6 — AST over regex)
    #
    # Section preservation uses PartialTemplateMerger (PTM) from markly-merge
    # with swapped template/destination roles:
    #
    # - PTM +destination:+ = the running document (starts as the token-resolved template)
    # - PTM +template:+ = the extracted section content from the original destination
    # - PTM +replace_mode: true+ stamps the destination's section over the template's
    #
    # This is conceptually inverted (the "template" argument holds destination content),
    # but mechanically correct: PTM locates a section in its +destination:+ argument and
    # replaces it with its +template:+ argument.
    #
    # H1 preservation remains line-based because an H1 section spans the entire document
    # in Markdown heading-level semantics, making PTM section replacement unsuitable.
    # This is an accepted narrow text operation per the migration plan.
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
      # @param preset [Ast::Merge::Recipe::Config, nil] Optional executable recipe
      # @return [String] Merged content
      def merge(template_content:, destination_content:, preset: nil)
        return template_content if destination_content.nil? || destination_content.strip.empty?

        recipe = preset || Kettle::Jem.recipe(:readme)
        Ast::Merge::Recipe::Runner.new(recipe).run_content(
          template_content: template_content,
          destination_content: destination_content,
          relative_path: "README.md",
        ).content
      end

      # Replace designated sections in the template with their destination
      # counterparts using PartialTemplateMerger in replace_mode.
      #
      # For each preserved section found in both template and destination,
      # PTM is invoked with roles swapped:
      #   PTM destination: = running document (template being modified)
      #   PTM template:    = section content extracted from original destination
      #
      # @param template [String] The resolved template content (base document)
      # @param destination [String] The original destination content
      # @return [String] Content with preserved sections restored from destination
      def preserve_sections(template, destination)
        dest_sections = parse_sections(destination)
        dest_lookup = build_section_lookup(dest_sections)

        src_sections = parse_sections(template)
        preserve_targets = PRESERVE_SECTIONS.dup

        # Also preserve any "Note:*" sections found in the template
        src_sections[:sections].each do |sec|
          preserve_targets << sec[:base] if sec[:base].match?(NOTE_PATTERN)
        end

        return template if src_sections[:sections].empty?

        running = template

        # Process each section that should be preserved from destination.
        # Order doesn't matter because each PTM call re-parses the running
        # document and targets by heading text, not by line index.
        src_sections[:sections].each do |sec|
          next unless preserve_targets.include?(sec[:base])

          dest_entry = dest_lookup[sec[:base]]
          next unless dest_entry

          # Build the replacement content: heading (from template) + body (from destination)
          replacement_content = "#{sec[:heading]}\n#{dest_entry[:body_branch]}"

          # Use PTM with replace_mode to swap the template's section with destination's.
          # Roles are inverted: PTM "template:" holds the destination content to inject,
          # and PTM "destination:" holds the running document being modified.
          result = Markly::Merge::PartialTemplateMerger.new(
            template: replacement_content,
            destination: running,
            anchor: {type: :heading, text: build_anchor_pattern(sec[:base])},
            replace_mode: true,
            when_missing: :skip,
            backend: :markly,
          ).merge

          running = result.content if result.changed
        end

        running
      end

      # Preserve the entire H1 line from destination.
      #
      # This remains line-based because an H1 heading section encompasses the
      # entire Markdown document (no same-or-higher-level heading follows), so
      # PTM section replacement cannot be used for a single-line H1 swap.
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

      # Build an anchor pattern for matching a heading by its normalized base text.
      #
      # The base text is lowercase with leading non-alphanumeric characters stripped.
      # Markly heading nodes expose text with a trailing newline, so the pattern
      # uses +\s*\z+ to absorb any trailing whitespace.
      #
      # @param base [String] Normalized heading text (lowercase, leading non-alnum stripped)
      # @return [Regexp] Pattern that matches the heading content
      def build_anchor_pattern(base)
        /\A\s*#{Regexp.escape(base)}\s*\z/i
      end

      # ----------------------------------------------------------------
      # Section extraction helpers
      #
      # These parse destination content to extract section bodies for use
      # as PTM replacement templates. They use lightweight line-scanning
      # (not AST parsing) because the extraction is simple and the heavy
      # structural work (splicing) is delegated to PTM.
      # ----------------------------------------------------------------

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
