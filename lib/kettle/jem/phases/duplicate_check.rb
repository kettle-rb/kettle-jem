# frozen_string_literal: true

require "fileutils"
require "json"

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
            lock_path: duplicate_lock_path(project_root),
            mode: :update,
            printer_class: nil,
          )

          write_duplicate_report!(outcome, project_root: project_root) if outcome.json_path

          out.phase(duplicate_phase_emoji(outcome), "Duplicate check", detail: duplicate_phase_detail(outcome))
          drift_delta_summary = duplicate_diff_summary(outcome, project_root: project_root)
          out.report_detail(drift_delta_summary) if drift_delta_summary
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
            "new drift appeared, some acknowledged drift fixed, lockfile outdated"
          when :worse
            "new drift, lockfile outdated"
          else
            state.to_s.tr("_", " ")
          end
        end

        def duplicate_lock_path(project_root)
          File.join(project_root, Kettle::Drift::DEFAULT_LOCKFILE)
        end

        def duplicate_diff_summary(outcome, project_root:)
          case outcome.diff.state
          when :new
            "No existing duplicate lockfile. First baseline recorded at #{Kettle::Jem.display_path(outcome.lock_path)}."
          when :worse, :better, :updated, :no_changes, :complete
            <<~TEXT.rstrip
              ### Duplicate Drift Delta
              Lockfile: #{Kettle::Jem.display_path(outcome.lock_path)}
              State: #{duplicate_state_label(outcome.diff.state)}
              New since lockfile: #{outcome.diff.new_entries.size}
              Fixed since lockfile: #{outcome.diff.fixed_entries.size}
              Unchanged acknowledged: #{outcome.diff.unchanged_entries.size}
            TEXT
          end
        end

        def write_duplicate_report!(outcome, project_root:)
          FileUtils.mkdir_p(File.dirname(outcome.json_path))
          File.write(
            outcome.json_path,
            JSON.pretty_generate(duplicate_report_payload(outcome, project_root: project_root)) + "\n",
          )
        end

        def duplicate_report_payload(outcome, project_root:)
          {
            report_type: "kettle-jem-duplicate-drift",
            state: outcome.diff.state.to_s,
            warning_count: outcome.warning_count,
            lockfile: outcome.lock_path,
            summary: {
              new_entries: outcome.diff.new_entries.size,
              fixed_entries: outcome.diff.fixed_entries.size,
              unchanged_entries: outcome.diff.unchanged_entries.size,
            },
            diff: {
              new_entries: duplicate_report_entries(outcome.diff.new_entries, project_root: project_root),
              fixed_entries: duplicate_report_entries(outcome.diff.fixed_entries, project_root: project_root),
              unchanged_entries: duplicate_report_entries(outcome.diff.unchanged_entries, project_root: project_root),
            },
            current_results: duplicate_report_results(outcome.results, project_root: project_root),
          }
        end

        def duplicate_report_results(results, project_root:)
          results.to_h do |chunk, entries|
            [chunk, duplicate_report_entries(entries, project_root: project_root, include_chunk: false)]
          end
        end

        def duplicate_report_entries(entries, project_root:, include_chunk: true)
          Array(entries).map do |entry|
            payload = {
              file: duplicate_report_file_path(entry[:file], project_root: project_root),
              lines: Array(entry[:lines]),
            }
            payload[:chunk] = entry[:chunk] if include_chunk && entry.key?(:chunk)
            payload
          end
        end

        def duplicate_report_file_path(path, project_root:)
          displayed = Kettle::Jem.display_path(path)
          displayed_root = Kettle::Jem.display_path(project_root)
          displayed.sub(%r{^#{Regexp.escape(displayed_root)}/?}, "")
        end
      end
    end
  end
end
