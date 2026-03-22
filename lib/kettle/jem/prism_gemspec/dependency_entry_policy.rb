# frozen_string_literal: true

module Kettle
  module Jem
    module PrismGemspec
      module DependencyEntryPolicy
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
          context = safe_gemspec_context(content)
          return development_dependency_entries_fallback(content) unless context

          dependency_node_records(context[:stmt_nodes], context[:blk_param]).filter_map do |record|
            development_dependency_entry(record, content)
          end
        end

        def development_dependency_signatures(content)
          development_dependency_entries(content)
            .map { |entry| entry[:signature] }
            .compact
            .sort
        end

        private

        def development_dependency_entry(record, content)
          return unless record[:method] == "add_development_dependency"

          {
            gem: record[:gem],
            line: PrismUtils.node_slice_with_trailing_comment(record[:node], content).rstrip,
            signature: dependency_signature(record[:node]),
          }
        end

        def development_dependency_entries_fallback(content)
          DependencySectionPolicy.development_dependency_records(content).map do |record|
            fallback_development_dependency_entry(record)
          end
        end

        def fallback_development_dependency_entry(record)
          {
            gem: record[:gem],
            line: record[:line].rstrip,
            signature: record[:signature],
          }
        end
      end
    end
  end
end
