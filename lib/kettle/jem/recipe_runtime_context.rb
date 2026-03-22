# frozen_string_literal: true

module Kettle
  module Jem
    # Shared builder for recipe-backed runtime context hashes.
    # Normalizes hash-like caller input to symbol keys and overlays explicit
    # runtime values while dropping nil / blank string additions.
    module RecipeRuntimeContext
      module_function

      def build(context = nil, **runtime_values)
        normalize_context_hash(context).tap do |normalized|
          runtime_values.each do |key, value|
            next if runtime_value_omitted?(value)

            normalized[key] = value
          end
        end
      end

      def normalize_context_hash(context)
        return {} unless context.respond_to?(:to_h)

        context.to_h.each_with_object({}) do |(key, value), memo|
          normalized_key = key.respond_to?(:to_sym) ? key.to_sym : key
          memo[normalized_key] = value
        end
      end

      def runtime_value_omitted?(value)
        value.nil? || blank_string?(value)
      end

      def blank_string?(value)
        value.respond_to?(:strip) && value.strip.empty?
      end
    end
  end
end
