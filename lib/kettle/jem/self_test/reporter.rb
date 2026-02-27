# frozen_string_literal: true

require "open3"
require "time"

module Kettle
  module Jem
    module SelfTest
      # Generate unified diffs and markdown summary reports for self-test runs.
      module Reporter
        module_function

        # Produce a unified diff between two files.
        # Falls back to a simple line-by-line comparison when the +diff+ command
        # is unavailable. When one file is missing it is treated as empty.
        #
        # @param file_a [String] path to the "before" file
        # @param file_b [String] path to the "after" file
        # @return [String] unified diff output (empty string when files are identical)
        def diff(file_a, file_b)
          a = File.exist?(file_a.to_s) ? file_a.to_s : "/dev/null"
          b = File.exist?(file_b.to_s) ? file_b.to_s : "/dev/null"
          out, _status = Open3.capture2("diff", "-u", a, b)
          out
        rescue Errno::ENOENT
          # `diff` not installed — minimal fallback
          a_lines = File.exist?(file_a.to_s) ? File.readlines(file_a) : []
          b_lines = File.exist?(file_b.to_s) ? File.readlines(file_b) : []
          return "" if a_lines == b_lines

          lines = []
          lines << "--- #{file_a}"
          lines << "+++ #{file_b}"
          a_lines.each { |l| lines << "-#{l.chomp}" }
          b_lines.each { |l| lines << "+#{l.chomp}" }
          lines.join("\n") + "\n"
        end

        # Generate a markdown summary report from a manifest comparison.
        #
        # @param comparison [Hash{Symbol => Array<String>}] output of +Manifest.compare+
        #   Standard keys: +:matched+, +:changed+, +:added+, +:removed+.
        #   Optional key: +:skipped+ — files present in the source gem but not
        #   expected to be produced by the template task (lib/, spec/, template/, etc.).
        #   When +:skipped+ is provided, only truly unexpected removals appear under
        #   "Removed Files"; skipped files get an informational collapsed section.
        # @param output_dir [String] path to the output directory (for the report header)
        # @return [String] markdown report
        def summary(comparison, output_dir:)
          matched = comparison.fetch(:matched, [])
          changed = comparison.fetch(:changed, [])
          added = comparison.fetch(:added, [])
          removed = comparison.fetch(:removed, [])
          skipped = comparison.fetch(:skipped, [])

          total = matched.size + changed.size + added.size
          score = total.zero? ? 0.0 : (matched.size.to_f / total * 100).round(1)

          lines = []
          lines << "# Template Self-Test Report"
          lines << ""
          lines << "**Date**: #{Time.now.iso8601}"
          lines << "**Output**: `#{output_dir}`"
          lines << "**Score**: #{score}% (#{matched.size}/#{total} files unchanged)"
          lines << ""

          if changed.any?
            lines << "## Changed Files (#{changed.size})"
            lines << ""
            lines << "| File | Status |"
            lines << "|------|--------|"
            changed.each { |f| lines << "| #{f} | modified |" }
            lines << ""
          end

          if added.any?
            lines << "## New Files (#{added.size})"
            lines << ""
            lines << "| File |"
            lines << "|------|"
            added.each { |f| lines << "| #{f} |" }
            lines << ""
          end

          if removed.any?
            lines << "## Unexpected Removals (#{removed.size})"
            lines << ""
            lines << "These files exist in the source gem and appear to be within the template's"
            lines << "scope, but were not produced by the template task."
            lines << ""
            lines << "| File |"
            lines << "|------|"
            removed.each { |f| lines << "| #{f} |" }
            lines << ""
          end

          if changed.empty? && added.empty? && removed.empty?
            lines << "## All files match! :tada:"
          else
            lines << "## Detailed Diffs"
            lines << ""
            lines << "See `report/diffs/` directory."
          end

          if skipped.any?
            lines << ""
            lines << "<details>"
            lines << "<summary>Not Templated (#{skipped.size} files) — source-only files not produced by the template task</summary>"
            lines << ""
            lines << "These files are part of the gem source (lib/, spec/, template/, exe/, etc.)"
            lines << "and are not expected to appear in the template output. This is normal."
            lines << ""
            lines << "| File |"
            lines << "|------|"
            skipped.each { |f| lines << "| #{f} |" }
            lines << ""
            lines << "</details>"
          end
          lines << ""

          lines.join("\n")
        end
      end
    end
  end
end
