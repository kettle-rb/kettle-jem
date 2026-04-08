# frozen_string_literal: true

require_relative "template_phase"

module Kettle
  module Jem
    module Phases
      # Phase 6: Sync .env.local.example and bootstrap version_gem touchpoints.
      class EnvironmentTemplates < TemplatePhase
        PHASE_EMOJI = "🌍"
        PHASE_NAME = "Environment templates"
        PHASE_DETAIL = ".env.local.example"

        private

        def perform
          helpers = context.helpers
          out = context.out
          envlocal_src = File.join(context.template_root, ".env.local.example")
          envlocal_dest = File.join(context.project_root, ".env.local.example")
          if File.exist?(envlocal_src)
            envlocal_strategy = helpers.strategy_for(envlocal_dest)
            unless envlocal_strategy == :keep_destination
              if envlocal_strategy == :raw_copy
                helpers.copy_file_with_prompt(envlocal_src, envlocal_dest, allow_create: true, allow_replace: true, raw: true)
              else
                helpers.copy_file_with_prompt(envlocal_src, envlocal_dest, allow_create: true, allow_replace: true) do |content|
                  if envlocal_strategy != :accept_template && File.exist?(envlocal_dest)
                    begin
                      Dotenv::Merge::SmartMerger.new(
                        content,
                        File.read(envlocal_dest),
                        preference: :destination,
                        add_template_only_nodes: true,
                        freeze_token: "kettle-jem",
                      ).merge
                    rescue StandardError => e
                      Kettle::Dev.debug_error(e, __method__)
                      content
                    end
                  else
                    content
                  end
                end
              end
            end
          end

          # version_gem bootstrap
          begin
            Kettle::Jem::Tasks::TemplateTask.bootstrap_version_gem_touchpoints!(
              helpers: helpers,
              project_root: context.project_root,
              meta: context.meta,
            )
          rescue StandardError => e
            Kettle::Dev.debug_error(e, __method__)
            out.warning("Skipped version_gem bootstrap due to #{e.class}: #{e.message}")
          end
        end
      end
    end
  end
end
