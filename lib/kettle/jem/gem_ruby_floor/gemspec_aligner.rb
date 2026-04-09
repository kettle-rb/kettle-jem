# frozen_string_literal: true

module Kettle
  module Jem
    module GemRubyFloor
      # Aligns a gemspec's +required_ruby_version+ to the maximum of all runtime
      # dependencies' minimum Ruby requirements.
      #
      # If the computed floor is strictly higher than the current gemspec value,
      # this aligner:
      #   1. Writes an ALL-CAPS warning to +$stderr+.
      #   2. Updates the +required_ruby_version+ line in the gemspec.
      #   3. Bumps the major version in the gem's version file (+VERSION+
      #      constant reset to +<X+1>.0.0+).
      #
      # @example
      #   result = GemspecAligner.align_required_ruby_version(
      #     gemspec_path: "/path/to/my_gem.gemspec",
      #     resolver: Kettle::Jem::GemRubyFloor::Resolver.new,
      #   )
      #   result # => { previous: "2.3", new: "3.0", changed: true }
      module GemspecAligner
        module_function

        REQUIRED_RUBY_RE = /^(\s*\w+\.required_ruby_version\s*=\s*["'])([^"']+)(["'].*)$/
        VERSION_CONST_RE = /^(\s*VERSION\s*=\s*["'])(\d+)\.(\d+)\.(\d+)(["'].*)$/

        # Align +required_ruby_version+ to the computed floor.
        #
        # @param gemspec_path [String] absolute path to the +.gemspec+ file
        # @param resolver [Resolver] used to query RubyGems for dep min-ruby data
        # @param dry_run [Boolean] when true, computes and returns results without
        #   writing any files (default: +false+)
        # @return [Hash] +:previous+ (+String+ or +nil+), +:new+ (+String+ or +nil+),
        #   +:changed+ (+Boolean+), +:version_file+ (+String+ or +nil+),
        #   +:version_bumped+ (+Boolean+)
        def align_required_ruby_version(gemspec_path:, resolver:, dry_run: false)
          spec = Gem::Specification.load(gemspec_path)
          return no_op_result unless spec

          # Current gemspec floor
          current_floor = extract_required_ruby(spec)

          # Compute floor from runtime deps
          runtime_deps = spec.runtime_dependencies.map { |d| {name: d.name, requirements: d.requirements} }
          computed_floor = resolve_floor(runtime_deps, resolver)

          return no_op_result(previous: current_floor&.to_s) unless computed_floor

          if current_floor && computed_floor <= current_floor
            return {
              previous: current_floor.to_s,
              new: current_floor.to_s,
              changed: false,
              version_file: nil,
              version_bumped: false,
            }
          end

          # computed_floor > current_floor — a raise is needed
          previous_str = current_floor&.to_s
          new_str      = computed_floor.to_s

          warn_floor_raised(previous_str, new_str, gemspec_path)

          version_file   = nil
          version_bumped = false

          unless dry_run
            update_gemspec_floor(gemspec_path, new_str)

            version_file   = find_version_file(spec)
            version_bumped = bump_major_version(version_file) if version_file
          end

          {
            previous: previous_str,
            new: new_str,
            changed: true,
            version_file: version_file,
            version_bumped: version_bumped,
          }
        rescue StandardError => e
          warn("GemspecAligner error: #{e.message}")
          no_op_result
        end

        private

        def no_op_result(previous: nil)
          {previous: previous, new: nil, changed: false, version_file: nil, version_bumped: false}
        end

        def extract_required_ruby(spec)
          req = spec.required_ruby_version
          return nil unless req

          tuple = Gem::Requirement.parse(req)
          tuple[1]
        rescue StandardError
          nil
        end

        def resolve_floor(runtime_deps, resolver)
          dep_hashes = runtime_deps.filter_map do |dep|
            versions = resolver.fetch_versions(dep[:name])
            next if versions.empty?

            req  = Gem::Requirement.new(dep[:requirements].to_s)
            best = versions.reverse_each.find { |v| req.satisfied_by?(Gem::Version.new(v["number"])) }
            next unless best

            {name: dep[:name], version: best["number"]}
          end

          return nil if dep_hashes.empty?

          Kettle::Jem::GemRubyFloor::GemspecFloor.compute(dep_hashes, resolver: resolver)
        end

        def warn_floor_raised(previous, new_floor, gemspec_path)
          border = "=" * 72
          $stderr.puts border
          $stderr.puts "WARNING: REQUIRED_RUBY_VERSION RAISED"
          $stderr.puts "  GEMSPEC : #{gemspec_path}"
          $stderr.puts "  PREVIOUS: #{previous || "(none)"}"
          $stderr.puts "  NEW     : #{new_floor}"
          $stderr.puts "  ACTION  : UPDATING GEMSPEC AND BUMPING MAJOR VERSION"
          $stderr.puts border
        end

        def update_gemspec_floor(gemspec_path, new_floor)
          content = File.read(gemspec_path)
          updated = content.gsub(REQUIRED_RUBY_RE) do
            # Preserve operator (>= / ~>) that was already there
            prefix   = ::Regexp.last_match(1)
            old_ver  = ::Regexp.last_match(2)
            suffix   = ::Regexp.last_match(3)
            # Keep the operator but replace the version number
            op       = old_ver.match(/\A([><=~!]+\s*)/) ? ::Regexp.last_match(1) : ">= "
            "#{prefix}#{op}#{new_floor}#{suffix}"
          end
          File.write(gemspec_path, updated)
        end

        def find_version_file(spec)
          return nil unless spec.name && !spec.name.empty?

          # Convention: lib/<gem_name_path>/version.rb
          name_path = spec.name.tr("-", "/")
          candidate = File.join(File.dirname(spec.loaded_from), "lib", name_path, "version.rb")
          return candidate if File.exist?(candidate)

          # Broader search within lib/
          lib_dir = File.join(File.dirname(spec.loaded_from), "lib")
          Dir.glob(File.join(lib_dir, "**", "version.rb")).first
        end

        def bump_major_version(version_file)
          return false unless version_file && File.exist?(version_file)

          content = File.read(version_file)
          bumped  = false

          updated = content.gsub(VERSION_CONST_RE) do
            prefix = ::Regexp.last_match(1)
            major  = ::Regexp.last_match(2).to_i
            suffix = ::Regexp.last_match(5)
            bumped = true
            "#{prefix}#{major + 1}.0.0#{suffix}"
          end

          File.write(version_file, updated) if bumped
          bumped
        end
      end
    end
  end
end
