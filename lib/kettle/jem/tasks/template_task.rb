# frozen_string_literal: true

module Kettle
  module Jem
    module Tasks
      # Thin wrapper to expose the kettle:jem:template task logic as a callable API
      # for testability. The rake task should only call this method.
      module TemplateTask
        MODULAR_GEMFILE_DIR = "gemfiles/modular"
        MARKDOWN_HEADING_EXTENSIONS = %w[.md .markdown].freeze

        module_function

        # Ensure every Markdown atx-style heading line has exactly one blank line
        # before and after, skipping content inside fenced code blocks.
        def normalize_heading_spacing(text)
          lines = text.split("\n", -1)
          out = []
          in_fence = false
          fence_re = /^\s*```/
          heading_re = /^\s*#+\s+.+/
          lines.each_with_index do |ln, idx|
            if ln&.match?(fence_re)
              in_fence = !in_fence
              out << ln
              next
            end
            if !in_fence && ln =~ heading_re
              prev_blank = out.empty? ? false : out.last.to_s.strip == ""
              out << "" unless out.empty? || prev_blank
              out << ln
              nxt = lines[idx + 1]
              out << "" unless nxt.to_s.strip == ""
            else
              out << ln
            end
          end
          # Collapse accidental multiple blanks
          collapsed = []
          out.each do |l|
            if l.strip == "" && collapsed.last.to_s.strip == ""
              next
            end
            collapsed << l
          end
          collapsed.join("\n")
        end

        def markdown_heading_file?(relative_path)
          ext = File.extname(relative_path.to_s).downcase
          MARKDOWN_HEADING_EXTENSIONS.include?(ext)
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

          project_root = helpers.project_root
          gem_checkout_root = helpers.gem_checkout_root

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

          # 1) .devcontainer directory
          helpers.copy_dir_with_prompt(File.join(gem_checkout_root, ".devcontainer"), File.join(project_root, ".devcontainer"))

          # 2) .github/**/*.yml with FUNDING.yml customizations
          source_github_dir = File.join(gem_checkout_root, ".github")
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
              rel = orig_src.sub(/^#{Regexp.escape(gem_checkout_root)}\/?/, "").sub(/\.example\z/, "")
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
                  c = content.dup
                  # Effective funding handle should fall back to forge_org when funding_org is nil.
                  # This allows tests to stub FUNDING_ORG=false to bypass explicit funding detection
                  # while still templating the line with the derived organization (e.g., from homepage URL).
                  effective_funding = funding_org || forge_org
                  c = if helpers.opencollective_disabled?
                    c.gsub(/^open_collective:\s+.*$/i) { |line| "open_collective: # Replace with a single Open Collective username" }
                  else
                    c.gsub(/^open_collective:\s+.*$/i) { |line| effective_funding ? "open_collective: #{effective_funding}" : line }
                  end
                  if gem_name && !gem_name.empty?
                    c = c.gsub(/^tidelift:\s+.*$/i, "tidelift: rubygems/#{gem_name}")
                  end
                  helpers.apply_common_replacements(
                    c,
                    org: forge_org,
                    funding_org: effective_funding, # pass effective funding for downstream tokens
                    gem_name: gem_name,
                    namespace: namespace,
                    namespace_shield: namespace_shield,
                    gem_shield: gem_shield,
                    min_ruby: min_ruby,
                  )
                end
              else
                helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true) do |content|
                  helpers.apply_common_replacements(
                    content,
                    org: forge_org,
                    funding_org: funding_org,
                    gem_name: gem_name,
                    namespace: namespace,
                    namespace_shield: namespace_shield,
                    gem_shield: gem_shield,
                    min_ruby: min_ruby,
                  )
                end
              end
            end
          end

          # 3) .qlty/qlty.toml
          helpers.copy_file_with_prompt(
            helpers.prefer_example(File.join(gem_checkout_root, ".qlty/qlty.toml")),
            File.join(project_root, ".qlty/qlty.toml"),
            allow_create: true,
            allow_replace: true,
          )

          # 4) gemfiles/modular/* and nested directories (delegated for DRYness)
          Kettle::Jem::ModularGemfiles.sync!(
            helpers: helpers,
            project_root: project_root,
            gem_checkout_root: gem_checkout_root,
            min_ruby: min_ruby,
          )

          # 5) spec/spec_helper.rb (no create)
          dest_spec_helper = File.join(project_root, "spec/spec_helper.rb")
          if File.file?(dest_spec_helper)
            old = File.read(dest_spec_helper)
            if old.include?('require "kettle/dev"') || old.include?("require 'kettle/dev'")
              replacement = %(require "#{entrypoint_require}")
              new_content = old.gsub(/require\s+["']kettle\/dev["']/, replacement)
              if new_content != old
                if helpers.ask("Replace require \"kettle/dev\" in spec/spec_helper.rb with #{replacement}?", true)
                  helpers.write_file(dest_spec_helper, new_content)
                  puts "Updated require in spec/spec_helper.rb"
                else
                  puts "Skipped modifying spec/spec_helper.rb"
                end
              end
            end
          end

          # 6) .env.local special case: never read or touch .env.local from source; only copy .env.local.example to .env.local.example
          begin
            envlocal_src = File.join(gem_checkout_root, ".env.local.example")
            envlocal_dest = File.join(project_root, ".env.local.example")
            if File.exist?(envlocal_src)
              helpers.copy_file_with_prompt(envlocal_src, envlocal_dest, allow_create: true, allow_replace: true)
            end
          rescue StandardError => e
            Kettle::Dev.debug_error(e, __method__)
            puts "WARNING: Skipped .env.local example copy due to #{e.class}: #{e.message}"
          end

          # 7) Root and other files
          # 7a) Special-case: gemspec example must be renamed to destination gem's name
          begin
            # Prefer the .example variant when present
            gemspec_template_src = helpers.prefer_example(File.join(gem_checkout_root, "kettle-jem.gemspec"))
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
                # First apply standard replacements from the template example, but only
                # when we have a usable gem_name. If gem_name is unknown, leave content as-is
                # to allow filename fallback behavior without raising.
                c = if gem_name && !gem_name.to_s.empty?
                  helpers.apply_common_replacements(
                    content,
                    org: forge_org,
                    funding_org: funding_org,
                    gem_name: gem_name,
                    namespace: namespace,
                    namespace_shield: namespace_shield,
                    gem_shield: gem_shield,
                    min_ruby: min_ruby,
                  )
                else
                  content.dup
                end

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

          files_to_copy = %w[
            .aiignore
            .envrc
            .gitignore
            .idea/.gitignore
            .gitlab-ci.yml
            .junie/guidelines-rbs.md
            .junie/guidelines.md
            .licenserc.yaml
            .opencollective.yml
            .rspec
            .rubocop.yml
            .rubocop_rspec.yml
            .simplecov
            .tool-versions
            .yardopts
            .yardignore
            Appraisal.root.gemfile
            Appraisals
            CHANGELOG.md
            CITATION.cff
            CODE_OF_CONDUCT.md
            CONTRIBUTING.md
            FUNDING.md
            Gemfile
            README.md
            RUBOCOP.md
            Rakefile
            SECURITY.md
          ]

          files_to_copy.each do |rel|
            # Skip opencollective-specific files when Open Collective is disabled
            if helpers.skip_for_disabled_opencollective?(rel)
              puts "Skipping #{rel} (Open Collective disabled)"
              next
            end

            src = helpers.prefer_example_with_osc_check(File.join(gem_checkout_root, rel))
            dest = File.join(project_root, rel)
            next unless File.exist?(src)

            if File.basename(rel) == "README.md"
              prev_readme = File.exist?(dest) ? File.read(dest) : nil

              helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true) do |content|
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

                begin
                  c = MarkdownMerger.merge(
                    template_content: c,
                    destination_content: prev_readme,
                  )
                rescue StandardError => e
                  Kettle::Dev.debug_error(e, __method__)
                  # Best effort; if anything fails, keep c as-is
                end

                # Normalize spacing around Markdown headings for broad renderer compatibility
                c = normalize_heading_spacing(c) if markdown_heading_file?(rel)
                c
              end
            elsif ["CHANGELOG.md", "CITATION.cff", "CONTRIBUTING.md", ".opencollective.yml", "FUNDING.md", ".junie/guidelines.md", ".envrc"].include?(rel)
              helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true) do |content|
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
                if File.basename(rel) == "CHANGELOG.md"
                  begin
                    dest_content = File.file?(dest) ? File.read(dest) : ""
                    c = ChangelogMerger.merge(
                      template_content: c,
                      destination_content: dest_content,
                    )
                  rescue StandardError => e
                    Kettle::Dev.debug_error(e, __method__)
                    # Fallback: whitespace normalization only
                    lines = c.split("\n", -1)
                    lines.map! { |ln| ln.match?(/^##\s+\[.*\]/) ? ln.gsub(/[ \t]+/, " ") : ln }
                    c = lines.join("\n")
                  end
                end
                # Normalize spacing around Markdown headings for broad renderer compatibility
                c = normalize_heading_spacing(c) if markdown_heading_file?(rel)
                c
              end
            else
              helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true)
            end
          end


          # 7b) certs/pboling.pem
          begin
            cert_src = File.join(gem_checkout_root, "certs", "pboling.pem")
            cert_dest = File.join(project_root, "certs", "pboling.pem")
            if File.exist?(cert_src)
              helpers.copy_file_with_prompt(cert_src, cert_dest, allow_create: true, allow_replace: true)
            end
          rescue StandardError => e
            puts "WARNING: Skipped copying certs/pboling.pem due to #{e.class}: #{e.message}"
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

          # Handle .git-hooks files (see original rake task for details)
          source_hooks_dir = File.join(gem_checkout_root, ".git-hooks")
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
                [[goalie_src, "commit-subjects-goalie.txt"], [footer_src, "footer-template.erb.txt"]].each do |src, base|
                  dest = File.join(dest_dir, base)
                  # Allow create/replace prompts for these files (question applies to them)
                  helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true)
                  # Ensure readable (0644). These are data/templates, not executables.
                  begin
                    File.chmod(0o644, dest) if File.exist?(dest)
                  rescue StandardError => e
                    Kettle::Dev.debug_error(e, __method__)
                    # ignore permission issues
                  end
                end
              else
                puts "Skipping copy of .git-hooks templates."
              end
            end

            # Second: hook scripts — copy only to local project; prompt only on overwrite
            hook_dests = [File.join(project_root, ".git-hooks")]
            hook_pairs = [[hook_ruby_src, "commit-msg", 0o755], [hook_sh_src, "prepare-commit-msg", 0o755]]
            hook_pairs.each do |src, base, mode|
              next unless File.file?(src)

              hook_dests.each do |dstdir|
                FileUtils.mkdir_p(dstdir)
                dest = File.join(dstdir, base)
                # Create without prompt if missing; if exists, ask to replace
                if File.exist?(dest)
                  if helpers.ask("Overwrite existing #{dest}?", true)
                    content = File.read(src)
                    helpers.write_file(dest, content)
                    begin
                      File.chmod(mode, dest)
                    rescue StandardError => e
                      Kettle::Dev.debug_error(e, __method__)
                      # ignore permission issues
                    end
                    puts "Replaced #{dest}"
                  else
                    puts "Kept existing #{dest}"
                  end
                else
                  content = File.read(src)
                  helpers.write_file(dest, content)
                  begin
                    File.chmod(mode, dest)
                  rescue StandardError => e
                    Kettle::Dev.debug_error(e, __method__)
                    # ignore permission issues
                  end
                  puts "Installed #{dest}"
                end
              rescue StandardError => e
                puts "WARNING: Could not install hook #{base} to #{dstdir}: #{e.class}: #{e.message}"
              end
            end
          end

          # Done
          nil
        end
      end
    end
  end
end
