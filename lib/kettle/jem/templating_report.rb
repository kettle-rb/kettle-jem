# frozen_string_literal: true

require "fileutils"
require "time"

module Kettle
  module Jem
    # Captures and renders the merge-gem environment used during templating.
    module TemplatingReport
      REPORT_DIR = File.join("tmp", "kettle-jem").freeze
      REPORT_PREFIX = "templating-report"
      MERGE_GEM_NAMES = %w[
        ast-merge
        bash-merge
        dotenv-merge
        json-merge
        markdown-merge
        markly-merge
        prism-merge
        psych-merge
        rbs-merge
        toml-merge
      ].freeze

      module_function

      def snapshot(loaded_specs: Gem.loaded_specs, workspace_root: default_workspace_root)
        {
          kettle_jem: build_entry("kettle-jem", loaded_specs["kettle-jem"], workspace_root: workspace_root),
          workspace_root: workspace_root,
          merge_gems: MERGE_GEM_NAMES.map { |name| build_entry(name, loaded_specs[name], workspace_root: workspace_root) },
        }
      end

      def build_entry(name, spec, workspace_root:)
        path = spec&.full_gem_path.to_s

        {
          name: name,
          version: spec&.version&.to_s,
          path: path.empty? ? nil : path,
          local_path: !path.empty? && local_path?(path, workspace_root: workspace_root),
          loaded: !spec.nil?,
        }
      end

      def default_workspace_root
        env_root = ENV["KETTLE_RB_DEV"].to_s.strip
        return if env_root.casecmp("false").zero?

        repo_root = File.expand_path("../../..", __dir__)
        sibling_root = File.expand_path("..", repo_root)
        if env_root.empty? || env_root.casecmp("true").zero?
          return canonical_path(sibling_root) if File.directory?(File.join(sibling_root, "nomono"))

          return
        end

        canonical_path(env_root)
      end

      def local_path?(path, workspace_root: default_workspace_root)
        return false if workspace_root.to_s.strip.empty?

        expanded_path = canonical_path(path)
        expanded_root = canonical_path(workspace_root)
        expanded_path == expanded_root || expanded_path.start_with?("#{expanded_root}/")
      end

      def canonical_path(path)
        File.realpath(path)
      rescue StandardError
        File.expand_path(path)
      end

      def print(snapshot: nil, io: $stdout)
        snapshot ||= self.snapshot
        lines = console_lines(snapshot: snapshot)
        return if lines.empty?

        io.puts
        lines.each { |line| io.puts(line) }
        io.puts
      end

      def console_lines(snapshot: nil)
        snapshot ||= self.snapshot
        merge_gems = snapshot.fetch(:merge_gems, [])
        return [] if merge_gems.empty?

        lines = []
        kettle_jem = snapshot[:kettle_jem]
        header = "[kettle-jem] Templating merge environment"
        header += " (kettle-jem #{kettle_jem[:version]})" if kettle_jem&.dig(:version)
        lines << header

        workspace_root = snapshot[:workspace_root]
        lines << "  workspace root: #{workspace_root}" if workspace_root

        merge_gems.each do |entry|
          version = entry[:version] || "not loaded"
          source = source_label(entry)
          path = entry[:path] ? " — #{entry[:path]}" : ""
          lines << "  - #{entry[:name]} #{version} (#{source})#{path}"
        end

        lines
      end

      def report_path(project_root:, output_dir: nil, run_started_at: Time.now, pid: Process.pid)
        target_root = output_dir || project_root
        timestamp = run_started_at.utc.strftime("%Y%m%d-%H%M%S-%6N")
        File.join(target_root, REPORT_DIR, "#{REPORT_PREFIX}-#{timestamp}-#{pid}.md")
      end

      def render_markdown(
        project_root:,
        output_dir: nil,
        snapshot: nil,
        run_started_at: Time.now,
        finished_at: nil,
        status: nil,
        warnings: [],
        error: nil,
        template_diff: nil,
        template_commit_sha: nil
      )
        snapshot ||= self.snapshot
        lines = []
        lines << "# kettle-jem Templating Run Report"
        lines << ""
        lines << "**Started**: #{run_started_at.iso8601}"
        lines << "**Finished**: #{finished_at.iso8601}" if finished_at
        lines << "**Status**: `#{status}`" if status
        lines << "**Project root**: `#{project_root}`"
        lines << "**Output dir**: `#{output_dir}`" if output_dir

        kettle_jem = snapshot[:kettle_jem]
        if kettle_jem
          version = kettle_jem[:version] || "unknown"
          path = kettle_jem[:path] ? " `#{kettle_jem[:path]}`" : ""
          lines << "**kettle-jem**: #{version} (#{source_label(kettle_jem)})#{path}"
        end

        lines << "**Template commit**: `#{template_commit_sha}`" if template_commit_sha
        lines << ""

        if template_diff
          lines << template_diff_section(template_diff)
        end

        environment_section = markdown_section(snapshot: snapshot)
        lines << environment_section unless environment_section.empty?

        unique_warnings = Array(warnings).map(&:to_s).reject { |warning| warning.strip.empty? }.uniq
        if unique_warnings.any?
          lines << "## Warnings"
          lines << ""
          unique_warnings.each { |warning| lines << "- #{warning}" }
          lines << ""
        end

        if error
          lines << "## Error"
          lines << ""
          lines << "```text"
          lines << "#{error.class}: #{error.message}"
          Array(error.backtrace).first(10).each { |line| lines << line }
          lines << "```"
          lines << ""
        end

        lines.join("\n")
      end

      def write(
        project_root:,
        output_dir: nil,
        snapshot: nil,
        report_path: nil,
        run_started_at: Time.now,
        finished_at: nil,
        status: nil,
        warnings: [],
        error: nil,
        template_diff: nil,
        template_commit_sha: nil
      )
        snapshot ||= self.snapshot
        report_path ||= self.report_path(
          project_root: project_root,
          output_dir: output_dir,
          run_started_at: run_started_at,
        )

        FileUtils.mkdir_p(File.dirname(report_path))
        File.write(
          report_path,
          render_markdown(
            project_root: project_root,
            output_dir: output_dir,
            snapshot: snapshot,
            run_started_at: run_started_at,
            finished_at: finished_at,
            status: status,
            warnings: warnings,
            error: error,
            template_diff: template_diff,
            template_commit_sha: template_commit_sha,
          ),
        )
        report_path
      end

      def markdown_section(snapshot: nil)
        snapshot ||= self.snapshot
        merge_gems = snapshot.fetch(:merge_gems, [])
        return "" if merge_gems.empty?

        lines = []
        lines << "## Merge Gem Environment"
        lines << ""

        workspace_root = snapshot[:workspace_root]
        if workspace_root
          lines << "**Workspace root**: `#{workspace_root}`"
          lines << ""
        end

        lines << "| Gem | Version | Source | Path |"
        lines << "|-----|---------|--------|------|"
        merge_gems.each do |entry|
          version = entry[:version] || "_not loaded_"
          path = entry[:path] ? "`#{entry[:path]}`" : ""
          lines << "| #{entry[:name]} | #{version} | #{source_label(entry)} | #{path} |"
        end
        lines << ""

        lines.join("\n")
      end

      def source_label(entry)
        return "not loaded" unless entry[:loaded]
        return "local path" if entry[:local_path]

        "installed gem"
      end

      # Render a Markdown section summarising template file changes since the last run.
      #
      # @param diff [Hash{Symbol => Array<String>}] result of TemplateChecksums.diff
      # @return [String] Markdown section (may be empty string when there are no changes)
      def template_diff_section(diff)
        require_relative "template_checksums"

        count = Kettle::Jem::TemplateChecksums.diff_count(diff)
        lines = []
        lines << "## Template File Changes"
        lines << ""

        if count.zero?
          lines << "_No template files changed since last run._"
          lines << ""
          return lines.join("\n")
        end

        lines << Kettle::Jem::TemplateChecksums.summary(diff)
        lines << ""

        if diff[:added].any?
          lines << "### Added (#{diff[:added].size})"
          lines << ""
          diff[:added].each { |f| lines << "- `#{f}`" }
          lines << ""
        end

        if diff[:changed].any?
          lines << "### Changed (#{diff[:changed].size})"
          lines << ""
          diff[:changed].each { |f| lines << "- `#{f}`" }
          lines << ""
        end

        if diff[:removed].any?
          lines << "### Removed (#{diff[:removed].size})"
          lines << ""
          diff[:removed].each { |f| lines << "- `#{f}`" }
          lines << ""
        end

        lines.join("\n")
      end
    end
  end
end
