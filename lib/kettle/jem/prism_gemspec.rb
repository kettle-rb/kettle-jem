# frozen_string_literal: true

module Kettle
  module Jem
    # Prism helpers for gemspec manipulation.
    module PrismGemspec
      module_function

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

          if found_node
            edit = build_replacement_edit(found_node, body_node, blk_param, field, field_sym, value, build_literal)
            edits << edit if edit
          else
            edit = build_insertion_edit(stmt_nodes, body_node, body_src, blk_param, field, field_sym, value, build_literal)
            edits << edit if edit
          end
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

      # Remove spec.add_dependency / add_development_dependency calls that name the given gem
      def remove_spec_dependency(content, gem_name)
        return content if gem_name.to_s.strip.empty?
        replace_gemspec_fields(content, _remove_self_dependency: gem_name)
      end

      # Ensure development dependency lines in a gemspec match the desired lines.
      # `desired` is a hash mapping gem_name => desired_line (string, without leading indentation).
      def ensure_development_dependencies(content, desired)
        return content if desired.nil? || desired.empty?
        result = PrismUtils.parse_with_comments(content)
        stmts = PrismUtils.extract_statements(result.value.statements)
        gemspec_call = stmts.find do |s|
          s.is_a?(Prism::CallNode) && s.block && PrismUtils.extract_const_name(s.receiver) == "Gem::Specification" && s.name == :new
        end

        unless gemspec_call
          out = content.dup
          out << "\n" unless out.end_with?("\n") || out.empty?
          desired.each do |_gem, line|
            out << line.strip + "\n"
          end
          return out
        end

        call_src = gemspec_call.slice
        body_node = gemspec_call.block&.body
        body_src = if (m = call_src.match(/do\b[^\n]*\|[^|]*\|\s*(.*)end\s*\z/m))
          m[1]
        else
          body_node ? body_node.slice : ""
        end

        new_body = body_src.dup
        stmt_nodes = PrismUtils.extract_statements(body_node)

        version_node = stmt_nodes.find do |n|
          n.is_a?(Prism::CallNode) && n.name.to_s.start_with?("version") && n.receiver && n.receiver.slice.strip.end_with?("spec")
        end

        desired.each do |gem_name, desired_line|
          found = stmt_nodes.find do |n|
            next false unless n.is_a?(Prism::CallNode)
            next false unless [:add_development_dependency, :add_dependency].include?(n.name)
            first_arg = n.arguments&.arguments&.first
            val = PrismUtils.extract_literal_value(first_arg)
            val && val.to_s == gem_name
          end

          if found
            indent = found.slice.lines.first.match(/^(\s*)/)[1]
            replacement = indent + desired_line.strip + "\n"
            new_body = new_body.sub(found.slice, replacement)
          else
            insert_line = "  " + desired_line.strip + "\n"
            new_body = if version_node
              new_body.sub(version_node.slice, version_node.slice + "\n" + insert_line)
            else
              new_body.rstrip + "\n" + insert_line
            end
          end
        end

        new_call_src = call_src.sub(body_src, new_body)
        content.sub(call_src, new_call_src)
      rescue StandardError => e
        debug_error(e, __method__)
        content
      end

      # --- Private helpers ---

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

          recv = n.receiver
          recv_name = recv ? recv.slice.strip : nil
          recv_name && recv_name.end_with?(blk_param) && n.name.to_s.start_with?(field)
        end
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

      def build_literal_value(v)
        if v.is_a?(Array)
          arr = v.compact.map(&:to_s).map { |e| '"' + e.gsub('"', '\\"') + '"' }
          "[" + arr.join(", ") + "]"
        else
          '"' + v.to_s.gsub('"', '\\"') + '"'
        end
      end

      def placeholder?(v)
        return false unless v.is_a?(String)
        v.strip.match?(/\A[^\x00-\x7F]{1,4}\s*\z/)
      end
    end
  end
end
