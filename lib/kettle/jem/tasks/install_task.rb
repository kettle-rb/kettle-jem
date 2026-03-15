# frozen_string_literal: true

module Kettle
  module Jem
    module Tasks
      module InstallTask
        module_function

        # Fixed-version engine badges mapped to the MRI they target.
        # "current" and "HEAD" badges are intentionally left dynamic.
        ENGINE_COMPATIBILITY_MRI_VERSION = {
          "jruby" => {
            "9.1" => Gem::Version.new("2.3"),
            "9.2" => Gem::Version.new("2.5"),
            "9.3" => Gem::Version.new("2.6"),
            "9.4" => Gem::Version.new("3.1"),
          }.freeze,
          "truby" => {
            "22.3" => Gem::Version.new("3.0"),
            "23.0" => Gem::Version.new("3.0"),
            "23.1" => Gem::Version.new("3.1"),
          }.freeze,
        }.freeze
        COMPATIBILITY_ROW_PREFIX_RE = /\A\| Works with (?:MRI Ruby|JRuby|Truffle Ruby)/.freeze
        COMPATIBILITY_REFERENCE_LABEL_RE = /\A(?:💎(?:ruby|jruby|truby)-|🚎)/.freeze

        # Abort wrapper that avoids terminating the current rake task process.
        # Always raise Kettle::Dev::Error so callers can decide whether to handle
        # it without terminating the process (e.g., in tests or non-interactive runs).
        def task_abort(msg)
          raise Kettle::Dev::Error, msg
        end

        def trim_readme_compatibility_badges!(readme_path, min_ruby)
          content = File.read(readme_path)
          content = remove_incompatible_compatibility_badges(content, min_ruby)
          content = normalize_compatibility_rows(content)
          content = prune_unused_compatibility_reference_definitions(content)
          File.open(readme_path, "w") { |f| f.write(content) }
        end

        def remove_incompatible_compatibility_badges(content, min_ruby)
          labels = content.scan(/\[(💎(?:ruby|jruby|truby)-[^\]]+)\]/).flatten.uniq

          labels.each do |label|
            badge_min_mri = compatibility_badge_min_mri(label)
            next unless badge_min_mri && badge_min_mri < min_ruby

            content = remove_badge_occurrences(content, label)
          end

          content
        end

        def compatibility_badge_min_mri(label)
          if (match = label.match(/\A💎ruby-(?<version>\d+\.\d+)i\z/))
            Gem::Version.new(match[:version])
          elsif (match = label.match(/\A💎(?<engine>jruby|truby)-(?<version>\d+\.\d+)i\z/))
            ENGINE_COMPATIBILITY_MRI_VERSION.dig(match[:engine], match[:version])
          end
        rescue StandardError => e
          Kettle::Dev.debug_error(e, __method__)
          nil
        end

        def remove_badge_occurrences(content, label)
          label_re = Regexp.escape(label)
          content = content.gsub(/\s*\[!\[[^\]]*?\]\s*\[#{label_re}\]\s*\]\s*\[[^\]]+\]\s*/, " ")
          content.gsub(/\s*!\[[^\]]*?\]\s*\[#{label_re}\]\s*/, " ")
        end

        def normalize_compatibility_rows(content)
          content.lines.filter_map do |line|
            next line unless compatibility_row?(line)

            cells = line.split("|", -1)
            badge_cell = normalize_compatibility_badge_cell(cells[2])
            next if badge_cell.empty?

            cells[2] = " #{badge_cell}"
            cells.join("|")
          end.join
        end

        def normalize_compatibility_badge_cell(cell)
          normalized = cell.to_s.gsub(/[ \t]+/, " ").strip
          normalized = normalized.gsub(/\s*<br\/>\s*/i, " <br/> ").gsub(/[ \t]{2,}/, " ").strip
          normalized = normalized.sub(/\A<br\/>\s*/i, "")
          normalized = normalized.sub(/\s*<br\/>\z/i, "")
          normalized.strip
        end

        def compatibility_row?(line)
          COMPATIBILITY_ROW_PREFIX_RE.match?(line)
        end

        def prune_unused_compatibility_reference_definitions(content)
          referenced_labels = {}

          content.lines.each do |line|
            next if line.match?(/^\[[^\]]+\]:/)

            line.scan(/\]\[([^\]]+)\]/) do |match|
              referenced_labels[match.first] = true
            end
          end

          content.lines.reject do |line|
            label = line[/^\[([^\]]+)\]:/, 1]
            label && COMPATIBILITY_REFERENCE_LABEL_RE.match?(label) && !referenced_labels[label]
          end.join
        end

        def run
          helpers = Kettle::Jem::TemplateHelpers
          project_root = helpers.project_root

          helpers.clear_template_run_outcome!
          Rake::Task["kettle:jem:template"].invoke
          return :bootstrap_only if helpers.template_run_outcome == :bootstrap_only

          # .tool-versions cleanup offers
          tool_versions_path = File.join(project_root, ".tool-versions")
          if File.file?(tool_versions_path)
            rv = File.join(project_root, ".ruby-version")
            rg = File.join(project_root, ".ruby-gemset")
            to_remove = [rv, rg].select { |p| File.exist?(p) }
            unless to_remove.empty?
              if helpers.ask("Remove #{to_remove.map { |p| File.basename(p) }.join(" and ")} (managed by .tool-versions)?", true)
                to_remove.each { |p| FileUtils.rm_f(p) }
                puts "Removed #{to_remove.map { |p| File.basename(p) }.join(" and ")}"
              end
            end
          end

          # Trim README compatibility badges that target MRI versions below required_ruby_version from the gemspec
          begin
            readme_path = File.join(project_root, "README.md")
            if File.file?(readme_path)
              md = helpers.gemspec_metadata(project_root)
              min_ruby = md[:min_ruby] # an instance of Gem::Version
              trim_readme_compatibility_badges!(readme_path, min_ruby) if min_ruby
            end
          rescue StandardError => e
            Kettle::Dev.debug_error(e, __method__)
            puts "WARNING: Skipped trimming compatibility badges in README.md due to #{e.class}: #{e.message}"
          end

          # Synchronize leading grapheme (emoji) between README H1 and gemspec summary/description
          begin
            readme_path = File.join(project_root, "README.md")
            gemspecs = Dir.glob(File.join(project_root, "*.gemspec"))
            if File.file?(readme_path) && !gemspecs.empty?
              gemspec_path = gemspecs.first
              readme = File.read(readme_path)
              first_h1_idx = readme.lines.index { |ln| ln =~ /^#\s+/ }
              chosen_grapheme = nil
              if first_h1_idx
                lines = readme.split("\n", -1)
                h1 = lines[first_h1_idx]
                tail = h1.sub(/^#\s+/, "")
                begin
                  emoji_re = Kettle::EmojiRegex::REGEX
                  # Extract first emoji grapheme cluster if present
                  if /\A#{emoji_re.source}/u.match?(tail)
                    cluster = tail[/\A\X/u]
                    chosen_grapheme = cluster unless cluster.to_s.empty?
                  end
                rescue StandardError => e
                  Kettle::Dev.debug_error(e, __method__)
                  # Fallback: take first Unicode grapheme if any non-space char
                  chosen_grapheme ||= tail[/\A\X/u]
                end
              end

              # If no grapheme found in README H1, either use a default in force mode, or ask the user.
              if chosen_grapheme.nil? || chosen_grapheme.empty?
                if Kettle::Dev::ENV_TRUE_RE.match?(ENV.fetch("force", "").to_s)
                  # Non-interactive install: default to pizza slice to match template style.
                  chosen_grapheme = "🍕"
                else
                  puts "No grapheme found after README H1. Enter a grapheme (emoji/symbol) to use for README, summary, and description:"
                  print("Grapheme: ")
                  ans = Kettle::Dev::InputAdapter.gets&.strip.to_s
                  chosen_grapheme = ans[/\A\X/u].to_s
                  # If still empty, skip synchronization silently
                  chosen_grapheme = nil if chosen_grapheme.empty?
                end
              end

              if chosen_grapheme
                # 1) Normalize README H1 to exactly one grapheme + single space after '#'
                begin
                  lines = readme.split("\n", -1)
                  idx = lines.index { |ln| ln =~ /^#\s+/ }
                  if idx
                    rest = lines[idx].sub(/^#\s+/, "")
                    begin
                      emoji_re = Kettle::EmojiRegex::REGEX
                      # Remove any leading emojis from the H1 by peeling full grapheme clusters
                      tmp = rest.dup
                      while tmp =~ /\A#{emoji_re.source}/u
                        cluster = tmp[/\A\X/u]
                        tmp = tmp[cluster.length..-1].to_s
                      end
                      rest_wo_emoji = tmp.sub(/\A\s+/, "")
                    rescue StandardError => e
                      Kettle::Dev.debug_error(e, __method__)
                      rest_wo_emoji = rest.sub(/\A\s+/, "")
                    end
                    # Build H1 with single spaces only around separators; preserve inner spacing in rest_wo_emoji
                    new_line = ["#", chosen_grapheme, rest_wo_emoji].join(" ").sub(/^#\s+/, "# ")
                    lines[idx] = new_line
                    new_readme = lines.join("\n")
                    File.open(readme_path, "w") { |f| f.write(new_readme) }
                  end
                rescue StandardError => e
                  Kettle::Dev.debug_error(e, __method__)
                  # ignore README normalization errors
                end

                # 2) Update gemspec summary and description to start with grapheme + single space
                begin
                  gspec = File.read(gemspec_path)

                  normalize_field = lambda do |text, field|
                    # Match the assignment line and the first quoted string
                    text.gsub(/(\b#{Regexp.escape(field)}\s*=\s*)(["'])([^\"']*)(\2)/) do
                      pre = Regexp.last_match(1)
                      q = Regexp.last_match(2)
                      body = Regexp.last_match(3)
                      # Strip existing leading emojis and spaces
                      begin
                        emoji_re = Kettle::EmojiRegex::REGEX
                        tmp = body.dup
                        tmp = tmp.sub(/\A\s+/, "")
                        while tmp =~ /\A#{emoji_re.source}/u
                          cluster = tmp[/\A\X/u]
                          tmp = tmp[cluster.length..-1].to_s
                        end
                        tmp = tmp.sub(/\A\s+/, "")
                        body_wo = tmp
                      rescue StandardError => e
                        Kettle::Dev.debug_error(e, __method__)
                        body_wo = body.sub(/\A\s+/, "")
                      end
                      pre + q + ("#{chosen_grapheme} " + body_wo) + q
                    end
                  end

                  gspec2 = normalize_field.call(gspec, "spec.summary")
                  gspec3 = normalize_field.call(gspec2, "spec.description")
                  if gspec3 != gspec
                    File.open(gemspec_path, "w") { |f| f.write(gspec3) }
                  end
                rescue StandardError => e
                  Kettle::Dev.debug_error(e, __method__)
                  # ignore gemspec edits on error
                end
              end
            end
          rescue StandardError => e
            puts "WARNING: Skipped grapheme synchronization due to #{e.class}: #{e.message}"
          end

          # Perform final whitespace normalization for README: only squish whitespace between word characters (non-table lines)
          begin
            readme_path = File.join(project_root, "README.md")
            if File.file?(readme_path)
              content = File.read(readme_path)
              content = content.lines.map do |ln|
                if ln.start_with?("|")
                  ln
                else
                  ln.gsub(/(\w)[ \t]{2,}(\w)/u, "\\1 \\2")
                end
              end.join
              File.open(readme_path, "w") { |f| f.write(content) }
            end
          rescue StandardError => e
            Kettle::Dev.debug_error(e, __method__)
            # ignore whitespace normalization errors
          end

          # Validate gemspec homepage points to GitHub and is a non-interpolated string
          begin
            gemspecs = Dir.glob(File.join(project_root, "*.gemspec"))
            if gemspecs.empty?
              puts
              puts "No .gemspec found in #{project_root}; skipping homepage check."
            else
              gemspec_path = gemspecs.first
              if gemspecs.size > 1
                puts
                puts "Multiple gemspecs found; defaulting to #{File.basename(gemspec_path)} for homepage check."
              end

              content = File.read(gemspec_path)
              homepage_line = content.lines.find { |l| l =~ /\bspec\.homepage\s*=\s*/ }
              if homepage_line.nil?
                puts
                puts "WARNING: spec.homepage not found in #{File.basename(gemspec_path)}."
                puts "This gem should declare a GitHub homepage: https://github.com/<org>/<repo>"
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
                  puts "Checking git remote 'origin' to derive GitHub homepage..."
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

                  puts "Current spec.homepage appears #{interpolated ? "interpolated" : "invalid"}: #{assigned}"
                  puts "Suggested literal homepage: \"#{suggested}\""
                  print("Update #{File.basename(gemspec_path)} to use this homepage? [Y/n]: ")
                  do_update =
                    if Kettle::Dev::ENV_TRUE_RE.match?(ENV.fetch("force", "").to_s)
                      true
                    else
                      ans = Kettle::Dev::InputAdapter.gets&.strip
                      ans.nil? || ans.empty? || ans =~ /\Ay(es)?\z/i
                    end

                  if do_update
                    new_line = homepage_line.sub(/=.*/, "= \"#{suggested}\"\n")
                    new_content = content.sub(homepage_line, new_line)
                    File.open(gemspec_path, "w") { |f| f.write(new_content) }
                    puts "Updated spec.homepage in #{File.basename(gemspec_path)} to #{suggested}"
                  else
                    puts "Skipping update of spec.homepage. You should set it to: #{suggested}"
                  end
                end
              end
            end
          rescue StandardError => e
            # Do not swallow intentional task aborts signaled via Kettle::Dev::Error
            raise if e.is_a?(Kettle::Dev::Error)

            puts "WARNING: An error occurred while checking gemspec homepage: #{e.class}: #{e.message}"
          end

          # Summary of templating changes
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

          puts
          puts "Next steps:"
          puts "1) Configure a shared git hooks path (optional, recommended):"
          puts "   git config --global core.hooksPath .git-hooks"
          puts
          puts "2) Install binstubs for this gem so the commit-msg tool is available in ./bin:"
          puts "   bundle binstubs kettle-jem --path bin"
          puts "   # After running, you should have bin/kettle-commit-msg (wrapper)."
          puts
          # Step 3: direnv and .envrc
          envrc_path = File.join(project_root, ".envrc")
          puts "3) Install direnv (if not already):"
          puts "   brew install direnv"
          if helpers.modified_by_template?(envrc_path)
            puts "   Your .envrc was created/updated by kettle:jem:template."
            puts "   It includes PATH_add bin so that executables in ./bin are on PATH when direnv is active."
            puts "   This allows running tools without the bin/ prefix inside the project directory."
          else
            begin
              current = File.file?(envrc_path) ? File.read(envrc_path) : ""
            rescue StandardError => e
              Kettle::Dev.debug_error(e, __method__)
              current = ""
            end

            # Use Bash::Merge to ensure the destination .envrc has at least the essential
            # PATH_add lines from a minimal snippet. The full template .envrc was already
            # copied/merged by the template task; this is a supplementary check for cases
            # where the user has a custom .envrc that predates the template.
            essential_envrc = <<~BASH
              # Run any command in this project's bin/ without the bin/ prefix
              PATH_add exe
              PATH_add bin
            BASH

            if current.empty?
              puts "   No .envrc found."
              if helpers.ask("Create #{envrc_path} with PATH_add bin?", false)
                FileUtils.rm_rf(envrc_path) if File.directory?(envrc_path)
                File.open(envrc_path, "w") { |f| f.write(essential_envrc) }
                puts "   Created #{envrc_path}"
                updated_envrc_by_install = true
              else
                puts "   Skipping creation of .envrc."
              end
            else
              begin
                merged = Bash::Merge::SmartMerger.new(
                  essential_envrc,
                  current,
                  preference: :destination,
                  add_template_only_nodes: true,
                  freeze_token: "kettle-jem",
                ).merge
              rescue StandardError => e
                Kettle::Dev.debug_error(e, __method__)
                # Fallback: simple line-presence check when Bash::Merge isn't available
                # (e.g., tree-sitter-bash grammar not installed)
                missing_lines = essential_envrc.lines.reject do |line|
                  line.strip.empty? || line.strip.start_with?("#") || current.include?(line.strip)
                end
                merged = if missing_lines.any?
                  essential_envrc + "\n" + current
                else
                  nil # Nothing to add
                end
              end

              if merged && merged != current
                puts "   Your .envrc is missing some recommended entries."
                if helpers.ask("Update #{envrc_path} with merged content?", false)
                  FileUtils.rm_rf(envrc_path) if File.directory?(envrc_path)
                  File.open(envrc_path, "w") { |f| f.write(merged) }
                  puts "   Updated #{envrc_path}"
                  updated_envrc_by_install = true
                else
                  puts "   Skipping modification of .envrc."
                end
              else
                puts "   Your .envrc is up to date."
              end
            end
          end

          if defined?(updated_envrc_by_install) && updated_envrc_by_install
            allowed_truthy = ENV.fetch("allowed", "").to_s =~ Kettle::Dev::ENV_TRUE_RE
            if allowed_truthy
              puts "Proceeding after .envrc update because allowed=true."
            else
              puts
              puts "IMPORTANT: .envrc was updated during kettle:jem:install."
              puts "Please review it and then run:"
              puts "  direnv allow"
              puts
              puts "After that, re-run to resume:"
              puts "  bundle exec rake kettle:jem:install allowed=true"
              task_abort("Aborting: direnv allow required after .envrc changes.")
            end
          end

          # Warn about .env.local and offer to add it to .gitignore
          puts
          puts "WARNING: Do not commit .env.local; it often contains machine-local secrets."
          puts "Ensure your .gitignore includes:"
          puts "  # direnv - brew install direnv"
          puts "  .env.local"

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
              puts "Would you like to add '.env.local' to #{gitignore_path}?"
              print("Add to .gitignore now [Y/n]: ")
              answer = Kettle::Dev::InputAdapter.gets&.strip
              # Respect an explicit negative answer even when force=true
              add_it = if answer && answer =~ /\An(o)?\z/i
                false
              elsif Kettle::Dev::ENV_TRUE_RE.match?(ENV.fetch("force", "").to_s)
                true
              else
                answer.nil? || answer.empty? || answer =~ /\Ay(es)?\z/i
              end
              if add_it
                FileUtils.mkdir_p(File.dirname(gitignore_path))
                mode = File.exist?(gitignore_path) ? "a" : "w"
                File.open(gitignore_path, mode) do |f|
                  f.write("\n") unless gitignore_current.empty? || gitignore_current.end_with?("\n")
                  unless gitignore_current.lines.any? { |l| l.strip == "# direnv - brew install direnv" }
                    f.write("# direnv - brew install direnv\n")
                  end
                  f.write(".env.local\n")
                end
                puts "Added .env.local to #{gitignore_path}"
              else
                puts "Skipping modification of .gitignore. Remember to add .env.local to avoid committing it."
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
