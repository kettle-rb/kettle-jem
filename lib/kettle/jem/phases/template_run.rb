# frozen_string_literal: true

require "service_actor"

require_relative "template_phase"
require_relative "config_sync"
require_relative "dev_container"
require_relative "github_workflows"
require_relative "quality_config"
require_relative "modular_gemfiles"
require_relative "spec_helper"
require_relative "environment_templates"
require_relative "remaining_files"
require_relative "git_hooks"
require_relative "license_files"
require_relative "duplicate_check"

module Kettle
  module Jem
    module Phases
      # Orchestrator actor that chains all template phases in order.
      #
      # Usage:
      #   result = TemplateRun.call(
      #     context: phase_context,
      #     pre_dup_baseline_set: baseline_set,
      #     pre_dup_count: count,
      #     templating_report_path: path,
      #   )
      class TemplateRun < Actor
        input :context, type: PhaseContext
        input :pre_dup_baseline_set, type: Set, allow_nil: true, default: nil
        input :pre_dup_count, type: Integer, default: 0
        input :templating_report_path, type: String, allow_nil: true, default: nil

        play ConfigSync,
          DevContainer,
          GithubWorkflows,
          QualityConfig,
          ModularGemfiles,
          SpecHelper,
          EnvironmentTemplates,
          RemainingFiles,
          GitHooks,
          LicenseFiles,
          DuplicateCheck
      end
    end
  end
end
