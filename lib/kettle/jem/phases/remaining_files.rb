# frozen_string_literal: true

require_relative "template_phase"

module Kettle
  module Jem
    module Phases
      # Phase 7: Gemspec, README, Rakefile, and all remaining template files.
      class RemainingFiles < TemplatePhase
        PHASE_EMOJI = "📂"
        PHASE_NAME = "Remaining files"
        PHASE_DETAIL = "gemspec, README, Rakefile, …"

        private

        def perform
          helpers = context.helpers
          out = context.out
          project_root = context.project_root
          template_root = context.template_root
          gem_name = context.gem_name
          min_ruby = context.min_ruby

          # 7a) Special-case: gemspec example must be renamed to destination gem's name
          sync_gemspec!(helpers, out, project_root, template_root, gem_name)

          # 7) Discover and copy all remaining template files.
          sync_remaining_template_files!(helpers, out, project_root, template_root, gem_name, min_ruby)

          Kettle::Jem::Tasks::TemplateTask.sync_readme_gemspec_grapheme!(
            helpers: helpers,
            project_root: project_root,
            gem_name: gem_name,
          )

          # After creating or replacing .envrc or .env.local.example, require review and exit unless allowed
          check_env_file_review!(helpers, out, project_root)
        end

        def sync_gemspec!(helpers, out, project_root, template_root, gem_name)
          gemspec_template_src = helpers.prefer_example(File.join(template_root, "gem.gemspec"))
          return unless File.exist?(gemspec_template_src)

          dest_gemspec = if gem_name && !gem_name.to_s.empty?
            File.join(project_root, "#{gem_name}.gemspec")
          else
            existing = Dir.glob(File.join(project_root, "*.gemspec")).sort.first
            if existing
              existing
            else
              fallback_name = File.basename(gemspec_template_src).sub(/\.example\z/, "")
              File.join(project_root, fallback_name)
            end
          end

          gemspec_strategy = helpers.strategy_for(dest_gemspec)
          return if gemspec_strategy == :keep_destination

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
                repl[:licenses] = helpers.resolved_licenses
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

              gemspec_context = if orig_meta && orig_meta[:min_ruby] && orig_meta[:entrypoint_require] && orig_meta[:namespace]
                {
                  min_ruby: orig_meta[:min_ruby],
                  entrypoint_require: orig_meta[:entrypoint_require],
                  namespace: orig_meta[:namespace],
                }
              end

              if dest_existed || gemspec_context
                begin
                  merged = helpers.apply_strategy(c, dest_gemspec, context: gemspec_context)
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
        end

        def sync_remaining_template_files!(helpers, out, project_root, template_root, gem_name, min_ruby)
          handled_prefixes = %w[
            .devcontainer/
            .qlty/
            gemfiles/modular/
            .git-hooks/
          ]
          handled_files = %w[
            .env.local
            .kettle-jem.yml
            LICENSE.md
            MIT.md
            AGPL-3.0-only.md
            PolyForm-Noncommercial-1.0.0.md
            PolyForm-Small-Business-1.0.0.md
            Big-Time-Public-License.md
          ]

          effective_template_root = helpers.template_root
          return unless Dir.exist?(effective_template_root)

          require "find"
          Find.find(effective_template_root) do |path|
            next if File.directory?(path)

            # Compute relative path from template root, stripping .example / .no-osc.example suffixes
            rel = path.sub(%r{^#{Regexp.escape(effective_template_root)}/?}, "")
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
              out.report_detail("Skipping #{rel} (Open Collective disabled)")
              next
            end

            src = helpers.prefer_example_with_osc_check(File.join(effective_template_root, rel))
            dest = File.join(project_root, rel)
            next unless File.exist?(src)

            # Raw copy: no token resolution, no merging (e.g., certs/)
            if Kettle::Jem::Tasks::TemplateTask.raw_copy?(rel)
              begin
                helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true, raw: true)
              rescue StandardError => e
                Kettle::Dev.debug_error(e, __method__)
                out.warning("Could not copy #{rel}: #{e.class}: #{e.message}")
              end
              next
            end

            begin
              file_strategy = helpers.strategy_for(dest)
              next if file_strategy == :keep_destination

              if file_strategy == :raw_copy
                helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true, raw: true)
                next
              end

              if Kettle::Jem::Tasks::TemplateTask.accept_template_path?(rel)
                helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true)
              elsif File.basename(rel) == "README.md"
                prev_readme = File.exist?(dest) ? File.read(dest) : nil

                helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true) do |content|
                  c = content
                  if file_strategy != :accept_template
                    begin
                      c = Kettle::Jem::MarkdownMerger.merge(
                        template_content: c,
                        destination_content: prev_readme,
                      )
                    rescue StandardError => e
                      Kettle::Dev.debug_error(e, __method__)
                    end
                  end
                  c = Kettle::Jem::Tasks::TemplateTask.normalize_markdown_spacing(c) if Kettle::Jem::Tasks::TemplateTask.markdown_heading_file?(rel)
                  c = Kettle::Jem::ReadmePostProcessor.process(content: c, min_ruby: min_ruby, engines: helpers.engines_config)
                  c
                end
              elsif File.basename(rel) == "CHANGELOG.md"
                helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true) do |content|
                  c = content
                  if file_strategy != :accept_template
                    begin
                      dest_content = File.file?(dest) ? File.read(dest) : ""
                      c = Kettle::Jem::ChangelogMerger.merge(
                        template_content: c,
                        destination_content: dest_content,
                      )
                    rescue StandardError => e
                      Kettle::Dev.debug_error(e, __method__)
                    end
                  end
                  c = Kettle::Jem::Tasks::TemplateTask.normalize_markdown_spacing(c) if Kettle::Jem::Tasks::TemplateTask.markdown_heading_file?(rel)
                  c
                end
              else
                helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true) do |content|
                  c = content
                  if file_strategy == :accept_template
                    # token-resolved template content wins; no merge
                  elsif File.exist?(dest)
                    c = Kettle::Jem::Tasks::TemplateTask.merge_by_file_type(c, dest, rel, helpers)
                  end
                  c = Kettle::Jem::Tasks::TemplateTask.normalize_markdown_spacing(c) if Kettle::Jem::Tasks::TemplateTask.markdown_heading_file?(rel)
                  # Prune Appraisals entries for Ruby versions below min_ruby
                  # so that stale ruby-2.x blocks don't survive the merge.
                  if File.basename(rel) == "Appraisals" && min_ruby
                    begin
                      c, _removed = Kettle::Jem::PrismAppraisals.prune_ruby_appraisals(c, min_ruby: min_ruby)
                    rescue StandardError => e
                      Kettle::Dev.debug_error(e, __method__)
                    end
                  end
                  c
                end
              end
            rescue StandardError => e
              Kettle::Dev.debug_error(e, __method__)
              out.warning("Could not template #{rel}: #{e.class}: #{e.message}")
            end
          end
        end

        def check_env_file_review!(helpers, out, project_root)
          envrc_path = File.join(project_root, ".envrc")
          envlocal_example_path = File.join(project_root, ".env.local.example")
          changed_env_files = []
          changed_env_files << envrc_path if helpers.modified_by_template?(envrc_path)
          changed_env_files << envlocal_example_path if helpers.modified_by_template?(envlocal_example_path)
          if !changed_env_files.empty?
            if /\A(1|true|y|yes)\z/i.match?(ENV.fetch("allowed", "true").to_s)
              out.detail("Detected updates to #{changed_env_files.map { |p| File.basename(p) }.join(" and ")}. Proceeding because allowed=true.")
            else
              puts
              puts "IMPORTANT: The following environment-related files were created/updated:"
              changed_env_files.each { |p| puts "  - #{p}" }
              puts
              puts "Please review these files before continuing."
              puts "If mise prompts you to trust this repo, run:"
              puts "  mise trust"
              puts
              puts "After that, re-run to resume:"
              puts "  bundle exec rake kettle:jem:template allowed=true"
              puts "  # or to run the full install afterwards:"
              puts "  bundle exec rake kettle:jem:install allowed=true"
              Kettle::Jem::Tasks::TemplateTask.task_abort("Aborting: review of environment files required before continuing.")
            end
          end
        rescue StandardError => e
          # Do not swallow intentional task aborts
          raise if e.is_a?(Kettle::Dev::Error)

          out.warning("Could not determine env file changes: #{e.class}: #{e.message}")
        end
      end
    end
  end
end
