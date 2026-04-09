# frozen_string_literal: true

module Kettle
  module Jem
    module GemRubyFloor
      # Computes the effective Ruby version floor for a gemspec by taking the
      # maximum +min_ruby+ across all of the gemspec's runtime dependencies.
      #
      # The floor represents the lowest Ruby version on which ALL runtime
      # dependencies will install. Setting +required_ruby_version+ below this
      # value would cause installs to fail on older Rubies even though the
      # gemspec itself allows it.
      #
      # @example
      #   resolver = Kettle::Jem::GemRubyFloor::Resolver.new
      #   deps = [
      #     { name: "activerecord", version: "7.1.3" },
      #     { name: "version_gem",  version: "1.1.9" },
      #   ]
      #   floor = Kettle::Jem::GemRubyFloor::GemspecFloor.compute(deps, resolver: resolver)
      #   #=> #<Gem::Version "2.7">
      module GemspecFloor
        module_function

        # Computes the minimum Ruby version floor across a set of dependencies.
        #
        # For each dep entry the resolver is asked for the minimum Ruby required
        # by the pinned version. Any entry whose version cannot be resolved (or
        # that declares no +required_ruby_version+) is skipped.
        #
        # The returned floor is always at least {MINIMUM_RUBY_FLOOR} (+2.3+), since
        # setup-ruby cannot provision Rubies older than that.
        #
        # @param deps [Array<Hash>] each entry must have +:name+ (String) and
        #   +:version+ (String, an exact version such as +"7.1.3"+).
        #   Entries with a nil/empty +:version+ are skipped.
        # @param resolver [Resolver] a +Resolver+ instance used to query RubyGems
        # @return [Gem::Version] the computed floor, clamped to {MINIMUM_RUBY_FLOOR}
        def compute(deps, resolver:)
          min_rubies = Array(deps).filter_map do |dep|
            name = dep[:name].to_s
            version = dep[:version].to_s
            next if name.empty? || version.empty?

            resolver.min_ruby_version(name, version)
          rescue StandardError
            nil
          end

          effective = min_rubies.max
          effective ? [effective, MINIMUM_RUBY_FLOOR].max : MINIMUM_RUBY_FLOOR
        end

        # Like {.compute} but also returns a per-dep breakdown for diagnostic output.
        #
        # @param deps [Array<Hash>] same format as {.compute}
        # @param resolver [Resolver]
        # @return [Hash] +:floor+ (+Gem::Version+) and +:details+
        #   (+Array<Hash>+ with +:name+, +:version+, +:min_ruby+ keys)
        def compute_with_details(deps, resolver:)
          details = Array(deps).map do |dep|
            name = dep[:name].to_s
            version = dep[:version].to_s
            min_ruby = if name.empty? || version.empty?
              nil
            else
              resolver.min_ruby_version(name, version)
            end
            {name: name, version: version, min_ruby: min_ruby}
          rescue StandardError
            {name: dep[:name].to_s, version: dep[:version].to_s, min_ruby: nil}
          end

          min_rubies = details.filter_map { |d| d[:min_ruby] }
          effective = min_rubies.max
          floor = effective ? [effective, MINIMUM_RUBY_FLOOR].max : MINIMUM_RUBY_FLOOR

          {floor: floor, details: details}
        end
      end
    end
  end
end
