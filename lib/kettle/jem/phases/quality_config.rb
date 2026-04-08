# frozen_string_literal: true

require_relative "template_phase"

module Kettle
  module Jem
    module Phases
      # Phase 3: Sync .qlty/qlty.toml quality configuration.
      class QualityConfig < TemplatePhase
        PHASE_EMOJI = "🔍"
        PHASE_NAME = "Quality config"
        PHASE_DETAIL = ".qlty/qlty.toml"

        private

        def perform
          helpers = context.helpers
          qlty_src = helpers.prefer_example(File.join(context.template_root, ".qlty/qlty.toml"))
          qlty_dest = File.join(context.project_root, ".qlty/qlty.toml")
          qlty_strategy = helpers.strategy_for(qlty_dest)
          return if qlty_strategy == :keep_destination

          if qlty_strategy == :raw_copy
            helpers.copy_file_with_prompt(qlty_src, qlty_dest, allow_create: true, allow_replace: true, raw: true)
          else
            helpers.copy_file_with_prompt(qlty_src, qlty_dest, allow_create: true, allow_replace: true) do |content|
              c = content
              if qlty_strategy != :accept_template && File.exist?(qlty_dest)
                begin
                  c = Toml::Merge::SmartMerger.new(
                    c,
                    File.read(qlty_dest),
                    preference: :template,
                    add_template_only_nodes: true,
                    freeze_token: "kettle-jem",
                  ).merge
                rescue StandardError => e
                  Kettle::Dev.debug_error(e, __method__)
                end
              end
              c
            end
          end
        end
      end
    end
  end
end
