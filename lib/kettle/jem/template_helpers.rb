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

      # Warnings collected during template processing, for end-of-run summary.
      @@template_warnings = []

      # Track the outcome of the last template run so InstallTask can exit cleanly
      # after bootstrap-only config creation.
      @@template_run_outcome = nil

      EXECUTABLE_GIT_HOOKS_RE = %r{[\\/]\.git-hooks[\\/](commit-msg|prepare-commit-msg)\z}
      # The minimum Ruby supported by setup-ruby GHA
      MIN_SETUP_RUBY = Gem::Version.create("2.3")

      # All engines that kettle-jem currently knows about.
      # When the engines: key is absent from .kettle-jem.yml, all are enabled.
      DEFAULT_ENGINES = %w[ruby jruby truffleruby].freeze

      # Maps workflow filenames (without .yml / .yml.example) to the engine they
      # belong to. Only engine-specific workflow files are listed; shared
      # workflows (heads, dep-heads, current, etc.) are handled via matrix
      # pruning instead.
      ENGINE_WORKFLOW_MAP = {
        "jruby" => "jruby",
        "jruby-9.1" => "jruby",
        "jruby-9.2" => "jruby",
        "jruby-9.3" => "jruby",
        "jruby-9.4" => "jruby",
        "truffle" => "truffleruby",
        "truffleruby-22.3" => "truffleruby",
        "truffleruby-23.0" => "truffleruby",
        "truffleruby-23.1" => "truffleruby",
        "truffleruby-23.2" => "truffleruby",
        "truffleruby-24.2" => "truffleruby",
        "truffleruby-25.0" => "truffleruby",
      }.freeze

      # Engine-specific prefixes used in multi-engine workflow matrix entries
      # (heads.yml, dep-heads.yml). When an engine is disabled the matrix
      # items whose "ruby:" value starts with any of these prefixes are removed.
      ENGINE_MATRIX_PREFIXES = {
        "jruby" => %w[jruby],
        "truffleruby" => %w[truffleruby],
      }.freeze

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

      # Default config path within the template tree
      TEMPLATE_CONFIG_RELATIVE_PATH = ".kettle-jem.yml".freeze
      RUBY_BASENAMES = %w[Gemfile Rakefile Appraisals Appraisal.root.gemfile .simplecov].freeze
      RUBY_SUFFIXES = %w[.gemspec .gemfile].freeze
      RUBY_EXTENSIONS = %w[.rb .rake].freeze
      SUPPORTED_TEMPLATING_STRATEGIES = %i[
        merge
        accept_template
        keep_destination
        raw_copy
      ].freeze
      SUPPORTED_FILE_TYPES = %i[
        ruby
        gemfile
        appraisals
        gemspec
        rakefile
        yaml
        markdown
        bash
        tool_versions
        text
        json
        jsonc
        toml
        dotenv
        rbs
      ].freeze

      # RuboCop LTS version map: min_ruby -> constraint.
      # Used to resolve {KJ|RUBOCOP_LTS_CONSTRAINT} and {KJ|RUBOCOP_RUBY_GEM} tokens.
      RUBOCOP_VERSION_MAP = [
        [Gem::Version.new("1.8"), "~> 0.1"],
        [Gem::Version.new("1.9"), "~> 2.0"],
        [Gem::Version.new("2.0"), "~> 4.0"],
        [Gem::Version.new("2.1"), "~> 6.0"],
        [Gem::Version.new("2.2"), "~> 8.0"],
        [Gem::Version.new("2.3"), "~> 10.0"],
        [Gem::Version.new("2.4"), "~> 12.0"],
        [Gem::Version.new("2.5"), "~> 14.0"],
        [Gem::Version.new("2.6"), "~> 16.0"],
        [Gem::Version.new("2.7"), "~> 18.0"],
        [Gem::Version.new("3.0"), "~> 20.0"],
        [Gem::Version.new("3.1"), "~> 22.0"],
        [Gem::Version.new("3.2"), "~> 24.0"],
        [Gem::Version.new("3.3"), "~> 26.0"],
        [Gem::Version.new("3.4"), "~> 28.0"],
      ].freeze
      @@manifestation = nil
      @@kettle_config = nil
      @@project_root_override = nil
      # Cached token replacement map, built by configure_tokens!
      @@token_replacements = nil

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

      # Root of the template/ directory containing tokenized .example files.
      # @return [String]
      def template_root
        File.join(File.expand_path("../../..", __dir__), "template")
      end

      # Configure token replacements for the current templating session.
      # Must be called once before any read_template calls (typically at the
      # start of TemplateTask.run or SetupCLI).
      #
      # All {KJ|...} tokens are resolved here — there are no "special" tokens
      # that belong to a specific flow.
      #
      # @param org [String]
      # @param gem_name [String]
      # @param namespace [String]
      # @param namespace_shield [String]
      # @param gem_shield [String]
      # @param funding_org [String, nil]
      # @param min_ruby [Gem::Version, String, nil]
      # @return [void]
      def configure_tokens!(org:, gem_name:, namespace:, namespace_shield:, gem_shield:, funding_org: nil, min_ruby: nil, include_config_tokens: true)
        raise Error, "Org could not be derived" unless org && !org.empty?
        raise Error, "Gem name could not be derived" unless gem_name && !gem_name.empty?

        funding_org ||= org
        meta = safe_gemspec_metadata
        token_config = include_config_tokens ? token_config_values : {}
        template_run_at = template_run_timestamp

        # Derive min_ruby from gemspec if not provided
        mr = meta[:min_ruby]
        if min_ruby.nil? || min_ruby.to_s.strip.empty?
          min_ruby = mr.respond_to?(:to_s) ? mr.to_s : mr
        end

        # Derive min_dev_ruby: the greater of min_ruby and 2.3 (minimum for setup-ruby GHA)
        effective_min = begin
          v = min_ruby.is_a?(Gem::Version) ? min_ruby : Gem::Version.new(min_ruby.to_s)
          [v, MIN_SETUP_RUBY].max
        rescue StandardError => e
          Kettle::Dev.debug_error(e, __method__)
          MIN_SETUP_RUBY
        end
        min_dev_ruby = effective_min

        dashed = gem_name.tr("_", "-")
        ft = (kettle_config.dig("defaults", "freeze_token") || "kettle-jem").to_s
        author_name = resolved_author_name(meta, token_config)
        author_email = resolved_author_email(meta, token_config)
        author_domain = resolved_author_domain(author_email, token_config)
        author_given_names = resolved_author_given_names(author_name, token_config)
        author_family_names = resolved_author_family_names(author_name, token_config)
        author_orcid = preferred_token_value(nil, token_config.dig("author", "orcid"), env_key: "KJ_AUTHOR_ORCID")

        replacements = {
          "KJ|GEM_NAME" => gem_name,
          "KJ|GEM_NAME_PATH" => gem_name.tr("-", "/"),
          "KJ|GEM_SHIELD" => gem_shield,
          "KJ|GH_ORG" => org.to_s,
          "KJ|NAMESPACE" => namespace,
          "KJ|NAMESPACE_SHIELD" => namespace_shield,
          "KJ|OPENCOLLECTIVE_ORG" => funding_org || "opencollective",
          "KJ|FREEZE_TOKEN" => ft,
          "KJ|KETTLE_JEM_VERSION" => kettle_jem_version,
          "KJ|TEMPLATE_RUN_DATE" => template_run_at.strftime("%Y-%m-%d"),
          "KJ|TEMPLATE_RUN_YEAR" => template_run_at.year.to_s,
          "KJ|KETTLE_DEV_GEM" => "kettle-dev",
          "KJ|YARD_HOST" => "#{dashed}.#{author_domain || "example.com"}",
        }
        replacements["KJ|MIN_RUBY"] = min_ruby.to_s if min_ruby && !min_ruby.to_s.empty?
        replacements["KJ|MIN_DEV_RUBY"] = min_dev_ruby.to_s if min_dev_ruby && !min_dev_ruby.to_s.empty?
        replacements["KJ|AUTHOR:NAME"] = author_name if present_string?(author_name)
        replacements["KJ|AUTHOR:GIVEN_NAMES"] = author_given_names if present_string?(author_given_names)
        replacements["KJ|AUTHOR:FAMILY_NAMES"] = author_family_names if present_string?(author_family_names)
        replacements["KJ|AUTHOR:EMAIL"] = author_email if present_string?(author_email)
        replacements["KJ|AUTHOR:DOMAIN"] = author_domain if present_string?(author_domain)
        replacements["KJ|AUTHOR:ORCID"] = author_orcid if present_string?(author_orcid)

        # RuboCop LTS tokens — derived from min_ruby, used in style.gemfile and potentially others
        min_ruby_version = begin
          Gem::Version.new(min_ruby.to_s)
        rescue StandardError
          nil
        end
        rc_constraint, rc_gem = rubocop_tokens_for(min_ruby_version)
        replacements["KJ|RUBOCOP_LTS_CONSTRAINT"] = rc_constraint
        replacements["KJ|RUBOCOP_RUBY_GEM"] = rc_gem

        # Forge user tokens: {KJ|GH:USER}, {KJ|GL:USER}, {KJ|CB:USER}, {KJ|SH:USER}
        FORGE_USER_ENV_KEYS.each do |forge, env_key|
          config_key = case forge
          when "GH" then "gh_user"
          when "GL" then "gl_user"
          when "CB" then "cb_user"
          when "SH" then "sh_user"
          end
          value = preferred_token_value(nil, token_config.dig("forge", config_key), env_key: env_key)
          replacements["KJ|#{forge}:USER"] = value if present_string?(value)
        end

        # Funding platform tokens
        FUNDING_ENV_KEYS.each do |platform, env_key|
          value = preferred_token_value(nil, token_config.dig("funding", platform.downcase), env_key: env_key)
          replacements["KJ|FUNDING:#{platform}"] = value if present_string?(value)
        end

        # Social/community platform tokens
        SOCIAL_ENV_KEYS.each do |platform, env_key|
          value = preferred_token_value(nil, token_config.dig("social", platform.downcase), env_key: env_key)
          replacements["KJ|SOCIAL:#{platform}"] = value if present_string?(value)
        end

        @@token_replacements = replacements
      end

      def token_config_values
        config = kettle_config
        raw = config.is_a?(Hash) ? config["tokens"] : nil
        raw.is_a?(Hash) ? raw : {}
      end

      # Return token config values that can be safely backfilled into
      # .kettle-jem.yml from the current process environment, intentionally
      # ignoring the existing config content.
      #
      # This is used by TemplateTask preflight to persist concrete values into an
      # existing project config before unresolved-token validation runs.
      # @return [Hash<String, Hash<String, String>>]
      def derived_token_config_values
        forge = {
          "gh_user" => preferred_token_value(nil, nil, env_key: "KJ_GH_USER"),
          "gl_user" => preferred_token_value(nil, nil, env_key: "KJ_GL_USER"),
          "cb_user" => preferred_token_value(nil, nil, env_key: "KJ_CB_USER"),
          "sh_user" => preferred_token_value(nil, nil, env_key: "KJ_SH_USER"),
        }

        author = {
          "name" => preferred_token_value(nil, nil, env_key: "KJ_AUTHOR_NAME"),
          "given_names" => preferred_token_value(nil, nil, env_key: "KJ_AUTHOR_GIVEN_NAMES"),
          "family_names" => preferred_token_value(nil, nil, env_key: "KJ_AUTHOR_FAMILY_NAMES"),
          "email" => preferred_token_value(nil, nil, env_key: "KJ_AUTHOR_EMAIL"),
          "domain" => preferred_token_value(nil, nil, env_key: "KJ_AUTHOR_DOMAIN"),
          "orcid" => preferred_token_value(nil, nil, env_key: "KJ_AUTHOR_ORCID"),
        }

        funding = {
          "patreon" => preferred_token_value(nil, nil, env_key: "KJ_FUNDING_PATREON"),
          "kofi" => preferred_token_value(nil, nil, env_key: "KJ_FUNDING_KOFI"),
          "paypal" => preferred_token_value(nil, nil, env_key: "KJ_FUNDING_PAYPAL"),
          "buymeacoffee" => preferred_token_value(nil, nil, env_key: "KJ_FUNDING_BUYMEACOFFEE"),
          "polar" => preferred_token_value(nil, nil, env_key: "KJ_FUNDING_POLAR"),
          "liberapay" => preferred_token_value(nil, nil, env_key: "KJ_FUNDING_LIBERAPAY"),
          "issuehunt" => preferred_token_value(nil, nil, env_key: "KJ_FUNDING_ISSUEHUNT"),
        }

        social = {
          "mastodon" => preferred_token_value(nil, nil, env_key: "KJ_SOCIAL_MASTODON"),
          "bluesky" => preferred_token_value(nil, nil, env_key: "KJ_SOCIAL_BLUESKY"),
          "linktree" => preferred_token_value(nil, nil, env_key: "KJ_SOCIAL_LINKTREE"),
          "devto" => preferred_token_value(nil, nil, env_key: "KJ_SOCIAL_DEVTO"),
        }

        {
          "forge" => forge.select { |_, value| present_string?(value) },
          "author" => author.select { |_, value| present_string?(value) },
          "funding" => funding.select { |_, value| present_string?(value) },
          "social" => social.select { |_, value| present_string?(value) },
        }.reject { |_, values| values.empty? }
      end

      def seed_kettle_config_content(content, token_values)
        return content.to_s if token_values.nil? || token_values.empty?

        updated_content, = backfill_kettle_config_token_lines(content.to_s, token_values)
        merge_missing_kettle_config_token_values(updated_content, token_values)
      end

      def placeholder_or_blank_kettle_config_scalar?(raw_value)
        stripped = raw_value.to_s.strip
        return true if stripped.empty?

        parsed = begin
          YAML.safe_load(stripped, permitted_classes: [], aliases: false)
        rescue StandardError
          stripped.delete_prefix('"').delete_suffix('"').delete_prefix("'").delete_suffix("'")
        end

        value = parsed.is_a?(String) ? parsed : parsed.to_s
        value.to_s.strip.empty? || token_placeholder?(value)
      end

      def yaml_scalar_for_kettle_config_backfill(value, current_raw)
        stripped = current_raw.to_s.strip
        if stripped.start_with?("'") && stripped.end_with?("'")
          "'#{value.to_s.gsub("'", "''")}'"
        else
          value.to_s.dump
        end
      end

      def backfill_kettle_config_token_lines(content, token_values)
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
          next line unless present_string?(desired_value)
          next line unless placeholder_or_blank_kettle_config_scalar?(match[4])

          changed = true
          "#{match[1]}#{key}:#{match[3]}#{yaml_scalar_for_kettle_config_backfill(desired_value, match[4])}#{match[5]}#{match[6]}"
        end.join

        [updated, changed]
      end

      def merge_missing_kettle_config_token_values(destination_content, token_values)
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

      def safe_gemspec_metadata
        gemspec_metadata
      rescue StandardError => e
        Kettle::Dev.debug_error(e, __method__)
        {}
      end

      def template_run_timestamp
        Time.now
      end

      def kettle_jem_version
        Kettle::Jem::Version::VERSION
      end

      def preferred_token_value(derived_value, config_value, env_key:)
        env_value = ENV[env_key]
        env_clean = env_value.to_s.strip
        return env_clean if present_string?(env_clean) && !token_placeholder?(env_clean)

        config_clean = config_value.to_s.strip
        return config_clean if present_string?(config_clean) && !token_placeholder?(config_clean)
        return nil unless present_string?(derived_value)

        derived_value.to_s.strip
      end

      def token_placeholder?(value)
        value.to_s.strip.match?(%r{\A\{KJ\|[A-Z][A-Z0-9_:]*\}\z})
      end

      def present_string?(value)
        !value.to_s.strip.empty?
      end

      def first_present_value(values)
        Array(values).find { |value| present_string?(value) }
      end

      def resolved_author_name(meta, token_config)
        preferred_token_value(first_present_value(meta[:authors]), token_config.dig("author", "name"), env_key: "KJ_AUTHOR_NAME")
      end

      def resolved_author_email(meta, token_config)
        preferred_token_value(first_present_value(meta[:email]), token_config.dig("author", "email"), env_key: "KJ_AUTHOR_EMAIL")
      end

      def resolved_author_domain(author_email, token_config)
        derived_domain = author_email.to_s.split("@", 2)[1]
        preferred_token_value(derived_domain, token_config.dig("author", "domain"), env_key: "KJ_AUTHOR_DOMAIN")
      end

      def resolved_author_given_names(author_name, token_config)
        preferred_token_value(derive_given_names(author_name), token_config.dig("author", "given_names"), env_key: "KJ_AUTHOR_GIVEN_NAMES")
      end

      def resolved_author_family_names(author_name, token_config)
        preferred_token_value(derive_family_names(author_name), token_config.dig("author", "family_names"), env_key: "KJ_AUTHOR_FAMILY_NAMES")
      end

      def derive_given_names(author_name)
        parts = author_name.to_s.strip.split(/\s+/)
        return nil if parts.size < 2

        parts[0...-1].join(" ")
      end

      def derive_family_names(author_name)
        parts = author_name.to_s.strip.split(/\s+/)
        return nil if parts.size < 2

        parts[-1]
      end

      # Clear configured tokens (for test isolation).
      # @return [void]
      def clear_tokens!
        @@token_replacements = nil
      end

      # Whether tokens have been configured for this session.
      # @return [Boolean]
      def tokens_configured?
        !@@token_replacements.nil?
      end

      # Read a template file and resolve all {KJ|...} tokens.
      # This is the ONLY correct way to read template content. Token resolution
      # is inseparable from reading — there are no raw template reads.
      #
      # @param src_path [String] path to the template file
      # @return [String] content with all known tokens resolved
      # @raise [Kettle::Jem::Error] if tokens have not been configured
      def read_template(src_path)
        content = File.read(src_path)
        resolve_tokens(content)
      end

      # Resolve all {KJ|...} tokens in content using the configured replacements.
      # Unresolved tokens are kept as-is so they can be diagnosed.
      #
      # @param content [String]
      # @return [String] content with known tokens resolved
      def resolve_tokens(content)
        return content unless @@token_replacements

        doc = Token::Resolver::Document.new(content, config: TOKEN_CONFIG)
        resolver = Token::Resolver::Resolve.new(on_missing: :keep)
        resolver.resolve(doc, @@token_replacements)
      end

      # Return the token keys that would remain unresolved with the current
      # replacement map.
      #
      # @param content [String]
      # @return [Array<String>]
      def unresolved_token_keys(content)
        doc = Token::Resolver::Document.new(content, config: TOKEN_CONFIG)
        configured = @@token_replacements || {}

        doc.token_keys.select { |key|
          key.start_with?("KJ|") && !configured.key?(key)
        }.uniq
      end

      # Compute RuboCop LTS constraint and gem name from min_ruby.
      # @param min_ruby [Gem::Version, nil]
      # @return [Array(String, String)] [constraint, gem_name]
      def rubocop_tokens_for(min_ruby)
        fallback = RUBOCOP_VERSION_MAP.first
        constraint = nil
        gem_version = nil

        if min_ruby
          RUBOCOP_VERSION_MAP.reverse_each do |min, req|
            if min_ruby >= min
              constraint = req
              gem_version = min.segments.join("_")
              break
            end
          end
        end

        constraint ||= fallback[1]
        gem_version ||= fallback[0].segments.join("_")

        [constraint, "rubocop-ruby#{gem_version}"]
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
        # Ensure trailing newline — all text files should end with one
        normalized = content.to_s
        normalized += "\n" unless normalized.empty? || normalized.end_with?("\n")
        File.open(actual, "w") { |f| f.write(normalized) }
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

      # Return the normalised list of enabled engines for the current project.
      # Falls back to DEFAULT_ENGINES when the key is absent or not an array.
      # @return [Array<String>]
      def engines_config
        raw = kettle_config["engines"]
        engines = if raw.is_a?(Array) && !raw.empty?
          raw.map { |e| e.to_s.strip.downcase }.reject(&:empty?)
        else
          DEFAULT_ENGINES.dup
        end
        engines.empty? ? DEFAULT_ENGINES.dup : engines
      end

      # Whether a specific engine is enabled in the current config.
      # @param engine [String] one of "ruby", "jruby", "truffleruby"
      # @return [Boolean]
      def engine_enabled?(engine)
        engines_config.include?(engine.to_s.downcase)
      end

      # Check if a workflow file should be skipped because its engine is
      # disabled. Only applies to engine-dedicated workflow files listed in
      # ENGINE_WORKFLOW_MAP.
      # @param relative_path [String] relative path from project root (e.g. ".github/workflows/jruby.yml")
      # @return [Boolean]
      def skip_for_disabled_engine?(relative_path)
        basename = File.basename(relative_path.to_s, ".yml")
        engine = ENGINE_WORKFLOW_MAP[basename]
        return false unless engine

        !engine_enabled?(engine)
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
        # When force mode is active (e.g., from SetupCLI --force), skip the
        # dirty-tree check. The CLI workflow intentionally dirties the tree
        # before running the template task, and commits everything at the end.
        force_val = ENV.fetch("force", "false").to_s.strip
        return if force_val.casecmp("true").zero?

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

      # Copy a single file with interactive prompts for create/merge.
      # Yields content for transformation when block given.
      # @param raw [Boolean] when true, reads file verbatim (no token resolution, no yield)
      # @param content_override [String, nil] explicit content to use instead of reading src_path
      # @return [void]
      def copy_file_with_prompt(src_path, dest_path, allow_create: true, allow_replace: true, raw: false, content_override: nil)
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
        merge_op = dest_exists && block_given?
        action = nil
        if dest_exists
          if allow_replace
            verb = merge_op ? "Merge into" : "Replace"
            action = ask("#{verb} #{dest_path}?", true) ? :replace : :skip
          else
            puts "Skipping #{dest_path} (overwrite not allowed)."
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

        content = if content_override
          content_override
        else
          raw ? File.read(src_path) : read_template(src_path)
        end
        content = yield(content) if block_given? && !raw

        unless raw
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
        end

        # Apply self-dependency removal for all gem-related files
        # This ensures we don't introduce a self-dependency when templating
        unless raw
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
        wrote_verb = merge_op ? "Merged" : "Wrote"
        puts "#{wrote_verb} #{dest_path}"
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
        merged = Kettle::Jem::PrismAppraisals.merge(content, existing)
        min_ruby = begin
          gemspec_metadata[:min_ruby]
        rescue StandardError => e
          Kettle::Dev.debug_error(e, __method__)
          nil
        end
        pruned, _removed = Kettle::Jem::PrismAppraisals.prune_ruby_appraisals(merged, min_ruby: min_ruby)
        pruned
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
          if ask("Merge into directory #{dest_dir}?", true)
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
      # Calls configure_tokens! with the provided parameters, then delegates
      # to resolve_tokens. This ensures the token map is always fresh with
      # respect to the provided parameters and current ENV state.
      #
      # @deprecated Prefer calling configure_tokens! once at startup, then
      #   use read_template or resolve_tokens directly.
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
        configure_tokens!(
          org: org,
          gem_name: gem_name,
          namespace: namespace,
          namespace_shield: namespace_shield,
          gem_shield: gem_shield,
          funding_org: funding_org,
          min_ruby: min_ruby,
        )
        resolve_tokens(content)
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
        file_type = configured_file_type_for(dest_path)
        Kettle::Jem::SourceMerger.apply(
          strategy: strategy,
          src: content,
          dest: dest_content,
          path: rel_path(dest_path),
          file_type: file_type,
        )
      end

      def manifestation
        @@manifestation ||= load_manifest
      end

      def strategy_for(dest_path)
        relative = rel_path(dest_path)
        config_for(relative)&.fetch(:strategy, :merge) || :merge
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

      def configured_file_type_for(path_or_relative)
        relative_path = path_or_relative.to_s
        if relative_path.start_with?(project_root.to_s)
          relative_path = rel_path(relative_path)
        end

        config_for(relative_path)&.fetch(:file_type, nil)
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

        strategy = entry["strategy"].to_s.strip.downcase.to_sym
        unless SUPPORTED_TEMPLATING_STRATEGIES.include?(strategy)
          raise Kettle::Jem::Error, "Unknown templating strategy '#{strategy}'"
        end

        result = {strategy: strategy}
        result[:path] = path if path

        if entry.key?("file_type")
          file_type = entry["file_type"].to_s.strip.downcase.tr("-", "_").to_sym
          unless SUPPORTED_FILE_TYPES.include?(file_type)
            raise Kettle::Jem::Error, "Unknown templating file_type '#{entry["file_type"]}'"
          end

          result[:file_type] = file_type
        end

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
        configured_type = configured_file_type_for(dest_path)
        return true if Kettle::Jem::SourceMerger.ruby_file_type?(configured_type)

        base = File.basename(dest_path.to_s)
        return true if RUBY_BASENAMES.include?(base)
        return true if RUBY_SUFFIXES.any? { |suffix| base.end_with?(suffix) }
        ext = File.extname(base)
        RUBY_EXTENSIONS.include?(ext)
      end

      def project_kettle_config_path
        File.join(project_root.to_s, TEMPLATE_CONFIG_RELATIVE_PATH)
      end

      def template_kettle_config_path
        prefer_example(File.join(template_root, TEMPLATE_CONFIG_RELATIVE_PATH))
      end

      def load_kettle_config_file(path)
        return {} unless File.exist?(path)

        config = YAML.load_file(path)
        config.is_a?(Hash) ? config : {}
      rescue Errno::ENOENT
        {}
      end

      def project_kettle_config
        load_kettle_config_file(project_kettle_config_path)
      end

      # Load the raw kettle-jem config file.
      # Prefers the destination project's .kettle-jem.yml (so each gem can
      # customize its merge strategies); falls back to the template default config.
      # @return [Hash] Parsed YAML config
      def kettle_config
        @@kettle_config ||= begin
          if File.exist?(project_kettle_config_path)
            load_kettle_config_file(project_kettle_config_path)
          else
            load_kettle_config_file(template_kettle_config_path)
          end
        rescue Errno::ENOENT
          {}
        end
      end

      # Clear the cached kettle config so the next call to kettle_config
      # re-reads the (potentially updated) .kettle-jem.yml file.
      # @return [void]
      def clear_kettle_config!
        @@kettle_config = nil
        @@manifestation = nil
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

      # Add a warning message to the collection.
      # @param message [String, #to_s] the warning message
      # @return [void]
      def add_warning(message)
        @@template_warnings << message.to_s if message && !message.to_s.strip.empty?
      end

      # Retrieve a duplicate-free array of all collected warning messages.
      # @return [Array<String>]
      def warnings
        @@template_warnings.dup
      end

      # Clear the collection of warning messages.
      # @return [void]
      def clear_warnings
        @@template_warnings = []
      end

      # Print a summary of collected warnings to the console.
      # @return [void]
      def print_warnings_summary
        msgs = @@template_warnings.uniq
        return if msgs.empty?

        puts
        puts "Important warnings:"
        msgs.each { |m| puts "  - #{m}" }
      end

      def template_run_outcome
        @@template_run_outcome
      end

      def template_run_outcome=(value)
        @@template_run_outcome = value
      end

      def clear_template_run_outcome!
        @@template_run_outcome = nil
      end
    end
  end
end
