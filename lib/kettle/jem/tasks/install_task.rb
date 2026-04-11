# frozen_string_literal: true

module Kettle
  module Jem
    module Tasks
      module InstallTask
        module_function

        MISE_INSTALL_URL = "https://mise.jdx.dev/getting-started.html"
        ENV_LOCAL_GITIGNORE_COMMENT = "# Local environment overrides (KEY=value, loaded by mise via dotenvy)"

        # Abort wrapper that avoids terminating the current rake task process.
        # Always raise Kettle::Dev::Error so callers can decide whether to handle
        # it without terminating the process (e.g., in tests or non-interactive runs).
        def task_abort(msg)
          raise Kettle::Dev::Error, msg
        end

        def mise_installed?
          path = ENV.fetch("PATH", "").to_s
          return false if path.empty?

          path.split(File::PATH_SEPARATOR).any? do |dir|
            next false if dir.to_s.empty?

            candidate = File.join(dir, "mise")
            File.file?(candidate) && File.executable?(candidate)
          rescue StandardError
            false
          end
        end

        def trim_readme_compatibility_badges!(readme_path, min_ruby, engines: nil)
          content = Kettle::Jem::ReadmePostProcessor.process(content: File.read(readme_path), min_ruby: min_ruby, engines: engines)
          File.open(readme_path, "w") { |f| f.write(content) }
        end

        def sync_readme_gemspec_grapheme!(readme_path, gemspec_path, grapheme: nil)
          readme = File.read(readme_path)
          gemspec = File.read(gemspec_path)
          synced_readme, synced_gemspec, chosen_grapheme = Kettle::Jem::ReadmeGemspecSynchronizer.synchronize(
            readme_content: readme,
            gemspec_content: gemspec,
            grapheme: grapheme,
          )
          return unless chosen_grapheme

          File.open(readme_path, "w") { |f| f.write(synced_readme) } if synced_readme != readme
          File.open(gemspec_path, "w") { |f| f.write(synced_gemspec) } if synced_gemspec != gemspec
          chosen_grapheme
        end

        def run
          helpers = Kettle::Jem::TemplateHelpers
          project_root = helpers.project_root

          helpers.clear_template_run_outcome!
          Rake::Task["kettle:jem:template"].invoke
          return :bootstrap_only if helpers.template_run_outcome == :bootstrap_only

          # mise.toml cleanup offers
          mise_toml_path = File.join(project_root, "mise.toml")
          if File.file?(mise_toml_path)
            rv = File.join(project_root, ".ruby-version")
            rg = File.join(project_root, ".ruby-gemset")
            tv = File.join(project_root, ".tool-versions")
            to_remove = [rv, rg, tv].select { |p| File.exist?(p) }
            unless to_remove.empty?
              if helpers.ask("Remove #{to_remove.map { |p| File.basename(p) }.join(" and ")} (managed by mise.toml)?", true)
                to_remove.each { |p| FileUtils.rm_f(p) }
                puts "Removed #{to_remove.map { |p| File.basename(p) }.join(" and ")}" unless TemplateTask.quiet?
              end
            end
          end

          # Trim README compatibility badges that target MRI versions below required_ruby_version from the gemspec
          begin
            readme_path = File.join(project_root, "README.md")
            if File.file?(readme_path)
              md = helpers.gemspec_metadata(project_root)
              min_ruby = md[:min_ruby] # an instance of Gem::Version
              engines = helpers.engines_config
              trim_readme_compatibility_badges!(readme_path, min_ruby, engines: engines) if min_ruby
            end
          rescue StandardError => e
            Kettle::Dev.debug_error(e, __method__)
            Kernel.warn("[kettle-jem] ⚠️  Skipped trimming compatibility badges in README.md due to #{e.class}: #{e.message}")
          end

          # Synchronize leading grapheme (emoji) between README H1 and gemspec summary/description
          begin
            readme_path = File.join(project_root, "README.md")
            gemspecs = Dir.glob(File.join(project_root, "*.gemspec"))
            if File.file?(readme_path) && !gemspecs.empty?
              gemspec_path = gemspecs.first

              # Use project_emoji from .kettle-jem.yml as the authoritative source.
              # This prevents the template family emoji from overwriting per-project choices.
              config_emoji = helpers.resolved_config_string("project_emoji", env_key: "KJ_PROJECT_EMOJI")
              chosen_grapheme = helpers.present_string?(config_emoji) ? config_emoji : nil

              # Fall back to README H1 extraction when config has no value yet
              # (e.g. during initial install before .kettle-jem.yml is populated).
              if chosen_grapheme.nil?
                readme = File.read(readme_path)
                chosen_grapheme = Kettle::Jem::ReadmeGemspecSynchronizer.extract_readme_h1_grapheme(readme)
              end

              # If still no grapheme: in force mode abort with a clear message;
              # in interactive mode ask the user.
              if chosen_grapheme.nil? || chosen_grapheme.empty?
                if Kettle::Dev::ENV_TRUE_RE.match?(ENV.fetch("force", "true").to_s)
                  raise Kettle::Dev::Error,
                    "project_emoji is not set in .kettle-jem.yml and no emoji was found in README H1. " \
                      "Please add a `project_emoji:` key to .kettle-jem.yml (e.g. 🪙). " \
                      "ENV override: KJ_PROJECT_EMOJI"
                else
                  puts "No grapheme found in README H1 or project_emoji config. Enter a grapheme (emoji/symbol) to use for README, summary, and description:"
                  print("Grapheme: ")
                  ans = Kettle::Dev::InputAdapter.gets&.strip.to_s
                  chosen_grapheme = ans[/\A\X/u].to_s
                  # If still empty, skip synchronization silently
                  chosen_grapheme = nil if chosen_grapheme.empty?
                end
              end

              if chosen_grapheme
                begin
                  sync_readme_gemspec_grapheme!(readme_path, gemspec_path, grapheme: chosen_grapheme)
                rescue StandardError => e
                  Kettle::Dev.debug_error(e, __method__)
                  # ignore README / gemspec synchronization errors
                end
              end
            end
          rescue StandardError => e
            Kernel.warn("[kettle-jem] ⚠️  Skipped grapheme synchronization due to #{e.class}: #{e.message}")
          end

          # Validate gemspec homepage points to GitHub and is a non-interpolated string
          begin
            gemspecs = Dir.glob(File.join(project_root, "*.gemspec"))
            if gemspecs.empty?
              unless TemplateTask.quiet?
                puts
                puts "No .gemspec found in #{Kettle::Jem.display_path(project_root)}; skipping homepage check."
              end
            else
              gemspec_path = gemspecs.first
              if gemspecs.size > 1
                unless TemplateTask.quiet?
                  puts
                  puts "Multiple gemspecs found; defaulting to #{File.basename(gemspec_path)} for homepage check."
                end
              end

              content = File.read(gemspec_path)
              homepage_line = content.lines.find { |l| l =~ /\bspec\.homepage\s*=\s*/ }
              if homepage_line.nil?
                puts
                Kernel.warn("[kettle-jem] ⚠️  spec.homepage not found in #{File.basename(gemspec_path)}.")
                Kernel.warn("[kettle-jem] ⚠️  This gem should declare a GitHub homepage: https://github.com/<org>/<repo>")
              else
                assigned = homepage_line.split("=", 2).last.to_s.strip
                interpolated = assigned.include?('#{')

                if assigned.start_with?("\"", "'")
                  begin
                    assigned = assigned[1..-2]
                  rescue
                    # leave as-is
                  end
                end

                github_repo_from_url = lambda do |url|
                  return unless url

                  url = url.strip
                  m = url.match(%r{github\.com[/:]([^/\s:]+)/([^/\s]+?)(?:\.git)?/?\z}i)
                  return unless m

                  [m[1], m[2]]
                end

                github_homepage_literal = lambda do |val|
                  return false unless val
                  return false if val.include?('#{')

                  v = val.to_s.strip
                  if (v.start_with?("\"") && v.end_with?("\"")) || (v.start_with?("'") && v.end_with?("'"))
                    v = begin
                      v[1..-2]
                    rescue
                      v
                    end
                  end
                  return false unless %r{\Ahttps?://github\.com/}i.match?(v)

                  !!github_repo_from_url.call(v)
                end

                valid_literal = github_homepage_literal.call(assigned)

                if interpolated || !valid_literal
                  puts
                  puts "Checking git remote 'origin' to derive GitHub homepage..." unless TemplateTask.quiet?
                  origin_url = ""
                  # Use GitAdapter to avoid hanging and to simplify testing.
                  begin
                    ga = Kettle::Dev::GitAdapter.new
                    origin_url = ga.remote_url("origin") || ga.remotes_with_urls["origin"]
                    origin_url = origin_url.to_s.strip
                  rescue StandardError => e
                    Kettle::Dev.debug_error(e, __method__)
                  end

                  org_repo = github_repo_from_url.call(origin_url)
                  unless org_repo
                    puts "ERROR: git remote 'origin' is not a GitHub URL (or not found): #{origin_url.empty? ? "(none)" : origin_url}"
                    puts "To complete installation: set your GitHub repository as the 'origin' remote, and move any other forge to an alternate name."
                    puts "Example:"
                    puts "  git remote rename origin something_else"
                    puts "  git remote add origin https://github.com/<org>/<repo>.git"
                    puts "After fixing, re-run: rake kettle:jem:install"
                    task_abort("Aborting: homepage cannot be corrected without a GitHub origin remote.")
                  end

                  org, repo = org_repo
                  suggested = "https://github.com/#{org}/#{repo}"

                  unless TemplateTask.quiet?
                    puts "Current spec.homepage appears #{interpolated ? "interpolated" : "invalid"}: #{assigned}"
                    puts "Suggested literal homepage: \"#{suggested}\""
                  end
                  print("Update #{File.basename(gemspec_path)} to use this homepage? [Y/n]: ")
                  do_update =
                    if Kettle::Dev::ENV_TRUE_RE.match?(ENV.fetch("force", "true").to_s)
                      true
                    else
                      ans = Kettle::Dev::InputAdapter.gets&.strip
                      ans.nil? || ans.empty? || ans =~ /\Ay(es)?\z/i
                    end

                  if do_update
                    new_line = homepage_line.sub(/=.*/, "= \"#{suggested}\"\n")
                    new_content = content.sub(homepage_line, new_line)
                    File.open(gemspec_path, "w") { |f| f.write(new_content) }
                    puts "Updated spec.homepage in #{File.basename(gemspec_path)} to #{suggested}" unless TemplateTask.quiet?
                  else
                    puts "Skipping update of spec.homepage. You should set it to: #{suggested}" unless TemplateTask.quiet?
                  end
                end
              end
            end
          rescue StandardError => e
            # Do not swallow intentional task aborts signaled via Kettle::Dev::Error
            raise if e.is_a?(Kettle::Dev::Error)

            Kernel.warn("[kettle-jem] ⚠️  An error occurred while checking gemspec homepage: #{e.class}: #{e.message}")
          end

          # Summary of templating changes
          unless TemplateTask.quiet?
            begin
              results = helpers.template_results
              meaningful = results.select { |_, rec| [:create, :replace, :dir_create, :dir_replace].include?(rec[:action]) }
              puts
              puts "Summary of templating changes:"
              if meaningful.empty?
                puts "  (no files were created or merged by kettle:jem:template)"
              else
                action_labels = {
                  create: "Created",
                  replace: "Merged",
                  dir_create: "Directory created",
                  dir_replace: "Directory merged",
                }
                [:create, :replace, :dir_create, :dir_replace].each do |sym|
                  items = meaningful.select { |_, rec| rec[:action] == sym }.map { |path, _| path }
                  next if items.empty?

                  puts "  #{action_labels[sym]}:"
                  items.sort.each do |abs|
                    rel = begin
                      abs.start_with?(project_root.to_s) ? abs.sub(/^#{Regexp.escape(project_root.to_s)}\/?/, "") : abs
                    rescue
                      abs
                    end
                    puts "    - #{rel}"
                  end
                end
              end
            rescue StandardError => e
              puts
              puts "Summary of templating changes: (unavailable: #{e.class}: #{e.message})"
            end
          end

          unless TemplateTask.quiet?
            puts
            puts "Next steps:"
            puts "1) Configure a shared git hooks path (optional, recommended):"
            puts "   git config --global core.hooksPath .git-hooks"
            puts
            puts "2) Install binstubs for this gem so the commit-msg tool is available in ./bin:"
            puts "   bundle binstubs kettle-jem --path bin"
            puts "   # After running, you should have bin/kettle-commit-msg (wrapper)."
            puts
            # Step 3: mise and .envrc
            envrc_path = File.join(project_root, ".envrc")
            if mise_installed?
              puts "3) If mise prompts you to trust this repo, run:"
              puts "   mise trust"
            else
              puts "3) Install mise (recommended):"
              puts "   #{MISE_INSTALL_URL}"
              puts "   Then, from the project root, run:"
              puts "     mise trust"
            end
            if helpers.modified_by_template?(envrc_path)
              puts "   Your .envrc was created/updated by kettle:jem:template."
              puts "   It is a lightweight shim for this repo's mise-managed environment."
            else
              puts "   PATH management is handled by mise. No .envrc changes needed."
            end
          end

          if defined?(updated_envrc_by_install) && updated_envrc_by_install
            allowed_truthy = ENV.fetch("allowed", "true").to_s =~ Kettle::Dev::ENV_TRUE_RE
            if allowed_truthy
              puts "Proceeding after .envrc update because allowed=true." unless TemplateTask.quiet?
            else
              puts
              puts "IMPORTANT: .envrc was updated during kettle:jem:install."
              puts "Please review it before continuing."
              puts "If mise prompts you to trust this repo, run:"
              puts "  mise trust"
              puts
              puts "After that, re-run to resume:"
              puts "  bundle exec rake kettle:jem:install allowed=true"
              task_abort("Aborting: review .envrc changes before continuing.")
            end
          end

          # Warn about .env.local and offer to add it to .gitignore
          unless TemplateTask.quiet?
            puts
            Kernel.warn("[kettle-jem] ⚠️  Do not commit .env.local; it often contains machine-local secrets.")
            puts "It uses simple KEY=value env-file syntax and is loaded by mise via dotenvy."
            puts "Ensure your .gitignore includes:"
            puts "  #{ENV_LOCAL_GITIGNORE_COMMENT}"
            puts "  .env.local"
          end

          gitignore_path = File.join(project_root, ".gitignore")
          unless helpers.modified_by_template?(gitignore_path)
            begin
              gitignore_current = File.exist?(gitignore_path) ? File.read(gitignore_path) : ""
            rescue StandardError => e
              Kettle::Dev.debug_error(e, __method__)
              gitignore_current = ""
            end
            has_env_local = gitignore_current.lines.any? { |l| l.strip == ".env.local" }
            unless has_env_local
              puts
              puts "Would you like to add '.env.local' to #{Kettle::Jem.display_path(gitignore_path)}?"
              print("Add to .gitignore now [Y/n]: ")
              answer = Kettle::Dev::InputAdapter.gets&.strip
              # Respect an explicit negative answer even when force=true
              add_it = if answer && answer =~ /\An(o)?\z/i
                false
              elsif Kettle::Dev::ENV_TRUE_RE.match?(ENV.fetch("force", "true").to_s)
                true
              else
                answer.nil? || answer.empty? || answer =~ /\Ay(es)?\z/i
              end
              if add_it
                FileUtils.mkdir_p(File.dirname(gitignore_path))
                mode = File.exist?(gitignore_path) ? "a" : "w"
                File.open(gitignore_path, mode) do |f|
                  f.write("\n") unless gitignore_current.empty? || gitignore_current.end_with?("\n")
                  unless gitignore_current.lines.any? { |l| l.strip == ENV_LOCAL_GITIGNORE_COMMENT }
                    f.write("#{ENV_LOCAL_GITIGNORE_COMMENT}\n")
                  end
                  f.write(".env.local\n")
                end
                puts "Added .env.local to #{Kettle::Jem.display_path(gitignore_path)}" unless TemplateTask.quiet?
              else
                puts "Skipping modification of .gitignore. Remember to add .env.local to avoid committing it." unless TemplateTask.quiet?
              end
            end
          end

          puts
          puts "kettle:jem:install complete."
        end
      end
    end
  end
end
