# frozen_string_literal: true

require "set"

module Kettle
  module Jem
    # Prism helpers for gemspec manipulation.
    module PrismGemspec
      module_function

      MODERN_VERSION_LOADER_MIN_RUBY = Gem::Version.new("3.1").freeze
      GEMSPEC_DEPENDENCY_LINE_RE = /^(?<indent>\s*)spec\.(?<method>add_(?:development_|runtime_)?dependency)\s*\(?\s*["'](?<gem>[^"']+)["'][^\n]*(?:\n|\z)/.freeze
      GEMSPEC_NOTE_BLOCK_START_RE = /^\s*# NOTE: It is preferable to list development dependencies in the gemspec due to increased/.freeze

      # Emit a debug warning for rescued errors when debugging is enabled.
      # @param error [Exception]
      # @param context [String, Symbol, nil] optional label, often __method__
      # @return [void]
      def debug_error(error, context = nil)
        Kettle::Dev.debug_error(error, context)
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

        result = PrismUtils.parse_with_comments(content)
        stmts = PrismUtils.extract_statements(result.value.statements)

        gemspec_call = stmts.find do |s|
          s.is_a?(Prism::CallNode) && s.block && PrismUtils.extract_const_name(s.receiver) == "Gem::Specification" && s.name == :new
        end
        return content unless gemspec_call

        # Extract block parameter name from Prism AST (e.g., |spec|)
        blk_param = extract_block_param(gemspec_call) || "spec"

        Kettle::Dev.debug_log("PrismGemspec final blk_param: #{blk_param.inspect}")

        body_node = gemspec_call.block&.body
        return content unless body_node

        body_src = body_node.slice

        build_literal = method(:build_literal_value)
        stmt_nodes = PrismUtils.extract_statements(body_node)

        edits = []

        replacements.each do |field_sym, value|
          next if field_sym == :_remove_self_dependency
          next if value.nil?

          field = field_sym.to_s

          found_node = find_field_node(stmt_nodes, blk_param, field)

          edit = if found_node
            build_replacement_edit(found_node, body_node, blk_param, field, field_sym, value, build_literal)
          else
            build_insertion_edit(stmt_nodes, body_node, body_src, blk_param, field, field_sym, value, build_literal)
          end
          edits << edit if edit
        end

        # Handle removal of self-dependency
        if replacements[:_remove_self_dependency]
          edits.concat(build_self_dependency_removal_edits(stmt_nodes, body_node, body_src, blk_param, replacements[:_remove_self_dependency].to_s))
        end

        # Apply edits in reverse order by offset to avoid offset shifts
        edits.sort_by! { |offset, _len, _repl| -offset }

        new_body = apply_edits(body_src, edits)

        # Reassemble the gemspec call by replacing just the body
        reassemble_gemspec(content, gemspec_call, body_node, new_body)
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
        replace_gemspec_fields(content, _remove_self_dependency: gem_name)
      end

      # Ensure development dependency lines in a gemspec match the desired lines.
      # `desired` is a hash mapping gem_name => desired_line (string, without leading indentation).
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

          insert_line = "  " + desired_line.strip + "\n"
          insert_at = development_dependency_insert_line_index(lines)
          if insert_at
            lines.insert(insert_at, insert_line)
          else
            end_index = lines.rindex { |line| line.strip == "end" } || lines.length
            lines.insert(end_index, insert_line)
          end
        end
        normalize_dependency_sections(
          lines.join,
          template_content: desired.values.join("\n"),
          destination_content: content,
          prefer_template: true,
        )
      rescue StandardError => e
        debug_error(e, __method__)
        content
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

          preferred = preferred_lines[[match[:method], match[:gem]]]
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

        note_index = lines.index { |line| GEMSPEC_NOTE_BLOCK_START_RE.match?(line) }
        return lines.join unless note_index

        runtime_after_note = dependency_records(lines)
          .select { |record| runtime_dependency_method?(record[:method]) && record[:line_index] > note_index }

        return lines.join if runtime_after_note.empty?

        moved_blocks = []
        runtime_after_note.reverse_each do |record|
          range = dependency_block_range(lines, record[:line_index])
          moved_blocks.unshift(lines[range].map(&:dup))
          lines = remove_line_ranges(lines, [range])
        end

        note_index = lines.index { |line| GEMSPEC_NOTE_BLOCK_START_RE.match?(line) }
        return lines.join unless note_index

        insertion = build_dependency_block_insertion(
          moved_blocks,
          before_line: note_index.positive? ? lines[note_index - 1] : nil,
          after_line: lines[note_index],
        )

        (lines[0...note_index] + insertion + lines[note_index..]).join
      rescue StandardError => e
        debug_error(e, __method__)
        content
      end

      # --- Private helpers ---

      def development_dependency_insert_line_index(lines)
        line_index = 0
        in_note_block = false
        note_end_index = nil

        Array(lines).each do |line|
          if GEMSPEC_NOTE_BLOCK_START_RE.match?(line)
            in_note_block = true
            line_index += 1
            next
          end

          if in_note_block
            if line.strip.empty? || line.lstrip.start_with?("#")
              line_index += 1
              next
            end

            note_end_index = line_index
            break
          end

          line_index += 1
        end

        note_end_index
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

        loc = merged_node.location
        relative_start = loc.start_offset - merged_context[:body_node].location.start_offset
        relative_length = loc.end_offset - loc.start_offset
        new_body = apply_edits(merged_context[:body_src], [[relative_start, relative_length, replacement]])
        reassemble_gemspec(content, merged_context[:gemspec_call], merged_context[:body_node], new_body)
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
        content.to_s.each_line.each_with_object({}) do |line, memo|
          match = dependency_line_match(line)
          next unless match

          memo[[match[:method], match[:gem]]] ||= line
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
        match = GEMSPEC_DEPENDENCY_LINE_RE.match(line.to_s)
        return unless match

        {
          method: match[:method],
          gem: match[:gem],
        }
      end

      def runtime_dependency_method?(method_name)
        %w[add_dependency add_runtime_dependency].include?(method_name.to_s)
      end

      def dependency_block_range(lines, line_index)
        start_index = line_index
        while start_index.positive?
          previous_line = lines[start_index - 1]
          break unless previous_line.lstrip.start_with?("#")

          start_index -= 1
        end

        start_index..line_index
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
        insertion << "\n" if before_line && !before_line.strip.empty?

        Array(blocks).each_with_index do |block, idx|
          insertion.concat(block)
          next if idx == blocks.length - 1

          insertion << "\n" unless block.last.to_s.strip.empty?
        end

        insertion << "\n" if after_line && !after_line.strip.empty? && insertion.last.to_s.strip != ""
        insertion
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

        edit = if field_node
          loc = field_node.location
          indent = field_node.slice.lines.first.match(/^(\s*)/)[1]
          replacement = "#{indent}#{blk_param}.#{field} = #{rhs}"
          relative_start = loc.start_offset - body_node.location.start_offset
          relative_length = loc.end_offset - loc.start_offset
          [relative_start, relative_length, replacement]
        else
          anchor_node = find_field_node(stmt_nodes, blk_param, "name") || stmt_nodes.first
          insert_line = "  #{blk_param}.#{field} = #{rhs}\n"

          insert_offset = if anchor_node
            anchor_node.location.end_offset - body_node.location.start_offset
          else
            0
          end

          [insert_offset, 0, "\n" + insert_line]
        end

        new_body = apply_edits(body_node.slice, [edit])
        reassemble_gemspec(content, gemspec_call, body_node, new_body)
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


      def build_replacement_edit(found_node, body_node, blk_param, field, field_sym, value, build_literal)
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
        indent = found_node.slice.lines.first.match(/^(\s*)/)[1]
        rhs = build_literal.call(value)
        replacement = "#{indent}#{blk_param}.#{field} = #{rhs}"

        relative_start = loc.start_offset - body_node.location.start_offset
        relative_length = loc.end_offset - loc.start_offset

        [relative_start, relative_length, replacement]
      end

      def build_insertion_edit(stmt_nodes, body_node, body_src, blk_param, field, field_sym, value, build_literal)
        return if [:summary, :description].include?(field_sym) && placeholder?(value)

        version_node = stmt_nodes.find do |n|
          n.is_a?(Prism::CallNode) && n.name.to_s.start_with?("version", "version=") && n.receiver && n.receiver.slice.strip.end_with?(blk_param)
        end

        insert_line = "  #{blk_param}.#{field} = #{build_literal.call(value)}\n"

        insert_offset = if version_node
          version_node.location.end_offset - body_node.location.start_offset
        else
          body_src.rstrip.bytesize
        end

        [insert_offset, 0, "\n" + insert_line]
      end

      def build_self_dependency_removal_edits(stmt_nodes, body_node, body_src, blk_param, name_to_remove)
        edits = []
        dep_nodes = stmt_nodes.select do |n|
          next false unless n.is_a?(Prism::CallNode)

          recv = n.receiver
          next false unless recv && recv.slice.strip.end_with?(blk_param)
          [:add_dependency, :add_development_dependency].include?(n.name)
        end

        dep_nodes.each do |dn|
          first_arg = dn.arguments&.arguments&.first
          arg_val = PrismUtils.extract_literal_value(first_arg)

          next unless arg_val && arg_val.to_s == name_to_remove

          loc = dn.location
          relative_start = loc.start_offset - body_node.location.start_offset
          relative_end = loc.end_offset - body_node.location.start_offset

          line_start = body_src.rindex("\n", relative_start)
          line_start = line_start ? line_start + 1 : 0

          line_end = body_src.index("\n", relative_end)
          line_end = line_end ? line_end + 1 : body_src.length

          edits << [line_start, line_end - line_start, ""]
        end

        edits
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
