# frozen_string_literal: true

require "fileutils"
require "shellwords"
require "open3"
require "optparse"

require_relative "config_seeder"

module Kettle
  module Jem
    # SetupCLI bootstraps a host gem repository to use kettle-jem tooling.
    # It performs prechecks, syncs development dependencies, ensures bin/setup and
    # Rakefile templates, runs setup tasks, and invokes kettle:jem:install.
    #
    # Usage:
    #   Kettle::Jem::SetupCLI.new(ARGV).run!
    #
    # Options are parsed from argv and passed through to the rake task as
    # key=value pairs (e.g., --force => force=true).
    class SetupCLI
      BUNDLED_GEMFILE_ENV = "BUNDLE_GEMFILE".freeze
      TEMPLATE_CONFIG_RELATIVE_PATH = ".kettle-jem.yml".freeze
      BOOTSTRAP_GEMFILE_EVAL_PATHS = ["gemfiles/modular/templating.gemfile"].freeze
      BOOTSTRAP_MODULAR_GEMFILES = %w[templating.gemfile templating_local.gemfile].freeze
      BOOTSTRAP_FORCEABLE_MODULAR_GEMFILES = %w[templating.gemfile].freeze

      # @param argv [Array<String>] CLI arguments
      def initialize(argv)
        @argv = argv
        @original_argv = argv.dup
        @passthrough = []
        @options = {}
        parse!
      end

      # Execute the full setup workflow.
      # @return [void]
      def run!
        say("Starting kettle-jem setup…", verbose_only: true)
        debug_bundler_env({}, "kettle-jem startup")
        return run_bundled_phase! if bundled_execution_context?

        run_bootstrap_phase!
      end

      def run_bootstrap_phase!
        prechecks!
        debug_git_status("prechecks!")
        prereq_result = if template_config_present?
          :present
        else
          ensure_template_config_bootstrap!
        end
        return if prereq_result == :bootstrap_only

        ensure_gemfile_from_example!(eval_paths: BOOTSTRAP_GEMFILE_EVAL_PATHS)
        debug_git_status("ensure_gemfile_from_example! (bootstrap)")
        ensure_bootstrap_modular_gemfiles!
        debug_git_status("ensure_bootstrap_modular_gemfiles!")
        ensure_bin_setup!
        debug_git_status("ensure_bin_setup!")
        run_bin_setup!
        debug_git_status("run_bin_setup!")
        run_bundle_binstubs!
        debug_git_status("run_bundle_binstubs!")
        handoff_to_bundled_phase!
      end

      def run_bundled_phase!
        ensure_project_files!
        debug_git_status("ensure_project_files! (bundled)")
        load_bundled_runtime!
        debug_git_status("load_bundled_runtime!")
        ensure_dev_deps!
        debug_git_status("ensure_dev_deps!")
        ensure_gemfile_from_example!
        debug_git_status("ensure_gemfile_from_example!")
        ensure_modular_gemfiles!
        debug_git_status("ensure_modular_gemfiles!")
        ensure_rakefile!
        debug_git_status("ensure_rakefile!")
        ensure_bin_setup!
        debug_git_status("ensure_bin_setup! (bundled)")
        run_bin_setup!
        debug_git_status("run_bin_setup!")
        run_bundle_binstubs!
        debug_git_status("run_bundle_binstubs!")
        run_kettle_install!
        debug_git_status("run_kettle_install!")
        commit_bootstrap_changes!
        say("kettle-jem setup complete.", verbose_only: true)
      end

      private

      def template_config_present?
        File.exist?(File.join(Dir.pwd, TEMPLATE_CONFIG_RELATIVE_PATH))
      end

      def bundled_execution_context?
        env_val = ENV[BUNDLED_GEMFILE_ENV].to_s.strip
        !env_val.empty?
      end

      def load_bundled_runtime!
        return if defined?(Kettle::Dev::ExitAdapter) && defined?(Kettle::Jem::TemplateHelpers)

        require "kettle/jem"
      end

      def debug(msg)
        return if ENV.fetch("DEBUG", "false").casecmp("true").nonzero?

        $stderr.puts("[kettle-jem] DEBUG: #{msg}")
      end

      # Attempt to derive a funding organization from the git remote 'origin' when
      # not explicitly provided via env or .opencollective.yml.
      # This is a soft helper that only sets ENV["FUNDING_ORG"] if a plausible
      # GitHub org can be parsed from the origin URL.
      # @return [void]
      def derive_funding_org_from_git_if_missing!
        # Respect explicit bypass
        env_val = ENV["FUNDING_ORG"]
        return if env_val && env_val.to_s.strip.casecmp("false").zero?

        # If already provided via env, do nothing
        return if ENV["FUNDING_ORG"].to_s.strip != ""
        return if ENV["OPENCOLLECTIVE_HANDLE"].to_s.strip != ""

        # If project provides an .opencollective.yml with org, do nothing
        begin
          oc_path = File.join(Dir.pwd, ".opencollective.yml")
          if File.file?(oc_path)
            txt = File.read(oc_path)
            return if /\borg:\s*([\w\-]+)/i.match?(txt)
          end
        rescue StandardError => e
          debug("Reading .opencollective.yml failed: #{e.class}: #{e.message}")
        end

        # Attempt to get origin URL and parse GitHub org
        begin
          ga = Kettle::Dev::GitAdapter.new
          origin_url = nil
          origin_url = ga.remote_url("origin") if ga.respond_to?(:remote_url)
          if origin_url.nil? && ga.respond_to?(:remotes_with_urls)
            begin
              urls = ga.remotes_with_urls
              origin_url = urls["origin"] if urls
            rescue StandardError => e
              # graceful fallback if adapter backend errs; keep silent behavior
              debug("remotes_with_urls failed: #{e.class}: #{e.message}")
            end
          end
          origin_url = origin_url.to_s.strip
          if (m = origin_url.match(%r{github\.com[/:]([^/]+)/}i))
            org = m[1].to_s
            if !org.empty?
              ENV["FUNDING_ORG"] = org
              debug("Derived FUNDING_ORG from git origin: #{org}")
            end
          end
        rescue StandardError => e
          # Be silent; this is a best-effort and shouldn't fail setup
          debug("Could not derive funding org from git: #{e.class}: #{e.message}")
        end
      end

      def parse!
        parser = OptionParser.new do |opts|
          opts.banner = "Usage: kettle-jem [options]"
          opts.on("--allowed=VAL", "Pass through to kettle:jem:install") { |v| @passthrough << "allowed=#{v}" }
          opts.on("--force", "Pass through to kettle:jem:install") do
            # Ensure in-process helpers (TemplateHelpers.ask) also see force mode
            @force = true
            ENV["force"] = "true"
            @passthrough << "force=true"
          end
          opts.on("--quiet", "Run quieter setup commands and pass --quiet through to downstream steps") do
            @quiet = true
            @passthrough << "--quiet"
          end
          opts.on("--hook_templates=VAL", "Pass through to kettle:jem:install") { |v| @passthrough << "hook_templates=#{v}" }
          opts.on("--only=VAL", "Pass through to kettle:jem:install") { |v| @passthrough << "only=#{v}" }
          opts.on("--include=VAL", "Pass through to kettle:jem:install") { |v| @passthrough << "include=#{v}" }
          opts.on("--failure-mode=VAL", "Merge failure handling: error (default) or rescue") do |v|
            ENV["FAILURE_MODE"] = v
            @passthrough << "FAILURE_MODE=#{v}"
          end
          opts.on("-h", "--help", "Show help") do
            puts opts
            exit_with_status(0)
          end
        end
        begin
          parser.parse!(@argv)
        rescue OptionParser::ParseError => e
          warn("[kettle-jem] #{e.class}: #{e.message}")
          puts parser
          exit_with_status(2)
        end
        @passthrough.concat(@argv)
      end

      def say(msg, verbose_only: false)
        return if verbose_only && quiet?

        puts "[kettle-jem] #{msg}"
      end

      def quiet?
        @quiet || Array(@passthrough).include?("--quiet") || Array(@original_argv).include?("--quiet")
      end

      def force?
        env_force = ENV["force"].to_s.strip
        @force || env_force.casecmp("true").zero? || Array(@passthrough).include?("force=true") || Array(@original_argv).include?("--force")
      end

      def abort!(msg)
        if defined?(Kettle::Dev::ExitAdapter)
          Kettle::Dev::ExitAdapter.abort("[kettle-jem] ERROR: #{msg}")
        else
          Kernel.abort("[kettle-jem] ERROR: #{msg}")
        end
      end

      def exit_with_status(status)
        if defined?(Kettle::Dev::ExitAdapter)
          Kettle::Dev::ExitAdapter.exit(status)
        else
          exit(status)
        end
      end

      # Environment variables that affect bundler resolution / Gemfile evaluation.
      # Logged before subprocess execution when DEBUG=true.
      BUNDLER_ENV_KEYS = %w[
        KETTLE_RB_DEV
        BUNDLE_GEMFILE
        BUNDLE_PATH
        BUNDLE_WITHOUT
        BUNDLE_WITH
        BUNDLE_FROZEN
        GEM_HOME
        GEM_PATH
        RUBYOPT
        RUBYLIB
      ].freeze

      def sh!(cmd, env: {}, suppress_output: false, suppress_command_log: false)
        say("exec: #{cmd}") unless suppress_command_log
        debug_bundler_env(env, cmd)
        stdout_str, stderr_str, status = Open3.capture3(env, cmd)
        if status.success?
          unless suppress_output
            $stdout.print(stdout_str) unless stdout_str.empty?
            $stderr.print(stderr_str) unless stderr_str.empty?
          end
          return
        end

        say("exec: #{cmd}") if suppress_command_log
        $stdout.print(stdout_str) unless stdout_str.empty?
        $stderr.print(stderr_str) unless stderr_str.empty?
        abort!("Command failed: #{cmd}") unless status.success?
      end

      # Log environment variables relevant to bundler when DEBUG=true.
      # Shows both the explicit env hash passed to the subprocess and
      # the inherited process ENV values, so we can trace what the
      # subprocess will actually see.
      def debug_bundler_env(explicit_env, cmd)
        debug("subprocess env for: #{cmd}")
        unless explicit_env.empty?
          debug("  explicit env overrides: #{explicit_env.inspect}")
        end
        BUNDLER_ENV_KEYS.each do |key|
          val = explicit_env.key?(key) ? explicit_env[key] : ENV[key]
          source = explicit_env.key?(key) ? "(explicit)" : "(inherited)"
          debug("  #{key}=#{val.inspect} #{source}")
        end
        debug("  PWD=#{Dir.pwd.inspect}")
      end

      # Log git status after a step completes. When DEBUG=true, shows
      # the porcelain output so we can identify exactly which step
      # first dirties the working tree.
      def debug_git_status(step_label)
        porcelain, _err, _st = Open3.capture3("git status --porcelain")
        if porcelain.strip.empty?
          debug("git status after #{step_label}: clean")
        else
          debug("git status after #{step_label}: DIRTY")
          porcelain.each_line { |l| debug("  #{l.rstrip}") }
        end
      end

      # 1. Prechecks
      def prechecks!
        abort!("Not inside a git repository (missing .git).") unless Dir.exist?(".git")

        # Ensure clean working tree — ALWAYS required, --force does NOT bypass this
        begin
          if defined?(Kettle::Dev::GitAdapter)
            dirty = !Kettle::Dev::GitAdapter.new.clean?
          else
            stdout, _stderr, _status = Open3.capture3("git status --porcelain")
            dirty = !stdout.strip.empty?
          end
          if dirty
            # Always show what's dirty (to stderr), even without DEBUG, so users can diagnose
            porcelain, _err, _st = Open3.capture3("git status --porcelain")
            $stderr.puts("[kettle-jem] Dirty files detected by prechecks!:")
            porcelain.each_line { |l| $stderr.puts("  #{l.rstrip}") }
            abort!("Git working tree is not clean. Please commit/stash changes and try again.")
          end
        rescue StandardError
          stdout, _stderr, _status = Open3.capture3("git status --porcelain")
          unless stdout.strip.empty?
            $stderr.puts("[kettle-jem] Dirty files detected by prechecks! (fallback):")
            stdout.each_line { |l| $stderr.puts("  #{l.rstrip}") }
            abort!("Git working tree is not clean. Please commit/stash changes and try again.")
          end
        end

        ensure_project_files!

        # Seed FUNDING_ORG from git remote origin org when not provided elsewhere
        derive_funding_org_from_git_if_missing!
      end

      def ensure_project_files!
        gemspecs = Dir["*.gemspec"]
        abort!("No gemspec found in current directory.") if gemspecs.empty?
        @gemspec_path = gemspecs.first

        abort!("No Gemfile found; bundler is required.") unless File.exist?("Gemfile")
      end

      # 3. Sync dev dependencies from this gem's example gemspec into target gemspec
      def ensure_dev_deps!
        source_example = installed_path("gem.gemspec.example")
        abort!("Internal error: gem.gemspec.example not found within the installed gem.") unless source_example && File.exist?(source_example)

        example = File.read(source_example)
        doc = Token::Resolver::Document.new(example)
        resolver = Token::Resolver::Resolve.new(on_missing: :keep)
        example = resolver.resolve(doc, {"KJ|KETTLE_DEV_GEM" => "kettle-dev"})

        wanted_lines = example.each_line.map(&:rstrip).select { |line|
          line =~ /add_development_dependency\s*\(?/ && !line.strip.start_with?("#")
        }
        return if wanted_lines.empty?

        target = File.read(@gemspec_path)

        # Build gem=>desired line map
        wanted = {}
        wanted_lines.each do |line|
          if (m = line.match(/add_development_dependency\s*\(?\s*["']([^"']+)["']/))
            wanted[m[1]] = line
          end
        end

        # Use Prism-based gemspec edit to ensure development dependencies match
        begin
          modified = Kettle::Jem::PrismGemspec.ensure_development_dependencies(target, wanted)
          # Check if any actual changes were made to development dependency declarations.
          # Extract gem name + version args from dependency lines to compare semantically,
          # ignoring whitespace, comments, and formatting differences.
          extract_deps = lambda do |content|
            content.to_s.lines
              .select { |ln| ln =~ /add_development_dependency\s*\(?/ }
              .reject { |ln| ln.strip.start_with?("#") }
              .filter_map { |ln|
                if (m = ln.match(/add_development_dependency\s*\(?\s*(.+?)\s*\)?\s*(#.*)?$/))
                  m[1].strip
                end
              }
              .sort
          end
          target_deps = extract_deps.call(target)
          modified_deps = extract_deps.call(modified)
          if modified_deps != target_deps
            File.write(@gemspec_path, modified)
            say("Updated development dependencies in #{@gemspec_path}.", verbose_only: true)
          else
            say("Development dependencies already up to date.", verbose_only: true)
          end
        rescue StandardError => e
          Kettle::Dev.debug_error(e, __method__)
          # Fall back to previous behavior: write nothing and report up-to-date
          say("Development dependencies already up to date.", verbose_only: true)
        end
      end

      def ensure_template_config_bootstrap!
        source = installed_path(TEMPLATE_CONFIG_RELATIVE_PATH)
        abort!("Internal error: #{TEMPLATE_CONFIG_RELATIVE_PATH}.example not found within the installed gem.") unless source && File.exist?(source)

        content = seed_bootstrap_template_config(File.read(source))
        File.write(TEMPLATE_CONFIG_RELATIVE_PATH, ensure_trailing_newline(content))
        say("Wrote #{File.join(Dir.pwd, TEMPLATE_CONFIG_RELATIVE_PATH)}.")
        say("Review that file, fill in any missing token values, commit it, then re-run kettle-jem.")
        :bootstrap_only
      end

      def seed_bootstrap_template_config(content)
        Kettle::Jem::ConfigSeeder.seed_kettle_config_content(content, bootstrap_template_config_values)
      end

      def bootstrap_template_config_values
        author_name = preferred_bootstrap_env("KJ_AUTHOR_NAME") || first_gemspec_array_value("authors")
        author_email = preferred_bootstrap_env("KJ_AUTHOR_EMAIL") || first_gemspec_array_value("email")
        author_domain = preferred_bootstrap_env("KJ_AUTHOR_DOMAIN") || author_email.to_s.split("@", 2)[1]
        given_names, family_names = split_author_name(author_name)

        {
          "forge" => {
            "gh_user" => preferred_bootstrap_env("KJ_GH_USER"),
            "gl_user" => preferred_bootstrap_env("KJ_GL_USER"),
            "cb_user" => preferred_bootstrap_env("KJ_CB_USER"),
            "sh_user" => preferred_bootstrap_env("KJ_SH_USER"),
          }.reject { |_, value| value.to_s.strip.empty? },
          "author" => {
            "name" => author_name,
            "given_names" => preferred_bootstrap_env("KJ_AUTHOR_GIVEN_NAMES") || given_names,
            "family_names" => preferred_bootstrap_env("KJ_AUTHOR_FAMILY_NAMES") || family_names,
            "email" => author_email,
            "domain" => author_domain,
            "orcid" => preferred_bootstrap_env("KJ_AUTHOR_ORCID"),
          }.reject { |_, value| value.to_s.strip.empty? },
          "funding" => {
            "patreon" => preferred_bootstrap_env("KJ_FUNDING_PATREON"),
            "kofi" => preferred_bootstrap_env("KJ_FUNDING_KOFI"),
            "paypal" => preferred_bootstrap_env("KJ_FUNDING_PAYPAL"),
            "buymeacoffee" => preferred_bootstrap_env("KJ_FUNDING_BUYMEACOFFEE"),
            "polar" => preferred_bootstrap_env("KJ_FUNDING_POLAR"),
            "liberapay" => preferred_bootstrap_env("KJ_FUNDING_LIBERAPAY"),
            "issuehunt" => preferred_bootstrap_env("KJ_FUNDING_ISSUEHUNT"),
          }.reject { |_, value| value.to_s.strip.empty? },
          "social" => {
            "mastodon" => preferred_bootstrap_env("KJ_SOCIAL_MASTODON"),
            "bluesky" => preferred_bootstrap_env("KJ_SOCIAL_BLUESKY"),
            "linktree" => preferred_bootstrap_env("KJ_SOCIAL_LINKTREE"),
            "devto" => preferred_bootstrap_env("KJ_SOCIAL_DEVTO"),
          }.reject { |_, value| value.to_s.strip.empty? },
        }.reject { |_, values| values.empty? }
      end

      def preferred_bootstrap_env(key)
        value = ENV[key].to_s
        return nil if value.strip.empty?

        value
      end

      def first_gemspec_array_value(name)
        return nil unless @gemspec_path && File.exist?(@gemspec_path)

        content = File.read(@gemspec_path)
        match = content.match(/spec\.(?:#{Regexp.escape(name)})\s*=\s*\[(.*?)\]/m)
        return nil unless match

        values = match[1].scan(/["']([^"']+)["']/).flatten
        values.first
      rescue StandardError => e
        debug("Could not seed #{name} from #{@gemspec_path}: #{e.class}: #{e.message}")
        nil
      end

      def split_author_name(author_name)
        parts = author_name.to_s.strip.split(/\s+/)
        return [nil, nil] if parts.empty?
        return [parts.first, nil] if parts.length == 1

        [parts[0..-2].join(" "), parts[-1]]
      end

      def ensure_trailing_newline(text)
        str = text.to_s
        return str if str.empty? || str.end_with?("\n")

        str + "\n"
      end

      # 4. Ensure bin/setup present (copy from gem if missing, or overwrite when forced)
      def ensure_bin_setup!
        target = File.join("bin", "setup")
        existed_before = File.exist?(target)
        if existed_before && !force?
          return say("bin/setup present.", verbose_only: true)
        end

        source = installed_path(File.join("bin", "setup"))
        abort!("Internal error: source bin/setup not found within installed gem.") unless source && File.exist?(source)
        FileUtils.mkdir_p("bin")
        FileUtils.cp(source, target)
        FileUtils.chmod("+x", target)
        say(existed_before ? "Overwrote bin/setup." : "Copied bin/setup.", verbose_only: true)
      end

      # 3b. Ensure Gemfile contains required lines from example without duplicating directives
      #    - Copies source, git_source, gemspec, and eval_gemfile lines that are missing
      #    - Idempotent (running multiple times does not duplicate entries)
      def ensure_gemfile_from_example!(eval_paths: nil)
        source_path = installed_path("Gemfile.example")
        abort!("Internal error: Gemfile.example not found within installed gem.") unless source_path && File.exist?(source_path)

        example = File.read(source_path)
        target_path = "Gemfile"
        target = File.exist?(target_path) ? File.read(target_path) : ""

        # Extract interesting lines from example
        ex_sources = []
        ex_git_sources = [] # names (e.g., :github)
        ex_git_source_lines = {}
        ex_has_gemspec = false
        ex_eval_paths = []

        example.each_line do |ln|
          s = ln.strip
          next if s.empty?

          if s.start_with?("source ")
            ex_sources << ln.rstrip
          elsif (m = s.match(/^git_source\(\s*:(\w+)\s*\)/))
            name = m[1]
            ex_git_sources << name
            ex_git_source_lines[name] = ln.rstrip
          elsif s.start_with?("gemspec")
            ex_has_gemspec = true
          elsif (m = s.match(%r{\Aeval_gemfile\s+["']([^"']+)["']}))
            path = m[1]
            ex_eval_paths << path if eval_paths.nil? || eval_paths.include?(path)
          end
        end

        # Scan target for presence
        tg_sources = target.each_line.map(&:rstrip).select { |l| l.strip.start_with?("source ") }
        tg_git_sources = {}
        target.each_line do |ln|
          if (m = ln.strip.match(/^git_source\(\s*:(\w+)\s*\)/))
            tg_git_sources[m[1]] = true
          end
        end
        tg_has_gemspec = !!target.each_line.find { |l| l.strip.start_with?("gemspec") }
        tg_eval_paths = target.each_line.map do |ln|
          if (m = ln.strip.match(%r{\Aeval_gemfile\s+["']([^"']+)["']}))
            m[1]
          end
        end.compact

        additions = []
        # Add missing sources (exact line match)
        ex_sources.each do |src_line|
          additions << src_line unless tg_sources.include?(src_line)
        end
        # Add missing git_source by name
        ex_git_sources.each do |name|
          additions << ex_git_source_lines[name] unless tg_git_sources[name]
        end
        # Add gemspec if example has it and target lacks it
        additions << "gemspec" if ex_has_gemspec && !tg_has_gemspec
        # Add missing eval_gemfile paths (recreate the exact example line when possible)
        ex_eval_paths.each do |path|
          next if tg_eval_paths.include?(path)

          additions << "eval_gemfile \"#{path}\""
        end

        return say("Gemfile already contains required entries from example.", verbose_only: true) if additions.empty?

        # Ensure file ends with a newline
        target << "\n" unless target.end_with?("\n") || target.empty?
        new_content = target + additions.join("\n") + "\n"
        File.write(target_path, new_content)
        say("Updated Gemfile with entries from Gemfile.example (added #{additions.size}).", verbose_only: true)
      end

      def ensure_bootstrap_modular_gemfiles!
        BOOTSTRAP_MODULAR_GEMFILES.each do |filename|
          rel = File.join("gemfiles", "modular", filename)
          source = installed_path(rel)
          abort!("Internal error: #{rel}.example not found within the installed gem.") unless source && File.exist?(source)

          dest = File.join("gemfiles", "modular", filename)
          existed_before = File.exist?(dest)
          overwrite = existed_before && force? && BOOTSTRAP_FORCEABLE_MODULAR_GEMFILES.include?(filename)
          next if existed_before && !overwrite

          FileUtils.mkdir_p(File.dirname(dest))
          FileUtils.cp(source, dest)
          say(existed_before ? "Overwrote #{dest}." : "Copied #{dest}.", verbose_only: true)
        end
      end

      # 3c. Ensure gemfiles/modular/* are present (copied like template task)
      def ensure_modular_gemfiles!
        helpers = Kettle::Jem::TemplateHelpers
        project_root = helpers.project_root
        # Gather metadata for token replacement and style.gemfile adjustments
        meta = begin
          helpers.gemspec_metadata(project_root)
        rescue StandardError
          {}
        end
        min_ruby = meta[:min_ruby]
        gem_name = meta[:gem_name]
        forge_org = meta[:forge_org] || meta[:gh_org]
        funding_org = helpers.opencollective_disabled? ? nil : (meta[:funding_org] || forge_org)
        namespace = meta[:namespace]
        namespace_shield = meta[:namespace_shield]
        gem_shield = meta[:gem_shield]

        configure_template_tokens!(
          helpers: helpers,
          forge_org: forge_org,
          gem_name: gem_name,
          namespace: namespace,
          namespace_shield: namespace_shield,
          gem_shield: gem_shield,
          funding_org: funding_org,
          min_ruby: min_ruby,
        )

        Kettle::Jem::ModularGemfiles.sync!(
          helpers: helpers,
          project_root: project_root,
          min_ruby: min_ruby,
          gem_name: gem_name,
        )
      end

      def configure_template_tokens!(helpers:, forge_org:, gem_name:, namespace:, namespace_shield:, gem_shield:, funding_org:, min_ruby:)
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
        helpers.clear_tokens! if helpers.respond_to?(:clear_tokens!)
        debug("Token configuration failed: #{e.class}: #{e.message}")
      end

      def ensure_template_prerequisites!
        helpers = Kettle::Jem::TemplateHelpers
        meta = begin
          helpers.gemspec_metadata(helpers.project_root)
        rescue StandardError
          {}
        end

        Kettle::Jem::Tasks::TemplateTask.ensure_template_prerequisites!(
          helpers: helpers,
          project_root: helpers.project_root,
          template_root: helpers.template_root,
          meta: meta,
        )
      rescue Kettle::Dev::Error => e
        abort!(e.message)
      end

      # 5. Ensure Rakefile is present and merged with example
      def ensure_rakefile!
        source = installed_path("Rakefile.example")
        abort!("Internal error: Rakefile.example not found within installed gem.") unless source && File.exist?(source)

        helpers = Kettle::Jem::TemplateHelpers
        meta = begin
          helpers.gemspec_metadata(helpers.project_root)
        rescue StandardError
          {}
        end
        forge_org = meta[:forge_org] || meta[:gh_org]
        funding_org = helpers.opencollective_disabled? ? nil : (meta[:funding_org] || forge_org)
        configure_template_tokens!(
          helpers: helpers,
          forge_org: forge_org,
          gem_name: meta[:gem_name],
          namespace: meta[:namespace],
          namespace_shield: meta[:namespace_shield],
          gem_shield: meta[:gem_shield],
          funding_org: funding_org,
          min_ruby: meta[:min_ruby],
        )

        content = helpers.read_template(source)
        if File.exist?("Rakefile")
          begin
            existing = File.read("Rakefile")
            merged = Kettle::Jem::SourceMerger.apply(
              strategy: :merge,
              src: content,
              dest: existing,
              path: "Rakefile",
            )
            content = merged if merged.is_a?(String) && !merged.empty?
            say("Merged Rakefile with kettle-jem Rakefile.example.", verbose_only: true)
          rescue StandardError => e
            if Kettle::Jem::Tasks::TemplateTask.failure_mode == :rescue
              Kettle::Dev.debug_error(e, __method__)
              say("Merging Rakefile with kettle-jem Rakefile.example (merge failed, using template).")
            else
              raise Kettle::Dev::Error, "Merge failed for Rakefile: #{e.class}: #{e.message}"
            end
          end
        else
          say("Creating Rakefile from kettle-jem Rakefile.example.", verbose_only: true)
        end
        File.write("Rakefile", content)
      end

      # 6. Run bin/setup
      def run_bin_setup!
        cmd = [File.join("bin", "setup")]
        cmd << "--quiet" if quiet?
        sh!(Shellwords.join(cmd), suppress_command_log: quiet?)
      end

      # 7. Run bundle binstubs --all
      def run_bundle_binstubs!
        sh!("bundle binstubs --all", suppress_output: quiet?, suppress_command_log: quiet?)
      end

      def handoff_to_bundled_phase!
        cmd = ["bundle", "exec", "kettle-jem"] + @original_argv
        sh!(Shellwords.join(cmd), suppress_command_log: quiet?)
      end

      # 8. Commit template bootstrap changes if any
      def commit_bootstrap_changes!
        dirty = begin
          if defined?(Kettle::Dev::GitAdapter)
            !Kettle::Dev::GitAdapter.new.clean?
          else
            out, _st = Open3.capture2("git", "status", "--porcelain")
            !out.strip.empty?
          end
        rescue StandardError
          out, _st = Open3.capture2("git", "status", "--porcelain")
          !out.strip.empty?
        end
        unless dirty
          say("No changes to commit from template bootstrap.", verbose_only: true)
          return
        end
        sh!(Shellwords.join(["git", "add", "-A"]), suppress_output: quiet?, suppress_command_log: quiet?)
        msg = "🎨 Template bootstrap by kettle-jem v#{Kettle::Jem::Version::VERSION}"
        sh!(Shellwords.join(["git", "commit", "-m", msg]), suppress_output: quiet?, suppress_command_log: quiet?)
        say("Committed template bootstrap changes.", verbose_only: true)
      end

      # 9. Invoke rake install task with passthrough
      def run_kettle_install!
        cmd = ["bin/rake", "kettle:jem:install"] + Array(@passthrough)
        sh!(Shellwords.join(cmd), suppress_command_log: quiet?)
      end

      # Resolve a path to a templated asset shipped within the installed gem or repo checkout.
      # Template sources MUST come from template/ only; the gem root is never a template source.
      # @param rel [String]
      # @return [String, nil]
      def installed_path(rel)
        roots = []
        if defined?(Gem) && (spec = Gem.loaded_specs["kettle-jem"])
          roots << spec.full_gem_path
        end
        roots << File.expand_path(File.join(__dir__, "..", "..", "..")) # lib/kettle/jem/ -> project root

        roots.each do |root|
          template_path = prefer_example(File.join(root, "template", rel))
          return template_path if File.exist?(template_path)
        end

        nil
      end

      def prefer_example(path)
        return path if path.end_with?(".example")

        example = path + ".example"
        File.exist?(example) ? example : path
      end
    end
  end
end
