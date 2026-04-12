# frozen_string_literal: true

module Kettle
  module Jem
    module PluginLoader
      module_function

      REGISTRATION_METHOD = :register_kettle_jem_plugin

      def load!(plugin_names:)
        registry = Kettle::Jem::PluginRegistry.new

        normalize_plugin_names(plugin_names).each do |plugin_name|
          load_plugin!(plugin_name, registry: registry)
        end

        registry
      end

      def load_plugin!(plugin_name, registry:)
        require(plugin_require_path(plugin_name))

        handle = plugin_handle(plugin_name)
        unless handle.respond_to?(REGISTRATION_METHOD)
          raise Kettle::Jem::Error,
            "Plugin #{plugin_name.inspect} does not implement #{REGISTRATION_METHOD}."
        end

        handle.public_send(
          REGISTRATION_METHOD,
          Kettle::Jem::PluginRegistrar.new(plugin_name: plugin_name, registry: registry),
        )
      rescue LoadError => e
        raise Kettle::Jem::Error, "Could not load plugin #{plugin_name.inspect}: #{e.message}"
      end

      def normalize_plugin_names(plugin_names)
        Array(plugin_names).flatten.map { |name| name.to_s.strip }.reject(&:empty?).uniq
      end

      def plugin_require_path(plugin_name)
        plugin_name.to_s.tr("-", "/")
      end

      def plugin_handle(plugin_name)
        constant_name = plugin_name.to_s.split("-").map { |part| camelize(part) }.join("::")
        constant_name.split("::").inject(Object) { |scope, name| scope.const_get(name) }
      rescue NameError => e
        raise Kettle::Jem::Error, "Could not resolve plugin handle for #{plugin_name.inspect}: #{e.message}"
      end

      def camelize(value)
        value.to_s.split("_").map(&:capitalize).join
      end
    end
  end
end
