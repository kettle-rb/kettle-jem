# frozen_string_literal: true

require "yaml"
require "set"
require "find"

module Kettle
  module Jem
    module Tasks
      # Thin wrapper to expose the kettle:jem:template task logic as a callable API
      # for testability. The rake task should only call this method.
      module TemplateTask
        MODULAR_GEMFILE_DIR = "gemfiles/modular"
        MARKDOWN_HEADING_EXTENSIONS = %w[.md .markdown].freeze
        MARKDOWN_PARAGRAPH_MATCH_REFINER = Ast::Merge::ContentMatchRefiner.new(
          threshold: 0.3,
          node_types: [:paragraph],
        )

        module_function

        # Whether a relative template path should be raw-copied (no tokens, no merge).
        # Checks the .kettle-jem.yml config for `strategy: raw_copy` on the given path.
        # @param rel [String] relative path from template root (with .example stripped)
        # @return [Boolean]
        def raw_copy?(rel)
          config = TemplateHelpers.config_for(rel)
          config&.fetch(:strategy, nil) == :raw_copy
        end

        # Normalize whitespace in Markdown content using AST-based processing.
        #
        # Performs a self-merge through Markdown::Merge::SmartMerger which:
        # 1. Parses the content into a proper AST (via Markly/Commonmarker)
        # 2. Applies WhitespaceNormalizer to collapse excessive blank lines
        #
        # Then ensures blank lines around headings. The SmartMerger self-merge
        # suppresses auto-spacing for same-source-adjacent nodes, so this
        # post-processing step is needed. It is AST-aware via the fenced code
        # block tracking to avoid modifying lines inside code blocks.
        #
        # @param text [String] Markdown content to normalize
        # @return [String] Normalized content
        def normalize_markdown_spacing(text)
          merged = Markdown::Merge::SmartMerger.new(
            text,
            text,
            backend: :markly,
            preference: :destination,
            normalize_whitespace: :basic,
          ).merge

          ensure_heading_spacing(merged)
        rescue StandardError => e
          Kettle::Dev.debug_error(e, __method__)
          # If AST parsing fails, return content unchanged
          text
        end

        # Ensure blank lines before and after Markdown headings.
        # Skips lines inside fenced code blocks.
        #
        # @param text [String] Markdown content
        # @return [String] Content with blank lines around headings
        def ensure_heading_spacing(text)
          lines = text.split("\n", -1)
          result = []
          in_fence = false

          lines.each_with_index do |line, i|
            # Track fenced code block state
            if line.match?(/\A\s{0,3}(`{3,}|~{3,})/)
              in_fence = !in_fence
              result << line
              next
            end

            if !in_fence && line.match?(/\A\#{1,6}\s/)
              # Insert blank line before heading if previous line is non-blank, non-heading content
              if result.any? && result.last != "" && !result.last.match?(/\A\s*\z/)
                result << ""
              end
              result << line
              # Insert blank line after heading if next line is non-blank content
              next_line = lines[i + 1]
              if next_line && !next_line.match?(/\A\s*\z/)
                result << ""
              end
            else
              result << line
            end
          end

          result.join("\n")
        end

        def markdown_heading_file?(relative_path)
          ext = File.extname(relative_path.to_s).downcase
          MARKDOWN_HEADING_EXTENSIONS.include?(ext)
        end

        def sync_readme_gemspec_grapheme!(helpers:, project_root:, gem_name:)
          actual_root = helpers.output_dir || project_root
          readme_path = File.join(actual_root, "README.md")
          gemspec_path = File.join(actual_root, "#{gem_name}.gemspec")
          return unless File.file?(readme_path) && File.file?(gemspec_path)

          readme = File.read(readme_path)
          gemspec = File.read(gemspec_path)
          synced_readme, synced_gemspec, chosen_grapheme = Kettle::Jem::ReadmeGemspecSynchronizer.synchronize(
            readme_content: readme,
            gemspec_content: gemspec,
          )
          return unless chosen_grapheme

          helpers.write_file(File.join(project_root, "README.md"), synced_readme) if synced_readme != readme
          helpers.write_file(File.join(project_root, "#{gem_name}.gemspec"), synced_gemspec) if synced_gemspec != gemspec
        rescue StandardError => e
          Kettle::Dev.debug_error(e, __method__)
          puts "WARNING: Could not synchronize README H1 grapheme with gemspec metadata: #{e.class}: #{e.message}"
        end

        # Merge template content with an existing destination file using the
        # appropriate AST-aware merge gem based on file type.
        #
        # @param content [String] Token-resolved template content
        # @param dest [String] Destination file path
        # @param rel [String] Relative path (for type detection)
        # @param helpers [Module] TemplateHelpers
        # @return [String] Merged content (or original content on failure when failure_mode is rescue)
        # @raise [Kettle::Dev::Error] When merge fails and failure_mode is error (default)
        def merge_by_file_type(content, dest, rel, helpers)
          dest_content = File.read(dest)
          file_type = merge_file_type_for(rel, dest, helpers)
          merged =
            if Kettle::Jem::SourceMerger.ruby_file_type?(file_type)
              # Ruby files: prism-merge via SourceMerger
              helpers.apply_strategy(content, dest)
            elsif file_type == :yaml
              # YAML files: psych-merge
              Psych::Merge::SmartMerger.new(
                content,
                dest_content,
                preference: :template,
                add_template_only_nodes: true,
              ).merge
            elsif file_type == :markdown
              # Markdown files (not README/CHANGELOG, which have dedicated steps):
              # use SmartMerger with template preference. Fuzzy paragraph
              # matching helps near-matching unmatched paragraphs align so they
              # are not emitted separately as destination-only and template-only
              # blocks.
              Markdown::Merge::SmartMerger.new(
                content,
                dest_content,
                backend: :markly,
                preference: :template,
                add_template_only_nodes: true,
                match_refiner: MARKDOWN_PARAGRAPH_MATCH_REFINER,
              ).merge
            elsif file_type == :bash
              # Shell / bash files: bash-merge
              Bash::Merge::SmartMerger.new(
                content,
                dest_content,
                preference: :template,
                add_template_only_nodes: true,
              ).merge
            elsif file_type == :dotenv
              Dotenv::Merge::SmartMerger.new(
                content,
                dest_content,
                preference: :template,
                add_template_only_nodes: true,
                freeze_token: "kettle-jem",
              ).merge
            elsif file_type == :json
              Json::Merge::SmartMerger.new(
                content,
                dest_content,
                preference: :template,
                add_template_only_nodes: true,
                freeze_token: "kettle-jem",
              ).merge
            elsif file_type == :jsonc
              Jsonc::Merge::SmartMerger.new(
                content,
                dest_content,
                preference: :template,
                add_template_only_nodes: true,
                freeze_token: "kettle-jem",
              ).merge
            elsif file_type == :toml
              Toml::Merge::SmartMerger.new(
                content,
                dest_content,
                preference: :template,
                add_template_only_nodes: true,
                freeze_token: "kettle-jem",
              ).merge
            elsif file_type == :rbs
              RBS::Merge::SmartMerger.new(
                content,
                dest_content,
                preference: :template,
                add_template_only_nodes: true,
                freeze_token: "kettle-jem",
              ).merge
            elsif file_type == :tool_versions
              # .tool-versions: text-merge with first-word signature matching.
              # Lines match by tool name (e.g., "ruby"), so template version
              # values replace destination values while destination-only tools
              # are preserved.
              Ast::Merge::Text::SmartMerger.new(
                content,
                dest_content,
                preference: :template,
                add_template_only_nodes: true,
                signature_generator: TOOL_VERSIONS_SIGNATURE_GENERATOR,
              ).merge
            else
              # Text files: text-merge. For .gitignore specifically, include
              # template-only lines so new ignore rules are added to existing
              # destination files.
              text_merge_options = {
                preference: :template,
              }
              text_merge_options[:add_template_only_nodes] = true if File.basename(rel.to_s) == ".gitignore"

              Ast::Merge::Text::SmartMerger.new(
                content,
                dest_content,
                **text_merge_options,
              ).merge
            end

          result = (merged.is_a?(String) && !merged.empty?) ? merged : content
          # Ensure all merge results end with a trailing newline (standard file convention)
          SourceMerger.ensure_trailing_newline(result)
        rescue StandardError => e
          if failure_mode == :rescue
            Kettle::Dev.debug_error(e, __method__)
            content
          else
            raise Kettle::Dev::Error, "Merge failed for #{rel}: #{e.class}: #{e.message}"
          end
        end

        def merge_file_type_for(rel, dest, helpers)
          helpers.configured_file_type_for(dest) ||
            if helpers.ruby_template?(dest)
              :ruby
            elsif yaml_file?(rel)
              :yaml
            elsif markdown_heading_file?(rel)
              :markdown
            elsif bash_file?(rel)
              :bash
            elsif tool_versions_file?(rel)
              :tool_versions
            else
              :text
            end
        end

        def write_templating_run_report(
          project_root:,
          output_dir:,
          snapshot:,
          run_started_at:,
          finished_at: nil,
          status: nil,
          warnings: [],
          error: nil,
          report_path: nil
        )
          Kettle::Jem::TemplatingReport.write(
            project_root: project_root,
            output_dir: output_dir,
            snapshot: snapshot,
            report_path: report_path,
            run_started_at: run_started_at,
            finished_at: finished_at,
            status: status,
            warnings: warnings,
            error: error,
          )
        rescue StandardError => e
          Kettle::Dev.debug_error(e, __method__)
          warn("[kettle-jem] WARNING: Could not write templating report: #{e.class}: #{e.message}")
          report_path
        end

        def templating_run_status(helpers, error)
          outcome = helpers.template_run_outcome
          return outcome || :failed if error

          outcome || :complete
        end

        # Determine the failure mode for merge operations.
        #
        # @return [Symbol] :error (default) or :rescue
        #   - :error  — merge failures raise Kettle::Dev::Error, halting the template task
        #   - :rescue — merge failures are logged and the unmerged content is used instead
        def failure_mode
          val = ENV.fetch("FAILURE_MODE", "error").to_s.strip.downcase
          val == "rescue" ? :rescue : :error
        end

        YAML_EXTENSIONS = %w[.yml .yaml].freeze
        BASH_EXTENSIONS = %w[.sh .bash].freeze
        # Basenames that are shell scripts without a shell extension
        BASH_BASENAMES = %w[.envrc].freeze
        # Basenames that use "tool version" key-value format (first word = key)
        TOOL_VERSIONS_BASENAMES = %w[.tool-versions].freeze

        # Custom signature generator for .tool-versions files.
        # Matches lines by the tool name (first word) so that e.g.
        # "ruby 3.2.0" in the destination matches "ruby 4.0.0" in the template.
        # With preference: :template, the template version value wins while
        # destination-only tool entries are preserved.
        TOOL_VERSIONS_SIGNATURE_GENERATOR = ->(node) {
          return node unless node.respond_to?(:content)
          first_word = node.content.to_s.strip.split(/\s+/, 2).first
          return node if first_word.nil? || first_word.empty?
          [:line, first_word]
        }.freeze

        def yaml_file?(relative_path)
          ext = File.extname(relative_path.to_s).downcase
          # CITATION.cff is YAML-structured
          return true if File.basename(relative_path.to_s).casecmp("citation.cff").zero?
          YAML_EXTENSIONS.include?(ext)
        end

        def bash_file?(relative_path)
          ext = File.extname(relative_path.to_s).downcase
          base = File.basename(relative_path.to_s)
          BASH_EXTENSIONS.include?(ext) || BASH_BASENAMES.include?(base)
        end

        def tool_versions_file?(relative_path)
          base = File.basename(relative_path.to_s)
          TOOL_VERSIONS_BASENAMES.include?(base)
        end

        # Abort wrapper that avoids terminating the entire process during specs
        def task_abort(msg)
          raise Kettle::Dev::Error, msg
        end

        def token_options(meta, helpers)
          forge_org = meta[:forge_org] || meta[:gh_org]
          funding_org = helpers.opencollective_disabled? ? nil : meta[:funding_org] || forge_org

          {
            org: forge_org,
            gem_name: meta[:gem_name],
            namespace: meta[:namespace],
            namespace_shield: meta[:namespace_shield],
            gem_shield: meta[:gem_shield],
            funding_org: funding_org,
            min_ruby: meta[:min_ruby],
          }
        end

        def prerequisite_validation_available?(options)
          %i[org gem_name].all? { |key| !options[key].to_s.strip.empty? }
        end

        def seeded_kettle_config_content(helpers, config_src, token_options)
          helpers.configure_tokens!(**token_options, include_config_tokens: false)
          helpers.read_template(config_src)
        ensure
          helpers.clear_tokens!
        end

        def placeholder_or_blank_scalar?(raw_value)
          stripped = raw_value.to_s.strip
          return true if stripped.empty?

          parsed = begin
            YAML.safe_load(stripped, permitted_classes: [], aliases: false)
          rescue StandardError
            stripped.delete_prefix('"').delete_suffix('"').delete_prefix("'").delete_suffix("'")
          end

          value = parsed.is_a?(String) ? parsed : parsed.to_s
          value.to_s.strip.empty? || Kettle::Jem::TemplateHelpers.token_placeholder?(value)
        end

        def yaml_scalar_for_backfill(value, current_raw)
          stripped = current_raw.to_s.strip
          if stripped.start_with?("'") && stripped.end_with?("'")
            "'#{value.to_s.gsub("'", "''")}'"
          else
            value.to_s.dump
          end
        end

        def backfill_kettle_config_token_lines(content, token_values, helpers:)
          in_tokens = false
          current_section = nil
          changed = false

          updated = content.lines.map do |line|
            stripped = line.lstrip
            indent = line[/\A\s*/].to_s.length

            if indent.zero? && stripped.match?(/\Atokens:\s*(?:#.*)?\z/)
              in_tokens = true
              current_section = nil
              next line
            elsif indent.zero? && stripped.match?(/\A[\w-]+:\s*(?:#.*)?\z/)
              in_tokens = false
              current_section = nil
            end

            next line unless in_tokens

            if indent == 2 && (match = stripped.match(/\A([a-z_]+):\s*(?:#.*)?\z/))
              current_section = match[1]
              next line
            end

            next line unless indent == 4 && current_section

            match = line.match(/\A(\s*)([a-z_]+):(\s*)([^#\n]*?)(\s*(?:#.*)?)?(\n?)\z/)
            next line unless match

            key = match[2]
            desired_value = token_values.dig(current_section, key)
            next line unless helpers.present_string?(desired_value)
            next line unless placeholder_or_blank_scalar?(match[4])

            changed = true
            "#{match[1]}#{key}:#{match[3]}#{yaml_scalar_for_backfill(desired_value, match[4])}#{match[5]}#{match[6]}"
          end.join

          [updated, changed]
        end

        def merge_missing_backfilled_token_values(destination_content, token_values)
          source_hash = {"tokens" => token_values}
          source_content = YAML.dump(source_hash)
          Psych::Merge::SmartMerger.new(
            source_content,
            destination_content,
            preference: :destination,
            add_template_only_nodes: true,
          ).merge
        rescue StandardError => e
          Kettle::Dev.debug_error(e, __method__)
          destination_content
        end

        def backfill_project_kettle_config_tokens!(helpers:, project_root:)
          config_dest = File.join(project_root, ".kettle-jem.yml")
          return false unless File.exist?(config_dest)

          token_values = helpers.derived_token_config_values
          return false if token_values.empty?

          current_content = File.read(config_dest)
          updated_content, replaced_existing_values = backfill_kettle_config_token_lines(current_content, token_values, helpers: helpers)
          merged_content = merge_missing_backfilled_token_values(updated_content, token_values)
          return false if merged_content == current_content

          merged_content += "\n" unless merged_content.empty? || merged_content.end_with?("\n")
          FileUtils.mkdir_p(File.dirname(config_dest))
          File.open(config_dest, "w") { |f| f.write(merged_content) }
          helpers.record_template_result(config_dest, :replace)
          helpers.clear_kettle_config!
          replaced_existing_values || merged_content != updated_content
        end

        def ensure_kettle_config_bootstrap!(helpers:, project_root:, template_root:, token_options:)
          config_src = helpers.prefer_example(File.join(template_root, ".kettle-jem.yml"))
          config_dest = File.join(project_root, ".kettle-jem.yml")
          return :missing_template unless File.exist?(config_src)
          return :present if File.exist?(config_dest)

          seeded_config_content = seeded_kettle_config_content(helpers, config_src, token_options)
          helpers.write_file(config_dest, seeded_config_content)
          helpers.record_template_result(config_dest, :create)
          helpers.clear_kettle_config!
          helpers.template_run_outcome = :bootstrap_only
          puts "[kettle-jem] Wrote #{config_dest}."
          puts "[kettle-jem] Review that file, fill in any missing token values, commit it, then re-run kettle-jem."
          :bootstrap_only
        end

        def sync_existing_kettle_config!(helpers:, project_root:, template_root:, token_options:)
          config_src = helpers.prefer_example(File.join(template_root, ".kettle-jem.yml"))
          config_dest = File.join(project_root, ".kettle-jem.yml")
          return unless File.exist?(config_src) && File.exist?(config_dest)

          seeded_config_content = seeded_kettle_config_content(helpers, config_src, token_options)
          helpers.copy_file_with_prompt(
            config_src,
            config_dest,
            allow_create: true,
            allow_replace: true,
            content_override: seeded_config_content,
          ) do |content|
            c = content
            if File.exist?(config_dest)
              begin
                c = Psych::Merge::SmartMerger.new(
                  c,
                  File.read(config_dest),
                  preference: :destination,
                  add_template_only_nodes: true,
                ).merge
              rescue StandardError => e
                Kettle::Dev.debug_error(e, __method__)
              end
            end
            c
          end
          helpers.clear_kettle_config!
        end

        def preflight_destination_for(rel, project_root, gem_name)
          return nil if rel == ".kettle-jem.yml"
          return File.join(project_root, ".env.local.example") if rel == ".env.local"

          return File.join(project_root, rel) unless rel.end_with?(".gemspec")

          return File.join(project_root, "#{gem_name}.gemspec") if gem_name && !gem_name.to_s.empty?

          Dir.glob(File.join(project_root, "*.gemspec")).sort.first || File.join(project_root, rel)
        end

        def logical_template_paths(template_root)
          rels = Set.new
          Find.find(template_root) do |path|
            next if File.directory?(path)

            rel = path.sub(%r{^#{Regexp.escape(template_root)}/?}, "")
              .sub(/\.no-osc\.example\z/, "")
              .sub(/\.example\z/, "")
            rels << rel unless rel.empty?
          end
          rels.to_a.sort
        end

        def include_matches?(project_root, abs_dest)
          include_patterns = ENV["include"].to_s.split(",").map { |s| s.strip }.reject(&:empty?)
          return false if include_patterns.empty?

          rel_dest = abs_dest.to_s
          proj = project_root.to_s
          if rel_dest.start_with?(proj + "/")
            rel_dest = rel_dest[(proj.length + 1)..]
          elsif rel_dest == proj
            rel_dest = ""
          end

          include_patterns.any? do |pat|
            if pat.end_with?("/**")
              base = pat[0..-4]
              rel_dest == base || rel_dest.start_with?(base + "/")
            else
              File.fnmatch?(pat, rel_dest, File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH)
            end
          end
        rescue StandardError => e
          Kettle::Dev.debug_error(e, __method__)
          false
        end

        def unresolved_required_tokens(helpers:, project_root:, template_root:, gem_name:)
          return {} unless Dir.exist?(template_root)

          logical_template_paths(template_root).each_with_object({}) do |rel, unresolved_by_file|
            next if rel == ".kettle-jem.yml"
            next if helpers.skip_for_disabled_opencollective?(rel)

            dest = preflight_destination_for(rel, project_root, gem_name)
            next unless dest
            next if rel == ".github/workflows/discord-notifier.yml" && !include_matches?(project_root, dest)

            strategy = helpers.strategy_for(dest)
            next if %i[keep_destination raw_copy].include?(strategy)

            src = helpers.prefer_example_with_osc_check(File.join(template_root, rel))
            next unless File.exist?(src)

            tokens = helpers.unresolved_token_keys(File.read(src))
            next if tokens.empty?

            display_rel = helpers.rel_path(dest)
            unresolved_by_file[display_rel] = tokens.sort
          end
        end

        def unresolved_written_tokens(helpers:, project_root:)
          token_pattern = /\{KJ\|[A-Z][A-Z0-9_:]*\}/
          scan_root = (helpers.output_dir || project_root).to_s
          unresolved_by_file = {}
          scan_paths = []

          helpers.template_results.each do |dest_path, record|
            actual_path = helpers.output_path(dest_path)

            case record[:action]
            when :create, :replace
              scan_paths << actual_path if File.file?(actual_path)
            when :dir_create, :dir_replace
              next unless Dir.exist?(actual_path)

              Find.find(actual_path) do |path|
                scan_paths << path if File.file?(path)
              end
            end
          end

          scan_paths.uniq.each do |path|
            rel = path.sub(%r{^#{Regexp.escape(scan_root)}/?}, "")
            next if rel.empty? || rel == ".kettle-jem.yml"

            ext = File.extname(path)
            next unless %w[.rb .gemspec .gemfile .yml .yaml .toml .md .txt .sh .json .jsonc .cff .example .lock].include?(ext) ||
              File.basename(path).match?(/\A(Gemfile|Rakefile|Appraisals|REEK|\.envrc|\.env|\.rspec|\.yardopts|\.gitignore|\.rubocop|LICENSE)\z/i)

            begin
              content = File.read(path)
              tokens = content.scan(token_pattern).uniq
              unresolved_by_file[rel] = tokens unless tokens.empty?
            rescue StandardError
              # Skip files that can't be read as text.
            end
          end

          unresolved_by_file
        end

        def validate_required_token_values!(helpers:, project_root:, template_root:, gem_name:)
          unresolved_by_file = unresolved_required_tokens(
            helpers: helpers,
            project_root: project_root,
            template_root: template_root,
            gem_name: gem_name,
          )
          return if unresolved_by_file.empty?

          msg_lines = ["Unresolved {KJ|...} tokens would be written to #{unresolved_by_file.size} template file(s):"]
          unresolved_by_file.each do |rel, tokens|
            msg_lines << "  #{rel}: #{tokens.join(", ")}"
          end
          msg_lines << ""
          msg_lines << "Please set the required environment variables or add values to .kettle-jem.yml and re-run."
          msg_lines << "Tip: .kettle-jem.yml is the first file to review when token values are missing."

          helpers.add_warning(msg_lines.join("\n"))
          helpers.print_warnings_summary
          task_abort(msg_lines.first)
        end

        def ensure_template_prerequisites!(helpers:, project_root:, template_root:, meta:)
          options = token_options(meta, helpers)
          return :unavailable unless prerequisite_validation_available?(options)

          bootstrap_result = ensure_kettle_config_bootstrap!(
            helpers: helpers,
            project_root: project_root,
            template_root: template_root,
            token_options: options,
          )
          return bootstrap_result if bootstrap_result == :bootstrap_only

          backfill_project_kettle_config_tokens!(
            helpers: helpers,
            project_root: project_root,
          )

          helpers.clear_kettle_config!
          helpers.configure_tokens!(**options)
          validate_required_token_values!(
            helpers: helpers,
            project_root: project_root,
            template_root: template_root,
            gem_name: options[:gem_name],
          )

          :ready
        end

        # Execute the template operation into the current project.
        # All options/IO are controlled via TemplateHelpers and ENV.
        def run
          helpers = Kettle::Jem::TemplateHelpers
          helpers.clear_warnings
          helpers.clear_template_run_outcome!

          project_root = helpers.project_root
          template_root = helpers.template_root
          run_started_at = helpers.template_run_timestamp
          templating_environment = Kettle::Jem::TemplatingReport.snapshot
          templating_report_path = write_templating_run_report(
            project_root: project_root,
            output_dir: helpers.output_dir,
            snapshot: templating_environment,
            run_started_at: run_started_at,
            status: :started,
          )
          Kettle::Jem::TemplatingReport.print(snapshot: templating_environment)
          puts "[kettle-jem] Per-run report: #{templating_report_path}" if templating_report_path

          # Ensure git working tree is clean before making changes (when run standalone)
          helpers.ensure_clean_git!(root: project_root, task_label: "kettle:jem:template")

          meta = helpers.gemspec_metadata(project_root)
          gem_name = meta[:gem_name]
          min_ruby = meta[:min_ruby]
          forge_org = meta[:forge_org] || meta[:gh_org]
          funding_org = helpers.opencollective_disabled? ? nil : meta[:funding_org] || forge_org
          entrypoint_require = meta[:entrypoint_require]
          namespace = meta[:namespace]
          namespace_shield = meta[:namespace_shield]
          gem_shield = meta[:gem_shield]

          prerequisites = ensure_template_prerequisites!(
            helpers: helpers,
            project_root: project_root,
            template_root: template_root,
            meta: meta,
          )
          return :bootstrap_only if prerequisites == :bootstrap_only

          # Configure token replacements once for the entire session.
          # All template reads (via read_template) will automatically resolve tokens.
          begin
            helpers.configure_tokens!(
              org: forge_org,
              gem_name: gem_name,
              namespace: namespace,
              namespace_shield: namespace_shield,
              gem_shield: gem_shield,
              funding_org: funding_org,
              min_ruby: min_ruby,
            )
          rescue StandardError => e
            Kettle::Dev.debug_error(e, __method__)
            $stderr.puts("[kettle-jem] WARNING: Token configuration failed: #{e.message}")
            $stderr.puts("[kettle-jem] Templates will be written with unresolved tokens.")
          end

          removed_appraisals = []
          appraisals_src = helpers.prefer_example(File.join(template_root, "Appraisals"))
          if File.exist?(appraisals_src)
            begin
              content = File.read(appraisals_src)
              _pruned, removed_appraisals = Kettle::Jem::PrismAppraisals.prune_ruby_appraisals(content, min_ruby: min_ruby)
            rescue StandardError => e
              Kettle::Dev.debug_error(e, __method__)
              removed_appraisals = []
            end
          end

          # 0) .kettle-jem.yml — keep existing config in sync with the template after
          # preflight has confirmed we have the required token values.
          begin
            sync_existing_kettle_config!(
              helpers: helpers,
              project_root: project_root,
              template_root: template_root,
              token_options: {
                org: forge_org,
                gem_name: gem_name,
                namespace: namespace,
                namespace_shield: namespace_shield,
                gem_shield: gem_shield,
                funding_org: funding_org,
                min_ruby: min_ruby,
              },
            )
          rescue StandardError => e
            Kettle::Dev.debug_error(e, __method__)
          end

          # sync_existing_kettle_config! temporarily seeds and clears token state
          # while rewriting .kettle-jem.yml, so restore the full replacement map
          # before templating the rest of the project files.
          begin
            helpers.configure_tokens!(
              org: forge_org,
              gem_name: gem_name,
              namespace: namespace,
              namespace_shield: namespace_shield,
              gem_shield: gem_shield,
              funding_org: funding_org,
              min_ruby: min_ruby,
            )
          rescue StandardError => e
            Kettle::Dev.debug_error(e, __method__)
            $stderr.puts("[kettle-jem] WARNING: Token configuration failed after syncing .kettle-jem.yml: #{e.message}")
          end

          # 1) .devcontainer directory — per-file merging with format-appropriate merge gems
          devcontainer_src_dir = File.join(template_root, ".devcontainer")
          if Dir.exist?(devcontainer_src_dir)
            require "find"
            Find.find(devcontainer_src_dir) do |path|
              next if File.directory?(path)

              rel = path.sub(%r{^#{Regexp.escape(devcontainer_src_dir)}/?}, "")
              src = helpers.prefer_example(path)
              dest_rel = rel.sub(/\.example\z/, "")
              dest = File.join(project_root, ".devcontainer", dest_rel)
              next unless File.exist?(src)

              file_strategy = helpers.strategy_for(dest)
              next if file_strategy == :keep_destination
              if file_strategy == :raw_copy
                helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true, raw: true)
                next
              end

              helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true) do |content|
                c = content
                if file_strategy != :accept_template && File.exist?(dest)
                  begin
                    merger_class = case dest_rel
                    when /\.json$/
                      if content.match?(%r{^\s*//})
                        Jsonc::Merge::SmartMerger
                      else
                        Json::Merge::SmartMerger
                      end
                    when /\.sh$/
                      Bash::Merge::SmartMerger
                    end
                    if merger_class
                      c = merger_class.new(
                        c,
                        File.read(dest),
                        preference: :template,
                        add_template_only_nodes: true,
                        freeze_token: "kettle-jem",
                      ).merge
                    end
                  rescue StandardError => e
                    Kettle::Dev.debug_error(e, __method__)
                  end
                end
                c
              end
            end
          end

          # 2) .github/**/*.yml with FUNDING.yml customizations
          source_github_dir = File.join(template_root, ".github")
          if Dir.exist?(source_github_dir)
            # Build a unique set of logical .yml paths, preferring the .example variant when present
            candidates = Dir.glob(File.join(source_github_dir, "**", "*.yml")) +
              Dir.glob(File.join(source_github_dir, "**", "*.yml.example"))
            selected = {}
            candidates.each do |path|
              # Key by the path without the optional .example suffix
              key = path.sub(/\.example\z/, "")
              # Prefer example: overwrite a plain selection with .example, but do not downgrade
              if path.end_with?(".example")
                selected[key] = path
              else
                selected[key] ||= path
              end
            end
            # Parse optional include patterns (comma-separated globs relative to project root)
            include_raw = ENV["include"].to_s
            include_patterns = include_raw.split(",").map { |s| s.strip }.reject(&:empty?)
            matches_include = lambda do |abs_dest|
              return false if include_patterns.empty?
              begin
                rel_dest = abs_dest.to_s
                proj = project_root.to_s
                if rel_dest.start_with?(proj + "/")
                  rel_dest = rel_dest[(proj.length + 1)..-1]
                elsif rel_dest == proj
                  rel_dest = ""
                end
                include_patterns.any? do |pat|
                  if pat.end_with?("/**")
                    base = pat[0..-4]
                    rel_dest == base || rel_dest.start_with?(base + "/")
                  else
                    File.fnmatch?(pat, rel_dest, File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH)
                  end
                end
              rescue StandardError => e
                Kettle::Dev.debug_error(e, __method__)
                false
              end
            end

            selected.values.each do |orig_src|
              src = helpers.prefer_example_with_osc_check(orig_src)
              rel = orig_src.sub(/^#{Regexp.escape(template_root)}\/?/, "").sub(/\.example\z/, "")
              dest = File.join(project_root, rel)
              next unless File.exist?(src)

              file_strategy = helpers.strategy_for(dest)
              next if file_strategy == :keep_destination

              if helpers.skip_for_disabled_opencollective?(rel)
                puts "Skipping #{rel} (Open Collective disabled)"
                next
              end

              if rel == ".github/workflows/discord-notifier.yml"
                unless matches_include.call(dest)
                  next
                end
              end

              if file_strategy == :raw_copy
                helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true, raw: true)
                next
              end

              if File.basename(rel) == "FUNDING.yml"
                helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true) do |content|
                  c = content
                  if file_strategy != :accept_template && File.exist?(dest)
                    begin
                      c = Psych::Merge::SmartMerger.new(
                        c,
                        File.read(dest),
                        preference: :template,
                        add_template_only_nodes: true,
                      ).merge
                    rescue StandardError => e
                      Kettle::Dev.debug_error(e, __method__)
                    end
                  end
                  c
                end
              else
                prepared = nil
                if rel.start_with?(".github/workflows/")
                  c = helpers.read_template(src)
                  if file_strategy != :accept_template && File.exist?(dest)
                    begin
                      c = Psych::Merge::SmartMerger.new(
                        c,
                        File.read(dest),
                        preference: :template,
                        add_template_only_nodes: true,
                      ).merge
                    rescue StandardError => e
                      Kettle::Dev.debug_error(e, __method__)
                    end
                  end
                  c, _removed_count, _total_count, empty = prune_workflow_matrix_by_appraisals(c, removed_appraisals)
                  if empty
                    if File.exist?(dest)
                      helpers.add_warning("Workflow #{rel} has no remaining matrix entries for min Ruby #{min_ruby}; consider removing the file")
                    end
                    next
                  end
                  prepared = c
                end

                helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true) do |content|
                  prepared || content
                end
              end
            end
          end

          # 3) .qlty/qlty.toml — merge with TOML-aware SmartMerger
          qlty_src = helpers.prefer_example(File.join(template_root, ".qlty/qlty.toml"))
          qlty_dest = File.join(project_root, ".qlty/qlty.toml")
          qlty_strategy = helpers.strategy_for(qlty_dest)
          unless qlty_strategy == :keep_destination
            if qlty_strategy == :raw_copy
              helpers.copy_file_with_prompt(
                qlty_src,
                qlty_dest,
                allow_create: true,
                allow_replace: true,
                raw: true,
              )
            else
              helpers.copy_file_with_prompt(
                qlty_src,
                qlty_dest,
                allow_create: true,
                allow_replace: true,
              ) do |content|
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

          # 4) gemfiles/modular/* and nested directories (delegated for DRYness)
          Kettle::Jem::ModularGemfiles.sync!(
            helpers: helpers,
            project_root: project_root,
            min_ruby: min_ruby,
            gem_name: gem_name,
          )

          # 5) spec/spec_helper.rb (no create)
          dest_spec_helper = File.join(project_root, "spec/spec_helper.rb")
          if File.file?(dest_spec_helper)
            old = File.read(dest_spec_helper)
            if old.include?('require "kettle/dev"') || old.include?("require 'kettle/dev'")
              replacement = %(require "#{entrypoint_require}")
              new_content = old.gsub(/require\s+["']kettle\/dev["']/, replacement)
              if new_content != old
                if helpers.ask("Update require \"kettle/dev\" in spec/spec_helper.rb to #{replacement}?", true)
                  helpers.write_file(dest_spec_helper, new_content)
                  puts "Updated require in spec/spec_helper.rb"
                else
                  puts "Skipped modifying spec/spec_helper.rb"
                end
              end
            end
          end

          # 6) .env.local.example: merge template env vars with existing destination using dotenv-merge
          begin
            envlocal_src = File.join(template_root, ".env.local.example")
            envlocal_dest = File.join(project_root, ".env.local.example")
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
          rescue StandardError => e
            Kettle::Dev.debug_error(e, __method__)
            puts "WARNING: Skipped .env.local example copy due to #{e.class}: #{e.message}"
          end

          # 7a) Special-case: gemspec example must be renamed to destination gem's name
          begin
            # Prefer the .example variant when present
            gemspec_template_src = helpers.prefer_example(File.join(template_root, "kettle-jem.gemspec"))
            if File.exist?(gemspec_template_src)
              dest_gemspec = if gem_name && !gem_name.to_s.empty?
                File.join(project_root, "#{gem_name}.gemspec")
              else
                # Fallback rules:
                # 1) Prefer any existing gemspec in the destination project
                existing = Dir.glob(File.join(project_root, "*.gemspec")).sort.first
                if existing
                  existing
                else
                  # 2) If none, use the example file's name with ".example" removed
                  fallback_name = File.basename(gemspec_template_src).sub(/\.example\z/, "")
                  File.join(project_root, fallback_name)
                end
              end

              gemspec_strategy = helpers.strategy_for(dest_gemspec)
              unless gemspec_strategy == :keep_destination
                orig_meta = nil
                dest_existed = File.exist?(dest_gemspec)
                if dest_existed
                  begin
                    orig_meta = helpers.gemspec_metadata(File.dirname(dest_gemspec))
                  rescue StandardError => e
                    Kettle::Dev.debug_error(e, __method__)
                    orig_meta = nil
                  end
                end

                if gemspec_strategy == :raw_copy
                  helpers.copy_file_with_prompt(gemspec_template_src, dest_gemspec, allow_create: true, allow_replace: true, raw: true)
                else
                  helpers.copy_file_with_prompt(gemspec_template_src, dest_gemspec, allow_create: true, allow_replace: true) do |content|
                    c = content

                    if gemspec_strategy != :accept_template && orig_meta
                      repl = {}
                      if (name = orig_meta[:gem_name]) && !name.to_s.empty?
                        repl[:name] = name.to_s
                      end
                      repl[:authors] = Array(orig_meta[:authors]).map(&:to_s) if orig_meta[:authors]
                      repl[:email] = Array(orig_meta[:email]).map(&:to_s) if orig_meta[:email]
                      repl[:summary] = orig_meta[:summary].to_s if orig_meta[:summary] && !orig_meta[:summary].to_s.strip.empty?
                      repl[:description] = orig_meta[:description].to_s if orig_meta[:description] && !orig_meta[:description].to_s.strip.empty?
                      repl[:licenses] = Array(orig_meta[:licenses]).map(&:to_s) if orig_meta[:licenses]
                      if orig_meta[:required_ruby_version]
                        repl[:required_ruby_version] = orig_meta[:required_ruby_version].to_s
                      end
                      repl[:require_paths] = Array(orig_meta[:require_paths]).map(&:to_s) if orig_meta[:require_paths]
                      repl[:bindir] = orig_meta[:bindir].to_s if orig_meta[:bindir]
                      repl[:executables] = Array(orig_meta[:executables]).map(&:to_s) if orig_meta[:executables]

                      begin
                        c = Kettle::Jem::PrismGemspec.replace_gemspec_fields(c, repl)
                      rescue StandardError => e
                        Kettle::Dev.debug_error(e, __method__)
                      end
                    end

                    begin
                      if gem_name && !gem_name.to_s.empty?
                        begin
                          c = Kettle::Jem::PrismGemspec.remove_spec_dependency(c, gem_name)
                        rescue StandardError => e
                          Kettle::Dev.debug_error(e, __method__)
                        end
                      end
                    rescue StandardError => e
                      Kettle::Dev.debug_error(e, __method__)
                    end

                    if gemspec_strategy != :accept_template && dest_existed
                      begin
                        merged = helpers.apply_strategy(c, dest_gemspec)
                        c = merged if merged.is_a?(String) && !merged.empty?
                      rescue StandardError => e
                        Kettle::Dev.debug_error(e, __method__)
                      end
                    end

                    c
                  end
                end
              end
            end
          rescue StandardError => e
            Kettle::Dev.debug_error(e, __method__)
          end

          # 7) Discover and copy all remaining template files.
          #
          # Walks the template/ directory to find every file. Files already
          # handled by earlier steps are excluded. Everything else gets
          # apply_common_replacements with per-file special handling for
          # README.md, CHANGELOG.md, and markdown spacing normalization.
          #
          # Prefixes that are handled by dedicated steps above:
          #   .devcontainer/      → step 1 (per-file merging: JSONC, JSON, Bash)
          #   .github/**/*.yml    → step 2 (dynamic discovery + FUNDING.yml; non-yml files handled here)
          #   .qlty/              → step 3 (TOML merge)
          #   gemfiles/modular/   → step 4 (ModularGemfiles.sync!)
          #   .env.local.example  → step 6 (dotenv-merge; rel is ".env.local" after .example strip)
          #   *.gemspec           → step 7a (renamed + field carry-over)
          #   .git-hooks/         → handled after this block (per-file merging: Text, Prism, Bash)
          handled_prefixes = %w[
            .devcontainer/
            .qlty/
            gemfiles/modular/
            .git-hooks/
          ]
          handled_files = %w[
            .env.local
            .kettle-jem.yml
          ]

          template_root = helpers.template_root
          if Dir.exist?(template_root)
            require "find"
            Find.find(template_root) do |path|
              next if File.directory?(path)

              # Compute relative path from template root, stripping .example / .no-osc.example suffixes
              rel = path.sub(%r{^#{Regexp.escape(template_root)}/?}, "")
                .sub(/\.no-osc\.example\z/, "")
                .sub(/\.example\z/, "")

              # Skip files handled by dedicated steps
              next if handled_prefixes.any? { |prefix| rel.start_with?(prefix) }
              next if handled_files.include?(rel)
              next if rel.end_with?(".gemspec") # gemspec handled in step 7a
              # .github/**/*.yml files are handled by step 2 (dynamic discovery + FUNDING.yml)
              next if rel.start_with?(".github/") && rel.end_with?(".yml")

              # Skip opencollective-specific files when Open Collective is disabled
              if helpers.skip_for_disabled_opencollective?(rel)
                puts "Skipping #{rel} (Open Collective disabled)"
                next
              end

              src = helpers.prefer_example_with_osc_check(File.join(template_root, rel))
              dest = File.join(project_root, rel)
              next unless File.exist?(src)

              # Raw copy: no token resolution, no merging (e.g., certs/)
              if raw_copy?(rel)
                begin
                  helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true, raw: true)
                rescue StandardError => e
                  Kettle::Dev.debug_error(e, __method__)
                  puts "WARNING: Could not copy #{rel}: #{e.class}: #{e.message}"
                end
                next
              end

              begin
                file_strategy = helpers.strategy_for(dest)
                if file_strategy == :keep_destination
                  next
                end

                if file_strategy == :raw_copy
                  helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true, raw: true)
                  next
                end

                if File.basename(rel) == "README.md"
                  prev_readme = File.exist?(dest) ? File.read(dest) : nil

                  helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true) do |content|
                    c = content
                    if file_strategy != :accept_template
                      begin
                        c = MarkdownMerger.merge(
                          template_content: c,
                          destination_content: prev_readme,
                        )
                      rescue StandardError => e
                        Kettle::Dev.debug_error(e, __method__)
                      end
                    end
                    c = normalize_markdown_spacing(c) if markdown_heading_file?(rel)
                    c = Kettle::Jem::ReadmePostProcessor.process(content: c, min_ruby: min_ruby)
                    c
                  end
                elsif File.basename(rel) == "CHANGELOG.md"
                  helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true) do |content|
                    c = content
                    if file_strategy != :accept_template
                      begin
                        dest_content = File.file?(dest) ? File.read(dest) : ""
                        c = ChangelogMerger.merge(
                          template_content: c,
                          destination_content: dest_content,
                        )
                      rescue StandardError => e
                        Kettle::Dev.debug_error(e, __method__)
                      end
                    end
                    c = normalize_markdown_spacing(c) if markdown_heading_file?(rel)
                    c
                  end
                else
                  helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true) do |content|
                    c = content
                    if file_strategy == :accept_template
                      # token-resolved template content wins; no merge
                    elsif File.exist?(dest)
                      c = merge_by_file_type(c, dest, rel, helpers)
                    end
                    c = normalize_markdown_spacing(c) if markdown_heading_file?(rel)
                    c
                  end
                end
              rescue StandardError => e
                Kettle::Dev.debug_error(e, __method__)
                puts "WARNING: Could not template #{rel}: #{e.class}: #{e.message}"
              end
            end
          end

          sync_readme_gemspec_grapheme!(helpers: helpers, project_root: project_root, gem_name: gem_name)

          # After creating or replacing .envrc or .env.local.example, require review and exit unless allowed
          begin
            envrc_path = File.join(project_root, ".envrc")
            envlocal_example_path = File.join(project_root, ".env.local.example")
            changed_env_files = []
            changed_env_files << envrc_path if helpers.modified_by_template?(envrc_path)
            changed_env_files << envlocal_example_path if helpers.modified_by_template?(envlocal_example_path)
            if !changed_env_files.empty?
              if /\A(1|true|y|yes)\z/i.match?(ENV.fetch("allowed", "").to_s)
                puts "Detected updates to #{changed_env_files.map { |p| File.basename(p) }.join(" and ")}. Proceeding because allowed=true."
              else
                puts
                puts "IMPORTANT: The following environment-related files were created/updated:"
                changed_env_files.each { |p| puts "  - #{p}" }
                puts
                puts "Please review these files. If .envrc changed, run:"
                puts "  direnv allow"
                puts
                puts "After that, re-run to resume:"
                puts "  bundle exec rake kettle:jem:template allowed=true"
                puts "  # or to run the full install afterwards:"
                puts "  bundle exec rake kettle:jem:install allowed=true"
                task_abort("Aborting: review of environment files required before continuing.")
              end
            end
          rescue StandardError => e
            # Do not swallow intentional task aborts
            raise if e.is_a?(Kettle::Dev::Error)

            puts "WARNING: Could not determine env file changes: #{e.class}: #{e.message}"
          end

          # Handle .git-hooks files — per-file merging with format-appropriate merge gems
          source_hooks_dir = File.join(template_root, ".git-hooks")
          if Dir.exist?(source_hooks_dir)
            # Honor ENV["only"]: skip entire .git-hooks handling unless patterns include .git-hooks
            begin
              only_raw = ENV["only"].to_s
              if !only_raw.empty?
                patterns = only_raw.split(",").map { |s| s.strip }.reject(&:empty?)
                if !patterns.empty?
                  proj = helpers.project_root.to_s
                  target_dir = File.join(proj, ".git-hooks")
                  # Determine if any pattern would match either the directory itself (with /** semantics) or files within it
                  matches = patterns.any? do |pat|
                    if pat.end_with?("/**")
                      base = pat[0..-4]
                      base == ".git-hooks" || base == target_dir.sub(/^#{Regexp.escape(proj)}\/?/, "")
                    else
                      # Check for explicit .git-hooks or subpaths
                      File.fnmatch?(pat, ".git-hooks", File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH) ||
                        File.fnmatch?(pat, ".git-hooks/*", File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH)
                    end
                  end
                  unless matches
                    # No interest in .git-hooks => skip prompts and copies for hooks entirely
                    # Note: we intentionally do not record template_results for hooks
                    return
                  end
                end
              end
            rescue StandardError => e
              Kettle::Dev.debug_error(e, __method__)
              # If filter parsing fails, proceed as before
            end
            # Prefer .example variant when present for .git-hooks
            goalie_src = helpers.prefer_example(File.join(source_hooks_dir, "commit-subjects-goalie.txt"))
            footer_src = helpers.prefer_example(File.join(source_hooks_dir, "footer-template.erb.txt"))
            hook_ruby_src = helpers.prefer_example(File.join(source_hooks_dir, "commit-msg"))
            hook_sh_src = helpers.prefer_example(File.join(source_hooks_dir, "prepare-commit-msg"))

            # First: templates (.txt) — ask local/global/skip
            if File.file?(goalie_src) && File.file?(footer_src)
              puts
              puts "Git hooks templates found:"
              puts "  - #{goalie_src}"
              puts "  - #{footer_src}"
              puts
              puts "About these files:"
              puts "- commit-subjects-goalie.txt:"
              puts "  Lists commit subject prefixes to look for; if a commit subject starts with any listed prefix,"
              puts "  kettle-commit-msg will append a footer to the commit message (when GIT_HOOK_FOOTER_APPEND=true)."
              puts "  Defaults include release prep (🔖 Prepare release v) and checksum commits (🔒️ Checksums for v)."
              puts "- footer-template.erb.txt:"
              puts "  ERB template rendered to produce the footer. You can customize its contents and variables."
              puts
              puts "Where would you like to install these two templates?"
              puts "  [l] Local to this project (#{File.join(project_root, ".git-hooks")})"
              puts "  [g] Global for this user (#{File.join(ENV["HOME"], ".git-hooks")})"
              puts "  [s] Skip copying"
              # Allow non-interactive selection via environment
              # Precedence: CLI switch (hook_templates) > KETTLE_DEV_HOOK_TEMPLATES > prompt
              force_mode = Kettle::Dev::ENV_TRUE_RE.match?(ENV.fetch("force", "").to_s)
              non_interactive_mode = force_mode || !helpers.output_dir.nil?
              env_choice = ENV["hook_templates"]
              env_choice = ENV["KETTLE_DEV_HOOK_TEMPLATES"] if env_choice.nil? || env_choice.strip.empty?
              choice = env_choice&.strip
              unless choice && !choice.empty?
                if non_interactive_mode
                  choice = "l"
                  puts "Choose (l/g/s) [l]: l (non-interactive)"
                else
                  print("Choose (l/g/s) [l]: ")
                  choice = Kettle::Dev::InputAdapter.gets&.strip
                end
              end
              choice = "l" if choice.nil? || choice.empty?
              dest_dir = case choice.downcase
              when "g", "global" then File.join(ENV["HOME"], ".git-hooks")
              when "s", "skip" then nil
              else File.join(project_root, ".git-hooks")
              end

              if dest_dir
                FileUtils.mkdir_p(dest_dir)

                goalie_dest = File.join(dest_dir, "commit-subjects-goalie.txt")
                goalie_strategy = helpers.strategy_for(goalie_dest)
                unless goalie_strategy == :keep_destination
                  if goalie_strategy == :raw_copy
                    helpers.copy_file_with_prompt(goalie_src, goalie_dest, allow_create: true, allow_replace: true, raw: true)
                  else
                    helpers.copy_file_with_prompt(goalie_src, goalie_dest, allow_create: true, allow_replace: true) do |content|
                      if goalie_strategy != :accept_template && File.exist?(goalie_dest)
                        begin
                          content = Ast::Merge::Text::SmartMerger.new(
                            content,
                            File.read(goalie_dest),
                            preference: :template,
                            add_template_only_nodes: true,
                            freeze_token: "kettle-jem",
                          ).merge
                        rescue StandardError => e
                          Kettle::Dev.debug_error(e, __method__)
                        end
                      end
                      content
                    end
                  end
                end

                footer_dest = File.join(dest_dir, "footer-template.erb.txt")
                footer_strategy = helpers.strategy_for(footer_dest)
                unless footer_strategy == :keep_destination
                  if footer_strategy == :raw_copy
                    helpers.copy_file_with_prompt(footer_src, footer_dest, allow_create: true, allow_replace: true, raw: true)
                  else
                    helpers.copy_file_with_prompt(footer_src, footer_dest, allow_create: true, allow_replace: true) do |content|
                      c = helpers.apply_common_replacements(
                        content,
                        org: forge_org,
                        funding_org: funding_org,
                        gem_name: gem_name,
                        namespace: namespace,
                        namespace_shield: namespace_shield,
                        gem_shield: gem_shield,
                        min_ruby: min_ruby,
                      )
                      if footer_strategy != :accept_template && File.exist?(footer_dest)
                        begin
                          c = Ast::Merge::Text::SmartMerger.new(
                            c,
                            File.read(footer_dest),
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

                [goalie_dest, footer_dest].each do |txt_dest|
                  File.chmod(0o644, txt_dest) if File.exist?(txt_dest)
                rescue StandardError => e
                  Kettle::Dev.debug_error(e, __method__)
                end
              else
                puts "Skipping copy of .git-hooks templates."
              end
            end

            hook_dest_dir = File.join(project_root, ".git-hooks")
            begin
              FileUtils.mkdir_p(hook_dest_dir)
            rescue StandardError => e
              puts "WARNING: Could not create #{hook_dest_dir}: #{e.class}: #{e.message}"
              hook_dest_dir = nil
            end

            if hook_dest_dir
              if File.file?(hook_ruby_src)
                commit_msg_dest = File.join(hook_dest_dir, "commit-msg")
                commit_msg_strategy = helpers.strategy_for(commit_msg_dest)
                unless commit_msg_strategy == :keep_destination
                  if commit_msg_strategy == :raw_copy
                    helpers.copy_file_with_prompt(hook_ruby_src, commit_msg_dest, allow_create: true, allow_replace: true, raw: true)
                  else
                    helpers.copy_file_with_prompt(hook_ruby_src, commit_msg_dest, allow_create: true, allow_replace: true) do |content|
                      c = content
                      c = merge_by_file_type(c, commit_msg_dest, helpers.rel_path(commit_msg_dest), helpers) if commit_msg_strategy != :accept_template && File.exist?(commit_msg_dest)
                      c
                    end
                  end
                  begin
                    File.chmod(0o755, commit_msg_dest) if File.exist?(commit_msg_dest)
                  rescue StandardError => e
                    Kettle::Dev.debug_error(e, __method__)
                  end
                end
              end

              if File.file?(hook_sh_src)
                prepare_msg_dest = File.join(hook_dest_dir, "prepare-commit-msg")
                prepare_msg_strategy = helpers.strategy_for(prepare_msg_dest)
                unless prepare_msg_strategy == :keep_destination
                  if prepare_msg_strategy == :raw_copy
                    helpers.copy_file_with_prompt(hook_sh_src, prepare_msg_dest, allow_create: true, allow_replace: true, raw: true)
                  else
                    helpers.copy_file_with_prompt(hook_sh_src, prepare_msg_dest, allow_create: true, allow_replace: true) do |content|
                      c = content
                      c = merge_by_file_type(c, prepare_msg_dest, helpers.rel_path(prepare_msg_dest), helpers) if prepare_msg_strategy != :accept_template && File.exist?(prepare_msg_dest)
                      c
                    end
                  end
                  begin
                    File.chmod(0o755, prepare_msg_dest) if File.exist?(prepare_msg_dest)
                  rescue StandardError => e
                    Kettle::Dev.debug_error(e, __method__)
                  end
                end
              end
            end
          end

          # Scan all written files for unresolved {KJ|...} tokens and abort.
          # Unresolved tokens indicate missing configuration (e.g., AUTHOR_NAME,
          # FUNDING_LIBERAPAY). The user should add missing values to .kettle-jem.yml
          # or environment variables and re-run.
          begin
            unresolved_by_file = unresolved_written_tokens(
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

              task_abort(msg_lines.first)
            end
          rescue Kettle::Dev::Error
            raise # re-raise task_abort errors
          rescue StandardError => e
            Kettle::Dev.debug_error(e, __method__)
          end

          helpers.print_warnings_summary
          helpers.template_run_outcome = :complete

          nil
        ensure
          if project_root && run_started_at && templating_environment
            error = $!
            write_templating_run_report(
              project_root: project_root,
              output_dir: helpers.output_dir,
              snapshot: templating_environment,
              report_path: templating_report_path,
              run_started_at: run_started_at,
              finished_at: helpers.template_run_timestamp,
              status: templating_run_status(helpers, error),
              warnings: helpers.warnings,
              error: error,
            )
          end
        end

        def prune_workflow_matrix_by_appraisals(content, removed_appraisals)
          removed = Array(removed_appraisals).map(&:to_s).uniq
          return [content, 0, 0, false] if removed.empty?

          analysis = Psych::Merge::FileAnalysis.new(content)
          return [content, 0, 0, false] unless analysis.valid?

          lines = content.lines
          remove_lines = Set.new
          removed_count = 0
          total_count = 0

          root_entries = analysis.root_mapping_entries
          jobs_value = mapping_value_for(root_entries, "jobs")
          return [content, 0, 0, false] unless jobs_value&.mapping?

          jobs_value.mapping_entries(comment_tracker: analysis.comment_tracker).each do |_job_key, job_value|
            next unless job_value.mapping?
            strategy_value = mapping_value_for(job_value.mapping_entries(comment_tracker: analysis.comment_tracker), "strategy")
            next unless strategy_value&.mapping?
            matrix_value = mapping_value_for(strategy_value.mapping_entries(comment_tracker: analysis.comment_tracker), "matrix")
            next unless matrix_value&.mapping?
            include_value = mapping_value_for(matrix_value.mapping_entries(comment_tracker: analysis.comment_tracker), "include")
            next unless include_value&.sequence?

            items = include_value.sequence_items(comment_tracker: analysis.comment_tracker)
            total_count += items.size

            items.each do |item|
              next unless item.mapping?
              appraisal_value = mapping_value_for(item.mapping_entries(comment_tracker: analysis.comment_tracker), "appraisal")
              next unless appraisal_value&.scalar?

              appraisal = appraisal_value.value.to_s
              next unless removed.include?(appraisal)

              removed_count += 1
              start_line = item.start_line
              leading = item.leading_comments
              if leading && leading.any?
                start_line = [start_line, leading.first[:line]].min
              end
              end_line = item.end_line || start_line

              (start_line..end_line).each { |ln| remove_lines << ln }
            end
          end

          return [content, 0, 0, false] if removed_count.zero?

          new_lines = []
          lines.each_with_index do |line, idx|
            new_lines << line unless remove_lines.include?(idx + 1)
          end

          empty = total_count.positive? && removed_count == total_count
          [new_lines.join, removed_count, total_count, empty]
        rescue StandardError => e
          Kettle::Dev.debug_error(e, __method__)
          [content, 0, 0, false]
        end

        def mapping_value_for(entries, key_name)
          pair = entries.find do |k, _v|
            k.respond_to?(:scalar?) && k.scalar? && k.value.to_s == key_name.to_s
          end
          pair ? pair[1] : nil
        end
      end
    end
  end
end
