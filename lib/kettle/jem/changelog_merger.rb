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
    # === Migration note (Phase 6 — AST over regex)
    #
    # The Unreleased section replacement uses PartialTemplateMerger (PTM) from
    # markly-merge with +replace_mode: true+ for AST-aware section boundary
    # detection and source-preserving document splicing.
    #
    # The domain-specific +parse_items+ logic and +STD_HEADS+ canonical ordering
    # loop are retained because SmartMerger cannot express these semantics:
    # - SmartMerger sorts matched nodes by destination index, not template index
    # - Headings and lists are unpaired siblings in the Markdown AST
    # - There is no +ordering: :template+ mode in FileAligner
    #
    # The header replacement (template header wins over destination header) and
    # release-header whitespace normalization remain as narrow line-based text
    # operations — accepted residual text handling per the migration plan.
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

      # Pattern matching the Unreleased heading in a CHANGELOG.
      UNRELEASED_PATTERN = /^##\s*\[\s*Unreleased\s*\]/i

      module_function

      # Merge CHANGELOG content.
      #
      # @param template_content [String] Template content (after token replacement)
      # @param destination_content [String, nil] Existing destination content
      # @param preset [Ast::Merge::Recipe::Config, nil] Optional executable recipe
      # @return [String] Merged CHANGELOG content
      def merge(template_content:, destination_content:, preset: nil)
        return template_content if destination_content.nil? || destination_content.strip.empty?

        recipe = preset || Kettle::Jem.recipe(:changelog)
        Ast::Merge::Recipe::Runner.new(recipe).run_content(
          template_content: template_content,
          destination_content: destination_content,
          relative_path: "CHANGELOG.md",
        ).content
      end

      # Build the merged content through the canonical Unreleased replacement
      # pass while preserving destination version history and link references.
      #
      # This is the first hybrid recipe step for CHANGELOG merging.
      #
      # @param template_content [String]
      # @param destination_content [String]
      # @return [String]
      def merge_unreleased_content(template_content, destination_content)
        src_lines = template_content.split("\n", -1)
        tpl_unrel_idx = src_lines.index { |ln| ln.match?(UNRELEASED_PATTERN) }

        # If template has no Unreleased heading, leave later recipe steps to
        # finalize the template content without trying to splice a section.
        unless tpl_unrel_idx
          return template_content
        end

        # 1) Extract template heading for the canonical Unreleased section
        tpl_unrel_heading = src_lines[tpl_unrel_idx]

        # 2) Extract destination Unreleased body and parse list items
        dest_lines = destination_content.split("\n", -1)
        dest_unrel_idx = dest_lines.index { |ln| ln.match?(UNRELEASED_PATTERN) }
        dest_end_idx = find_section_end(dest_lines, dest_unrel_idx)
        dest_unrel_body = dest_unrel_idx ? (dest_lines[(dest_unrel_idx + 1)..dest_end_idx] || []) : []
        dest_items = parse_items(dest_unrel_body)

        # 3) Build canonical Unreleased section with destination items
        canonical_section = build_canonical_unreleased(tpl_unrel_heading, dest_items)

        # 4) Replace destination's Unreleased section with the canonical one via PTM
        replace_unreleased_section(destination_content, canonical_section, dest_unrel_idx)
      end

      # Extract the template header lines (everything before the Unreleased
      # section) for the header-replacement recipe step.
      #
      # @param template_content [String]
      # @return [Array<String>, nil]
      def template_header_lines(template_content)
        src_lines = template_content.split("\n", -1)
        tpl_unrel_idx = src_lines.index { |ln| ln.match?(UNRELEASED_PATTERN) }
        return unless tpl_unrel_idx

        src_lines[0...tpl_unrel_idx]
      end

      # Replace the rendered header with the template header when the template
      # has an Unreleased section to anchor the split point.
      #
      # @param merged [String]
      # @param template_content [String]
      # @return [String]
      def replace_header_from_template(merged, template_content)
        tpl_header_lines = template_header_lines(template_content)
        return merged unless tpl_header_lines

        replace_header(merged, tpl_header_lines)
      end

      # Normalize release headers and ensure a trailing newline.
      #
      # @param text [String]
      # @return [String]
      def finalize_content(text)
        result = normalize_release_headers(text)
        result.end_with?("\n") ? result : "#{result}\n"
      end

      # Build the canonical Unreleased section from template heading and
      # destination list items in STD_HEADS order.
      #
      # @param heading [String] The Unreleased heading line (from template)
      # @param dest_items [Hash{String => Array<String>}] Destination items by subheading
      # @return [String] The canonical Unreleased section content
      def build_canonical_unreleased(heading, dest_items)
        block = [heading]
        STD_HEADS.each do |h|
          block << ""
          block << h
          if dest_items[h]&.any?
            items = dest_items[h].dup
            # Strip trailing blank lines from items — our blank line before the
            # next heading provides the inter-section spacing.
            items.pop while items.any? && items.last.to_s.strip.empty?
            block.concat(items)
          end
        end
        # Trim trailing blank lines from the section
        block.pop while block.any? && block.last.to_s.strip.empty?
        block.join("\n")
      end

      # Replace the Unreleased section in destination using PTM.
      #
      # Uses PartialTemplateMerger with replace_mode to splice the canonical
      # section into the destination at the Unreleased heading, preserving all
      # content before and after (header, version history, link references).
      #
      # Falls back to simple concatenation when the destination has no
      # Unreleased heading (PTM would skip).
      #
      # @param destination [String] Full destination content
      # @param canonical_section [String] The built canonical Unreleased section
      # @param dest_unrel_idx [Integer, nil] Line index of Unreleased heading (for fallback)
      # @return [String] Destination with Unreleased section replaced
      def replace_unreleased_section(destination, canonical_section, dest_unrel_idx)
        if dest_unrel_idx
          # PTM replaces the destination's Unreleased section with the canonical one.
          # PTM "template:" = the canonical section content to inject;
          # PTM "destination:" = the real destination document.
          result = Markly::Merge::PartialTemplateMerger.new(
            template: canonical_section,
            destination: destination,
            anchor: {type: :heading, text: /\A\s*\[?\s*Unreleased\s*\]?\s*\z/i},
            replace_mode: true,
            when_missing: :skip,
            backend: :markly,
          ).merge

          result.content
        else
          # No Unreleased in destination — just prepend the section
          destination.chomp + "\n\n" + canonical_section + "\n"
        end
      end

      # Replace the header (everything before the first ## heading) in merged
      # content with the template's header lines.
      #
      # This is a narrow line-based operation (accepted residual text handling)
      # because the pre-heading content is not a section in Markdown AST terms.
      #
      # @param merged [String] Current merged content
      # @param tpl_header_lines [Array<String>] Template header lines (before ## [Unreleased])
      # @return [String] Content with header replaced
      def replace_header(merged, tpl_header_lines)
        lines = merged.split("\n", -1)
        # Find the first ## heading in the merged content
        first_h2_idx = lines.index { |ln| ln.match?(/^##\s/) }
        return merged unless first_h2_idx

        # Replace everything before the first ## heading with template header
        remaining = lines[first_h2_idx..]
        new_lines = tpl_header_lines + remaining
        new_lines.join("\n")
      end

      # Find the end index of the Unreleased section (exclusive).
      # Stops at the next version heading (`## [version]`), a top-level heading,
      # or a block of link reference definitions at the bottom of the file
      # (e.g., `[Unreleased]: https://...`).
      #
      # @param lines [Array<String>] All CHANGELOG lines
      # @param unrel_idx [Integer, nil] Index of the Unreleased heading
      # @return [Integer, nil] End index (inclusive)
      def find_section_end(lines, unrel_idx)
        return unless unrel_idx

        j = unrel_idx + 1
        while j < lines.length
          ln = lines[j]
          # Stop at the next version heading or top-level heading
          if ln.match?(/^##\s+\[/) || ln.match?(/^#\s+/) || ln.match?(/^##\s+[^\[]/)
            return j - 1
          end
          # Stop at link reference definitions (e.g., [Unreleased]: https://...)
          # These live at the bottom of the file, outside any section.
          if ln.match?(/^\[.+\]:\s/)
            return j - 1
          end
          j += 1
        end
        lines.length - 1
      end

      # Parse Unreleased body into map of subheading => list items.
      # Each list item includes its continuation lines (indented, fenced, blank).
      #
      # This is domain-specific Keep-a-Changelog logic that cannot be expressed
      # through SmartMerger because headings and lists are unpaired siblings in
      # the Markdown AST, and SmartMerger preserves destination ordering rather
      # than enforcing canonical template ordering.
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
