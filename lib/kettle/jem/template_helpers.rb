# frozen_string_literal: true

# External stdlibs
require "find"
require "set"
require "yaml"

module Kettle
  module Jem
    # Helpers shared by kettle:jem Rake tasks for templating and file ops.
    module TemplateHelpers
      # Track results of templating actions across a single process run.
      # Keys: absolute destination paths (String)
      # Values: Hash with keys: :action (Symbol, one of :create, :replace, :skip, :dir_create, :dir_replace), :timestamp (Time)
      @@template_results = {}

      # When set, write operations are redirected to this directory instead of
      # modifying files under project_root.  The merge logic still *reads* from
      # the real destination so it has authentic content to merge against — only
      # the *write* is redirected.
      # @see #output_path
      @@output_dir = nil

      EXECUTABLE_GIT_HOOKS_RE = %r{[\\/]\.git-hooks[\\/](commit-msg|prepare-commit-msg)\z}
      # The minimum Ruby supported by setup-ruby GHA
      MIN_SETUP_RUBY = Gem::Version.create("2.3")

      # Multi-separator token config: {KJ|SECTION:NAME}
      TOKEN_CONFIG = Token::Resolver::Config.new(separators: ["|", ":"]).freeze

      # ENV variable names for forge user tokens.
      # Each maps a forge prefix to its ENV key.
      FORGE_USER_ENV_KEYS = {
        "GH" => "KJ_GH_USER",
        "GL" => "KJ_GL_USER",
        "CB" => "KJ_CB_USER",
        "SH" => "KJ_SH_USER",
      }.freeze

      # ENV variable names for author identity tokens.
      AUTHOR_ENV_KEYS = {
        "NAME" => "KJ_AUTHOR_NAME",
        "GIVEN_NAMES" => "KJ_AUTHOR_GIVEN_NAMES",
        "FAMILY_NAMES" => "KJ_AUTHOR_FAMILY_NAMES",
        "EMAIL" => "KJ_AUTHOR_EMAIL",
        "ORCID" => "KJ_AUTHOR_ORCID",
        "DOMAIN" => "KJ_AUTHOR_DOMAIN",
      }.freeze

      # ENV variable names for funding platform tokens.
      FUNDING_ENV_KEYS = {
        "PATREON" => "KJ_FUNDING_PATREON",
        "KOFI" => "KJ_FUNDING_KOFI",
        "PAYPAL" => "KJ_FUNDING_PAYPAL",
        "BUYMEACOFFEE" => "KJ_FUNDING_BUYMEACOFFEE",
        "POLAR" => "KJ_FUNDING_POLAR",
        "LIBERAPAY" => "KJ_FUNDING_LIBERAPAY",
        "ISSUEHUNT" => "KJ_FUNDING_ISSUEHUNT",
      }.freeze

      # ENV variable names for social/community platform tokens.
      SOCIAL_ENV_KEYS = {
        "MASTODON" => "KJ_SOCIAL_MASTODON",
        "BLUESKY" => "KJ_SOCIAL_BLUESKY",
        "LINKTREE" => "KJ_SOCIAL_LINKTREE",
        "DEVTO" => "KJ_SOCIAL_DEVTO",
      }.freeze

      KETTLE_JEM_CONFIG_PATH = File.expand_path("../../..", __dir__) + "/.kettle-jem.yml"
      RUBY_BASENAMES = %w[Gemfile Rakefile Appraisals Appraisal.root.gemfile .simplecov].freeze
      RUBY_SUFFIXES = %w[.gemspec .gemfile].freeze
      RUBY_EXTENSIONS = %w[.rb .rake].freeze
      @@manifestation = nil
      @@kettle_config = nil
      @@project_root_override = nil

      module_function

      # Root of the host project where Rake was invoked.
      # When +@@project_root_override+ is set (by SelfTestTask), that value
      # is returned instead of the real project root.
      # @return [String]
      def project_root
        @@project_root_override || Kettle::Dev::CIHelpers.project_root
      end

      # Directory to redirect write operations to (nil = write in-place).
      # @return [String, nil]
      def output_dir
        @@output_dir
      end

      # Set the output directory for write redirection.
      # When set, +write_file+ and +copy_dir_with_prompt+ will write results
      # under this directory instead of under +project_root+. Pass +nil+ to
      # restore in-place write behaviour.
      # @param dir [String, nil]
      # @return [void]
      def output_dir=(dir)
        @@output_dir = dir
      end

      # Compute the actual filesystem path to write to.
      # When +@@output_dir+ is nil the original +dest_path+ is returned
      # unchanged. When set, the path is rewritten so that the portion
      # relative to +project_root+ is placed under +@@output_dir+ instead.
      # @param dest_path [String] logical destination path (relative to project_root)
      # @return [String]
      def output_path(dest_path)
        return dest_path unless @@output_dir

        rel = dest_path.to_s.sub(/^#{Regexp.escape(project_root.to_s)}\/?/, "")
        File.join(@@output_dir, rel)
      end

      # Root of this gem's checkout (repository root when working from source)
      # Calculated relative to lib/kettle/jem/
      # @return [String]
      def gem_checkout_root
        File.expand_path("../../..", __dir__)
      end

      # Root of the template/ directory containing tokenized .example files.
      # @return [String]
      def template_root
        File.join(gem_checkout_root, "template")
      end

      # Simple yes/no prompt.
      # @param prompt [String]
      # @param default [Boolean]
      # @return [Boolean]
      def ask(prompt, default)
        # Force mode: any prompt resolves to Yes when ENV["force"] is set truthy
        if /\A(1|true|y|yes)\z/i.match?(ENV.fetch("force", "").to_s)
          puts "#{prompt} #{default ? "[Y/n]" : "[y/N]"}: Y (forced)"
          return true
        end
        print("#{prompt} #{default ? "[Y/n]" : "[y/N]"}: ")
        ans = Kettle::Dev::InputAdapter.gets&.strip
        ans = "" if ans.nil?
        # Normalize explicit no first
        return false if /\An(o)?\z/i.match?(ans)
        if default
          # Empty -> default true; explicit yes -> true; anything else -> false
          ans.empty? || ans =~ /\Ay(es)?\z/i
        else
          # Empty -> default false; explicit yes -> true; others (including garbage) -> false
          ans =~ /\Ay(es)?\z/i
        end
      end

      # Write file content creating directories as needed.
      # When +output_dir+ is set the write is redirected via +output_path+.
      # @param dest_path [String]
      # @param content [String]
      # @return [void]
      def write_file(dest_path, content)
        actual = output_path(dest_path)
        FileUtils.mkdir_p(File.dirname(actual))
        File.open(actual, "w") { |f| f.write(content) }
      end

      # Prefer an .example variant for a given source path when present
      # For a given intended source path (e.g., "/src/Rakefile"), this will return
      # "/src/Rakefile.example" if it exists, otherwise returns the original path.
      # If the given path already ends with .example, it is returned as-is.
      # @param src_path [String]
      # @return [String]
      def prefer_example(src_path)
        return src_path if src_path.end_with?(".example")
        example = src_path + ".example"
        File.exist?(example) ? example : src_path
      end

      # Check if Open Collective is disabled via environment variable.
      # Delegates to Kettle::Dev::OpenCollectiveConfig.disabled?
      # @return [Boolean]
      def opencollective_disabled?
        Kettle::Dev::OpenCollectiveConfig.disabled?
      end

      # Prefer a .no-osc.example variant when Open Collective is disabled.
      # Otherwise, falls back to prefer_example behavior.
      # For a given source path, this will return:
      #   - "path.no-osc.example" if opencollective_disabled? and it exists
      #   - Otherwise delegates to prefer_example
      # @param src_path [String]
      # @return [String]
      def prefer_example_with_osc_check(src_path)
        if opencollective_disabled?
          # Try .no-osc.example first
          base = src_path.sub(/\.example\z/, "")
          no_osc = base + ".no-osc.example"
          return no_osc if File.exist?(no_osc)
        end
        prefer_example(src_path)
      end

      # Check if a file should be skipped when Open Collective is disabled.
      # Returns true for opencollective-specific files when opencollective_disabled? is true.
      # @param relative_path [String] relative path from gem checkout root
      # @return [Boolean]
      def skip_for_disabled_opencollective?(relative_path)
        return false unless opencollective_disabled?

        opencollective_files = [
          ".opencollective.yml",
          ".github/workflows/opencollective.yml",
        ]

        opencollective_files.include?(relative_path)
      end

      # Record a template action for a destination path
      # @param dest_path [String]
      # @param action [Symbol] one of :create, :replace, :skip, :dir_create, :dir_replace
      # @return [void]
      def record_template_result(dest_path, action)
        abs = File.expand_path(dest_path.to_s)
        if action == :skip && @@template_results.key?(abs)
          # Preserve the last meaningful action; do not downgrade to :skip
          return
        end
        @@template_results[abs] = {action: action, timestamp: Time.now}
      end

      # Access all template results (read-only clone)
      # @return [Hash]
      def template_results
        @@template_results.clone
      end

      # Returns true if the given path was created or replaced by the template task in this run
      # @param dest_path [String]
      # @return [Boolean]
      def modified_by_template?(dest_path)
        rec = @@template_results[File.expand_path(dest_path.to_s)]
        return false unless rec
        [:create, :replace, :dir_create, :dir_replace].include?(rec[:action])
      end

      # Ensure git working tree is clean before making changes in a task.
      # If not a git repo, this is a no-op.
      # @param root [String] project root to run git commands in
      # @param task_label [String] name of the rake task for user-facing messages (e.g., "kettle:jem:install")
      # @return [void]
      def ensure_clean_git!(root:, task_label:)
        inside_repo = begin
          system("git", "-C", root.to_s, "rev-parse", "--is-inside-work-tree", out: File::NULL, err: File::NULL)
        rescue StandardError => e
          Kettle::Dev.debug_error(e, __method__)
          false
        end
        return unless inside_repo

        # Prefer GitAdapter for cleanliness check; fallback to porcelain output
        clean = begin
          ga = Kettle::Dev::GitAdapter.new
          out, ok = ga.capture(["-C", root.to_s, "status", "--porcelain"])
          ok ? out.to_s.strip.empty? : nil
        rescue StandardError => e
          Kettle::Dev.debug_error(e, __method__)
          nil
        end

        if clean.nil?
          # Fallback to using the GitAdapter to get both status and preview
          status_output = begin
            ga = Kettle::Dev::GitAdapter.new
            out, ok = ga.capture(["-C", root.to_s, "status", "--porcelain"]) # adapter can use CLI safely
            ok ? out.to_s : ""
          rescue StandardError => e
            Kettle::Dev.debug_error(e, __method__)
            ""
          end
          return if status_output.strip.empty?
        else
          return if clean
          # For messaging, provide a small preview using GitAdapter even when using the adapter
          status_output = begin
            ga = Kettle::Dev::GitAdapter.new
            out, ok = ga.capture(["-C", root.to_s, "status", "--porcelain"]) # read-only query
            ok ? out.to_s : ""
          rescue StandardError => e
            Kettle::Dev.debug_error(e, __method__)
            ""
          end
        end

        preview = status_output.lines.take(10).map(&:rstrip)

        puts "ERROR: Your git working tree has uncommitted changes."
        puts "#{task_label} may modify files (e.g., .github/, .gitignore, *.gemspec)."
        puts "Please commit or stash your changes, then re-run: rake #{task_label}"
        unless preview.empty?
          puts "Detected changes:"
          preview.each { |l| puts "  #{l}" }
          puts "(showing up to first 10 lines)"
        end
        raise Kettle::Dev::Error, "Aborting: git working tree is not clean."
      end

      # Copy a single file with interactive prompts for create/replace.
      # Yields content for transformation when block given.
      # @return [void]
      def copy_file_with_prompt(src_path, dest_path, allow_create: true, allow_replace: true)
        return unless File.exist?(src_path)

        # Apply optional inclusion filter via ENV["only"] (comma-separated glob patterns relative to project root)
        begin
          only_raw = ENV["only"].to_s
          if !only_raw.empty?
            patterns = only_raw.split(",").map { |s| s.strip }.reject(&:empty?)
            if !patterns.empty?
              proj = project_root.to_s
              rel_dest = dest_path.to_s
              if rel_dest.start_with?(proj + "/")
                rel_dest = rel_dest[(proj.length + 1)..-1]
              elsif rel_dest == proj
                rel_dest = ""
              end
              matched = patterns.any? do |pat|
                if pat.end_with?("/**")
                  base = pat[0..-4]
                  rel_dest == base || rel_dest.start_with?(base + "/")
                else
                  File.fnmatch?(pat, rel_dest, File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH)
                end
              end
              unless matched
                record_template_result(dest_path, :skip)
                puts "Skipping #{dest_path} (excluded by only filter)"
                return
              end
            end
          end
        rescue StandardError => e
          Kettle::Dev.debug_error(e, __method__)
          # If anything goes wrong parsing/matching, ignore the filter and proceed.
        end

        dest_exists = File.exist?(dest_path)
        action = nil
        if dest_exists
          if allow_replace
            action = ask("Replace #{dest_path}?", true) ? :replace : :skip
          else
            puts "Skipping #{dest_path} (replace not allowed)."
            action = :skip
          end
        elsif allow_create
          action = ask("Create #{dest_path}?", true) ? :create : :skip
        else
          puts "Skipping #{dest_path} (create not allowed)."
          action = :skip
        end
        if action == :skip
          record_template_result(dest_path, :skip)
          return
        end

        content = File.read(src_path)
        content = yield(content) if block_given?

        basename = File.basename(dest_path.to_s)
        content = apply_appraisals_merge(content, dest_path) if basename == "Appraisals"
        if basename == "Appraisal.root.gemfile" && File.exist?(dest_path)
          begin
            prior = File.read(dest_path)
            content = merge_gemfile_dependencies(content, prior)
          rescue StandardError => e
            Kettle::Dev.debug_error(e, __method__)
          end
        end

        # Apply self-dependency removal for all gem-related files
        # This ensures we don't introduce a self-dependency when templating
        begin
          meta = gemspec_metadata
          gem_name = meta[:gem_name]
          if gem_name && !gem_name.to_s.empty?
            content = remove_self_dependency(content, gem_name, dest_path)
          end
        rescue StandardError => e
          Kettle::Dev.debug_error(e, __method__)
          # If metadata extraction or removal fails, proceed with content as-is
        end

        write_file(dest_path, content)
        begin
          # Ensure executable bit for git hook scripts when writing under .git-hooks
          if EXECUTABLE_GIT_HOOKS_RE.match?(dest_path.to_s)
            actual = output_path(dest_path)
            File.chmod(0o755, actual) if File.exist?(actual)
          end
        rescue StandardError => e
          Kettle::Dev.debug_error(e, __method__)
          # ignore permission issues
        end
        record_template_result(dest_path, dest_exists ? :replace : :create)
        puts "Wrote #{dest_path}"
      end

      # Merge gem dependency lines from a source Gemfile-like content into an existing
      # destination Gemfile-like content. Existing gem lines in the destination win;
      # we only append missing gem declarations from the source at the end of the file.
      # This is deliberately conservative and avoids attempting to relocate gems inside
      # group/platform blocks or reconcile version constraints.
      # @param src_content [String]
      # @param dest_content [String]
      # @return [String] merged content
      def merge_gemfile_dependencies(src_content, dest_content)
        Kettle::Jem::PrismGemfile.merge_gem_calls(src_content.to_s, dest_content.to_s)
      rescue StandardError => e
        Kettle::Dev.debug_error(e, __method__)
        dest_content
      end

      def apply_appraisals_merge(content, dest_path)
        dest = dest_path.to_s
        existing = if File.exist?(dest)
          File.read(dest)
        else
          ""
        end
        Kettle::Jem::PrismAppraisals.merge(content, existing)
      rescue StandardError => e
        Kettle::Dev.debug_error(e, __method__)
        content
      end

      # Remove self-referential gem dependencies from content based on file type.
      # Applies to gemspec, Gemfile, modular gemfiles, Appraisal.root.gemfile, and Appraisals.
      # @param content [String] file content
      # @param gem_name [String] the gem name to remove
      # @param file_path [String] path to the file (used to determine type)
      # @return [String] content with self-dependencies removed
      def remove_self_dependency(content, gem_name, file_path)
        return content if gem_name.to_s.strip.empty?

        basename = File.basename(file_path.to_s)

        begin
          case basename
          when /\.gemspec$/
            Kettle::Jem::PrismGemspec.remove_spec_dependency(content, gem_name)
          when "Gemfile", "Appraisal.root.gemfile", /\.gemfile$/
            Kettle::Jem::PrismGemfile.remove_gem_dependency(content, gem_name)
          when "Appraisals"
            Kettle::Jem::PrismAppraisals.remove_gem_dependency(content, gem_name)
          else
            # Return content unchanged for unknown file types
            content
          end
        rescue StandardError => e
          Kettle::Dev.debug_error(e, __method__)
          content
        end
      end

      # Copy a directory tree, prompting before creating or overwriting.
      # @return [void]
      def copy_dir_with_prompt(src_dir, dest_dir)
        return unless Dir.exist?(src_dir)

        # Build a matcher for ENV["only"], relative to project root, that can be reused within this method
        only_raw = ENV["only"].to_s
        patterns = only_raw.split(",").map { |s| s.strip }.reject(&:empty?) unless only_raw.nil?
        patterns ||= []
        proj_root = project_root.to_s
        matches_only = lambda do |abs_dest|
          return true if patterns.empty?
          begin
            rel_dest = abs_dest.to_s
            if rel_dest.start_with?(proj_root + "/")
              rel_dest = rel_dest[(proj_root.length + 1)..-1]
            elsif rel_dest == proj_root
              rel_dest = ""
            end
            patterns.any? do |pat|
              if pat.end_with?("/**")
                base = pat[0..-4]
                rel_dest == base || rel_dest.start_with?(base + "/")
              else
                File.fnmatch?(pat, rel_dest, File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH)
              end
            end
          rescue StandardError => e
            Kettle::Dev.debug_error(e, __method__)
            # On any error, do not filter out (act as matched)
            true
          end
        end

        # Early exit: if an only filter is present and no files inside this directory would match,
        # do not prompt to create/replace this directory at all.
        begin
          if !patterns.empty?
            any_match = false
            Find.find(src_dir) do |path|
              rel = path.sub(/^#{Regexp.escape(src_dir)}\/?/, "")
              next if rel.empty?
              next if File.directory?(path)
              target = File.join(dest_dir, rel)
              if matches_only.call(target)
                any_match = true
                break
              end
            end
            unless any_match
              record_template_result(dest_dir, :skip)
              return
            end
          end
        rescue StandardError => e
          Kettle::Dev.debug_error(e, __method__)
          # If determining matches fails, fall through to prompting logic
        end

        dest_exists = Dir.exist?(dest_dir)
        if dest_exists
          if ask("Replace directory #{dest_dir} (will overwrite files)?", true)
            Find.find(src_dir) do |path|
              rel = path.sub(/^#{Regexp.escape(src_dir)}\/?/, "")
              next if rel.empty?
              target = File.join(dest_dir, rel)
              if File.directory?(path)
                FileUtils.mkdir_p(output_path(target))
              else
                # Per-file inclusion filter
                next unless matches_only.call(target)

                actual_target = output_path(target)
                FileUtils.mkdir_p(File.dirname(actual_target))
                if File.exist?(actual_target)

                  # Skip only if the actual output already has identical contents.
                  # Compare against actual_target (not target) so that when output_dir
                  # is set the check looks at the real write destination.
                  # If source and actual_target are the same path, avoid FileUtils.cp
                  # (which raises) and do an in-place rewrite to satisfy "copy".
                  begin
                    if FileUtils.compare_file(path, actual_target)
                      next
                    elsif path == actual_target
                      data = File.binread(path)
                      File.open(actual_target, "wb") { |f| f.write(data) }
                      next
                    end
                  rescue StandardError => e
                    Kettle::Dev.debug_error(e, __method__)
                    # ignore compare errors; fall through to copy
                  end
                end
                FileUtils.cp(path, actual_target)
                begin
                  # Ensure executable bit for git hook scripts when copying under .git-hooks
                  if target.end_with?("/.git-hooks/commit-msg", "/.git-hooks/prepare-commit-msg") ||
                      EXECUTABLE_GIT_HOOKS_RE =~ target
                    File.chmod(0o755, actual_target)
                  end
                rescue StandardError => e
                  Kettle::Dev.debug_error(e, __method__)
                  # ignore permission issues
                end
              end
            end
            puts "Updated #{dest_dir}"
            record_template_result(dest_dir, :dir_replace)
          else
            puts "Skipped #{dest_dir}"
            record_template_result(dest_dir, :skip)
          end
        elsif ask("Create directory #{dest_dir}?", true)
          FileUtils.mkdir_p(output_path(dest_dir))
          Find.find(src_dir) do |path|
            rel = path.sub(/^#{Regexp.escape(src_dir)}\/?/, "")
            next if rel.empty?
            target = File.join(dest_dir, rel)
            if File.directory?(path)
              FileUtils.mkdir_p(output_path(target))
            else
              # Per-file inclusion filter
              next unless matches_only.call(target)

              actual_target = output_path(target)
              FileUtils.mkdir_p(File.dirname(actual_target))
              if File.exist?(actual_target)
                # Skip only if the actual output already has identical contents.
                # Compare against actual_target (not target) so that when output_dir
                # is set the check looks at the real write destination.
                begin
                  if FileUtils.compare_file(path, actual_target)
                    next
                  elsif path == actual_target
                    data = File.binread(path)
                    File.open(actual_target, "wb") { |f| f.write(data) }
                    next
                  end
                rescue StandardError => e
                  Kettle::Dev.debug_error(e, __method__)
                  # ignore compare errors; fall through to copy
                end
              end
              FileUtils.cp(path, actual_target)
              begin
                # Ensure executable bit for git hook scripts when copying under .git-hooks
                if target.end_with?("/.git-hooks/commit-msg", "/.git-hooks/prepare-commit-msg") ||
                    EXECUTABLE_GIT_HOOKS_RE =~ target
                  File.chmod(0o755, actual_target)
                end
              rescue StandardError => e
                Kettle::Dev.debug_error(e, __method__)
                # ignore permission issues
              end
            end
          end
          puts "Created #{dest_dir}"
          record_template_result(dest_dir, :dir_create)
        end
      end

      # Apply common token replacements used when templating text files.
      #
      # Uses Token::Resolver to resolve all {KJ|...} tokens in the content.
      # Unresolved tokens are kept as-is (on_missing: :keep) so that tokens
      # resolved at a different stage (e.g. {KJ|RUBOCOP_RUBY_GEM} in
      # ModularGemfiles) are not prematurely removed.
      #
      # @param content [String]
      # @param org [String, nil]
      # @param gem_name [String]
      # @param namespace [String]
      # @param namespace_shield [String]
      # @param gem_shield [String]
      # @param funding_org [String, nil]
      # @param min_ruby [String, nil]
      # @return [String]
      def apply_common_replacements(content, org:, gem_name:, namespace:, namespace_shield:, gem_shield:, funding_org: nil, min_ruby: nil)
        raise Error, "Org could not be derived" unless org && !org.empty?
        raise Error, "Gem name could not be derived" unless gem_name && !gem_name.empty?

        funding_org ||= org

        # Derive min_ruby from gemspec if not provided
        mr = begin
          meta = gemspec_metadata
          meta[:min_ruby]
        rescue StandardError => e
          Kettle::Dev.debug_error(e, __method__)
          nil
        end
        if min_ruby.nil? || min_ruby.to_s.strip.empty?
          min_ruby = mr.respond_to?(:to_s) ? mr.to_s : mr
        end

        # Derive min_dev_ruby: the greater of min_ruby and 2.3 (minimum for setup-ruby GHA)
        min_dev_ruby = begin
          [mr, MIN_SETUP_RUBY].max
        rescue StandardError => e
          Kettle::Dev.debug_error(e, __method__)
          MIN_SETUP_RUBY
        end

        dashed = gem_name.tr("_", "-")
        ft = (kettle_config.dig("defaults", "freeze_token") || "kettle-jem").to_s
        author_domain = ENV["KJ_AUTHOR_DOMAIN"]
        author_domain = nil if author_domain.to_s.strip.empty?

        # Build the token replacement map
        replacements = {
          "KJ|GEM_NAME" => gem_name,
          "KJ|GEM_NAME_PATH" => gem_name.tr("-", "/"),
          "KJ|GEM_SHIELD" => gem_shield,
          "KJ|GH_ORG" => org.to_s,
          "KJ|NAMESPACE" => namespace,
          "KJ|NAMESPACE_SHIELD" => namespace_shield,
          "KJ|OPENCOLLECTIVE_ORG" => funding_org || "opencollective",
          "KJ|FREEZE_TOKEN" => ft,
          "KJ|KETTLE_DEV_GEM" => "kettle-dev",
          "KJ|YARD_HOST" => "#{dashed}.#{author_domain || "example.com"}",
        }
        replacements["KJ|MIN_RUBY"] = min_ruby.to_s if min_ruby && !min_ruby.to_s.empty?
        replacements["KJ|MIN_DEV_RUBY"] = min_dev_ruby.to_s if min_dev_ruby && !min_dev_ruby.to_s.empty?

        # Forge user tokens: {KJ|GH:USER}, {KJ|GL:USER}, {KJ|CB:USER}, {KJ|SH:USER}
        FORGE_USER_ENV_KEYS.each do |forge, env_key|
          value = ENV[env_key]
          replacements["KJ|#{forge}:USER"] = value if value && !value.strip.empty?
        end

        # Author identity tokens: {KJ|AUTHOR:NAME}, {KJ|AUTHOR:EMAIL}, etc.
        AUTHOR_ENV_KEYS.each do |field, env_key|
          value = ENV[env_key]
          replacements["KJ|AUTHOR:#{field}"] = value if value && !value.strip.empty?
        end

        # Funding platform tokens: {KJ|FUNDING:PATREON}, {KJ|FUNDING:KOFI}, {KJ|FUNDING:PAYPAL}
        FUNDING_ENV_KEYS.each do |platform, env_key|
          value = ENV[env_key]
          replacements["KJ|FUNDING:#{platform}"] = value if value && !value.strip.empty?
        end

        # Social/community platform tokens: {KJ|SOCIAL:MASTODON}, {KJ|SOCIAL:BLUESKY}, etc.
        SOCIAL_ENV_KEYS.each do |platform, env_key|
          value = ENV[env_key]
          replacements["KJ|SOCIAL:#{platform}"] = value if value && !value.strip.empty?
        end

        # Resolve all {KJ|...} and {KJ|XX:YY} tokens; unresolved ones kept for later-stage resolution
        doc = Token::Resolver::Document.new(content, config: TOKEN_CONFIG)
        resolver = Token::Resolver::Resolve.new(on_missing: :keep)
        resolver.resolve(doc, replacements)
      end

      # Parse gemspec metadata and derive useful strings
      # @param root [String] project root
      # @return [Hash]
      def gemspec_metadata(root = project_root)
        Kettle::Dev::GemSpecReader.load(root)
      end

      def apply_strategy(content, dest_path)
        return content unless ruby_template?(dest_path)
        strategy = strategy_for(dest_path)
        dest_content = File.exist?(dest_path) ? File.read(dest_path) : ""
        Kettle::Jem::SourceMerger.apply(strategy: strategy, src: content, dest: dest_content, path: rel_path(dest_path))
      end

      def manifestation
        @@manifestation ||= load_manifest
      end

      def strategy_for(dest_path)
        relative = rel_path(dest_path)
        config_for(relative)&.fetch(:strategy, :skip) || :skip
      end

      # Get full configuration for a file path including merge options
      # @param relative_path [String] Path relative to project root
      # @return [Hash, nil] Configuration hash with :strategy and optional merge options
      def config_for(relative_path)
        # First check individual file configs (highest priority)
        file_config = find_file_config(relative_path)
        return file_config if file_config

        # Fall back to pattern matching
        manifestation.find do |entry|
          File.fnmatch?(entry[:path], relative_path, File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH)
        end
      end

      # Find configuration for a specific file in the nested files structure
      # @param relative_path [String] Path relative to project root (e.g., "gemfiles/modular/coverage.gemfile")
      # @return [Hash, nil] Configuration hash or nil if not found
      def find_file_config(relative_path)
        config = kettle_config
        return unless config && config["files"]

        parts = relative_path.split("/")
        current = config["files"]

        parts.each do |part|
          return nil unless current.is_a?(Hash) && current.key?(part)
          current = current[part]
        end

        # Check if we reached a leaf config node (has "strategy" key)
        return unless current.is_a?(Hash) && current.key?("strategy")

        # Merge with defaults for merge strategy
        build_config_entry(nil, current)
      end

      # Build a config entry hash, merging with defaults as appropriate
      # @param path [String, nil] The path (for pattern entries) or nil (for file entries)
      # @param entry [Hash] The raw config entry
      # @return [Hash] Normalized config entry
      def build_config_entry(path, entry)
        config = kettle_config
        defaults = config&.fetch("defaults", {}) || {}

        result = {strategy: entry["strategy"].to_s.strip.downcase.to_sym}
        result[:path] = path if path

        # For merge strategy, include merge options (from entry or defaults)
        if result[:strategy] == :merge
          %w[preference add_template_only_nodes freeze_token max_recursion_depth].each do |opt|
            value = entry.key?(opt) ? entry[opt] : defaults[opt]
            result[opt.to_sym] = value unless value.nil?
          end
        end

        result
      end

      def rel_path(path)
        project = project_root.to_s
        path.to_s.sub(/^#{Regexp.escape(project)}\/?/, "")
      end

      def ruby_template?(dest_path)
        base = File.basename(dest_path.to_s)
        return true if RUBY_BASENAMES.include?(base)
        return true if RUBY_SUFFIXES.any? { |suffix| base.end_with?(suffix) }
        ext = File.extname(base)
        RUBY_EXTENSIONS.include?(ext)
      end

      # Load the raw kettle-jem config file
      # @return [Hash] Parsed YAML config
      def kettle_config
        @@kettle_config ||= YAML.load_file(KETTLE_JEM_CONFIG_PATH)
      rescue Errno::ENOENT
        {}
      end

      # Load manifest entries from patterns section of config
      # @return [Array<Hash>] Array of pattern entries with :path and :strategy
      def load_manifest
        config = kettle_config
        patterns = config["patterns"] || []
        patterns.map { |entry| build_config_entry(entry["path"], entry) }
      rescue Errno::ENOENT
        []
      end
    end
  end
end
