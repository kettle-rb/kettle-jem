# frozen_string_literal: true

require_relative "template_phase"

module Kettle
  module Jem
    module Phases
      # Phase 5: Update spec/spec_helper.rb require lines.
      class SpecHelper < TemplatePhase
        PHASE_EMOJI = "🧪"
        PHASE_NAME = "Spec helper"
        PHASE_DETAIL = "spec/spec_helper.rb"

        private

        def perform
          helpers = context.helpers
          out = context.out
          dest_spec_helper = File.join(context.project_root, "spec/spec_helper.rb")
          return unless File.file?(dest_spec_helper)

          old = File.read(dest_spec_helper)
          return unless old.include?('require "kettle/dev"') || old.include?("require 'kettle/dev'")

          replacement = %(require "#{context.entrypoint_require}")
          new_content = old.gsub(/require\s+["']kettle\/dev["']/, replacement)
          return if new_content == old

          if helpers.ask("Update require \"kettle/dev\" in spec/spec_helper.rb to #{replacement}?", true)
            helpers.write_file(dest_spec_helper, new_content)
            out.detail("Updated require in spec/spec_helper.rb")
          else
            out.report_detail("Skipped modifying spec/spec_helper.rb")
          end
        end
      end
    end
  end
end
