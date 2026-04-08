# frozen_string_literal: true

require_relative "template_phase"

module Kettle
  module Jem
    module Phases
      # Phase 4: Sync gemfiles/modular/ directory.
      class ModularGemfiles < TemplatePhase
        PHASE_EMOJI = "💎"
        PHASE_NAME = "Modular gemfiles"
        PHASE_DETAIL = "gemfiles/modular/"

        private

        def perform
          Kettle::Jem::ModularGemfiles.sync!(
            helpers: context.helpers,
            project_root: context.project_root,
            min_ruby: context.min_ruby,
            gem_name: context.gem_name,
          )
        end
      end
    end
  end
end
