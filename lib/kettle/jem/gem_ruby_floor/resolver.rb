# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Kettle
  module Jem
    module GemRubyFloor
      # Queries the RubyGems.org API to resolve a gem's minimum required Ruby version.
      #
      # Results are cached in-memory per instance to avoid redundant HTTP round-trips
      # within a single session.
      #
      # Only the subset of the RubyGems API needed for floor detection is implemented
      # here. Full version-list queries live in +kettle-jem-appraisals+
      # (+GemVersionResolver+), which delegates its floor-detection methods to this
      # class.
      #
      # @example
      #   resolver = Kettle::Jem::GemRubyFloor::Resolver.new
      #   resolver.min_ruby_version("activerecord", "7.1.3")
      #   #=> #<Gem::Version "2.7">
      class Resolver
        # @return [String] Base URL for the RubyGems v1 REST API
        RUBYGEMS_V1_API_BASE = "https://rubygems.org/api/v1"

        # @return [String] Base URL for the RubyGems v2 REST API
        RUBYGEMS_V2_API_BASE = "https://rubygems.org/api/v2/rubygems"

        # @return [Hash] in-memory cache of API responses keyed by request identifier
        attr_reader :cache

        def initialize
          @cache = {}
        end

        # Returns the minimum Ruby version required by a specific gem version.
        #
        # Uses the v1 versions list (which already includes +ruby_version+) rather
        # than the individual v2 endpoint, saving one HTTP request when the full
        # version list has already been fetched.
        #
        # @param gem_name [String] the RubyGems gem name
        # @param version [String] an exact version string (e.g., +"7.1.3"+)
        # @return [Gem::Version, nil] the minimum required Ruby version,
        #   or +nil+ if unspecified / unparseable
        def min_ruby_version(gem_name, version)
          vers = fetch_versions(gem_name)
          entry = vers.find { |v| v["number"] == version }
          return unless entry && entry["ruby_version"]

          parse_min_ruby(entry["ruby_version"])
        end

        # Returns a flat array of raw version hashes for a gem, sorted oldest-to-newest.
        #
        # Each hash is the raw RubyGems v1 JSON object (keys: +"number"+,
        # +"ruby_version"+, +"created_at"+, +"prerelease"+, etc.).
        #
        # @param gem_name [String]
        # @return [Array<Hash>]
        def fetch_versions(gem_name)
          cache_key = "versions:#{gem_name}"
          return @cache[cache_key] if @cache.key?(cache_key)

          uri = URI("#{RUBYGEMS_V1_API_BASE}/versions/#{gem_name}.json")
          response = Net::HTTP.get_response(uri)
          raise "RubyGems API error for #{gem_name}: #{response.code}" unless response.is_a?(Net::HTTPSuccess)

          raw = JSON.parse(response.body)
          @cache[cache_key] = raw.sort_by { |v| Gem::Version.new(v["number"]) }
        end

        # Returns version info (dependencies, ruby_version) for a specific gem version
        # using the RubyGems v2 API.
        #
        # @param gem_name [String]
        # @param version [String] exact version string
        # @return [Hash, nil] raw v2 JSON hash, or +nil+ if not found
        def fetch_gem_info(gem_name, version)
          cache_key = "info:#{gem_name}:#{version}"
          return @cache[cache_key] if @cache.key?(cache_key)

          uri = URI("#{RUBYGEMS_V2_API_BASE}/#{gem_name}/versions/#{version}.json")
          response = Net::HTTP.get_response(uri)
          return unless response.is_a?(Net::HTTPSuccess)

          @cache[cache_key] = JSON.parse(response.body)
        end

        # Parses a +required_ruby_version+ constraint string and extracts the
        # minimum (floor) +Gem::Version+.
        #
        # Handles the most common forms:
        # * +">= 2.7.0"+ → +Gem::Version.new("2.7.0")+
        # * +">= 2.7"+ → +Gem::Version.new("2.7")+
        # * +"~> 3.0"+ → +Gem::Version.new("3.0")+ (pessimistic — base is the floor)
        #
        # @param requirement_str [String, nil]
        # @return [Gem::Version, nil]
        def parse_min_ruby(requirement_str)
          return if requirement_str.nil? || requirement_str.strip.empty?

          req = Gem::Requirement.new(requirement_str)
          # Prefer >= constraints first
          req.requirements.each do |op, ver|
            return ver if op == ">="
          end
          # Fall back to ~> (base version is the effective floor)
          req.requirements.each do |op, ver|
            return ver if op == "~>"
          end
          nil
        rescue ArgumentError
          nil
        end
      end
    end
  end
end
