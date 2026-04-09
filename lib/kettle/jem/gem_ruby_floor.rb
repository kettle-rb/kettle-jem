# frozen_string_literal: true

module Kettle
  module Jem
    # Utilities for determining the minimum Ruby version floor required by a gem
    # or a set of gems, based on their +required_ruby_version+ metadata published
    # on RubyGems.org.
    #
    # This module is extracted here (in +kettle-jem+) so that both
    # +kettle-jem-appraisals+ and the gemspec harmonization pipeline can share
    # the same floor-detection logic without duplication.
    #
    # == Sub-modules
    #
    # * {Resolver}       — thin RubyGems API client (HTTP, cached per instance)
    # * {GemspecFloor}   — computes the max min-ruby across a set of runtime deps
    # * {ShuntedDependencies} — classifies dev deps that must be moved to a modular gemfile
    # * {GemspecAligner} — auto-aligns +required_ruby_version+ in a gemspec to the floor
    # * {DependencyCommentAligner} — rewrites +# ruby >= N.N+ trailing comments on dep lines
    #
    # == Key constant
    #
    # {MINIMUM_RUBY_FLOOR} — absolute minimum Ruby version supported by the
    # +setup-ruby+ GitHub Action (+2.3+). Any computed floor below this value is
    # clamped upward to this constant.
    module GemRubyFloor
      # Absolute minimum Ruby version supported by the +setup-ruby+ GitHub Action.
      # Any gem whose +required_ruby_version+ is lower than this still works in CI
      # because setup-ruby can never provision a Ruby older than 2.3.
      #
      # @return [Gem::Version]
      MINIMUM_RUBY_FLOOR = Gem::Version.new("2.3")

      autoload :Resolver, "kettle/jem/gem_ruby_floor/resolver"
      autoload :GemspecFloor, "kettle/jem/gem_ruby_floor/gemspec_floor"
      autoload :ShuntedDependencies, "kettle/jem/gem_ruby_floor/shunted_dependencies"
      autoload :GemspecAligner, "kettle/jem/gem_ruby_floor/gemspec_aligner"
      autoload :DependencyCommentAligner, "kettle/jem/gem_ruby_floor/dependency_comment_aligner"
    end
  end
end
