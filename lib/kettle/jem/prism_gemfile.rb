# frozen_string_literal: true

require "set"

module Kettle
  module Jem
    # Prism helpers for Gemfile-like merging.
    module PrismGemfile
      module_function

      # Merge gem calls from src_content into dest_content.
      # - Replaces dest `source` call with src's if present.
      # - Replaces or inserts non-comment `git_source` definitions.
      # - Appends missing `gem` calls (by name) from src to dest preserving dest content and newlines.
      # Uses Prism::Merge with pre-filtering to only merge top-level statements.
      def merge_gem_calls(src_content, dest_content)
        require "prism/merge" unless defined?(Prism::Merge)

        # Pre-filter: Extract only top-level gem-related calls from src
        src_filtered = filter_to_top_level_gems(src_content)

        # Always remove :github git_source from dest as it's built-in to Bundler
        dest_processed = remove_github_git_source(dest_content)

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
        merger.merge
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

        top_level_stmts = PrismUtils.extract_statements(parse_result.value.statements)

        filtered_stmts = top_level_stmts.select do |stmt|
          next false if stmt.is_a?(Prism::IfNode) || stmt.is_a?(Prism::UnlessNode)
          next false unless stmt.is_a?(Prism::CallNode)
          next false if stmt.block && stmt.name != :git_source

          [:gem, :source, :git_source, :eval_gemfile].include?(stmt.name)
        end

        return "" if filtered_stmts.empty?

        # Join statements with single newline. The trailing blank line ensures
        # SmartMerger's trailing blank detection emits a gap after the last
        # filtered statement, preserving separation from dest-only nodes.
        filtered_stmts.map do |stmt|
          src = stmt.slice.rstrip
          inline = begin
            PrismUtils.inline_comments_for_node(parse_result, stmt)
          rescue
            []
          end
          if inline && inline.any?
            src + " " + inline.map(&:slice).map(&:strip).join(" ")
          else
            src
          end
        end.join("\n") + "\n"
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
    end
  end
end
