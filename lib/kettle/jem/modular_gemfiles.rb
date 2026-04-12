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

      # Generate (or update) +gemfiles/modular/shunted.gemfile+ with the dev
      # dependencies from the gemspec that must be shunted to a higher-Ruby
      # environment.
      #
      # This method requires a live network-capable +resolver+ to look up each
      # gem's minimum Ruby on RubyGems.org.  Pass +resolver: nil+ (or omit the
      # keyword) to skip the step gracefully.
      #
      # The generated block is bracketed by machine-managed sentinels:
      #
      #   # <<kettle-jem:generated>> — do not edit below this line
      #   ...
      #   # <</kettle-jem:generated>>
      #
      # Content outside (and including) freeze-token blocks is preserved
      # unchanged.
      #
      # @param helpers      [Kettle::Jem::TemplateHelpers] helper API
      # @param project_root [String] destination project root
      # @param resolver     [Kettle::Jem::GemRubyFloor::Resolver, nil] resolver used to
      #   determine each gem's minimum Ruby.  When nil, no file is written.
      # @return [void]
      def sync_shunted_gemfile!(helpers:, project_root:, resolver: nil)
        unless resolver
          helpers.add_warning("sync_shunted_gemfile!: no resolver provided; skipping shunted.gemfile generation")
          return
        end

        gemspec_path = Dir.glob(File.join(project_root, "*.gemspec")).first
        unless gemspec_path
          helpers.add_warning("sync_shunted_gemfile!: no gemspec found in #{Kettle::Jem.display_path(project_root)}; skipping")
          return
        end

        result = Kettle::Jem::GemRubyFloor::ShuntedDependencies.compute_from_gemspec(
          gemspec_path: gemspec_path,
          resolver: resolver,
        )

        dest = File.join(project_root, MODULAR_GEMFILE_DIR, "shunted.gemfile")
        FileUtils.mkdir_p(File.dirname(dest))
        generated_block = build_shunted_generated_block(result)

        if File.exist?(dest)
          existing = File.read(dest)
          updated = replace_generated_block(existing, generated_block)
          if updated != existing
            File.write(dest, updated)
          end
        else
          # New file — use the template header then append the generated block
          template_src = File.join(helpers.template_root, MODULAR_GEMFILE_DIR, "shunted.gemfile.example")
          header = File.exist?(template_src) ? File.read(template_src) : default_shunted_header
          File.write(dest, header.chomp + "\n" + generated_block)
        end
      rescue StandardError => e
        helpers.add_warning("sync_shunted_gemfile!: #{e.message}")
      end

      # @api private
      SHUNTED_GENERATED_OPEN = "# <<kettle-jem:generated>> — do not edit below this line\n"
      SHUNTED_GENERATED_CLOSE = "# <</kettle-jem:generated>>\n"

      # @api private
      def build_shunted_generated_block(result)
        lines = []
        lines << SHUNTED_GENERATED_OPEN
        if result[:to_shunt].empty?
          lines << "# (no shunted dependencies)\n"
        else
          result[:to_shunt].each do |dep|
            comment = dep[:min_ruby] ? " # ruby >= #{dep[:min_ruby]}" : ""
            constraint = dep[:constraint] ? ", \"#{dep[:constraint]}\"" : ""
            lines << "gem \"#{dep[:name]}\"#{constraint}#{comment}\n"
          end
        end
        lines << SHUNTED_GENERATED_CLOSE
        lines.join
      end

      # @api private
      def replace_generated_block(content, new_block)
        open_re = /^#{Regexp.escape(SHUNTED_GENERATED_OPEN.strip)}\n/
        close_re = /^#{Regexp.escape(SHUNTED_GENERATED_CLOSE.strip)}\n?/

        open_idx = content.index(open_re)
        close_idx = content.index(close_re)

        if open_idx && close_idx
          # Replace everything from open sentinel through (and including) close sentinel
          close_end = close_idx + content[close_idx..].match(close_re)[0].length
          content[open_idx...close_end] = new_block
          content
        else
          content.chomp + "\n" + new_block
        end
      end

      # @api private
      def default_shunted_header
        <<~HEADER
          # frozen_string_literal: true

          # Shunted development dependencies (requires Ruby > project dev floor).
          # Regenerated by `rake template` — use freeze/unfreeze tokens to preserve custom additions.
        HEADER
      end
    end
  end
end
