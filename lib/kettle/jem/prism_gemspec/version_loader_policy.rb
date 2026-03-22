# frozen_string_literal: true

module Kettle
  module Jem
    module PrismGemspec
      module VersionLoaderPolicy
        MODERN_VERSION_LOADER_MIN_RUBY = Gem::Version.new("3.1").freeze

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

          gemspec_call = stmts.find do |stmt|
            stmt.is_a?(Prism::CallNode) && stmt.block && PrismUtils.extract_const_name(stmt.receiver) == "Gem::Specification" && stmt.name == :new
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

        def replace_or_insert_raw_field_assignment(content:, gemspec_call:, stmt_nodes:, blk_param:, field:, rhs:)
          field_node = find_field_node(stmt_nodes, blk_param, field)

          lines = content.lines

          plan = if field_node
            loc = field_node.location
            indent = content.lines[loc.start_line - 1].to_s[/^(\s*)/, 1] || ""
            build_splice_plan(
              content: content,
              replacement: "#{indent}#{blk_param}.#{field} = #{rhs}\n",
              start_line: loc.start_line,
              end_line: loc.end_line,
              metadata: {
                source: :kettle_jem_prism_gemspec,
                edit: :replace_or_insert_raw_field_assignment,
                field: field,
              },
            )
          else
            anchor_node = raw_field_insertion_anchor_node(stmt_nodes, blk_param)
            build_anchor_splice_plan(
              content: content,
              lines: lines,
              anchor_line: raw_field_insertion_anchor_line(anchor_node, gemspec_call),
              insertion_text: "  #{blk_param}.#{field} = #{rhs}\n",
              position: :after,
              metadata: raw_field_insertion_metadata(field: field, anchor_node: anchor_node),
            )
          end

          merged_content_from_plans(
            content: content,
            plans: [plan],
            metadata: {source: :kettle_jem_prism_gemspec, edit: :replace_or_insert_raw_field_assignment, field: field},
          )
        end

        def raw_field_insertion_anchor_node(stmt_nodes, blk_param)
          find_field_node(stmt_nodes, blk_param, "name") || stmt_nodes.first
        end

        def raw_field_insertion_anchor_line(anchor_node, gemspec_call)
          if anchor_node
            anchor_node.location.end_line
          else
            gemspec_call.location.end_line
          end
        end

        def raw_field_insertion_metadata(field:, anchor_node:)
          {
            source: :kettle_jem_prism_gemspec,
            edit: :replace_or_insert_raw_field_assignment,
            field: field,
            inserted_after_anchor: anchor_node ? anchor_node.name : :gemspec_end,
          }
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
      end
    end
  end
end
