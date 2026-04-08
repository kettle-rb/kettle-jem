# frozen_string_literal: true

require_relative "template_phase"

module Kettle
  module Jem
    module Phases
      # Phase 0: Sync .kettle-jem.yml configuration.
      class ConfigSync < TemplatePhase
        PHASE_EMOJI = "⚙️"
        PHASE_NAME = "Config sync"
        PHASE_DETAIL = ".kettle-jem.yml"

        private

        def perform
          helpers = context.helpers
          Kettle::Jem::Tasks::TemplateTask.sync_existing_kettle_config!(
            helpers: helpers,
            project_root: context.project_root,
            template_root: context.template_root,
            token_options: {
              org: context.forge_org,
              gem_name: context.gem_name,
              namespace: context.namespace,
              namespace_shield: context.namespace_shield,
              gem_shield: context.gem_shield,
              funding_org: context.funding_org,
              min_ruby: context.min_ruby,
            },
          )
          # sync_existing_kettle_config! temporarily seeds and clears token state
          # while rewriting .kettle-jem.yml, so restore the full replacement map.
          helpers.configure_tokens!(
            org: context.forge_org,
            gem_name: context.gem_name,
            namespace: context.namespace,
            namespace_shield: context.namespace_shield,
            gem_shield: context.gem_shield,
            funding_org: context.funding_org,
            min_ruby: context.min_ruby,
          )
        end
      end
    end
  end
end
