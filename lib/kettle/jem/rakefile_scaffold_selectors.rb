# frozen_string_literal: true

require "set"

module Kettle
  module Jem
    module RakefileScaffoldSelectors
      module_function

      def selector_for(spec, **options)
        Kettle::Jem::Crispr::OwnerSelector.new(
          id: selector_id(spec),
          limit: options.fetch(:limit, {at_least: 0}),
          metadata: options,
          locate: lambda do |context|
            owners = context.structural_owners(owner_scope: :shared_default)
            return [] if owners.empty?

            anchor_indexes = owners.each_index.select { |index| anchor_match?(owners[index], spec) }
            return [] if anchor_indexes.empty?

            matched_indexes = anchor_indexes.flat_map do |anchor_index|
              indexes = [anchor_index]
              next indexes if spec.satellite_patterns.to_a.empty?

              start_index = [0, anchor_index - spec.max_lookbehind.to_i].max
              end_index = [owners.length - 1, anchor_index + spec.max_lookahead.to_i].min

              spec.satellite_patterns.each do |pattern|
                pattern_tokens = jaccard_tokens(pattern)
                (start_index..end_index).each do |index|
                  next if index == anchor_index

                  owner = owners[index]
                  candidate_tokens = jaccard_tokens(owner.slice.to_s)
                  score = jaccard(pattern_tokens, candidate_tokens)
                  indexes << index if score >= spec.jaccard_threshold.to_f
                end
              end

              indexes
            end.uniq.sort

            matched_indexes.filter_map do |index|
              owner = owners[index]
              next unless owner.respond_to?(:location) && owner.location

              Kettle::Jem::Crispr::Match.new(
                node: owner,
                start_line: owner.location.start_line,
                end_line: owner.location.end_line,
                metadata: {
                  selector: selector_id(spec),
                  owner_index: index,
                },
              )
            end
          end,
        )
      end

      def remove(content, spec)
        actor = Kettle::Jem::Crispr::Delete.call(
          content: content.to_s,
          target: selector_for(spec),
          source_label: "Rakefile",
        )
        normalize_deleted_gaps(actor.updated_content)
      end

      def normalize_deleted_gaps(content)
        content.to_s.gsub(/\n{3,}/, "\n\n")
      end

      def selector_id(spec)
        anchor_type = spec.anchor_type.to_s
        anchor_value = spec.anchor_value.to_s.gsub(/[^A-Za-z0-9]+/, "_").gsub(/\A_+|_+\z/, "")
        "rakefile_scaffold_#{anchor_type}_#{anchor_value}"
      end

      def anchor_match?(owner, spec)
        return false unless owner.respond_to?(:name)

        case spec.anchor_type
        when :require_call
          require_anchor_match?(owner, spec.anchor_value)
        when :task_call
          task_anchor_match?(owner, spec.anchor_value, spec.jaccard_threshold)
        else
          false
        end
      end

      def require_anchor_match?(owner, anchor_value)
        return false unless owner.name.to_s == "require"

        first_arg = owner.arguments&.arguments&.first
        return false unless first_arg

        first_arg.respond_to?(:unescaped) && first_arg.unescaped == anchor_value
      end

      def task_anchor_match?(owner, anchor_value, threshold)
        return false unless owner.name.to_s == "task"

        owner_tokens = jaccard_tokens(owner.slice.to_s)
        pattern_tokens = jaccard_tokens("task #{anchor_value}")
        jaccard(pattern_tokens, owner_tokens) >= threshold.to_f
      end

      def jaccard_tokens(text)
        text.to_s.scan(/[A-Za-z0-9_]+/).to_set
      end

      def jaccard(left, right)
        union = left | right
        return 0.0 if union.empty?

        (left & right).size.to_f / union.size
      end
    end
  end
end
