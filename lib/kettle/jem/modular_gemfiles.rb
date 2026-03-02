# frozen_string_literal: true

module Kettle
  module Jem
    # Utilities for copying modular Gemfiles and related directories
    # in a DRY fashion. Used by both the template rake task and the
    # setup CLI to ensure gemfiles/modular/* are present before use.
    module ModularGemfiles
      MODULAR_GEMFILE_DIR = "gemfiles/modular"

      module_function

      # Copy the modular gemfiles and nested directories from the gem
      # template into the target project, prompting where appropriate
      # via the provided helpers.
      #
      # Dynamically discovers all flat gemfiles and subdirectories from
      # the template/gemfiles/modular/ directory. No hardcoded lists —
      # everything in the template directory is part of the template.
      #
      # @param helpers [Kettle::Jem::TemplateHelpers] helper API
      # @param project_root [String] destination project root
      # @param gem_checkout_root [String] kettle-jem checkout root (source)
      # @param min_ruby [Gem::Version, nil] minimum Ruby version (for style.gemfile tuning)
      # @param gem_name [String, nil] destination gem name (to strip self-dependencies)
      # @return [void]
      def sync!(helpers:, project_root:, gem_checkout_root:, min_ruby: nil, gem_name: nil)
        template_modular_dir = File.join(gem_checkout_root, "template", MODULAR_GEMFILE_DIR)
        # Fallback for non-template layouts (e.g., test fixtures without template/)
        template_modular_dir = File.join(gem_checkout_root, MODULAR_GEMFILE_DIR) unless Dir.exist?(template_modular_dir)
        return unless Dir.exist?(template_modular_dir)

        # Discover flat gemfiles (*.gemfile or *.gemfile.example) and subdirectories
        flat_gemfiles = []
        subdirectories = []

        Dir.children(template_modular_dir).sort.each do |entry|
          full_path = File.join(template_modular_dir, entry)
          if File.directory?(full_path)
            subdirectories << entry
          elsif entry.end_with?(".gemfile", ".gemfile.example")
            # Normalize to base name without .example suffix
            base = entry.sub(/\.example\z/, "").sub(/\.gemfile\z/, "")
            flat_gemfiles << base unless flat_gemfiles.include?(base)
          end
        end

        # Copy flat modular gemfiles, with special handling for style.gemfile
        flat_gemfiles.each do |base|
          if base == "style"
            sync_style_gemfile!(helpers: helpers, project_root: project_root, gem_checkout_root: gem_checkout_root, min_ruby: min_ruby, gem_name: gem_name)
          else
            modular_gemfile = "#{base}.gemfile"
            src = helpers.prefer_example(File.join(gem_checkout_root, MODULAR_GEMFILE_DIR, modular_gemfile))
            dest = File.join(project_root, MODULAR_GEMFILE_DIR, modular_gemfile)
            helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true) do |content|
              c = helpers.apply_strategy(content, dest)
              c = PrismGemfile.remove_gem_dependency(c, gem_name) if gem_name && !gem_name.to_s.empty?
              c
            end
          end
        end

        # Copy subdirectories with nested/versioned files
        subdirectories.each do |dir|
          src_dir = File.join(gem_checkout_root, MODULAR_GEMFILE_DIR, dir)
          dest_dir = File.join(project_root, MODULAR_GEMFILE_DIR, dir)
          helpers.copy_dir_with_prompt(src_dir, dest_dir)
        end
      end

      # Handle style.gemfile separately due to dynamic rubocop-lts token replacement.
      #
      # @param helpers [Kettle::Jem::TemplateHelpers] helper API
      # @param project_root [String] destination project root
      # @param gem_checkout_root [String] kettle-jem checkout root (source)
      # @param min_ruby [Gem::Version, nil] minimum Ruby version
      # @param gem_name [String, nil] destination gem name (to strip self-dependencies)
      # @return [void]
      def sync_style_gemfile!(helpers:, project_root:, gem_checkout_root:, min_ruby: nil, gem_name: nil)
        modular_gemfile = "style.gemfile"
        src = helpers.prefer_example(File.join(gem_checkout_root, MODULAR_GEMFILE_DIR, modular_gemfile))
        dest = File.join(project_root, MODULAR_GEMFILE_DIR, modular_gemfile)
        helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true) do |content|
          # Adjust rubocop-lts constraint based on min_ruby
          version_map = [
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
          ]
          new_constraint = nil
          rubocop_ruby_gem_version = nil
          ruby1_8 = version_map.first
          begin
            if min_ruby
              version_map.reverse_each do |min, req|
                if min_ruby >= min
                  new_constraint = req
                  rubocop_ruby_gem_version = min.segments.join("_")
                  break
                end
              end
            end
            if !new_constraint || !rubocop_ruby_gem_version
              # A gem with no declared minimum ruby is effectively >= 1.8.7
              new_constraint = ruby1_8[1]
              rubocop_ruby_gem_version = ruby1_8[0].segments.join("_")
            end
          rescue StandardError => e
            Kettle::Dev.debug_error(e, __method__) if defined?(Kettle::Dev.debug_error)
            # ignore, use default
          ensure
            new_constraint ||= ruby1_8[1]
            rubocop_ruby_gem_version ||= ruby1_8[0].segments.join("_")
          end
          if new_constraint && rubocop_ruby_gem_version
            token = "{KJ|RUBOCOP_LTS_CONSTRAINT}"
            content.gsub!(token, new_constraint) if content.include?(token)
            token = "{KJ|RUBOCOP_RUBY_GEM}"
            content.gsub!(token, "rubocop-ruby#{rubocop_ruby_gem_version}") if content.include?(token)
          end
          # Use apply_strategy for proper AST-based merging with Prism
          c = helpers.apply_strategy(content, dest)
          c = PrismGemfile.remove_gem_dependency(c, gem_name) if gem_name && !gem_name.to_s.empty?
          c
        end
      end
    end
  end
end
