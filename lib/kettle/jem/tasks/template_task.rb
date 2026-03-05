# frozen_string_literal: true

require "set"

module Kettle
  module Jem
    module Tasks
      # Thin wrapper to expose the kettle:jem:template task logic as a callable API
      # for testability. The rake task should only call this method.
      module TemplateTask
        MODULAR_GEMFILE_DIR = "gemfiles/modular"
        MARKDOWN_HEADING_EXTENSIONS = %w[.md .markdown].freeze

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

          if helpers.ruby_template?(dest)
            # Ruby files: prism-merge via SourceMerger
            merged = helpers.apply_strategy(content, dest)
            return merged if merged.is_a?(String) && !merged.empty?
          elsif yaml_file?(rel)
            # YAML files: psych-merge
            merged = Psych::Merge::SmartMerger.new(
              content,
              dest_content,
              preference: :template,
              add_template_only_nodes: true,
            ).merge
            return merged if merged.is_a?(String) && !merged.empty?
          elsif markdown_heading_file?(rel)
            # Markdown files (not README/CHANGELOG, which have dedicated steps):
            # use SmartMerger with template preference
            merged = Markdown::Merge::SmartMerger.new(
              content,
              dest_content,
              preference: :template,
              add_template_only_nodes: true,
            ).merge
            return merged if merged.is_a?(String) && !merged.empty?
          elsif bash_file?(rel)
            # Shell / bash files: bash-merge
            merged = Bash::Merge::SmartMerger.new(
              content,
              dest_content,
              preference: :template,
              add_template_only_nodes: true,
            ).merge
            return merged if merged.is_a?(String) && !merged.empty?
          elsif tool_versions_file?(rel)
            # .tool-versions: text-merge with first-word signature matching.
            # Lines match by tool name (e.g., "ruby"), so template version
            # values replace destination values while destination-only tools
            # are preserved.
            merged = Ast::Merge::Text::SmartMerger.new(
              content,
              dest_content,
              preference: :template,
              add_template_only_nodes: true,
              signature_generator: TOOL_VERSIONS_SIGNATURE_GENERATOR,
            ).merge
            return merged if merged.is_a?(String) && !merged.empty?
          else
            # Text files (gitignore, rspec, yardopts, etc.): text-merge
            merged = Ast::Merge::Text::SmartMerger.new(
              content,
              dest_content,
              preference: :template,
            ).merge
            return merged if merged.is_a?(String) && !merged.empty?
          end

          content
        rescue StandardError => e
          if failure_mode == :rescue
            Kettle::Dev.debug_error(e, __method__)
            content
          else
            raise Kettle::Dev::Error, "Merge failed for #{rel}: #{e.class}: #{e.message}"
          end
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

        # Execute the template operation into the current project.
        # All options/IO are controlled via TemplateHelpers and ENV.
        def run
          # Inline the former rake task body, but using helpers directly.
          helpers = Kettle::Jem::TemplateHelpers
          helpers.clear_warnings

          project_root = helpers.project_root
          template_root = helpers.template_root

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

              helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true) do |content|
                c = content
                # Merge with existing destination file using format-appropriate merger
                if File.exist?(dest)
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
                    # Fall through with token-resolved content on merge failure
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
              # Destination path should never include the .example suffix.
              rel = orig_src.sub(/^#{Regexp.escape(template_root)}\/?/, "").sub(/\.example\z/, "")
              dest = File.join(project_root, rel)

              # Skip opencollective-specific files when Open Collective is disabled
              if helpers.skip_for_disabled_opencollective?(rel)
                puts "Skipping #{rel} (Open Collective disabled)"
                next
              end

              # Optional file: .github/workflows/discord-notifier.yml should NOT be copied by default.
              # Only copy when --include matches it.
              if rel == ".github/workflows/discord-notifier.yml"
                unless matches_include.call(dest)
                  # Explicitly skip without prompting
                  next
                end
              end

              if File.basename(rel) == "FUNDING.yml"
                helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true) do |content|
                  c = content
                  # Merge resolved template with existing destination FUNDING.yml using psych-merge.
                  # Template preference ensures updated funding values propagate while preserving
                  # any custom keys the destination has added.
                  if File.exist?(dest)
                    begin
                      c = Psych::Merge::SmartMerger.new(
                        c,
                        File.read(dest),
                        preference: :template,
                        add_template_only_nodes: true,
                      ).merge
                    rescue StandardError => e
                      Kettle::Dev.debug_error(e, __method__)
                      # Fall through with token-resolved content on merge failure
                    end
                  end
                  c
                end
              else
                prepared = nil
                if rel.start_with?(".github/workflows/")
                  # Read template with tokens resolved
                  c = helpers.read_template(src)
                  if File.exist?(dest)
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
                  c = prepared || content
                  # Merge non-workflow .github YAML files with destination (e.g., .codecov.yml, dependabot.yml)
                  if !prepared && File.exist?(dest)
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
              end
            end
          end

          # 3) .qlty/qlty.toml — merge with TOML-aware SmartMerger
          qlty_src = helpers.prefer_example(File.join(template_root, ".qlty/qlty.toml"))
          qlty_dest = File.join(project_root, ".qlty/qlty.toml")
          helpers.copy_file_with_prompt(
            qlty_src,
            qlty_dest,
            allow_create: true,
            allow_replace: true,
          ) do |content|
            c = content
            if File.exist?(qlty_dest)
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
                # Fall through with token-resolved content on merge failure
              end
            end
            c
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
              helpers.copy_file_with_prompt(envlocal_src, envlocal_dest, allow_create: true, allow_replace: true) do |content|
                if File.exist?(envlocal_dest)
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
                    content # Fall back to template content on merge failure
                  end
                else
                  content
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

              # If a destination gemspec already exists, get metadata from GemSpecReader via helpers
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

              helpers.copy_file_with_prompt(gemspec_template_src, dest_gemspec, allow_create: true, allow_replace: true) do |content|
                # Tokens are already resolved by read_template inside copy_file_with_prompt
                c = content

                if orig_meta
                  # Build replacements using AST-aware helper to carry over fields
                  repl = {}
                  if (name = orig_meta[:gem_name]) && !name.to_s.empty?
                    repl[:name] = name.to_s
                  end
                  repl[:authors] = Array(orig_meta[:authors]).map(&:to_s) if orig_meta[:authors]
                  repl[:email] = Array(orig_meta[:email]).map(&:to_s) if orig_meta[:email]
                  # Only carry over summary/description if they have actual content (not empty strings)
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
                    # Best-effort carry-over; ignore failure and keep c as-is
                  end
                end

                # Ensure we do not introduce a self-dependency when templating the gemspec.
                # If the template included a dependency on the template gem (e.g., "kettle-dev"),
                # the common replacements would have turned it into the destination gem's name.
                # Strip any dependency lines that name the destination gem.
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
                  # If anything goes wrong, keep the content as-is rather than failing the task
                end

                if dest_existed
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
          rescue StandardError => e
            Kettle::Dev.debug_error(e, __method__)
            # Do not fail the entire template task if gemspec copy has issues
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
                if File.basename(rel) == "README.md"
                  prev_readme = File.exist?(dest) ? File.read(dest) : nil

                  helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true) do |content|
                    c = content
                    begin
                      c = MarkdownMerger.merge(
                        template_content: c,
                        destination_content: prev_readme,
                      )
                    rescue StandardError => e
                      Kettle::Dev.debug_error(e, __method__)
                      # Best effort; if anything fails, keep c as-is
                    end

                    # Normalize spacing around Markdown structural elements using AST
                    c = normalize_markdown_spacing(c) if markdown_heading_file?(rel)
                    c
                  end
                elsif File.basename(rel) == "CHANGELOG.md"
                  helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true) do |content|
                    c = content
                    begin
                      dest_content = File.file?(dest) ? File.read(dest) : ""
                      c = ChangelogMerger.merge(
                        template_content: c,
                        destination_content: dest_content,
                      )
                    rescue StandardError => e
                      Kettle::Dev.debug_error(e, __method__)
                      # On merge failure, keep token-resolved content;
                      # normalize_markdown_spacing below handles whitespace via AST
                    end
                    # Normalize spacing around Markdown structural elements using AST
                    c = normalize_markdown_spacing(c) if markdown_heading_file?(rel)
                    c
                  end
                else
                  # All other files: consult config for strategy
                  file_strategy = helpers.strategy_for(dest)
                  helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true) do |content|
                    c = content
                    if file_strategy == :skip
                      # Token-resolved content wins; no merge with destination
                    elsif File.exist?(dest)
                      # Merge with existing destination when it exists
                      c = merge_by_file_type(c, dest, rel, helpers)
                    end
                    # Normalize spacing around Markdown structural elements using AST
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
              env_choice = ENV["hook_templates"]
              env_choice = ENV["KETTLE_DEV_HOOK_TEMPLATES"] if env_choice.nil? || env_choice.strip.empty?
              choice = env_choice&.strip
              unless choice && !choice.empty?
                print("Choose (l/g/s) [l]: ")
                choice = Kettle::Dev::InputAdapter.gets&.strip
              end
              choice = "l" if choice.nil? || choice.empty?
              dest_dir = case choice.downcase
              when "g", "global" then File.join(ENV["HOME"], ".git-hooks")
              when "s", "skip" then nil
              else File.join(project_root, ".git-hooks")
              end

              if dest_dir
                FileUtils.mkdir_p(dest_dir)

                # commit-subjects-goalie.txt — merge with Text::SmartMerger to preserve destination customizations
                goalie_dest = File.join(dest_dir, "commit-subjects-goalie.txt")
                helpers.copy_file_with_prompt(goalie_src, goalie_dest, allow_create: true, allow_replace: true) do |content|
                  if File.exist?(goalie_dest)
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

                # footer-template.erb.txt — resolve tokens, then merge with Text::SmartMerger
                footer_dest = File.join(dest_dir, "footer-template.erb.txt")
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
                  if File.exist?(footer_dest)
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

                # Ensure readable (0644). These are data/templates, not executables.
                [goalie_dest, footer_dest].each do |txt_dest|
                  File.chmod(0o644, txt_dest) if File.exist?(txt_dest)
                rescue StandardError => e
                  Kettle::Dev.debug_error(e, __method__)
                end
              else
                puts "Skipping copy of .git-hooks templates."
              end
            end

            # Second: hook scripts — merge with Prism (Ruby) / Bash (shell), then set executable
            hook_dest_dir = File.join(project_root, ".git-hooks")
            begin
              FileUtils.mkdir_p(hook_dest_dir)
            rescue StandardError => e
              puts "WARNING: Could not create #{hook_dest_dir}: #{e.class}: #{e.message}"
              hook_dest_dir = nil
            end

            if hook_dest_dir
              # commit-msg (Ruby script) -- merge with Prism::Merge::SmartMerger
              if File.file?(hook_ruby_src)
                commit_msg_dest = File.join(hook_dest_dir, "commit-msg")
                helpers.copy_file_with_prompt(hook_ruby_src, commit_msg_dest, allow_create: true, allow_replace: true) do |content|
                  if File.exist?(commit_msg_dest)
                    begin
                      content = Prism::Merge::SmartMerger.new(
                        content,
                        File.read(commit_msg_dest),
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
                begin
                  File.chmod(0o755, commit_msg_dest) if File.exist?(commit_msg_dest)
                rescue StandardError => e
                  Kettle::Dev.debug_error(e, __method__)
                end
              end

              # prepare-commit-msg (shell script) — merge with Bash::Merge::SmartMerger
              if File.file?(hook_sh_src)
                prepare_msg_dest = File.join(hook_dest_dir, "prepare-commit-msg")
                helpers.copy_file_with_prompt(hook_sh_src, prepare_msg_dest, allow_create: true, allow_replace: true) do |content|
                  if File.exist?(prepare_msg_dest)
                    begin
                      content = Bash::Merge::SmartMerger.new(
                        content,
                        File.read(prepare_msg_dest),
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
                begin
                  File.chmod(0o755, prepare_msg_dest) if File.exist?(prepare_msg_dest)
                rescue StandardError => e
                  Kettle::Dev.debug_error(e, __method__)
                end
              end
            end
          end

          # Scan all written files for unresolved {KJ|...} tokens and warn
          begin
            token_pattern = /\{KJ\|[A-Z][A-Z0-9_:]*\}/
            project_root_path = project_root.to_s
            unresolved_by_file = {}
            require "find"
            Find.find(project_root_path) do |path|
              next if File.directory?(path)
              # Skip binary files, vendored dirs, and non-text files
              rel = path.sub(%r{^#{Regexp.escape(project_root_path)}/?}, "")
              next if rel.start_with?("vendor/", ".git/", "coverage/", "tmp/", "pkg/", "node_modules/")
              next unless File.file?(path)
              # Only check text files by extension
              ext = File.extname(path)
              next unless %w[.rb .gemspec .gemfile .yml .yaml .toml .md .txt .sh .json .jsonc .cff .example .lock].include?(ext) ||
                File.basename(path).match?(/\A(Gemfile|Rakefile|Appraisals|REEK|\.envrc|\.env|\.rspec|\.yardopts|\.gitignore|\.rubocop|LICENSE)\z/i)
              begin
                content = File.read(path)
                tokens = content.scan(token_pattern).uniq
                unresolved_by_file[rel] = tokens unless tokens.empty?
              rescue StandardError
                # Skip files that can't be read
              end
            end

            unless unresolved_by_file.empty?
              helpers.add_warning("Unresolved {KJ|...} tokens found in #{unresolved_by_file.size} file(s):")
              unresolved_by_file.each do |rel, tokens|
                helpers.add_warning("  #{rel}: #{tokens.join(", ")}")
              end
            end
          rescue StandardError => e
            Kettle::Dev.debug_error(e, __method__)
          end

          helpers.print_warnings_summary

          # Done
          nil
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
