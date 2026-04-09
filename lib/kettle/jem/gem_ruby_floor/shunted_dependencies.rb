# frozen_string_literal: true

module Kettle
  module Jem
    module GemRubyFloor
      # Classifies development dependencies as either "shunted" (must be moved to a
      # separate modular gemfile) or "kept" (safe to remain in the gemspec).
      #
      # A dev dependency is shunted when its minimum Ruby requirement is strictly
      # greater than the effective dev-floor for the project:
      #
      #   effective_dev_floor = max(gemspec_min_ruby, MINIMUM_RUBY_FLOOR)
      #
      # The +MINIMUM_RUBY_FLOOR+ (+2.3+) is the oldest Ruby that the
      # +setup-ruby+ GitHub Action can provision.  A dep whose floor is at or
      # below this threshold will therefore never break any CI run, even when
      # the gemspec's own +required_ruby_version+ is lower.
      #
      # == The "≤ 2.3 exception" explained
      #
      # The rule above naturally handles the edge case mentioned in the design:
      # if the gemspec's +min_ruby+ is, say, +2.2+ and a dev dep requires +2.3+,
      # then +effective_dev_floor = max(2.2, 2.3) = 2.3+.  Since +2.3 ≤ 2.3+ the
      # dep is NOT shunted — setup-ruby will never run on Ruby < 2.3 anyway, so
      # no CI job would fail because of it.
      #
      # @example
      #   resolver = Kettle::Jem::GemRubyFloor::Resolver.new
      #   dev_deps = [
      #     { name: "rubocop",   version: "1.60.0" },   # requires ruby >= 2.7
      #     { name: "rake",      version: "13.2.1"  },   # requires ruby >= 2.2
      #   ]
      #   result = Kettle::Jem::GemRubyFloor::ShuntedDependencies.compute(
      #     dev_deps: dev_deps,
      #     gemspec_min_ruby: Gem::Version.new("2.3"),
      #     resolver: resolver,
      #   )
      #   result[:to_shunt]  #=> [{name: "rubocop", version: "1.60.0", min_ruby: #<Gem::Version "2.7">}]
      #   result[:to_keep]   #=> [{name: "rake", ...}]
      module ShuntedDependencies
        module_function

        # Classifies dev deps into those that must be shunted and those that may stay.
        #
        # @param dev_deps [Array<Hash>] each entry must have +:name+ (String),
        #   +:version+ (String, an exact version), and optionally +:constraint+
        #   (String, the gemspec constraint such as +"~> 1.60"+).  Entries whose
        #   +:version+ is nil/empty are skipped and omitted from both arrays.
        # @param gemspec_min_ruby [Gem::Version, String, nil] the gemspec's current
        #   +required_ruby_version+ floor.  Treated as +MINIMUM_RUBY_FLOOR+ when
        #   nil/empty.
        # @param resolver [Resolver] a +Resolver+ instance used to query RubyGems
        # @return [Hash] +:to_shunt+ and +:to_keep+ (both +Array<Hash>+).
        #   Each entry carries +:name+, +:version+, +:constraint+ (may be nil),
        #   and +:min_ruby+ (+Gem::Version+ or +nil+).
        def compute(dev_deps:, gemspec_min_ruby:, resolver:)
          effective_floor = effective_dev_floor(gemspec_min_ruby)
          to_shunt = []
          to_keep = []

          Array(dev_deps).each do |dep|
            name = dep[:name].to_s
            version = dep[:version].to_s
            next if name.empty? || version.empty?

            min_ruby = begin
              resolver.min_ruby_version(name, version)
            rescue StandardError
              nil
            end

            entry = {
              name: name,
              version: version,
              constraint: dep[:constraint],
              min_ruby: min_ruby,
            }

            if min_ruby && min_ruby > effective_floor
              to_shunt << entry
            else
              to_keep << entry
            end
          end

          {to_shunt: to_shunt, to_keep: to_keep, effective_floor: effective_floor}
        end

        # Convenience entry point: loads a gemspec, finds the latest published version
        # of each development dependency that satisfies the gemspec constraint, and
        # then calls {.compute}.
        #
        # @param gemspec_path [String] absolute path to the +.gemspec+ file
        # @param resolver [Resolver] a +Resolver+ instance used to query RubyGems
        # @return [Hash] same as {.compute}, plus +:gemspec_min_ruby+ key
        def compute_from_gemspec(gemspec_path:, resolver:)
          spec = Gem::Specification.load(gemspec_path)
          return {to_shunt: [], to_keep: [], effective_floor: MINIMUM_RUBY_FLOOR, gemspec_min_ruby: nil} unless spec

          min_ruby = extract_gemspec_min_ruby(spec)

          dev_deps = spec.development_dependencies.filter_map do |dep|
            latest = latest_matching_version(dep.name, dep.requirements, resolver)
            next unless latest

            {
              name: dep.name,
              version: latest,
              constraint: dep.requirements.to_s,
            }
          end

          result = compute(dev_deps: dev_deps, gemspec_min_ruby: min_ruby, resolver: resolver)
          result.merge(gemspec_min_ruby: min_ruby)
        rescue StandardError
          {to_shunt: [], to_keep: [], effective_floor: MINIMUM_RUBY_FLOOR, gemspec_min_ruby: nil}
        end

        # Returns the effective dev floor: +max(gemspec_min_ruby, MINIMUM_RUBY_FLOOR)+.
        #
        # @param gemspec_min_ruby [Gem::Version, String, nil]
        # @return [Gem::Version]
        def effective_dev_floor(gemspec_min_ruby)
          return MINIMUM_RUBY_FLOOR if gemspec_min_ruby.nil?

          v = gemspec_min_ruby.is_a?(Gem::Version) ? gemspec_min_ruby : Gem::Version.new(gemspec_min_ruby.to_s)
          [v, MINIMUM_RUBY_FLOOR].max
        rescue ArgumentError
          MINIMUM_RUBY_FLOOR
        end

        private

        def extract_gemspec_min_ruby(spec)
          return nil unless spec.required_ruby_version

          tuple = Gem::Requirement.parse(spec.required_ruby_version)
          tuple[1]
        rescue StandardError
          nil
        end

        # Finds the latest published version of +gem_name+ that satisfies +requirements+.
        #
        # Walks the cached version list from newest to oldest and returns the first
        # exact version string that satisfies the gemspec constraint.
        def latest_matching_version(gem_name, requirements, resolver)
          raw_versions = resolver.fetch_versions(gem_name)
          return if raw_versions.empty?

          req = Gem::Requirement.new(requirements.to_s)
          raw_versions.reverse_each do |v|
            return v["number"] if req.satisfied_by?(Gem::Version.new(v["number"]))
          end
          nil
        rescue StandardError
          nil
        end
      end
    end
  end
end
