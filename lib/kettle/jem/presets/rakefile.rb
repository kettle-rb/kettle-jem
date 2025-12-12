# frozen_string_literal: true

module Kettle
  module Jem
    module Presets
      # MergerConfig preset for Rakefile merging.
      #
      # Provides intelligent signature matching for Rake constructs:
      # - `task` definitions match by task name
      # - `namespace` blocks match by namespace name
      # - `desc` calls are associated with their task
      #
      # @example Basic usage
      #   config = Rakefile.destination_wins
      #   merger = Prism::Merge::SmartMerger.new(template, dest, **config.to_h)
      #
      # @see Kettle::Jem::Signatures.rakefile
      class Rakefile < Base
        class << self
          # Returns the signature generator for Rakefile merging.
          #
          # @return [Proc] Lambda that generates signatures for Rake nodes
          def signature_generator
            Signatures.rakefile
          end

          # Returns node typing for categorizing different types of tasks.
          #
          # Categorizes tasks into:
          # - `:build_task`: Tasks related to building (build, compile)
          # - `:test_task`: Tasks related to testing (test, spec)
          # - `:release_task`: Tasks related to releasing (release, publish)
          # - `:lint_task`: Tasks related to linting (rubocop, lint, style)
          # - `:doc_task`: Tasks related to documentation (yard, rdoc)
          #
          # @return [Hash] Node typing configuration
          def default_node_typing
            {
              CallNode: ->(node) {
                return node unless node.name == :task

                first_arg = node.arguments&.arguments&.first
                task_name = case first_arg
                when ->(a) { a.respond_to?(:unescaped) }
                  first_arg.unescaped.to_s
                when ->(a) { a.respond_to?(:elements) }
                  # Handle task :name => [:deps]
                  elem = first_arg.elements.first
                  elem&.key&.respond_to?(:unescaped) ? elem.key.unescaped.to_s : nil
                end

                return node unless task_name

                merge_type = categorize_task(task_name)
                merge_type ? Ast::Merge::NodeTyping.with_merge_type(node, merge_type) : node
              },
            }
          end

          private

          # Categorize a task by its name.
          #
          # @param task_name [String] The task name
          # @return [Symbol, nil] The category or nil for uncategorized
          def categorize_task(task_name)
            case task_name
            when /build/, /compile/, /install/
              :build_task
            when /test/, /spec/, /cucumber/
              :test_task
            when /release/, /publish/, /deploy/
              :release_task
            when /rubocop/, /lint/, /style/, /reek/
              :lint_task
            when /yard/, /rdoc/, /doc/
              :doc_task
            when /clean/, /clobber/
              :clean_task
            when /coverage/, /cov/
              :coverage_task
            end
          end
        end
      end
    end
  end
end
