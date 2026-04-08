# frozen_string_literal: true

require_relative "template_phase"

module Kettle
  module Jem
    module Phases
      # Phase 10: Unresolved token check and duplicate line validation.
      class DuplicateCheck < TemplatePhase
        PHASE_EMOJI = "🔎"
        PHASE_NAME = "Duplicate check"

        input :pre_dup_baseline_set, type: Set, allow_nil: true, default: nil
        input :pre_dup_count, type: Integer, default: 0
        input :templating_report_path, type: String, allow_nil: true, default: nil

        private

        # This phase emits its own phase line after computing results.
        def emit_phase_start
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

          # Duplicate line validation
          dup_results = Kettle::Jem::DuplicateLineValidator.scan_template_results(
            template_results: helpers.template_results,
            min_chars: Kettle::Jem::DuplicateLineValidator::DEFAULT_MIN_CHARS,
          )
          dup_results = Kettle::Jem::DuplicateLineValidator.subtract_baseline(dup_results, baseline_set: pre_dup_baseline_set)
          dup_count = Kettle::Jem::DuplicateLineValidator.warning_count(dup_results)
          dup_increased = dup_count > pre_dup_count

          if dup_results.empty?
            out.phase("🔎", "Duplicate check", detail: "clean")
          else
            emoji = dup_increased ? "❌" : "🔎"
            delta = dup_count - pre_dup_count
            delta_label = if delta > 0
              "+#{delta} new"
            elsif delta < 0
              "#{delta} fixed"
            else
              "unchanged"
            end
            out.phase(emoji, "Duplicate check", detail: "#{dup_count} warning(s) (#{pre_dup_count} pre-existing, #{delta_label})")
            out.report_detail(Kettle::Jem::DuplicateLineValidator.report_summary(dup_results, project_root: project_root))

            if templating_report_path
              json_path = templating_report_path.sub(/\.md\z/, "-duplicates.json")
              Kettle::Jem::DuplicateLineValidator.write_json(dup_results, json_path)
              out.phase("📄", "Duplicate report", detail: json_path)
            end
          end
        end
      end
    end
  end
end
