# frozen_string_literal: true

require "fileutils"
require "shellwords"
require "open3"
require "optparse"
require "rubygems"

module Kettle
  module Jem
    autoload :ConfigSeeder, File.expand_path("config_seeder", __dir__)
    autoload :PrismGemfile, File.expand_path("prism_gemfile", __dir__)
    autoload :PrismUtils, File.expand_path("prism_utils", __dir__)
    autoload :Signatures, File.expand_path("signatures", __dir__)

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
      BUNDLED_GEMFILE_ENV = "BUNDLE_GEMFILE"
      TEMPLATE_CONFIG_RELATIVE_PATH = ".kettle-jem.yml"
      BOOTSTRAP_GEMFILE_EVAL_PATHS = ["gemfiles/modular/templating.gemfile"].freeze
      BOOTSTRAP_MODULAR_GEMFILES = %w[templating.gemfile templating_local.gemfile].freeze
      BOOTSTRAP_FORCEABLE_MODULAR_GEMFILES = %w[templating.gemfile templating_local.gemfile].freeze

      # Gems added by `bundle gem` scaffold that are covered by the kettle-jem template.
      # These are removed from the Gemfile during templating because they are either:
      #   - moved to the gemspec as development dependencies (rake, rspec)
      #   - managed by a modular gemfile (rubocop via style.gemfile/standard)
      # irb is intentionally excluded; it stays in the Gemfile via the template's own declaration.
      SCAFFOLD_DEFAULT_GEMS = %w[rake rspec rubocop].freeze

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

        run_preflight_templating!
        debug_git_status("run_preflight_templating!")
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
        ensure_rakefile!
        debug_git_status("ensure_rakefile!")
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

      # ── Pre-flight templating ─────────────────────────────────────────
      # Performs proper AST-based merging of files that only need pure-Ruby
      # merge gems (prism-merge, psych-merge, etc.) BEFORE `bundle install`.
      # This eliminates the bootstrap hacks that previously used regex/string
      # manipulation to make the target's gemspec and Gemfile valid enough
      # for bundler to resolve.
      #
      # All merge gems are available because they are runtime dependencies
      # of kettle-jem itself (installed alongside the gem).

      def run_preflight_templating!
        helpers = Kettle::Jem::TemplateHelpers
        meta = begin
          helpers.gemspec_metadata(Dir.pwd)
        rescue StandardError => e
          debug("Could not read gemspec metadata for pre-flight: #{e.class}: #{e.message}")
          {}
        end

        gem_name = meta[:gem_name] || gemspec_string_value("name")

        configure_preflight_tokens!(helpers, meta)

        preflight_merge_gemspec!(helpers, meta, gem_name)
        preflight_merge_gemfile!(helpers, gem_name)
        preflight_merge_modular_gemfiles!(helpers, gem_name)
      end

      def configure_preflight_tokens!(helpers, meta)
        forge_org = meta[:forge_org] || meta[:gh_org]
        return unless forge_org && meta[:gem_name]

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
      rescue StandardError => e
        debug("Token configuration failed (pre-flight will use raw templates): #{e.class}: #{e.message}")
      end

      def preflight_merge_gemspec!(helpers, meta, gem_name)
        source = installed_path("gem.gemspec")
        return unless source && File.exist?(source)
        return unless @gemspec_path && File.exist?(@gemspec_path)

        template_content = helpers.read_template(source)

        # Replace gemspec identity fields from destination metadata so the
        # merged result keeps the target gem's name, authors, description, etc.
        if meta && !meta.empty?
          repl = {}
          repl[:name] = gem_name.to_s if gem_name && !gem_name.to_s.empty?
          repl[:authors] = Array(meta[:authors]).map(&:to_s) if meta[:authors]
          repl[:email] = Array(meta[:email]).map(&:to_s) if meta[:email]
          repl[:summary] = meta[:summary].to_s if meta[:summary] && !meta[:summary].to_s.strip.empty?
          repl[:description] = meta[:description].to_s if meta[:description] && !meta[:description].to_s.strip.empty?
          repl[:licenses] = helpers.resolved_licenses
          repl[:required_ruby_version] = meta[:required_ruby_version].to_s if meta[:required_ruby_version]
          repl[:require_paths] = Array(meta[:require_paths]).map(&:to_s) if meta[:require_paths]
          repl[:bindir] = meta[:bindir].to_s if meta[:bindir]
          repl[:executables] = Array(meta[:executables]).map(&:to_s) if meta[:executables]

          template_content = Kettle::Jem::PrismGemspec.replace_gemspec_fields(template_content, repl)
        end

        # Remove self-dependency (the gem can't depend on itself)
        if gem_name && !gem_name.to_s.empty?
          template_content = Kettle::Jem::PrismGemspec.remove_spec_dependency(template_content, gem_name)
        end

        gemspec_context = if meta[:min_ruby] && meta[:entrypoint_require] && meta[:namespace]
          {
            min_ruby: meta[:min_ruby],
            entrypoint_require: meta[:entrypoint_require],
            namespace: meta[:namespace],
          }
        end

        merged = helpers.apply_strategy(template_content, @gemspec_path, context: gemspec_context)
        merged = template_content unless merged.is_a?(String) && !merged.empty?

        existing = File.read(@gemspec_path)
        if merged != existing
          File.write(@gemspec_path, merged)
          say("Pre-flight: merged #{@gemspec_path}.", verbose_only: true)
        else
          say("Pre-flight: gemspec already up to date.", verbose_only: true)
        end
      rescue StandardError => e
        Kettle::Dev.debug_error(e, __method__)
        say("Pre-flight: gemspec merge failed, falling back to dev-dep sync.", verbose_only: true)
        ensure_dev_deps!
      end

      def preflight_merge_gemfile!(helpers, gem_name)
        source = installed_path("Gemfile")
        return unless source && File.exist?(source)
        return unless File.exist?("Gemfile")

        template_content = helpers.read_template(source)
        target_content = File.read("Gemfile")

        merged = Kettle::Jem::PrismGemfile.merge_gem_calls(template_content, target_content)
        merged = remove_scaffold_default_gems(merged)
        merged = remove_conflicting_gems(merged)

        if merged != target_content
          File.write("Gemfile", ensure_trailing_newline(merged))
          say("Pre-flight: merged Gemfile.", verbose_only: true)
        else
          say("Pre-flight: Gemfile already up to date.", verbose_only: true)
        end
      rescue StandardError => e
        Kettle::Dev.debug_error(e, __method__)
        say("Pre-flight: Gemfile merge failed, falling back to bootstrap eval.", verbose_only: true)
        ensure_bootstrap_eval_gemfile!
      end

      def preflight_merge_modular_gemfiles!(helpers, gem_name)
        BOOTSTRAP_MODULAR_GEMFILES.each do |filename|
          rel = File.join("gemfiles", "modular", filename)
          source = installed_path(rel)
          next unless source && File.exist?(source)

          dest = File.join("gemfiles", "modular", filename)
          FileUtils.mkdir_p(File.dirname(dest))

          template_content = helpers.read_template(source)
          template_content = strip_self_from_templating_local(template_content) if filename == "templating_local.gemfile"
          template_content = strip_self_from_templating_gemfile(template_content) if filename == "templating.gemfile"

          if File.exist?(dest) && !force?
            existing = File.read(dest)
            # Merge using prism-merge for proper AST-based merge
            begin
              merged = Kettle::Jem::SourceMerger.apply(
                strategy: :merge,
                src: template_content,
                dest: existing,
                path: rel,
                force: force?,
              )
              merged = template_content unless merged.is_a?(String) && !merged.empty?
            rescue StandardError
              merged = template_content
            end

            # Always sanitize self-references from merge result
            merged = strip_self_from_templating_local(merged) if filename == "templating_local.gemfile"
            merged = strip_self_from_templating_gemfile(merged) if filename == "templating.gemfile"

            if merged != existing
              File.write(dest, ensure_trailing_newline(merged))
              say("Pre-flight: merged #{dest}.", verbose_only: true)
            end
          else
            File.write(dest, ensure_trailing_newline(template_content))
            say("Pre-flight: wrote #{dest}.", verbose_only: true)
          end
        end
      rescue StandardError => e
        Kettle::Dev.debug_error(e, __method__)
        say("Pre-flight: modular gemfile merge failed, falling back to bootstrap copy.", verbose_only: true)
        ensure_bootstrap_modular_gemfiles!
      end

      def debug(msg)
        return if ENV.fetch("KETTLE_DEV_DEBUG", "false").casecmp("true").nonzero?

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
          opts.on("--allowed=VAL", "Pass through to kettle:jem:install (default: true)") do |v|
            ENV["allowed"] = v
            @passthrough << "allowed=#{v}"
          end
          opts.on("--interactive", "Enable interactive prompts (default is non-interactive / force)") do
            @force = false
            ENV["force"] = "false"
            @passthrough << "force=false"
          end
          opts.on("--verbose", "Show detailed output (default is quiet)") do
            @verbose = true
            @quiet = false
            ENV["KETTLE_JEM_QUIET"] = "false"
            ENV["KETTLE_JEM_VERBOSE"] = "true"
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
        return false if verbose?

        # Default is quiet (true) unless --verbose was passed
        quiet_explicit = @quiet
        quiet_explicit = true if quiet_explicit.nil?
        quiet_explicit || Array(@passthrough).include?("--quiet") || Array(@original_argv).include?("--quiet")
      end

      def verbose?
        @verbose || Array(@passthrough).include?("--verbose") || Array(@original_argv).include?("--verbose")
      end

      def force?
        # Default is force (true) unless --interactive was passed
        env_force = ENV["force"].to_s.strip
        return false if env_force.casecmp("false").zero?

        @force.nil? ? true : @force || env_force.casecmp("true").zero? || Array(@passthrough).include?("force=true") || Array(@original_argv).include?("--force")
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

        wanted_entries = Kettle::Jem::PrismGemspec.development_dependency_entries(example)
        return if wanted_entries.empty?

        target = File.read(@gemspec_path)

        # Build gem=>desired line map
        wanted = wanted_entries.each_with_object({}) do |entry, memo|
          memo[entry[:gem]] = entry[:line]
        end

        # Use Prism-based gemspec edit to ensure development dependencies match
        begin
          modified = Kettle::Jem::PrismGemspec.ensure_development_dependencies(target, wanted)
          # Check if any actual changes were made to development dependency declarations.
          # Extract gem name + version args from dependency lines to compare semantically,
          # ignoring whitespace, comments, and formatting differences.
          target_deps = Kettle::Jem::PrismGemspec.development_dependency_signatures(target)
          modified_deps = Kettle::Jem::PrismGemspec.development_dependency_signatures(modified)
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
        return if value.strip.empty?

        value
      end

      def first_gemspec_array_value(name)
        values = Array(loaded_bootstrap_gemspec&.public_send(name)).map { |value| value.to_s.strip }.reject(&:empty?)
        values.first
      rescue StandardError => e
        debug("Could not seed #{name} from #{@gemspec_path}: #{e.class}: #{e.message}")
        nil
      end

      def gemspec_string_value(name)
        value = loaded_bootstrap_gemspec&.public_send(name)
        str = value.to_s.strip
        return if str.empty?

        str
      rescue StandardError => e
        debug("Could not read #{name} from #{@gemspec_path}: #{e.class}: #{e.message}")
        nil
      end

      def loaded_bootstrap_gemspec
        return unless @gemspec_path && File.exist?(@gemspec_path)
        return @loaded_bootstrap_gemspec if defined?(@loaded_bootstrap_gemspec)

        @loaded_bootstrap_gemspec = Gem::Specification.load(@gemspec_path)
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
      #    - Delegates top-level merge behavior to PrismGemfile so Gemfile bootstrap
      #      stays on the same structural merge path as the rest of kettle-jem.
      #    - Optionally limits which template eval_gemfile entries participate during
      #      bootstrap.
      def ensure_gemfile_from_example!(eval_paths: nil)
        source_path = installed_path("Gemfile.example")
        abort!("Internal error: Gemfile.example not found within installed gem.") unless source_path && File.exist?(source_path)

        example = filter_bootstrap_example_eval_gemfiles(File.read(source_path), eval_paths: eval_paths)
        target_path = "Gemfile"
        target = File.exist?(target_path) ? File.read(target_path) : ""

        load_bootstrap_gemfile_merge_runtime!
        merged = Kettle::Jem::PrismGemfile.merge_gem_calls(example, target)
        merged = remove_scaffold_default_gems(merged)
        merged = remove_conflicting_gems(merged)
        return say("Gemfile already contains required entries from example.", verbose_only: true) if merged == target

        File.write(target_path, ensure_trailing_newline(merged))
        say("Updated Gemfile with entries from Gemfile.example.", verbose_only: true)
      end

      def load_bootstrap_gemfile_merge_runtime!
        Kettle::Jem::PrismGemfile
      end

      # Remove scaffold-default gems from Gemfile content.
      # These gems are added by `bundle gem` but are covered by the kettle-jem template
      # (moved to gemspec dev deps or managed by modular gemfiles), so they should not
      # remain as direct top-level Gemfile declarations after templating.
      # @param content [String] Gemfile content
      # @return [String] Content with scaffold default gems removed
      def remove_scaffold_default_gems(content)
        SCAFFOLD_DEFAULT_GEMS.reduce(content) do |acc, gem_name|
          Kettle::Jem::PrismGemfile.remove_gem_dependency(acc, gem_name)
        end
      end

      # Remove gems that conflict with the kettle-jem template ecosystem from Gemfile content.
      # @param content [String] Gemfile content
      # @return [String] Content with conflicting gems removed
      def remove_conflicting_gems(content)
        Kettle::Jem::PrismGemfile::CONFLICTING_GEMS.reduce(content) do |acc, gem_name|
          Kettle::Jem::PrismGemfile.remove_gem_dependency(acc, gem_name)
        end
      end

      # Text-based bootstrap-safe version of adding the templating eval_gemfile line.
      # Does NOT use PrismGemfile — that requires NestedStatementWalker which may only
      # be present in local (unreleased) prism-merge. The full PrismGemfile merge runs
      # in the bundled phase via ensure_gemfile_from_example! after bundle exec handoff.
      def ensure_bootstrap_eval_gemfile!
        eval_line = %(eval_gemfile "#{BOOTSTRAP_GEMFILE_EVAL_PATHS.first}")
        target_path = "Gemfile"
        target = File.exist?(target_path) ? File.read(target_path) : ""
        if target.include?(eval_line)
          say("Gemfile already includes templating.gemfile eval.", verbose_only: true)
          return
        end
        new_content = ensure_trailing_newline(target) + "\n#{eval_line}\n"
        File.write(target_path, ensure_trailing_newline(new_content))
        say("Added templating.gemfile eval to Gemfile.", verbose_only: true)
      end

      def filter_bootstrap_example_eval_gemfiles(content, eval_paths: nil)
        return content if eval_paths.nil?

        allowed_paths = Array(eval_paths).map(&:to_s)

        content.each_line.reject { |line|
          match = line.strip.match(%r{\Aeval_gemfile\s+["']([^"']+)["']})
          match && !allowed_paths.include?(match[1])
        }.join
      end

      def ensure_bootstrap_modular_gemfiles!
        BOOTSTRAP_MODULAR_GEMFILES.each do |filename|
          rel = File.join("gemfiles", "modular", filename)
          source = installed_path(rel)
          abort!("Internal error: #{rel}.example not found within the installed gem.") unless source && File.exist?(source)

          dest = File.join("gemfiles", "modular", filename)
          existed_before = File.exist?(dest)

          overwrite = existed_before && force? && BOOTSTRAP_FORCEABLE_MODULAR_GEMFILES.include?(filename)
          if !existed_before || overwrite
            FileUtils.mkdir_p(File.dirname(dest))
            content = File.read(source)
            content = strip_self_from_templating_local(content) if filename == "templating_local.gemfile"
            content = strip_self_from_templating_gemfile(content) if filename == "templating.gemfile"
            File.write(dest, content)
            say(existed_before ? "Overwrote #{dest}." : "Copied #{dest}.", verbose_only: true)
          elsif filename == "templating_local.gemfile"
            # Always ensure the host gem is not a dependency of itself, even in existing files.
            original = File.read(dest)
            stripped = strip_self_from_templating_local(original)
            if stripped != original
              File.write(dest, stripped)
              say("Removed self-gem from #{dest}.", verbose_only: true)
            end
          elsif filename == "templating.gemfile"
            # Always ensure the host gem is not a dependency of itself, even in existing files.
            original = File.read(dest)
            stripped = strip_self_from_templating_gemfile(original)
            if stripped != original
              File.write(dest, stripped)
              say("Removed self-gem from #{dest}.", verbose_only: true)
            end
          end
        end
      end

      # Pure text-based removal of the host gem's own name from the templating_local gemfile
      # so it does not conflict with the gemspec source declaration. No AST tools used here
      # because this runs in the bootstrap phase before bundle exec is active.
      def strip_self_from_templating_local(content)
        gem_name = gemspec_string_value("name")
        return content unless gem_name

        # Remove "  gem-name" line from the %w[ ] array
        content = content.gsub(/^[ \t]+#{Regexp.escape(gem_name)}[ \t]*\n/, "")

        # Remove gem-name from the VENDORED_GEMS comment (comma-delimited, may be anywhere)
        content = content.gsub(
          /^(# export VENDORED_GEMS=)(.*)$/,
        ) do
          prefix = ::Regexp.last_match(1)
          gems = ::Regexp.last_match(2).split(",").reject { |g| g.strip == gem_name }
          "#{prefix}#{gems.join(",")}"
        end

        content
      end

      # Pure text-based removal of a `gem "host-gem-name"` call from the templating gemfile.
      # The template contains `gem "kettle-jem"` inside the non-dev conditional branch so
      # downstream consumers can pull the gem from RubyGems. When templating the host gem
      # itself that line must not exist (it conflicts with the gemspec PATH source).
      # No AST tools used here because this runs in the bootstrap phase.
      def strip_self_from_templating_gemfile(content)
        gem_name = gemspec_string_value("name")
        return content unless gem_name

        content.gsub(/^[ \t]*gem\s+['"]#{Regexp.escape(gem_name)}['"][^\n]*\n?/, "")
      end

      def local_workspace_dev_mode?
        ENV.fetch("KETTLE_RB_DEV", "false").to_s.strip.casecmp("false").nonzero?
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
      end

      def ensure_template_prerequisites!
        helpers = Kettle::Jem::TemplateHelpers
        meta = begin
          helpers.gemspec_metadata(helpers.project_root)
        rescue StandardError
          {}
        end

        Kettle::Jem::Tasks::PrepareTask.run(
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
              force: force?,
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
        # Re-lock Gemfile.lock so that any gemspec dependency changes
        # (e.g. version_gem added by ensure_dev_deps!) are reflected
        # in the lockfile BEFORE we commit.  Without this, the next
        # invocation of kettle-jem would dirty Gemfile.lock on process
        # startup and fail the prechecks! dirty-worktree guard.
        if File.exist?("Gemfile.lock")
          sh!(Shellwords.join(["bundle", "lock"]), suppress_output: quiet?, suppress_command_log: quiet?)
        end

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
