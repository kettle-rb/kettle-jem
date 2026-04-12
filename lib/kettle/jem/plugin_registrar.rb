# frozen_string_literal: true

module Kettle
  module Jem
    class PluginRegistrar
      attr_reader :plugin_name

      def initialize(plugin_name:, registry:)
        @plugin_name = plugin_name.to_s
        @registry = registry
      end

      def on_phase(phase, timing: :after, &block)
        @registry.register(
          plugin_name: plugin_name,
          phase: phase,
          timing: timing,
          &block
        )
      end

      def before_phase(phase, &block)
        on_phase(phase, timing: :before, &block)
      end

      def after_phase(phase, &block)
        on_phase(phase, timing: :after, &block)
      end
    end
  end
end
