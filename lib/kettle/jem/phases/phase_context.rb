# frozen_string_literal: true

module Kettle
  module Jem
    module Phases
      # Immutable context shared across all template phase actors.
      #
      # Built once at the start of a template run and passed as an input
      # to every phase actor. Provides access to helpers, output formatter,
      # project/template paths, and gem metadata extracted during preflight.
      class PhaseContext
        attr_reader :helpers,
          :out,
          :progress,
          :plugins,
          :project_root,
          :template_root,
          :gem_name,
          :namespace,
          :namespace_shield,
          :gem_shield,
          :forge_org,
          :funding_org,
          :min_ruby,
          :entrypoint_require,
          :meta,
          :removed_appraisals,
          :parse_error_mode

        # @param helpers [Module] TemplateHelpers module
        # @param out [TemplateOutput::Formatter] CLI/report output formatter
        # @param progress [TemplateProgress, nil] optional CLI progress tracker
        # @param project_root [String] absolute path to destination project
        # @param template_root [String] absolute path to template scaffold
        # @param gem_name [String] the gem's name
        # @param namespace [String] the gem's Ruby namespace
        # @param namespace_shield [String] URL-safe namespace for shields/badges
        # @param gem_shield [String] URL-safe gem name for shields/badges
        # @param forge_org [String] GitHub/GitLab org
        # @param funding_org [String, nil] Open Collective org (nil when disabled)
        # @param min_ruby [String] minimum supported Ruby version
        # @param entrypoint_require [String] the gem's main require path
        # @param meta [Hash] raw gemspec metadata hash
        # @param removed_appraisals [Array<String>] appraisal names pruned by min_ruby
        # @param parse_error_mode [Symbol] :skip or :raise for AST parse failures
        def initialize(
          helpers:, out:, project_root:, template_root:, progress: nil, plugins: nil,
          gem_name:, namespace:, namespace_shield:, gem_shield:,
          forge_org:, funding_org:, min_ruby:, entrypoint_require:,
          meta:, removed_appraisals: [], parse_error_mode: :raise
        )
          @helpers = helpers
          @out = out
          @progress = progress
          @plugins = plugins
          @project_root = project_root
          @template_root = template_root
          @gem_name = gem_name
          @namespace = namespace
          @namespace_shield = namespace_shield
          @gem_shield = gem_shield
          @forge_org = forge_org
          @funding_org = funding_org
          @min_ruby = min_ruby
          @entrypoint_require = entrypoint_require
          @meta = meta
          @removed_appraisals = removed_appraisals
          @parse_error_mode = parse_error_mode
          freeze
        end
      end
    end
  end
end
