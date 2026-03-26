# frozen_string_literal: true

module Kettle
  module Jem
    # Merges README.md files using markly-merge with section-level
    # destination preservation.
    #
    # The template provides structure and heading text. Certain section
    # bodies are preserved from the destination:
    #   - "Synopsis"
    #   - "Configuration"
    #   - "Basic Usage"
    #   - Any "Note:*" section at any heading level
    #
    # H1 handling is conditional: preserve the destination heading only when
    # its semantic text differs from the template. When the only difference is
    # a decorative leading adornment (emoji, keycap, etc.), the template H1
    # wins so heading emojis can be refreshed.
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

      # Prefix for "Note:" headings (any level) that are also preserved.
      NOTE_PREFIX = "note:"

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
          preserve_targets << sec[:base] if note_heading?(sec[:base])
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
          replacement_content = [sec[:heading], dest_entry[:body_branch]].join("\n")

          # Use PTM with replace_mode to swap the template's section with destination's.
          # Roles are inverted: PTM "template:" holds the destination content to inject,
          # and PTM "destination:" holds the running document being modified.
          result = Markly::Merge::PartialTemplateMerger.new(
            template: replacement_content,
            destination: running,
            anchor: {type: :heading, text: build_anchor_pattern(sec[:heading_text])},
            replace_mode: true,
            when_missing: :skip,
            backend: :markly,
          ).merge

          running = result.content if result.changed
        end

        running
      end

      # Preserve the destination H1 only when its semantic text differs from
      # the merged/template H1.
      #
      # This remains line-based because an H1 heading section encompasses the
      # entire Markdown document (no same-or-higher-level heading follows), so
      # PTM section replacement cannot be used for a single-line H1 swap.
      #
      # @param merged [String] Current merged content
      # @param destination [String] Original destination content
      # @return [String] Content with H1 restored from destination
      def preserve_h1(merged, destination)
        destination_h1 = parse_sections(destination)[:sections].find { |section| section[:level] == 1 }
        merged_h1 = parse_sections(merged)[:sections].find { |section| section[:level] == 1 }
        return merged unless destination_h1 && merged_h1

        replacement = destination_h1[:source].to_s
        return merged if replacement.empty? || replacement == merged_h1[:source]
        return merged if semantic_heading_text(destination_h1[:heading_text]) == semantic_heading_text(merged_h1[:heading_text])

        Ast::Merge::StructuralEdit::PlanSet.new(
          source: merged,
          plans: [
            Ast::Merge::StructuralEdit::SplicePlan.new(
              source: merged,
              replacement: replacement,
              replace_start_line: merged_h1[:start_line],
              replace_end_line: merged_h1[:end_line],
              metadata: {
                source: :kettle_jem_markdown_merger,
                edit: :preserve_h1,
              },
            ),
          ],
          metadata: {
            source: :kettle_jem_markdown_merger,
            edit: :preserve_h1,
          },
        ).merged_content
      end

      # Build an anchor pattern for matching a heading by its exact rendered text.
      #
      # Markly heading nodes expose text with a trailing newline, so the pattern
      # uses +\s*\z+ to absorb any trailing whitespace.
      #
      # @param text [String] Heading text content without the leading markdown hashes
      # @return [Regexp] Pattern that matches the heading content
      def build_anchor_pattern(text)
        /\A\s*#{Regexp.escape(text.to_s.strip)}\s*\z/i
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
      # Uses markly-merge analysis so only real top-level heading statements are
      # considered; headings inside fenced code blocks are naturally excluded.
      #
      # @param md [String] Markdown content
      # @return [Hash] { lines:, sections:, line_count: }
      def parse_sections(md)
        return {lines: [], sections: [], line_count: 0} unless md

        lines = md.split("\n", -1)
        line_count = lines.length
        analysis = markdown_analysis(md)
        sections = analysis ? heading_sections_from_analysis(analysis) : []

        {lines: lines, sections: sections, line_count: line_count, analysis: analysis}
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
          lookup[s[:base]] = {
            body_branch: section_body_branch(parsed, s, be),
            level: s[:level],
          }
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

      def markdown_analysis(md)
        analysis = Markly::Merge::FileAnalysis.new(md.to_s)
        analysis if analysis.valid?
      rescue StandardError
        nil
      end

      def heading_sections_from_analysis(analysis)
        Array(analysis.statements).filter_map do |statement|
          next unless heading_statement?(statement)

          build_heading_section(statement, analysis)
        end
      end

      def heading_statement?(statement)
        merge_type = if statement.respond_to?(:merge_type)
          statement.merge_type
        else
          unwrap_markdown_statement(statement)&.type
        end

        merge_type.to_s == "heading" || merge_type.to_s == "header"
      end

      def build_heading_section(statement, analysis)
        node = unwrap_markdown_statement(statement)
        position = node&.source_position
        return unless node && position

        heading_source = analysis.source_range(position[:start_line], position[:end_line]).sub(/\n\z/, "")
        heading_text = node.to_plaintext.to_s.sub(/\n+\z/, "")

        {
          start: position[:start_line] - 1,
          start_line: position[:start_line],
          end_line: position[:end_line],
          level: node.header_level,
          heading: heading_source,
          heading_text: heading_text,
          source: heading_source,
          base: normalize_heading_base(heading_text),
        }
      rescue StandardError
        nil
      end

      def unwrap_markdown_statement(statement)
        if defined?(Ast::Merge::NodeTyping)
          Ast::Merge::NodeTyping.unwrap(statement)
        else
          statement
        end
      rescue StandardError
        statement
      end

      def normalize_heading_base(text)
        strip_leading_heading_adornment(text).strip.downcase
      end

      def semantic_heading_text(text)
        strip_leading_heading_adornment(text).downcase.gsub(/[^\p{Alnum}\s]/u, "").squeeze(" ").strip
      end

      def note_heading?(base)
        base.to_s.start_with?(NOTE_PREFIX)
      end

      def strip_leading_heading_adornment(text)
        text.to_s.sub(/\A(?:\d\uFE0F?\u20E3|[^[:alnum:][:space:]])+[ \t]*/u, "")
      end

      def section_body_branch(parsed, section, body_end_index)
        start_line = section[:start] + 2
        end_line = body_end_index + 1
        return "" if end_line < start_line

        if parsed[:analysis]
          parsed[:analysis].source_range(start_line, end_line)
        else
          (parsed[:lines][(section[:start] + 1)..body_end_index] || []).join("\n")
        end
      end
    end
  end
end
