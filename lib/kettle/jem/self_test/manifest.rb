# frozen_string_literal: true

require "digest"
require "find"

module Kettle
  module Jem
    module SelfTest
      # Generate file-content manifests (path → SHA256) and compare two manifests
      # to classify files as matched, changed, added, or removed.
      module Manifest
        module_function

        # Walk every *file* in +dir+ and compute a SHA256 hex digest for each.
        # Skips directories and binary files that cannot be read.
        #
        # @param dir [String] absolute path to the directory to scan
        # @return [Hash{String => String}] relative_path → hex digest
        def generate(dir)
          result = {}
          dir = dir.to_s
          return result unless Dir.exist?(dir)

          Find.find(dir) do |path|
            next if File.directory?(path)

            # Skip unreadable / binary files
            begin
              content = File.binread(path)
            rescue StandardError
              next
            end

            rel = path.sub(%r{^#{Regexp.escape(dir)}/?}, "")
            next if rel.empty?

            result[rel] = Digest::SHA256.hexdigest(content)
          end

          result
        end

        # Compare two manifests and classify every path.
        #
        # @param before [Hash{String => String}] manifest of the "before" state
        # @param after  [Hash{String => String}] manifest of the "after" state
        # @return [Hash{Symbol => Array<String>}] keys :matched, :changed, :added, :removed
        def compare(before, after)
          all_keys = (before.keys | after.keys).sort

          matched = []
          changed = []
          added = []
          removed = []

          all_keys.each do |key|
            b = before[key]
            a = after[key]

            if b.nil?
              added << key
            elsif a.nil?
              removed << key
            elsif b == a
              matched << key
            else
              changed << key
            end
          end

          {matched: matched, changed: changed, added: added, removed: removed}
        end
      end
    end
  end
end
