# frozen_string_literal: true

require_relative "template_phase"

module Kettle
  module Jem
    module Phases
      # Phase 10: Unresolved token check and duplicate line validation.
      class DuplicateCheck < TemplatePhase
        PHASE_EMOJI = "🔎"
        PHASE_NAME = "Duplicate check"

        input :templating_report_path, type: String, allow_nil: true, default: nil

        private

        # This phase emits its own phase line after computing results.
        def emit_phase_start
        end

        # DuplicateCheck prints its own final status after it knows the warning
        # count and optional report path, so the generic TemplatePhase summary
        # would only duplicate that output.
        def emit_phase_line
        end

        def perform
          helpers = context.helpers
          out = context.out
          project_root = context.project_root

          # Unresolved token check
          unresolved_by_file = Kettle::Jem::Tasks::TemplateTask.unresolved_written_tokens(
            helpers: helpers,
            project_root: project_root,
          )

          unless unresolved_by_file.empty?
            msg_lines = ["Unresolved {KJ|...} tokens found in #{unresolved_by_file.size} file(s):"]
            unresolved_by_file.each do |rel, tokens|
              msg_lines << "  #{rel}: #{tokens.join(", ")}"
            end
            msg_lines << ""
            msg_lines << "Please set the required environment variables or add values to .kettle-jem.yml and re-run."
            msg_lines << "Tip: .kettle-jem.yml was written first so you can commit it and fill in missing data."

            helpers.add_warning(msg_lines.join("\n"))
            helpers.print_warnings_summary

            Kettle::Jem::Tasks::TemplateTask.task_abort(msg_lines.first)
          end

          json_path = templating_report_path&.sub(/\.md\z/, "-duplicates.json")
          outcome = Kettle::Drift.run(
            project_root: project_root,
            template_dir: Kettle::Jem::DuplicateLineValidator.kettle_template_dir,
            min_chars: Kettle::Jem::DuplicateLineValidator::DEFAULT_MIN_CHARS,
            json_path: json_path,
            lock_path: File.join(project_root, ".kettle-jem.lock"),
            mode: :update,
            printer_class: nil,
          )

          out.phase(duplicate_phase_emoji(outcome), "Duplicate check", detail: duplicate_phase_detail(outcome))
          out.report_detail(Kettle::Jem::DuplicateLineValidator.report_summary(outcome.results, project_root: project_root)) unless outcome.results.empty?
          out.phase("📄", "Duplicate report", detail: Kettle::Jem.display_path(outcome.json_path)) if outcome.json_path

          return if outcome.exit_code.zero?

          Kettle::Jem::Tasks::TemplateTask.task_abort(
            "Duplicate drift changed for template-managed files. Review #{Kettle::Jem.display_path(outcome.lock_path)} and rerun kettle-drift.",
          )
        end

        def duplicate_phase_emoji(outcome)
          return "🔎" if outcome.clean? || outcome.diff.state == :no_changes

          outcome.exit_code.zero? ? "⚠️" : "❌"
        end

        def duplicate_phase_detail(outcome)
          return "clean" if outcome.clean?

          "#{outcome.warning_count} warning(s) (#{duplicate_state_label(outcome.diff.state)})"
        end

        def duplicate_state_label(state)
          case state
          when :new
            "first baseline"
          when :no_changes
            "acknowledged, unchanged"
          when :better
            "improved, lockfile updated"
          when :updated
            "changed, lockfile updated"
          when :worse
            "new drift, lockfile outdated"
          else
            state.to_s.tr("_", " ")
          end
        end
      end
    end
  end
end
