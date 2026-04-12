# frozen_string_literal: true

module Kettle
  module Jem
    class PluginRegistry
      Hook = Struct.new(:plugin_name, :phase, :timing, :callback, keyword_init: true)
      VALID_TIMINGS = %i[before after].freeze

      def initialize
        @hooks = []
      end

      def register(plugin_name:, phase:, timing:, &callback)
        raise ArgumentError, "Plugin callbacks require a block" unless callback

        normalized_phase = normalize_phase(phase)
        normalized_timing = normalize_timing(timing)
        @hooks << Hook.new(
          plugin_name: plugin_name.to_s,
          phase: normalized_phase,
          timing: normalized_timing,
          callback: callback,
        )
      end

      def run(timing:, phase:, context:, actor:, phase_stats:)
        normalized_phase = normalize_phase(phase)
        normalized_timing = normalize_timing(timing)

        hooks_for(normalized_timing, normalized_phase).each do |hook|
          hook.callback.call(
            context: context,
            actor: actor,
            phase: normalized_phase,
            phase_stats: phase_stats,
            plugin_name: hook.plugin_name,
          )
        end
      end

      private

      def hooks_for(timing, phase)
        @hooks.select { |hook| hook.timing == timing && hook.phase == phase }
      end

      def normalize_phase(phase)
        value = phase.to_s.strip
        raise ArgumentError, "Plugin phase cannot be blank" if value.empty?

        value.downcase.to_sym
      end

      def normalize_timing(timing)
        value = timing.to_s.strip.downcase.to_sym
        return value if VALID_TIMINGS.include?(value)

        raise ArgumentError, "Unsupported plugin timing #{timing.inspect}"
      end
    end
  end
end
