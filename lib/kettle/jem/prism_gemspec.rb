# frozen_string_literal: true

require "set"

module Kettle
  module Jem
    # Prism helpers for gemspec manipulation.
    module PrismGemspec
      module_function

      MODERN_VERSION_LOADER_MIN_RUBY = Gem::Version.new("3.1").freeze
      GEMSPEC_DEPENDENCY_LINE_RE = /^(?<indent>\s*)spec\.(?<method>add_(?:development_|runtime_)?dependency)\s*\(?\s*(?<args>(?<quote>["'])(?<gem>[^"']+)\k<quote>.*?)(?:\s*\))?\s*(?<comment>#.*)?(?:\n|\z)/
      GEMSPEC_NOTE_BLOCK_START_RE = /^\s*# NOTE: It is preferable to list development dependencies in the gemspec due to increased/

      # Explicit contract for gemspec dependency-section normalization.
      #
      # Given merged gemspec content plus template/destination source content, this
      # helper normalizes dependency sections by restoring preferred formatting for
      # matched dependency signatures, suppressing development dependencies that are
      # now runtime dependencies, and keeping runtime dependency blocks above the
      # development-dependency note block while carrying attached comments/spacing.
      module DependencySectionPolicy
        module_function

        def normalize(content:, template_content:, destination_content:, prefer_template: false)
          lines = content.to_s.lines
          return content if lines.empty?

          preferred_lines = if prefer_template
            dependency_line_lookup(template_content)
          else
            dependency_line_lookup(destination_content)
          end

          fallback_lines = prefer_template ? dependency_line_lookup(destination_content) : dependency_line_lookup(template_content)
          fallback_lines.each do |signature, line|
            preferred_lines[signature] ||= line
          end

          lines.each_with_index do |line, idx|
            match = dependency_line_match(line)
            next unless match

            preferred = preferred_lines[dependency_lookup_key(match)]
            lines[idx] = preferred.dup if preferred
          end

          runtime_gems = dependency_records(lines)
            .select { |record| runtime_dependency_method?(record[:method]) }
            .map { |record| record[:gem] }
            .to_set

          duplicate_dev_ranges = dependency_records(lines)
            .select { |record| record[:method] == "add_development_dependency" && runtime_gems.include?(record[:gem]) }
            .map { |record| dependency_block_range(lines, record[:line_index]) }

          lines = remove_line_ranges(lines, duplicate_dev_ranges)

          note_index = note_block_start_index(lines)
          return lines.join unless note_index

          note_end_index = note_block_end_index(lines, note_index)

          runtime_after_note = runtime_records_after_note(lines, note_end_index)

          return lines.join if runtime_after_note.empty?

          moved_blocks = []
          runtime_after_note.reverse_each do |record|
            range = dependency_block_range(lines, record[:line_index], stop_above_index: note_end_index)
            moved_blocks.unshift(lines[range].map(&:dup))
            lines = remove_line_ranges(lines, [range])
          end

          insert_blocks_before_note(lines, moved_blocks)
        end

        def note_block_start_index(lines)
          Array(lines).index { |line| PrismGemspec::GEMSPEC_NOTE_BLOCK_START_RE.match?(line) }
        end

        def note_block_end_index(lines, note_index)
          end_index = note_index

          while lines[end_index + 1]&.lstrip&.match?(/^#\s{2,}/)
            end_index += 1
          end

          end_index += 1 if lines[end_index + 1]&.strip&.empty?

          end_index
        end

        def runtime_records_after_note(lines, note_index)
          dependency_records(lines)
            .select { |record| runtime_dependency_method?(record[:method]) && record[:line_index] > note_index }
        end

        def insert_blocks_before_note(lines, blocks)
          note_index = note_block_start_index(lines)
          return lines.join unless note_index

          insertion = build_dependency_block_insertion(
            blocks,
            before_line: note_index.positive? ? lines[note_index - 1] : nil,
            after_line: lines[note_index],
          )

          (lines[0...note_index] + insertion + lines[note_index..]).join
        end

        def insertion_line_index(lines)
          note_index = note_block_start_index(lines)
          return note_block_end_index(lines, note_index) + 1 if note_index

          Array(lines).rindex { |line| line.strip == "end" } || Array(lines).length
        end

        def dependency_line_lookup(content)
          content.to_s.each_line.each_with_object({}) do |line, memo|
            match = dependency_line_match(line)
            next unless match

            normalized_line = line.end_with?("\n") ? line : "#{line}\n"
            memo[dependency_lookup_key(match)] ||= normalized_line
          end
        end

        def dependency_records(lines)
          Array(lines).each_with_index.filter_map do |line, idx|
            match = dependency_line_match(line)
            next unless match

            {
              line_index: idx,
              method: match[:method],
              gem: match[:gem],
            }
          end
        end

        def dependency_line_match(line)
          match = PrismGemspec::GEMSPEC_DEPENDENCY_LINE_RE.match(line.to_s)
          return unless match

          {
            method: match[:method],
            gem: match[:gem],
            signature: normalize_dependency_signature(match[:args]),
          }
        end

        def dependency_lookup_key(match)
          [match[:method], match[:signature]]
        end


        def normalize_dependency_signature(args_source)
          args_source.to_s.strip.gsub(/\s+/, " ")
        end

        def runtime_dependency_method?(method_name)
          %w[add_dependency add_runtime_dependency].include?(method_name.to_s)
        end

        def dependency_block_range(lines, line_index, stop_above_index: nil)
          attached_comment_start_index(lines, line_index, stop_above_index: stop_above_index)..trailing_blank_line_end_index(lines, line_index)
        end

        def remove_line_ranges(lines, ranges)
          new_lines = Array(lines).dup
          Array(ranges).sort_by(&:begin).reverse_each do |range|
            new_lines.slice!(range)
          end
          new_lines
        end

        def build_dependency_block_insertion(blocks, before_line:, after_line:)
          insertion = []
          insertion << "\n" if needs_separator_before_blocks?(before_line)

          Array(blocks).each_with_index do |block, idx|
            insertion.concat(block)
            next if idx == blocks.length - 1

            insertion << "\n" unless block_ends_with_separator?(block)
          end

          insertion << "\n" if needs_separator_after_blocks?(after_line, insertion)
          insertion
        end

        def attached_comment_start_index(lines, line_index, stop_above_index: nil)
          start_index = line_index
          while start_index.positive?
            break if !stop_above_index.nil? && (start_index - 1) <= stop_above_index

            previous_line = lines[start_index - 1]
            break unless previous_line.lstrip.start_with?("#")

            start_index -= 1
          end
          start_index
        end

        def trailing_blank_line_end_index(lines, line_index)
          end_index = line_index
          end_index += 1 if lines[end_index + 1]&.strip&.empty?
          end_index
        end

        def block_ends_with_separator?(block)
          Array(block).last.to_s.strip.empty?
        end

        def needs_separator_before_blocks?(before_line)
          before_line && !before_line.strip.empty?
        end

        def needs_separator_after_blocks?(after_line, insertion)
          after_line && !after_line.strip.empty? && insertion.last.to_s.strip != ""
        end
      end

      # Emit a debug warning for rescued errors when debugging is enabled.
      # @param error [Exception]
      # @param context [String, Symbol, nil] optional label, often __method__
      # @return [void]
      def debug_error(error, context = nil)
        Kettle::Dev.debug_error(error, context)
      end

      # Merge template and destination gemspec content through the shared recipe
      # runner so smart-merge orchestration and post-merge harmonization live in
      # the recipe surface instead of SourceMerger hooks.
      def merge(template_content, dest_content, preset: nil, min_ruby: nil, entrypoint_require: nil, namespace: nil, **options)
        template_content ||= ""
        dest_content ||= ""

        return dest_content if template_content.strip.empty?

        runtime_context = build_runtime_context(
          options.delete(:context),
          min_ruby: min_ruby,
          entrypoint_require: entrypoint_require,
          namespace: namespace,
        )
        return template_content if dest_content.strip.empty? && runtime_context.empty?

        recipe = preset || Kettle::Jem.recipe(:gemspec)
        run_options = {
          template_content: template_content,
          destination_content: dest_content,
          relative_path: "project.gemspec",
        }
        run_options[:context] = runtime_context unless runtime_context.empty?

        Ast::Merge::Recipe::Runner.new(recipe, **options).run_content(**run_options).content
      rescue StandardError => e
        Kernel.warn("[#{__method__}] Gemspec recipe merge failed: #{e.message}")
        template_content
      end

      def build_runtime_context(context, min_ruby:, entrypoint_require:, namespace:)
        runtime_context = context.respond_to?(:to_h) ? context.to_h : {}
        runtime_context = runtime_context.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
        runtime_context[:min_ruby] = min_ruby unless min_ruby.nil?
        runtime_context[:entrypoint_require] = entrypoint_require unless entrypoint_require.to_s.strip.empty?
        runtime_context[:namespace] = namespace unless namespace.to_s.strip.empty?
        runtime_context
      end

      # Extract leading emoji from text using Unicode grapheme clusters
      # @param text [String, nil] Text to extract emoji from
      # @return [String, nil] The first emoji grapheme cluster, or nil if none found
      def extract_leading_emoji(text)
        return unless text&.respond_to?(:scan)
        return if text.empty?

        first = text.scan(/\X/u).first
        return unless first

        emoji_re = Kettle::EmojiRegex::REGEX
        first if first.match?(/\A#{emoji_re.source}/u)
      end

      # Extract emoji from README H1 heading
      # @param readme_content [String, nil] README content
      # @return [String, nil] The emoji from the first H1, or nil if none found
      def extract_readme_h1_emoji(readme_content)
        return unless readme_content && !readme_content.empty?

        lines = readme_content.lines
        h1_line = lines.find { |ln| ln =~ /^#\s+/ }
        return unless h1_line

        text = h1_line.sub(/^#\s+/, "")
        extract_leading_emoji(text)
      end

      # Extract emoji from gemspec summary or description
      # @param gemspec_content [String] Gemspec content
      # @return [String, nil] The emoji from summary/description, or nil if none found
      def extract_gemspec_emoji(gemspec_content)
        return unless gemspec_content

        parse_result = PrismUtils.parse_with_comments(gemspec_content)
        return unless parse_result.success?

        statements = PrismUtils.extract_statements(parse_result.value.statements)

        gemspec_call = statements.find do |s|
          s.is_a?(Prism::CallNode) &&
            s.block &&
            PrismUtils.extract_const_name(s.receiver) == "Gem::Specification" &&
            s.name == :new
        end
        return unless gemspec_call

        body_node = gemspec_call.block&.body
        return unless body_node

        body_stmts = PrismUtils.extract_statements(body_node)

        %i[summary description].each do |field|
          node = body_stmts.find do |n|
            n.is_a?(Prism::CallNode) &&
              n.name.to_s.start_with?(field.to_s) &&
              n.receiver
          end

          next unless node

          first_arg = node.arguments&.arguments&.first
          value = PrismUtils.extract_literal_value(first_arg)
          next unless value

          emoji = extract_leading_emoji(value)
          return emoji if emoji
        end

        nil
      end

      # Synchronize README H1 emoji with gemspec emoji
      # @param readme_content [String] README content
      # @param gemspec_content [String] Gemspec content
      # @return [String] Updated README content
      def sync_readme_h1_emoji(readme_content:, gemspec_content:)
        return readme_content unless readme_content && gemspec_content

        gemspec_emoji = extract_gemspec_emoji(gemspec_content)
        return readme_content unless gemspec_emoji

        lines = readme_content.lines
        h1_idx = lines.index { |ln| ln =~ /^#\s+/ }
        return readme_content unless h1_idx

        h1_line = lines[h1_idx]
        text = h1_line.sub(/^#\s+/, "")

        # Remove any existing leading emoji(s)
        emoji_re = Kettle::EmojiRegex::REGEX
        while text =~ /\A#{emoji_re.source}/u
          cluster = text[/\A\X/u]
          text = text[cluster.length..-1].to_s
        end
        text = text.sub(/\A\s+/, "")

        new_h1 = "# #{gemspec_emoji} #{text}"
        new_h1 += "\n" unless new_h1.end_with?("\n")

        lines[h1_idx] = new_h1
        lines.join
      end

      # Replace scalar or array assignments inside a Gem::Specification.new block.
      # `replacements` is a hash mapping symbol field names to string or array values.
      # Operates only inside the Gem::Specification block to avoid accidental matches.
      def replace_gemspec_fields(content, replacements = {})
        return content if replacements.nil? || replacements.empty?

        context = gemspec_context(content)
        return content unless context

        require "ast-merge" unless defined?(Ast::Merge::StructuralEdit::PlanSet)

        build_literal = method(:build_literal_value)
        plans = []
        insertions = []
        lines = content.lines

        replacements.each do |field_sym, value|
          next if value.nil?

          field = field_sym.to_s

          found_node = find_field_node(context[:stmt_nodes], context[:blk_param], field)

          plan = if found_node
            build_replacement_plan(content, found_node, context[:blk_param], field, field_sym, value, build_literal)
          else
            build_insertion_plan(context[:stmt_nodes], context[:gemspec_call], context[:blk_param], field, field_sym, value, build_literal)
          end

          if plan.is_a?(Hash)
            insertions << plan
          elsif plan
            plans << plan
          end
        end

        plans = add_field_insertion_plans(plans, content: content, lines: lines, insertions: insertions)
        return content if plans.empty?

        Ast::Merge::StructuralEdit::PlanSet.new(
          source: content,
          plans: plans,
          metadata: {source: :kettle_jem_prism_gemspec},
        ).merged_content
      rescue StandardError => e
        debug_error(e, __method__)
        content
      end

      # Rewrite the gemspec version-loading logic based on the destination gem's
      # minimum supported Ruby. For Ruby >= 3.1 we can inline the anonymous-module
      # load expression directly into spec.version. Older rubies need the legacy
      # gem_version conditional block plus spec.version = gem_version.
      #
      # @param content [String]
      # @param min_ruby [Gem::Version, String]
      # @param entrypoint_require [String] require path like "kettle/jem"
      # @param namespace [String] Ruby namespace like "Kettle::Jem"
      # @return [String]
      def rewrite_version_loader(content, min_ruby:, entrypoint_require:, namespace:)
        return content if content.to_s.empty?
        return content if entrypoint_require.to_s.strip.empty? || namespace.to_s.strip.empty?

        min_version = Gem::Version.new(min_ruby.to_s)
        modern = min_version >= MODERN_VERSION_LOADER_MIN_RUBY

        result = PrismUtils.parse_with_comments(content)
        stmts = PrismUtils.extract_statements(result.value.statements)

        gemspec_call = stmts.find do |s|
          s.is_a?(Prism::CallNode) && s.block && PrismUtils.extract_const_name(s.receiver) == "Gem::Specification" && s.name == :new
        end
        return content unless gemspec_call

        blk_param = extract_block_param(gemspec_call) || "spec"
        body_node = gemspec_call.block&.body
        return content unless body_node

        stmt_nodes = PrismUtils.extract_statements(body_node)
        version_rhs = if modern
          modern_version_loader_expression(entrypoint_require: entrypoint_require, namespace: namespace)
        else
          "gem_version"
        end

        rewritten = replace_or_insert_raw_field_assignment(
          content: content,
          gemspec_call: gemspec_call,
          body_node: body_node,
          stmt_nodes: stmt_nodes,
          blk_param: blk_param,
          field: "version",
          rhs: version_rhs,
        )

        rewrite_version_preamble(
          rewritten,
          gemspec_call_start: gemspec_call.location.start_offset,
          modern: modern,
          entrypoint_require: entrypoint_require,
          namespace: namespace,
        )
      rescue StandardError => e
        debug_error(e, __method__)
        content
      end

      # Remove spec.add_dependency / add_development_dependency calls that name the given gem
      def remove_spec_dependency(content, gem_name)
        return content if gem_name.to_s.strip.empty?

        result = PrismUtils.parse_with_comments(content)
        return content unless result.success?

        stmts = PrismUtils.extract_statements(result.value.statements)
        gemspec_call = stmts.find do |stmt|
          stmt.is_a?(Prism::CallNode) && stmt.block && PrismUtils.extract_const_name(stmt.receiver) == "Gem::Specification" && stmt.name == :new
        end
        return content unless gemspec_call

        blk_param = extract_block_param(gemspec_call) || "spec"
        body_node = gemspec_call.block&.body
        return content unless body_node

        dependency_nodes = self_dependency_nodes(
          PrismUtils.extract_statements(body_node),
          blk_param,
          gem_name,
        )
        return content if dependency_nodes.empty?

        require "ast-merge" unless defined?(Ast::Merge::StructuralEdit::PlanSet)

        plans = dependency_nodes.map do |node|
          Ast::Merge::StructuralEdit::RemovePlan.new(
            source: content,
            remove_start_line: node.location.start_line,
            remove_end_line: node.location.end_line,
            metadata: {
              source: :kettle_jem_prism_gemspec,
              gem_name: gem_name.to_s,
              dependency_method: node.name,
            },
          )
        end

        Ast::Merge::StructuralEdit::PlanSet.new(
          source: content,
          plans: plans,
          metadata: {
            source: :kettle_jem_prism_gemspec,
            gem_name: gem_name.to_s,
          },
        ).merged_content
      rescue StandardError => e
        debug_error(e, __method__)
        content
      end

      # Ensure development dependency lines in a gemspec match the desired lines.
      # `desired` is a hash mapping gem_name => desired_line (string, without leading indentation).
      #
      # Normal operation prefers a Prism-backed edit because that lets setup/bootstrap
      # update real Gem::Specification bodies structurally. We still keep a narrow,
      # line-oriented fallback for the bootstrap case where the target file exists but
      # Prism cannot provide a usable gemspec context yet (for example: empty content,
      # a fragment missing the final `end`, or a file that is temporarily mid-edit).
      # That fallback is intentionally best-effort resilience for early setup flows,
      # not a claim that arbitrary malformed gemspecs are a first-class supported API.
      def ensure_development_dependencies(content, desired)
        return content if desired.nil? || desired.empty?

        lines = content.to_s.lines
        if lines.empty?
          out = content.dup
          out << "\n" unless out.end_with?("\n") || out.empty?
          desired.each do |_gem, line|
            out << line.strip + "\n"
          end
          return out
        end

        context = development_dependency_gemspec_context(content)
        return ensure_development_dependencies_fallback(content, desired) unless context

        require "ast-merge" unless defined?(Ast::Merge::StructuralEdit::PlanSet)

        dependency_records = dependency_node_records(context[:stmt_nodes], context[:blk_param])
        plans = []
        missing_lines = []

        desired.each do |gem_name, desired_line|
          runtime_record = dependency_records.find do |record|
            record[:gem] == gem_name && runtime_dependency_method?(record[:method])
          end
          next if runtime_record

          dev_record = dependency_records.find do |record|
            record[:gem] == gem_name && record[:method] == "add_development_dependency"
          end

          if dev_record
            plans << Ast::Merge::StructuralEdit::SplicePlan.new(
              source: content,
              replacement: formatted_dependency_line(desired_line, indent: dependency_indent(dev_record[:node])),
              replace_start_line: dev_record[:start_line],
              replace_end_line: dev_record[:end_line],
              metadata: {
                source: :kettle_jem_prism_gemspec,
                edit: :ensure_development_dependency_replace,
                gem_name: gem_name,
              },
            )
            next
          end

          missing_lines << formatted_dependency_line(desired_line, indent: "  ")
        end

        plans = add_missing_development_dependency_plans(
          plans,
          content: content,
          lines: lines,
          context: context,
          missing_lines: missing_lines,
        )

        updated = if plans.empty?
          content
        else
          Ast::Merge::StructuralEdit::PlanSet.new(
            source: content,
            plans: plans,
            metadata: {source: :kettle_jem_prism_gemspec, edit: :ensure_development_dependencies},
          ).merged_content
        end

        normalize_dependency_sections(
          updated,
          template_content: desired.values.join("\n"),
          destination_content: content,
          prefer_template: true,
        )
      rescue StandardError => e
        debug_error(e, __method__)
        content
      end

      # Best-effort bootstrap fallback when Prism parsing/context extraction is
      # unavailable. This only syncs dependency lines conservatively so SetupCLI can
      # seed or repair development dependencies without hard-failing on an incomplete
      # gemspec that may be normalized later in the same workflow.
      def ensure_development_dependencies_fallback(content, desired)
        lines = content.to_s.lines
        missing_lines = []

        desired.each do |gem_name, desired_line|
          records = dependency_records(lines)
          runtime_record = records.find do |record|
            record[:gem] == gem_name && runtime_dependency_method?(record[:method])
          end
          next if runtime_record

          dev_record = records.find do |record|
            record[:gem] == gem_name && record[:method] == "add_development_dependency"
          end

          if dev_record
            indent = lines[dev_record[:line_index]][/^(\s*)/, 1] || ""
            lines[dev_record[:line_index]] = indent + desired_line.strip + "\n"
            next
          end

          missing_lines << "  " + desired_line.strip + "\n"
        end

        unless missing_lines.empty?
          lines.insert(DependencySectionPolicy.insertion_line_index(lines), missing_lines.join)
        end

        normalize_dependency_sections(
          lines.join,
          template_content: desired.values.join("\n"),
          destination_content: content,
          prefer_template: true,
        )
      end

      # Return ordered development dependency entries from a gemspec, preferring
      # Prism-backed extraction when a usable Gem::Specification context exists.
      #
      # Each entry includes:
      # - :gem => dependency gem name
      # - :line => original dependency source line(s), preserving inline comments
      # - :signature => normalized/comparable dependency arguments
      #
      # When Prism is unavailable or the content is not parseable as a gemspec yet,
      # this falls back to the same conservative line-oriented scan used by
      # bootstrap flows so callers can still seed dependencies best-effort.
      def development_dependency_entries(content)
        context = development_dependency_gemspec_context(content)
        return development_dependency_entries_fallback(content) unless context

        dependency_node_records(context[:stmt_nodes], context[:blk_param]).filter_map do |record|
          next unless record[:method] == "add_development_dependency"

          {
            gem: record[:gem],
            line: PrismUtils.node_slice_with_trailing_comment(record[:node], content).rstrip,
            signature: dependency_signature(record[:node]),
          }
        end
      end

      def development_dependency_signatures(content)
        development_dependency_entries(content)
          .map { |entry| entry[:signature] }
          .compact
          .sort
      end

      def harmonize_merged_content(content, template_content:, destination_content:)
        return content if content.to_s.empty?

        updated = union_literal_dir_assignment(
          content,
          field: "files",
          template_content: template_content,
          destination_content: destination_content,
        )

        normalize_dependency_sections(
          updated,
          template_content: template_content,
          destination_content: destination_content,
          prefer_template: false,
        )
      rescue StandardError => e
        debug_error(e, __method__)
        content
      end

      def normalize_dependency_sections(content, template_content:, destination_content:, prefer_template: false)
        DependencySectionPolicy.normalize(
          content: content,
          template_content: template_content,
          destination_content: destination_content,
          prefer_template: prefer_template,
        )
      rescue StandardError => e
        debug_error(e, __method__)
        content
      end

      # --- Private helpers ---

      def development_dependency_gemspec_context(content)
        gemspec_context(content)
      rescue StandardError, LoadError => e
        debug_error(e, __method__)
        nil
      end

      def development_dependency_entries_fallback(content)
        content.to_s.lines.filter_map do |line|
          next if line.strip.start_with?("#")

          match = dependency_line_match(line)
          next unless match && match[:method] == "add_development_dependency"

          {
            gem: match[:gem],
            line: line.rstrip,
            signature: match[:signature],
          }
        end
      end

      def union_literal_dir_assignment(content, field:, template_content:, destination_content:)
        merged_context = gemspec_context(content)
        template_context = gemspec_context(template_content)
        destination_context = gemspec_context(destination_content)
        return content unless merged_context && template_context && destination_context

        merged_node = find_field_node(merged_context[:stmt_nodes], merged_context[:blk_param], field)
        template_node = find_field_node(template_context[:stmt_nodes], template_context[:blk_param], field)
        destination_node = find_field_node(destination_context[:stmt_nodes], destination_context[:blk_param], field)
        return content unless merged_node && template_node && destination_node

        replacement = merge_dir_assignment_source(
          merged_source: merged_node.slice,
          template_source: template_node.slice,
          destination_source: destination_node.slice,
        )
        return content unless replacement

        require "ast-merge" unless defined?(Ast::Merge::StructuralEdit::PlanSet)

        Ast::Merge::StructuralEdit::PlanSet.new(
          source: content,
          plans: [
            Ast::Merge::StructuralEdit::SplicePlan.new(
              source: content,
              replacement: replacement,
              replace_start_line: merged_node.location.start_line,
              replace_end_line: merged_node.location.end_line,
              metadata: {
                source: :kettle_jem_prism_gemspec,
                edit: :union_literal_dir_assignment,
                field: field,
              },
            ),
          ],
          metadata: {source: :kettle_jem_prism_gemspec, edit: :union_literal_dir_assignment, field: field},
        ).merged_content
      end

      def gemspec_context(content)
        result = PrismUtils.parse_with_comments(content)
        return unless result.success?

        stmts = PrismUtils.extract_statements(result.value.statements)
        gemspec_call = stmts.find do |stmt|
          stmt.is_a?(Prism::CallNode) && stmt.block && PrismUtils.extract_const_name(stmt.receiver) == "Gem::Specification" && stmt.name == :new
        end
        return unless gemspec_call

        body_node = gemspec_call.block&.body
        return unless body_node

        {
          gemspec_call: gemspec_call,
          body_node: body_node,
          body_src: body_node.slice,
          blk_param: extract_block_param(gemspec_call) || "spec",
          stmt_nodes: PrismUtils.extract_statements(body_node),
        }
      end

      def merge_dir_assignment_source(merged_source:, template_source:, destination_source:)
        merged_parts = multiline_collection_parts(merged_source)
        template_parts = multiline_collection_parts(template_source)
        destination_parts = multiline_collection_parts(destination_source)
        return unless merged_parts && template_parts && destination_parts

        combined_groups = []
        seen = {}

        [destination_parts[:groups], merged_parts[:groups], template_parts[:groups]].each do |groups|
          groups.each do |group|
            next if seen[group[:key]]

            combined_groups << group
            seen[group[:key]] = true
          end
        end

        merged_parts[:opening] + combined_groups.flat_map { |group| group[:lines] }.join + merged_parts[:closing]
      end

      def multiline_collection_parts(source)
        lines = source.to_s.lines
        return if lines.length < 3

        {
          opening: lines.first,
          closing: lines.last,
          groups: literal_collection_groups(lines[1...-1]),
        }
      end

      def literal_collection_groups(lines)
        pending = []
        groups = []

        lines.each do |line|
          if line.strip.empty? || line.lstrip.start_with?("#")
            pending << line
            next
          end

          groups << {
            key: normalize_collection_entry_key(line),
            lines: pending + [line],
          }
          pending = []
        end

        groups
      end

      def normalize_collection_entry_key(line)
        line.to_s.sub(/\s+#.*$/, "").strip.sub(/,\z/, "")
      end

      def dependency_line_lookup(content)
        DependencySectionPolicy.dependency_line_lookup(content)
      end

      def dependency_records(lines)
        DependencySectionPolicy.dependency_records(lines)
      end

      def dependency_line_match(line)
        DependencySectionPolicy.dependency_line_match(line)
      end

      def runtime_dependency_method?(method_name)
        DependencySectionPolicy.runtime_dependency_method?(method_name)
      end

      def dependency_node_records(stmt_nodes, blk_param)
        Array(stmt_nodes).filter_map do |node|
          next unless gemspec_dependency_call?(node, blk_param)

          first_arg = node.arguments&.arguments&.first
          gem_name = PrismUtils.extract_literal_value(first_arg)
          next if gem_name.to_s.empty?

          {
            node: node,
            method: node.name.to_s,
            gem: gem_name.to_s,
            start_line: node.location.start_line,
            end_line: node.location.end_line,
          }
        end
      end

      def dependency_indent(node)
        node.slice.lines.first[/^(\s*)/, 1] || ""
      end

      def formatted_dependency_line(desired_line, indent: "  ")
        "#{indent}#{desired_line.to_s.strip}\n"
      end

      def dependency_signature(node)
        arguments = node.arguments&.arguments || []
        arguments.map { |argument| PrismUtils.normalize_argument(argument) }.join(", ")
      end

      def add_missing_development_dependency_plans(plans, content:, lines:, context:, missing_lines:)
        return plans if missing_lines.empty?

        anchor_line = DependencySectionPolicy.insertion_line_index(lines) + 1
        insertion_text = missing_lines.join

        overlapping_index = plans.index { |plan| plan.line_range.include?(anchor_line) }
        if overlapping_index
          plan = plans[overlapping_index]
          plans[overlapping_index] = Ast::Merge::StructuralEdit::SplicePlan.new(
            source: content,
            replacement: insertion_text + plan.replacement,
            replace_start_line: plan.replace_start_line,
            replace_end_line: plan.replace_end_line,
            metadata: plan.metadata.merge(inserted_missing_dependencies: missing_lines.size),
          )
          return plans
        end

        original_line = lines[anchor_line - 1].to_s
        plans << Ast::Merge::StructuralEdit::SplicePlan.new(
          source: content,
          replacement: insertion_text + original_line,
          replace_start_line: anchor_line,
          replace_end_line: anchor_line,
          metadata: {
            source: :kettle_jem_prism_gemspec,
            edit: :ensure_development_dependency_insert,
            inserted_missing_dependencies: missing_lines.size,
          },
        )
      end

      def dependency_block_range(lines, line_index)
        DependencySectionPolicy.dependency_block_range(lines, line_index)
      end

      def remove_line_ranges(lines, ranges)
        DependencySectionPolicy.remove_line_ranges(lines, ranges)
      end

      def build_dependency_block_insertion(blocks, before_line:, after_line:)
        DependencySectionPolicy.build_dependency_block_insertion(blocks, before_line: before_line, after_line: after_line)
      end

      def extract_block_param(gemspec_call)
        return unless gemspec_call.block&.parameters

        params_node = gemspec_call.block.parameters
        return unless params_node.respond_to?(:parameters) && params_node.parameters

        inner_params = params_node.parameters
        return unless inner_params.respond_to?(:requireds) && inner_params.requireds&.any?

        first_param = inner_params.requireds.first
        return unless first_param.respond_to?(:name)

        param_name = first_param.name
        param_name.to_s if param_name && !param_name.to_s.empty?
      end

      def find_field_node(stmt_nodes, blk_param, field)
        stmt_nodes.find do |n|
          next false unless n.is_a?(Prism::CallNode)

          recv_name = n.receiver&.slice&.strip
          recv_name&.end_with?(blk_param) && n.name.to_s.start_with?(field)
        end
      end

      def replace_or_insert_raw_field_assignment(content:, gemspec_call:, body_node:, stmt_nodes:, blk_param:, field:, rhs:)
        field_node = find_field_node(stmt_nodes, blk_param, field)

        require "ast-merge" unless defined?(Ast::Merge::StructuralEdit::PlanSet)
        lines = content.lines

        plan = if field_node
          loc = field_node.location
          indent = content.lines[loc.start_line - 1].to_s[/^(\s*)/, 1] || ""
          Ast::Merge::StructuralEdit::SplicePlan.new(
            source: content,
            replacement: "#{indent}#{blk_param}.#{field} = #{rhs}\n",
            replace_start_line: loc.start_line,
            replace_end_line: loc.end_line,
            metadata: {
              source: :kettle_jem_prism_gemspec,
              edit: :replace_or_insert_raw_field_assignment,
              field: field,
            },
          )
        else
          anchor_node = find_field_node(stmt_nodes, blk_param, "name") || stmt_nodes.first
          anchor_line = if anchor_node
            anchor_node.location.end_line
          else
            gemspec_call.location.end_line
          end

          original_line = lines[anchor_line - 1].to_s
          Ast::Merge::StructuralEdit::SplicePlan.new(
            source: content,
            replacement: original_line + "  #{blk_param}.#{field} = #{rhs}\n",
            replace_start_line: anchor_line,
            replace_end_line: anchor_line,
            metadata: {
              source: :kettle_jem_prism_gemspec,
              edit: :replace_or_insert_raw_field_assignment,
              field: field,
              inserted_after_anchor: anchor_node ? anchor_node.name : :gemspec_end,
            },
          )
        end

        Ast::Merge::StructuralEdit::PlanSet.new(
          source: content,
          plans: [plan],
          metadata: {source: :kettle_jem_prism_gemspec, edit: :replace_or_insert_raw_field_assignment, field: field},
        ).merged_content
      end

      def modern_version_loader_expression(entrypoint_require:, namespace:)
        %(Module.new.tap { |mod| Kernel.load("\#{__dir__}/lib/#{entrypoint_require}/version.rb", mod) }::#{namespace}::Version::VERSION)
      end

      def legacy_version_loader_block(entrypoint_require:, namespace:)
        <<~RUBY.rstrip
          gem_version =
            if RUBY_VERSION >= "3.1" # rubocop:disable Gemspec/RubyVersionGlobalsUsage
              # Loading Version into an anonymous module allows version.rb to get code coverage from SimpleCov!
              # See: https://github.com/simplecov-ruby/simplecov/issues/557#issuecomment-2630782358
              # See: https://github.com/panorama-ed/memo_wise/pull/397
              #{modern_version_loader_expression(entrypoint_require: entrypoint_require, namespace: namespace)}
            else
              # NOTE: Use __FILE__ or __dir__ until removal of Ruby 1.x support
              # __dir__ introduced in Ruby 1.9.1
              # lib = File.expand_path("../lib", __FILE__)
              lib = File.expand_path("lib", __dir__)
              $LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
              require "#{entrypoint_require}/version"
              #{namespace}::Version::VERSION
            end
        RUBY
      end

      def rewrite_version_preamble(content, gemspec_call_start:, modern:, entrypoint_require:, namespace:)
        prefix = content.byteslice(0...gemspec_call_start) || ""
        suffix = content.byteslice(gemspec_call_start..-1) || ""
        pattern = /\n*gem_version =\n.*\z/m

        new_prefix = if modern
          prefix.sub(pattern, "\n\n")
        else
          block = legacy_version_loader_block(entrypoint_require: entrypoint_require, namespace: namespace)
          if pattern.match?(prefix)
            prefix.sub(pattern, "\n\n#{block}\n\n")
          else
            prefix.rstrip + "\n\n#{block}\n\n"
          end
        end

        new_prefix + suffix
      end

      def build_replacement_plan(content, found_node, blk_param, field, field_sym, value, build_literal)
        existing_arg = found_node.arguments&.arguments&.first
        existing_literal = PrismUtils.extract_literal_value(existing_arg)

        # For summary and description: don't replace real content with placeholders
        if [:summary, :description].include?(field_sym)
          return if placeholder?(value) && existing_literal && !placeholder?(existing_literal)
        end

        # Do not replace if the existing RHS is non-literal
        if existing_literal.nil? && !value.nil?
          debug_error(StandardError.new("Skipping replacement for #{field} because existing RHS is non-literal"), __method__)
          return
        end

        loc = found_node.location
        indent = content.lines[loc.start_line - 1].to_s[/^(\s*)/, 1] || ""
        rhs = build_literal.call(value)
        replacement = "#{indent}#{blk_param}.#{field} = #{rhs}\n"

        Ast::Merge::StructuralEdit::SplicePlan.new(
          source: content,
          replacement: replacement,
          replace_start_line: loc.start_line,
          replace_end_line: loc.end_line,
          metadata: {
            source: :kettle_jem_prism_gemspec,
            edit: :replace_gemspec_field,
            field: field,
          },
        )
      end

      def build_insertion_plan(stmt_nodes, gemspec_call, blk_param, field, field_sym, value, build_literal)
        return if [:summary, :description].include?(field_sym) && placeholder?(value)

        version_node = stmt_nodes.find do |n|
          n.is_a?(Prism::CallNode) && n.name.to_s.start_with?("version", "version=") && n.receiver && n.receiver.slice.strip.end_with?(blk_param)
        end

        {
          anchor_line: version_node ? version_node.location.end_line : gemspec_call.location.end_line,
          field: field,
          position: version_node ? :after : :before,
          text: "  #{blk_param}.#{field} = #{build_literal.call(value)}\n",
        }
      end

      def add_field_insertion_plans(plans, content:, lines:, insertions:)
        return plans if insertions.empty?

        insertions.group_by { |insertion| [insertion[:anchor_line], insertion[:position]] }.each_value do |group|
          anchor_line = group.first[:anchor_line]
          position = group.first[:position]
          insertion_text = group.map { |insertion| insertion[:text] }.join
          fields = group.map { |insertion| insertion[:field] }

          overlapping_index = plans.index { |plan| plan.line_range.include?(anchor_line) }
          if overlapping_index
            plan = plans[overlapping_index]
            replacement = position == :after ? plan.replacement + insertion_text : insertion_text + plan.replacement
            plans[overlapping_index] = Ast::Merge::StructuralEdit::SplicePlan.new(
              source: content,
              replacement: replacement,
              replace_start_line: plan.replace_start_line,
              replace_end_line: plan.replace_end_line,
              metadata: plan.metadata.merge(inserted_fields: Array(plan.metadata[:inserted_fields]) + fields),
            )
            next
          end

          original_line = lines[anchor_line - 1].to_s
          replacement = position == :after ? original_line + insertion_text : insertion_text + original_line
          plans << Ast::Merge::StructuralEdit::SplicePlan.new(
            source: content,
            replacement: replacement,
            replace_start_line: anchor_line,
            replace_end_line: anchor_line,
            metadata: {
              source: :kettle_jem_prism_gemspec,
              edit: :insert_gemspec_fields,
              inserted_fields: fields,
            },
          )
        end

        plans
      end

      def self_dependency_nodes(stmt_nodes, blk_param, gem_name)
        stmt_nodes.select do |node|
          next false unless gemspec_dependency_call?(node, blk_param)

          first_arg = node.arguments&.arguments&.first
          PrismUtils.extract_literal_value(first_arg).to_s == gem_name.to_s
        end
      end

      def gemspec_dependency_call?(node, blk_param)
        return false unless node.is_a?(Prism::CallNode)

        recv = node.receiver
        return false unless recv && recv.slice.strip.end_with?(blk_param)

        %i[add_dependency add_development_dependency add_runtime_dependency].include?(node.name)
      end

      def apply_edits(body_src, edits)
        new_body = body_src.dup
        edits.each do |offset, length, replacement|
          next if offset.nil? || length.nil? || offset < 0 || length < 0
          next if offset > new_body.bytesize
          next if replacement.nil?

          # CRITICAL: Prism uses byte offsets, not character offsets!
          before = (offset > 0) ? new_body.byteslice(0, offset) : ""
          after = ((offset + length) < new_body.bytesize) ? new_body.byteslice(offset + length..-1) : ""
          new_body = before + replacement + after
        end
        new_body
      end

      def reassemble_gemspec(content, gemspec_call, body_node, new_body)
        call_start = gemspec_call.location.start_offset
        call_end = gemspec_call.location.end_offset
        body_start = body_node.location.start_offset
        body_end = body_node.location.end_offset

        prefix = content.byteslice(call_start...body_start) || ""
        suffix = content.byteslice(body_end...call_end) || ""
        new_call = prefix + new_body + suffix

        result_prefix = content.byteslice(0...call_start) || ""
        result_suffix = content.byteslice(call_end..-1) || ""
        result_prefix + new_call + result_suffix
      end

      # Escape a string for safe inclusion in a Ruby double-quoted literal.
      # Backslashes are escaped first so they cannot act as escape prefixes
      # for the subsequent quote-escaping pass.
      # @param str [#to_s]
      # @return [String]
      def escape_double_quoted_string(str)
        str.to_s.gsub("\\", "\\\\").gsub('"', '\\"')
      end

      def build_literal_value(v)
        if v.is_a?(Array)
          arr = v.compact.map { |e| '"' + escape_double_quoted_string(e) + '"' }
          "[" + arr.join(", ") + "]"
        else
          '"' + escape_double_quoted_string(v) + '"'
        end
      end

      def placeholder?(v)
        return false unless v.is_a?(String)
        v.strip.match?(/\A[^\x00-\x7F]{1,4}\s*\z/)
      end
    end
  end
end
