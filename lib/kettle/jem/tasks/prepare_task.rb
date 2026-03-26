# frozen_string_literal: true

module Kettle
  module Jem
    module Tasks
      module PrepareTask
        module_function

        def run(helpers: Kettle::Jem::TemplateHelpers, project_root: nil, template_root: nil, meta: nil)
          helpers.clear_warnings if helpers.respond_to?(:clear_warnings)
          helpers.clear_template_run_outcome! if helpers.respond_to?(:clear_template_run_outcome!)

          project_root ||= helpers.project_root
          template_root ||= helpers.template_root
          meta ||= helpers.gemspec_metadata(project_root)

          options = Kettle::Jem::Tasks::TemplateTask.token_options(meta, helpers)
          return :unavailable unless Kettle::Jem::Tasks::TemplateTask.prerequisite_validation_available?(options)

          bootstrap_result = Kettle::Jem::Tasks::TemplateTask.ensure_kettle_config_bootstrap!(
            helpers: helpers,
            project_root: project_root,
            template_root: template_root,
            token_options: options,
          )
          return bootstrap_result if bootstrap_result == :bootstrap_only

          Kettle::Jem::Tasks::TemplateTask.backfill_project_kettle_config_tokens!(
            helpers: helpers,
            project_root: project_root,
          )

          helpers.clear_kettle_config!
          helpers.configure_tokens!(**options)
          Kettle::Jem::Tasks::TemplateTask.validate_required_token_values!(
            helpers: helpers,
            project_root: project_root,
            template_root: template_root,
            gem_name: options[:gem_name],
          )

          :ready
        end
      end
    end
  end
end
