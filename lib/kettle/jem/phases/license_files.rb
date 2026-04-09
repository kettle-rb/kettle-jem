# frozen_string_literal: true

require_relative "template_phase"

module Kettle
  module Jem
    module Phases
      # Phase 9: Copy, prune, and migrate license files.
      class LicenseFiles < TemplatePhase
        PHASE_EMOJI = "📄"
        PHASE_NAME = "License files"

        private

        def perform
          helpers = context.helpers
          context.out
          Kettle::Jem::Tasks::TemplateTask.copy_selected_license_files!(
            helpers: helpers,
            project_root: context.project_root,
            template_root: context.template_root,
          )
          Kettle::Jem::Tasks::TemplateTask.remove_obsolete_license_files!(
            helpers: helpers,
            project_root: context.project_root,
            template_root: context.template_root,
          )
          Kettle::Jem::Tasks::TemplateTask.migrate_license_txt!(helpers: helpers, project_root: context.project_root)
          Kettle::Jem::Tasks::TemplateTask.collect_git_copyright!(helpers: helpers, project_root: context.project_root)
        end
      end
    end
  end
end
