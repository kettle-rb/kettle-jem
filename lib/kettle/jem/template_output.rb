# frozen_string_literal: true

module Kettle
  module Jem
    # Centralizes all CLI output for kettle-jem templating runs.
    #
    # Output is routed to two destinations:
    # - **CLI** (STDOUT) — concise phase summaries; controlled by quiet mode
    # - **Report file** — verbose per-file details; always written regardless of quiet mode
    #
    # Quiet mode (`--quiet`) suppresses all CLI output except phase summary lines.
    # Default (not-quiet) mode adds limited extra info (warnings, skipped files)
    # but still keeps most detail in the report only.
    #
    # @example
    #   out = TemplateOutput.new(quiet: true)
    #   out.phase("⚙️", "Config sync", files_changed: 1)
    #   out.detail("Merged .kettle-jem.yml")  # suppressed in quiet mode
    #   out.report_detail("Full merge trace…") # report file only
    module TemplateOutput
      # Phase summary emoji mapping — thematically relevant to each phase's purpose.
      PHASE_EMOJI = {
        config: "⚙️",
        devcontainer: "📦",
        workflows: "🔄",
        quality: "🔍",
        gemfiles: "💎",
        spec: "🧪",
        env: "🌍",
        files: "📂",
        hooks: "🪝",
        license: "📄",
        complete: "✅",
        error: "❌",
        skip: "⏭️",
        warning: "⚠️",
      }.freeze

      class Formatter
        # @param quiet [Boolean] suppress non-phase output on CLI
        # @param report_io [IO, nil] IO for report file (opened by caller)
        # @param cli_io [IO] IO for CLI output (default: $stdout)
        def initialize(quiet: false, report_io: nil, cli_io: $stdout, progress: nil)
          @quiet = quiet
          @report_io = report_io
          @cli_io = cli_io
          @phase_results = []
        end

        # @return [Boolean] whether quiet mode is active
        def quiet?
          @quiet
        end

        # Emit a phase summary line — always shown on CLI (even in quiet mode).
        #
        # @param emoji [String] leading emoji for the line
        # @param message [String] phase description
        # @param detail [String, nil] optional short detail (file count, etc.)
        def phase(emoji, message, detail: nil)
          line = detail ? "[kettle-jem] #{emoji}  #{message} - #{detail}" : "[kettle-jem] #{emoji}  #{message}"
          emit_cli_line(line)
          report_line(line)
          @phase_results << {emoji: emoji, message: message, detail: detail}
        end

        # Emit a detail line — shown on CLI only in non-quiet mode.
        # Always written to report.
        #
        # @param message [String] the detail message
        def detail(message)
          emit_cli_line(message) unless @quiet
          report_line(message)
        end

        # Emit a warning — shown on CLI in both modes (prefixed with ⚠️).
        # Always written to report.
        #
        # @param message [String] warning text
        def warning(message)
          line = "[kettle-jem] ⚠️  #{message}"
          emit_cli_line(line)
          report_line(line)
        end

        # Write a line only to the report file — never shown on CLI.
        #
        # @param message [String] verbose detail for the report
        def report_detail(message)
          report_line(message)
        end

        # Emit an error line — always shown on CLI.
        #
        # @param message [String] error text
        def error(message)
          line = "[kettle-jem] ❌  #{message}"
          emit_cli_line(line)
          report_line(line)
        end

        # Attach a report IO after initialization (e.g., once report path is known).
        #
        # @param io [IO] writable IO for the report file
        attr_writer :report_io

        # @return [Array<Hash>] collected phase results for summary
        attr_reader :phase_results

        private

        def emit_cli_line(line)
          @cli_io.puts(line)
        end

        def report_line(line)
          @report_io&.puts(line)
        rescue IOError
          # Report IO closed or errored — don't crash the run
        end
      end
    end
  end
end
