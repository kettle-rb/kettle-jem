# frozen_string_literal: true

module Kettle
  module Jem
    # Utilities for copying modular Gemfiles and related directories
    # in a DRY fashion. Used by both the template rake task and the
    # setup CLI to ensure gemfiles/modular/* are present before use.
    module ModularGemfiles
      MODULAR_GEMFILE_DIR = "gemfiles/modular"
      RUBY_BUCKET_RE = /\Ar(\d+)(?:\.(\d+))?\z/

      module_function

      # Copy the modular gemfiles and nested directories from the gem
      # template into the target project, prompting where appropriate
      # via the provided helpers.
      #
      # Dynamically discovers all flat gemfiles and subdirectories from
      # the template/gemfiles/modular/ directory. No hardcoded lists —
      # everything in the template directory is part of the template.
      #
      # Token replacement is handled automatically by helpers.read_template
      # inside copy_file_with_prompt — callers do not need to worry about it.
      #
      # @param helpers [Kettle::Jem::TemplateHelpers] helper API
      # @param project_root [String] destination project root
      # @param min_ruby [Gem::Version, nil] minimum Ruby version (for style.gemfile tuning)
      # @param gem_name [String, nil] destination gem name (to strip self-dependencies)
      # @return [void]
      def sync!(helpers:, project_root:, min_ruby: nil, gem_name: nil)
        template_modular_dir = File.join(helpers.template_root, MODULAR_GEMFILE_DIR)
        unless Dir.exist?(template_modular_dir)
          helpers.add_warning("Template missing #{MODULAR_GEMFILE_DIR}; skipping modular gemfiles")
          return
        end

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
            sync_style_gemfile!(helpers: helpers, project_root: project_root, min_ruby: min_ruby, gem_name: gem_name)
          else
            modular_gemfile = "#{base}.gemfile"
            src = helpers.prefer_example(File.join(template_modular_dir, modular_gemfile))
            dest = File.join(project_root, MODULAR_GEMFILE_DIR, modular_gemfile)
            strategy = helpers.strategy_for(dest)
            next if strategy == :keep_destination

            if strategy == :raw_copy
              helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true, raw: true)
              next
            end

            helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true) do |content|
              existing_content = File.exist?(dest) ? File.read(dest) : nil
              c = if strategy == :accept_template
                content
              else
                helpers.apply_strategy(content, dest)
              end
              if modular_gemfile.end_with?("_local.gemfile")
                c = PrismGemfile.remove_gem_dependency(c, gem_name) if gem_name && !gem_name.to_s.empty?
                c = PrismGemfile.merge_local_gem_overrides(c, existing_content, excluded_gems: gem_name)
              elsif gem_name && !gem_name.to_s.empty?
                c = PrismGemfile.remove_gem_dependency(c, gem_name)
              end
              c
            end
          end
        end

        # Copy subdirectories with nested/versioned files
        subdirectories.each do |dir|
          src_dir = File.join(template_modular_dir, dir)
          dest_dir = File.join(project_root, MODULAR_GEMFILE_DIR, dir)
          next unless Dir.exist?(src_dir)

          require "find"
          Find.find(src_dir) do |path|
            next if File.directory?(path)
            rel = path.sub(%r{^#{Regexp.escape(src_dir)}/?}, "")
            rel_with_dir = File.join(dir, rel)
            bucket = ruby_bucket_for_path(rel_with_dir)

            unless keep_ruby_bucket?(bucket, min_ruby)
              dest = File.join(dest_dir, rel.sub(/\.example\z/, ""))
              if File.exist?(dest)
                helpers.add_warning("Skipped #{dest} (bucket #{bucket} is below min Ruby #{min_ruby})")
              end
              next
            end

            src = helpers.prefer_example(path)
            dest = File.join(dest_dir, rel.sub(/\.example\z/, ""))
            strategy = helpers.strategy_for(dest)
            next if strategy == :keep_destination

            if strategy == :raw_copy
              helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true, raw: true)
              next
            end

            helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true) do |content|
              existing_content = File.exist?(dest) ? File.read(dest) : nil
              c = if strategy == :accept_template
                content
              else
                helpers.apply_strategy(content, dest)
              end
              if File.basename(dest).end_with?("_local.gemfile")
                c = PrismGemfile.remove_gem_dependency(c, gem_name) if gem_name && !gem_name.to_s.empty?
                c = PrismGemfile.merge_local_gem_overrides(c, existing_content, excluded_gems: gem_name)
              elsif gem_name && !gem_name.to_s.empty?
                c = PrismGemfile.remove_gem_dependency(c, gem_name)
              end
              c
            end
          end
        end
      end

      # Handle style.gemfile — no special token handling needed since all tokens
      # (including RUBOCOP_LTS_CONSTRAINT and RUBOCOP_RUBY_GEM) are resolved
      # automatically by read_template in copy_file_with_prompt.
      #
      # @param helpers [Kettle::Jem::TemplateHelpers] helper API
      # @param project_root [String] destination project root
      # @param min_ruby [Gem::Version, nil] minimum Ruby version
      # @param gem_name [String, nil] destination gem name (to strip self-dependencies)
      # @return [void]
      def sync_style_gemfile!(helpers:, project_root:, min_ruby: nil, gem_name: nil)
        modular_gemfile = "style.gemfile"
        src = helpers.prefer_example(File.join(helpers.template_root, MODULAR_GEMFILE_DIR, modular_gemfile))
        dest = File.join(project_root, MODULAR_GEMFILE_DIR, modular_gemfile)
        strategy = helpers.strategy_for(dest)
        return if strategy == :keep_destination

        if strategy == :raw_copy
          helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true, raw: true)
          return
        end

        helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true) do |content|
          existing_content = File.exist?(dest) ? File.read(dest) : nil
          c = if strategy == :accept_template
            content
          else
            helpers.apply_strategy(content, dest)
          end
          if modular_gemfile.end_with?("_local.gemfile")
            c = PrismGemfile.remove_gem_dependency(c, gem_name) if gem_name && !gem_name.to_s.empty?
            c = PrismGemfile.merge_local_gem_overrides(c, existing_content, excluded_gems: gem_name)
          elsif gem_name && !gem_name.to_s.empty?
            c = PrismGemfile.remove_gem_dependency(c, gem_name)
          end
          c
        end
      end

      # Determine if a Ruby bucket (e.g., rMAJOR.MINOR) should be kept based on min_ruby.
      #
      # @param bucket [String] the Ruby bucket to check
      # @param min_ruby [Gem::Version, String, nil] the minimum Ruby version
      # @return [Boolean] true if the bucket should be kept, false otherwise
      def keep_ruby_bucket?(bucket, min_ruby)
        return true if bucket.nil? || bucket.to_s.strip.empty?
        return true if bucket == "vHEAD"
        return true if min_ruby.nil?

        min_version = Gem::Version.new(min_ruby.to_s)
        match = bucket.to_s.match(RUBY_BUCKET_RE)
        return true unless match

        major = match[1].to_i
        minor = match[2]&.to_i

        return false if min_version.segments[0].to_i > major
        return true if min_version.segments[0].to_i < major

        # Same major
        return true if minor.nil?
        min_minor = min_version.segments[1].to_i
        min_minor <= minor
      end

      # Extract the Ruby bucket (e.g., rMAJOR.MINOR) from a file path.
      #
      # @param rel_path [String] the relative file path
      # @return [String, nil] the Ruby bucket if found, nil otherwise
      def ruby_bucket_for_path(rel_path)
        parts = rel_path.to_s.split("/")
        parts.each do |part|
          base = part.sub(/\.gemfile(\.example)?\z/, "")
          return "vHEAD" if base == "vHEAD"
          return base if base.match?(RUBY_BUCKET_RE)
        end
        nil
      end
    end
  end
end
