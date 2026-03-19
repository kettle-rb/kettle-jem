# frozen_string_literal: true

require "set"

module Kettle
  module Jem
    # Prism helpers for Gemfile-like merging.
    module PrismGemfile
      module_function

      COMMENTED_GEM_CALL = /^\s*#\s*gem(?:\s+|\()(?<quote>["'])(?<name>[^"']+)\k<quote>/

      # Merge gem calls from src_content into dest_content.
      # - Replaces dest `source` call with src's if present.
      # - Replaces or inserts non-comment `git_source` definitions.
      # - Appends missing `gem` calls (by name) from src to dest preserving dest content and newlines.
      # Uses Prism::Merge with pre-filtering to only merge top-level statements.
      def merge_gem_calls(src_content, dest_content)
        require "prism/merge" unless defined?(Prism::Merge)

        source_tombstones = collect_commented_gem_tombstones(src_content)

        # Pre-filter: Extract only top-level gem-related calls from src
        src_filtered = filter_to_top_level_gems(src_content)

        # Always remove :github git_source from dest as it's built-in to Bundler
        dest_processed = prune_declarations_for_tombstones(dest_content, source_tombstones)
        dest_processed = remove_github_git_source(dest_processed)

        # Custom signature generator that normalizes string quotes
        signature_generator = ->(node) do
          return unless node.is_a?(Prism::CallNode)
          return unless [:gem, :source, :git_source].include?(node.name)

          return [:source] if node.name == :source

          first_arg = node.arguments&.arguments&.first

          arg_value = case first_arg
          when Prism::StringNode
            first_arg.unescaped.to_s
          when Prism::SymbolNode
            first_arg.unescaped.to_sym
          end

          arg_value ? [node.name, arg_value] : nil
        end

        merger = Prism::Merge::SmartMerger.new(
          src_filtered,
          dest_processed,
          preference: :template,
          add_template_only_nodes: true,
          signature_generator: signature_generator,
        )
        merged = merger.merge
        merged = restore_tombstone_comment_blocks(merged, src_content)
        suppress_commented_gem_declarations(merged)
      rescue Prism::Merge::Error => e
        if defined?(Kettle::Dev) && Kettle::Dev.respond_to?(:debug_error)
          Kettle::Dev.debug_error(e, __method__)
        else
          Kernel.warn("[#{__method__}] Prism::Merge failed: #{e.class}: #{e.message}")
        end
        dest_content
      end

      # Filter source content to only include top-level gem-related calls.
      #
      # Magic comments (frozen_string_literal, encoding, etc.) are NOT preserved
      # in the filtered output — SmartMerger handles them by always preserving
      # destination magic comments regardless of preference.
      def filter_to_top_level_gems(content)
        parse_result = PrismUtils.parse_with_comments(content)
        return content unless parse_result.success?

        lines = content.to_s.lines
        top_level_stmts = PrismUtils.extract_statements(parse_result.value.statements)

        filtered_stmts = top_level_stmts.select do |stmt|
          next false if stmt.is_a?(Prism::IfNode) || stmt.is_a?(Prism::UnlessNode)
          next false unless stmt.is_a?(Prism::CallNode)
          next false if stmt.block && stmt.name != :git_source

          [:gem, :source, :git_source, :eval_gemfile].include?(stmt.name)
        end

        ranges = filtered_stmts.map do |stmt|
          {
            start_line: leading_comment_start_line(lines, stmt.location.start_line),
            end_line: stmt.location.end_line,
          }
        end
        ranges.concat(commented_gem_tombstone_line_ranges(lines))

        return "" if ranges.empty?

        merge_line_ranges(ranges).map do |range|
          lines[(range[:start_line] - 1)..(range[:end_line] - 1)].join.rstrip
        end.join("\n\n") + "\n"
      rescue StandardError => e
        if defined?(Kettle::Dev) && Kettle::Dev.respond_to?(:debug_error)
          Kettle::Dev.debug_error(e, __method__)
        end
        content
      end

      # Remove git_source(:github) from content
      # @param content [String] Gemfile-like content
      # @return [String] content with git_source(:github) removed
      def remove_github_git_source(content)
        result = PrismUtils.parse_with_comments(content)
        return content unless result.success?

        stmts = PrismUtils.extract_statements(result.value.statements)

        github_node = stmts.find do |n|
          next false unless n.is_a?(Prism::CallNode) && n.name == :git_source

          first_arg = n.arguments&.arguments&.first
          first_arg.is_a?(Prism::SymbolNode) && first_arg.unescaped == "github"
        end

        return content unless github_node

        content.sub(github_node.slice, "")
      rescue StandardError => e
        if defined?(Kettle::Dev) && Kettle::Dev.respond_to?(:debug_error)
          Kettle::Dev.debug_error(e, __method__)
        end
        content
      end

      # Remove gem calls that reference the given gem name (to prevent self-dependency).
      # Recursively walks the AST to find gem calls inside platform/group/if/else blocks.
      # @param content [String] Gemfile-like content
      # @param gem_name [String] the gem name to remove
      # @return [String] modified content with self-referential gem calls removed
      def remove_gem_dependency(content, gem_name)
        return content if gem_name.to_s.strip.empty?

        result = PrismUtils.parse_with_comments(content)
        gem_nodes = find_gem_nodes_recursive(result.value.statements, gem_name)

        out = content.dup
        gem_nodes.each do |gn|
          # Remove the gem call, trailing comments, and the trailing newline to avoid orphaned comments
          out = out.sub(/^[ \t]*#{Regexp.escape(gn.slice.strip)}[^\n]*\n?/, "")
        end

        out
      rescue StandardError => e
        if defined?(Kettle::Dev) && Kettle::Dev.respond_to?(:debug_error)
          Kettle::Dev.debug_error(e, __method__)
        else
          Kernel.warn("[#{__method__}] #{e.class}: #{e.message}")
        end
        content
      end

      # Detect explained commented-out gem lines and treat them as intentional
      # tombstones for active declarations in the same block context.
      #
      # Recognized shape:
      #   # explanation line
      #   # gem "foo", "~> 1.0"
      #
      # A lone commented-out gem line is ignored to avoid treating examples or
      # alternate version notes as removals.
      #
      # @param content [String] Gemfile-like content
      # @return [Array<Hash>] tombstones with name/context/line metadata
      def collect_commented_gem_tombstones(content)
        result = PrismUtils.parse_with_comments(content)
        return [] unless result.success?

        ranges = collect_context_ranges(result.value.statements)
        lines = content.to_s.lines

        lines.each_with_index.with_object([]) do |(line, index), tombstones|
          match = COMMENTED_GEM_CALL.match(line)
          next unless match
          next unless explained_commented_gem?(lines, index)

          line_number = index + 1
          block_start_line = commented_gem_block_start_line(lines, index)
          block_end_index = commented_gem_block_end_index(lines, index)
          tombstones << {
            name: match[:name],
            context: context_for_line(line_number, ranges),
            slice: line.rstrip,
            line: line_number,
            block_start_line: block_start_line,
            trailing_blank_lines: block_end_index - index,
            block_text: lines[(block_start_line - 1)..block_end_index].join,
          }
        end
      rescue StandardError => e
        if defined?(Kettle::Dev) && Kettle::Dev.respond_to?(:debug_error)
          Kettle::Dev.debug_error(e, __method__)
        end
        []
      end

      # Remove active gem declarations when the same gem has been intentionally
      # commented out with an explanatory comment block in the same context.
      #
      # @param content [String] Gemfile-like content
      # @return [String] content with suppressed active declarations removed
      def suppress_commented_gem_declarations(content)
        tombstones = collect_commented_gem_tombstones(content)
        prune_declarations_for_tombstones(content, tombstones)
      rescue StandardError => e
        if defined?(Kettle::Dev) && Kettle::Dev.respond_to?(:debug_error)
          Kettle::Dev.debug_error(e, __method__)
        end
        content
      end

      # Remove active gem declarations from destination content when source
      # comments them out intentionally with an explanatory comment block.
      #
      # @param destination_content [String] Gemfile-like destination content
      # @param template_content [String] Gemfile-like template/source content
      # @return [String] destination content with matching active gems removed
      def remove_tombstoned_gem_declarations(destination_content, template_content)
        tombstones = collect_commented_gem_tombstones(template_content)
        prune_declarations_for_tombstones(destination_content, tombstones)
      rescue StandardError => e
        if defined?(Kettle::Dev) && Kettle::Dev.respond_to?(:debug_error)
          Kettle::Dev.debug_error(e, __method__)
        end
        destination_content
      end

      def restore_tombstone_comment_blocks(content, template_content)
        tombstones = collect_commented_gem_tombstones(template_content)
        return content if tombstones.empty?

        tombstones.reduce(content) do |updated, tombstone|
          ensure_tombstone_comment_block(updated, tombstone)
        end
      rescue StandardError => e
        if defined?(Kettle::Dev) && Kettle::Dev.respond_to?(:debug_error)
          Kettle::Dev.debug_error(e, __method__)
        end
        content
      end

      def prune_declarations_for_tombstones(content, tombstones)
        return content if tombstones.empty?

        tombstone_contexts = tombstones.each_with_object(Hash.new { |hash, key| hash[key] = Set.new }) do |tombstone, contexts|
          contexts[tombstone[:name]] << tombstone[:context]
        end

        declarations = collect_gem_declarations(content)
        removals = declarations.select do |declaration|
          tombstone_contexts[declaration[:name]].include?(declaration[:context])
        end
        return content if removals.empty?

        remove_declarations(content, removals)
      end

      def ensure_tombstone_comment_block(content, tombstone)
        block_text = tombstone[:block_text].to_s
        return content if block_text.empty? || content.include?(block_text)

        lines = content.lines
        ranges = context_ranges_for_content(content)
        marker_line = block_text.lines.first.to_s.rstrip
        start_index = comment_block_index_for_marker(lines, marker_line, tombstone[:context], ranges)
        start_index ||= comment_block_index_for_marker(lines, tombstone[:slice].to_s, tombstone[:context], ranges)

        updated_lines = lines.dup

        if start_index
          end_index = comment_block_end_index(lines, start_index, include_trailing_blank_lines: true)
          updated_lines[start_index..end_index] = block_text.lines
        else
          insertion_index = insertion_index_for_tombstone(updated_lines, tombstone, ranges)
          updated_lines.insert(insertion_index, *block_text.lines)
        end

        updated_lines.join
      end

      def context_ranges_for_content(content)
        result = PrismUtils.parse_with_comments(content)
        return [] unless result.success?

        collect_context_ranges(result.value.statements)
      end

      def comment_block_index_for_marker(lines, marker_line, context, ranges)
        lines.each_index.find do |index|
          next false unless lines[index].rstrip == marker_line

          context_for_line(index + 1, ranges) == context
        end
      end

      def comment_block_end_index(lines, start_index, include_trailing_blank_lines: false)
        finish = start_index

        while finish + 1 < lines.length && lines[finish + 1].match?(/^\s*#/) 
          finish += 1
        end

        if include_trailing_blank_lines
          while finish + 1 < lines.length && lines[finish + 1].strip.empty?
            finish += 1
          end
        end

        finish
      end

      def commented_gem_block_end_index(lines, index)
        finish = index

        while finish + 1 < lines.length && lines[finish + 1].strip.empty?
          finish += 1
        end

        finish
      end

      def insertion_index_for_tombstone(lines, tombstone, ranges)
        line_number = if tombstone[:context] == "top-level"
          lines.find_index { |line| line.match?(/\S/) }&.+(1)
        else
          declaration_line_for_context(lines.join, tombstone[:context]) || block_body_start_line_for_context(ranges, tombstone[:context])
        end

        line_number ? line_number - 1 : lines.length
      end

      def declaration_line_for_context(content, context)
        collect_gem_declarations(content)
          .select { |declaration| declaration[:context] == context }
          .map { |declaration| declaration[:line] }
          .min
      end

      def block_body_start_line_for_context(ranges, context)
        range = ranges.find { |candidate| candidate[:context] == context }
        range ? range[:start_line] + 1 : nil
      end

      def merge_local_gem_overrides(content, destination_content, excluded_gems: [])
        merged_local_gems_match = local_gems_array_match(content)
        destination_local_gems_match = local_gems_array_match(destination_content)
        merged_vendored_match = vendored_gems_export_match(content)
        destination_vendored_match = vendored_gems_export_match(destination_content)

        return content unless merged_local_gems_match || destination_local_gems_match || merged_vendored_match || destination_vendored_match

        excluded = Array(excluded_gems).map { |name| name.to_s.strip }.reject(&:empty?).to_set
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
        if merged_vendored_match
          out.sub!(merged_vendored_match[0], export_line)
        elsif export_line && merged_local_gems_match
          insertion = out.index(merged_local_gems_match[0])
          if insertion
            array_text = rebuild_local_gems_array(merged_local_gems_match, words)
            out.sub!(array_text, "#{array_text}\n\n#{export_line}")
          end
        end

        out
      end

      def remove_word_from_local_gems_array(content, gem_name)
        gem_word = gem_name.to_s.strip
        return content if gem_word.empty?

        content.gsub(/^(?<indent>[ \t]*)local_gems\s*=\s*%w\[(?<body>.*?)\](?<suffix>[ \t]*(?:#.*)?)$/m) do
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

        content.gsub(/^(?<prefix>[ \t]*#\s*export\s+VENDORED_GEMS=)(?<body>[^\n]*)$/) do
          match = Regexp.last_match
          words = match[:body].split(",").map(&:strip).reject(&:empty?)
          filtered = words.reject { |word| word == gem_word }
          next match[0] if filtered == words

          "#{match[:prefix]}#{filtered.join(",")}"
        end
      end

      def local_gems_array_match(content)
        content.to_s.match(/^(?<indent>[ \t]*)local_gems\s*=\s*%w\[(?<body>.*?)\](?<suffix>[ \t]*(?:#.*)?)$/m)
      end

      def local_gems_words_from_match(match)
        return [] unless match

        match[:body].to_s.split(/\s+/).reject(&:empty?)
      end

      def vendored_gems_export_match(content)
        content.to_s.match(/^(?<prefix>[ \t]*#\s*export\s+VENDORED_GEMS=)(?<body>[^\n]*)$/)
      end

      def vendored_gems_words_from_match(match)
        return [] unless match

        match[:body].to_s.split(",").map(&:strip).reject(&:empty?)
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

      # Recursively find all gem CallNodes matching gem_name throughout the AST.
      # Walks into block bodies, if/else branches, platform/group blocks, etc.
      # @param body_node [Prism::Node, nil] Body node to search
      # @param gem_name [String] the gem name to match
      # @return [Array<Prism::CallNode>] matching gem call nodes
      def find_gem_nodes_recursive(body_node, gem_name)
        stmts = PrismUtils.extract_statements(body_node)
        found = []

        stmts.each do |node|
          case node
          when Prism::CallNode
            if node.name == :gem
              first_arg = node.arguments&.arguments&.first
              arg_val = begin
                PrismUtils.extract_literal_value(first_arg)
              rescue StandardError
                nil
              end
              found << node if arg_val && arg_val.to_s == gem_name.to_s
            end
            # Recurse into block body (platform :mri do ... end, group :dev do ... end, etc.)
            if node.block
              block_body = node.block.body
              found.concat(find_gem_nodes_recursive(block_body, gem_name))
            end
          when Prism::IfNode, Prism::UnlessNode
            # Recurse into if/unless branches
            found.concat(find_gem_nodes_recursive(node.statements, gem_name)) if node.statements
            found.concat(find_gem_nodes_recursive(node.subsequent, gem_name)) if node.respond_to?(:subsequent) && node.subsequent
          when Prism::ElseNode
            found.concat(find_gem_nodes_recursive(node.statements, gem_name)) if node.statements
          end
        end

        found
      end

      # Validate that the merged content does not contain the same gem nested
      # inside block nodes with different signatures.
      #
      # When the merger encounters blocks with different signatures (e.g.,
      # `platform(:mri) do ... end` vs top-level, or `if ENV[...]` vs
      # `platform(:mri)`), it treats them as distinct nodes and keeps both.
      # If the same gem appears inside both, Bundler will reject the result:
      # "You cannot specify the same gem twice coming from different sources".
      #
      # Mutually exclusive branches (if/else of the same conditional) are NOT
      # flagged — they share the same block signature since only one executes.
      #
      # @param merged_content [String] The merged gemfile content
      # @param template_content [String] The template content (shown as reference in error)
      # @param path [String] File path (for error messages)
      # @raise [Kettle::Jem::Error] when a gem appears at different nesting levels
      # @return [void]
      def validate_no_cross_nesting_duplicates(merged_content, template_content, path: "Gemfile")
        merged_decls = collect_gem_declarations(merged_content)
        return if merged_decls.empty?

        # Group by gem name
        by_name = merged_decls.group_by { |d| d[:name] }

        # Find gems with declarations in more than one distinct context
        conflicts = {}
        by_name.each do |name, decls|
          contexts = decls.map { |d| d[:context] }.uniq
          conflicts[name] = decls if contexts.size > 1
        end

        return if conflicts.empty?

        # Collect template declarations for reference
        template_decls = collect_gem_declarations(template_content)
        template_by_name = template_decls.group_by { |d| d[:name] }

        # Build error message
        lines = ["Gemfile merge produced duplicate gem declarations in blocks with different signatures in #{path}:"]
        conflicts.each do |name, decls|
          lines << ""
          lines << "  gem #{name.inspect} appears in #{decls.map { |d| d[:context] }.uniq.size} different block contexts:"
          decls.each_with_index do |d, i|
            lines << "    #{i + 1}. #{d[:slice]}"
            lines << "       Block signature: #{d[:context]} (line #{d[:line]})"
          end

          if template_by_name[name]
            lines << ""
            lines << "  Template version (use as guide to resolve):"
            template_by_name[name].each do |td|
              lines << "    #{td[:slice]}"
              lines << "       Block signature: #{td[:context]} (line #{td[:line]})"
            end
          end
        end

        lines << ""
        lines << "  Resolution: reconcile the gem declarations in the destination file"
        lines << "  so each gem appears in only one block context, then re-run."

        raise Kettle::Jem::Error, lines.join("\n")
      end

      # Collect all gem declarations with their nesting context.
      # Returns an array of hashes: { name:, context:, slice:, line: }
      #
      # @param content [String] Gemfile-like content
      # @return [Array<Hash>] gem declarations with context info
      def collect_gem_declarations(content)
        result = PrismUtils.parse_with_comments(content)
        return [] unless result.success?

        declarations = []
        walk_for_declarations(result.value.statements, [], declarations)
        declarations
      end

      # Recursively walk AST collecting gem declarations with their context stack.
      # if/else branches of the same conditional share the same context label because
      # they are mutually exclusive — a gem appearing in both the `if` and `else`
      # branches is NOT a cross-nesting conflict.
      # @param body_node [Prism::Node, nil]
      # @param context_stack [Array<String>] current nesting context
      # @param declarations [Array<Hash>] output accumulator
      # @return [void]
      def walk_for_declarations(body_node, context_stack, declarations)
        stmts = PrismUtils.extract_statements(body_node)

        stmts.each do |node|
          case node
          when Prism::CallNode
            if node.name == :gem
              first_arg = node.arguments&.arguments&.first
              gem_name = begin
                PrismUtils.extract_literal_value(first_arg)
              rescue StandardError
                nil
              end
              if gem_name
                context = context_stack.empty? ? "top-level" : context_stack.join(" > ")
                declarations << {
                  name: gem_name.to_s,
                  context: context,
                  slice: node.slice.strip,
                  line: node.location.start_line,
                  start_offset: node.location.start_offset,
                  end_offset: node.location.end_offset,
                  end_line: node.location.end_line,
                }
              end
            end
            # Recurse into block body (platform, group, etc.)
            if node.block
              block_label = describe_call_context(node)
              walk_for_declarations(node.block.body, context_stack + [block_label], declarations)
            end
          when Prism::IfNode
            # Use the same context label for both branches since they're mutually exclusive
            cond_label = "if #{describe_condition(node)}"
            branch_context = context_stack + [cond_label]
            walk_for_declarations(node.statements, branch_context, declarations) if node.statements
            # else/elsif branches share the same conditional context
            walk_for_declarations(node.subsequent, branch_context, declarations) if node.respond_to?(:subsequent) && node.subsequent
          when Prism::UnlessNode
            cond_label = "unless #{describe_condition(node)}"
            branch_context = context_stack + [cond_label]
            walk_for_declarations(node.statements, branch_context, declarations) if node.statements
            walk_for_declarations(node.subsequent, branch_context, declarations) if node.respond_to?(:subsequent) && node.subsequent
          when Prism::ElseNode
            # ElseNode inherits the context from its parent if/unless — do NOT push a new context
            walk_for_declarations(node.statements, context_stack, declarations) if node.statements
          end
        end
      end

      # Describe a CallNode for context labels (e.g., "platform(:mri)", "group(:development)")
      # @param node [Prism::CallNode]
      # @return [String]
      def describe_call_context(node)
        args = node.arguments&.arguments
        if args && args.any?
          first = args.first
          arg_str = case first
          when Prism::SymbolNode then ":#{first.unescaped}"
          when Prism::StringNode then first.unescaped.inspect
          else first.slice
          end
          "#{node.name}(#{arg_str})"
        else
          node.name.to_s
        end
      rescue StandardError
        node.name.to_s
      end

      # Describe a condition node for context labels
      # @param node [Prism::IfNode, Prism::UnlessNode]
      # @return [String]
      def describe_condition(node)
        pred = node.predicate
        # Truncate long conditions
        text = pred.slice.to_s.strip
        text.length > 40 ? text[0..37] + "..." : text
      rescue StandardError
        "..."
      end

      def explained_commented_gem?(lines, index)
        cursor = index - 1
        saw_explanatory_comment = false

        while cursor >= 0
          line = lines[cursor]
          break unless line.match?(/^\s*#/) 

          saw_explanatory_comment ||= !COMMENTED_GEM_CALL.match?(line)
          cursor -= 1
        end

        saw_explanatory_comment
      end

      def commented_gem_tombstone_line_ranges(lines)
        lines.each_with_index.with_object([]) do |(line, index), ranges|
          next unless COMMENTED_GEM_CALL.match?(line)
          next unless explained_commented_gem?(lines, index)

          ranges << {
            start_line: commented_gem_block_start_line(lines, index),
            end_line: index + 1,
          }
        end
      end

      def commented_gem_block_start_line(lines, index)
        cursor = index

        while cursor.positive?
          previous = lines[cursor - 1]
          break if previous.to_s.strip.empty?
          break unless previous.match?(/^\s*#/)

          cursor -= 1
        end

        cursor + 1
      end

      def leading_comment_start_line(lines, line_number)
        commented_gem_block_start_line(lines, line_number - 1)
      end

      def merge_line_ranges(ranges)
        ranges
          .sort_by { |range| [range[:start_line], range[:end_line]] }
          .each_with_object([]) do |range, merged|
            previous = merged.last
            if previous && range[:start_line] <= (previous[:end_line] + 1)
              previous[:end_line] = [previous[:end_line], range[:end_line]].max
            else
              merged << range.dup
            end
          end
      end

      def collect_context_ranges(body_node, context_stack = [], ranges = [])
        stmts = PrismUtils.extract_statements(body_node)

        stmts.each do |node|
          case node
          when Prism::CallNode
            next unless node.block

            block_label = describe_call_context(node)
            next_context = context_stack + [block_label]
            ranges << build_context_range(node, next_context)
            collect_context_ranges(node.block.body, next_context, ranges)
          when Prism::IfNode
            cond_label = "if #{describe_condition(node)}"
            branch_context = context_stack + [cond_label]
            ranges << build_context_range(node, branch_context)
            collect_context_ranges(node.statements, branch_context, ranges) if node.statements
            collect_context_ranges(node.subsequent, branch_context, ranges) if node.respond_to?(:subsequent) && node.subsequent
          when Prism::UnlessNode
            cond_label = "unless #{describe_condition(node)}"
            branch_context = context_stack + [cond_label]
            ranges << build_context_range(node, branch_context)
            collect_context_ranges(node.statements, branch_context, ranges) if node.statements
            collect_context_ranges(node.subsequent, branch_context, ranges) if node.respond_to?(:subsequent) && node.subsequent
          when Prism::ElseNode
            collect_context_ranges(node.statements, context_stack, ranges) if node.statements
          end
        end

        ranges
      end

      def build_context_range(node, context_stack)
        {
          context: context_stack.join(" > "),
          start_line: node.location.start_line,
          end_line: node.location.end_line,
          depth: context_stack.length,
        }
      end

      def context_for_line(line_number, ranges)
        range = ranges
          .select { |candidate| line_number.between?(candidate[:start_line], candidate[:end_line]) }
          .max_by { |candidate| [candidate[:depth], -(candidate[:end_line] - candidate[:start_line])] }

        range ? range[:context] : "top-level"
      end

      def remove_declarations(content, declarations)
        declarations
          .sort_by { |declaration| -declaration[:start_offset] }
          .reduce(content.dup) do |updated, declaration|
            line_end = declaration[:end_offset]
            line_end += 1 while line_end < updated.bytesize && updated.getbyte(line_end) != 10
            line_end += 1 if line_end < updated.bytesize

            updated.byteslice(0, declaration[:start_offset]).to_s + updated.byteslice(line_end..).to_s
          end
      end
    end
  end
end
