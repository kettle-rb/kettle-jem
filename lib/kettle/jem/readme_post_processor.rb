# frozen_string_literal: true

module Kettle
  module Jem
    module ReadmePostProcessor
      module_function

      # Fixed-version engine badges mapped to the MRI they target.
      # "current" (`-c-i`) and "HEAD" badges are intentionally omitted from
      # this matrix because they track moving engine releases dynamically.
      ENGINE_COMPATIBILITY_MRI_VERSION = {
        "jruby" => {
          "9.1" => Gem::Version.new("2.3"),
          "9.2" => Gem::Version.new("2.5"),
          "9.3" => Gem::Version.new("2.6"),
          "9.4" => Gem::Version.new("3.1"),
          "10.0" => Gem::Version.new("3.4"),
        }.freeze,
        "truby" => {
          "22.3" => Gem::Version.new("3.0"),
          "23.0" => Gem::Version.new("3.0"),
          "23.1" => Gem::Version.new("3.1"),
          "23.2" => Gem::Version.new("3.2"),
          "24.2" => Gem::Version.new("3.3"),
          "25.0" => Gem::Version.new("3.3"),
        }.freeze,
      }.freeze
      COMPATIBILITY_ROW_PREFIX_RE = /\A\| Works with (?:MRI Ruby|JRuby|Truffle Ruby)/.freeze
      COMPATIBILITY_REFERENCE_LABEL_RE = /\A(?:💎(?:ruby|jruby|truby)-|🚎)/.freeze

      def process(content:, min_ruby:)
        return content unless min_ruby

        processed = remove_incompatible_compatibility_badges(content, min_ruby)
        processed = normalize_compatibility_rows(processed)
        prune_unused_compatibility_reference_definitions(processed)
      end

      def remove_incompatible_compatibility_badges(content, min_ruby)
        labels = content.scan(/\[(💎(?:ruby|jruby|truby)-[^\]]+)\]/).flatten.uniq

        labels.each do |label|
          badge_min_mri = compatibility_badge_min_mri(label)
          next unless badge_min_mri && badge_min_mri < min_ruby

          content = remove_badge_occurrences(content, label)
        end

        content
      end

      def compatibility_badge_min_mri(label)
        if (match = label.match(/\A💎ruby-(?<version>\d+\.\d+)i\z/))
          Gem::Version.new(match[:version])
        elsif (match = label.match(/\A💎(?<engine>jruby|truby)-(?<version>\d+\.\d+)i\z/))
          ENGINE_COMPATIBILITY_MRI_VERSION.dig(match[:engine], match[:version])
        end
      rescue StandardError => e
        Kettle::Dev.debug_error(e, __method__)
        nil
      end

      def remove_badge_occurrences(content, label)
        label_re = Regexp.escape(label)
        content = content.gsub(/\s*\[!\[[^\]]*?\]\s*\[#{label_re}\]\s*\]\s*\[[^\]]+\]\s*/, " ")
        content.gsub(/\s*!\[[^\]]*?\]\s*\[#{label_re}\]\s*/, " ")
      end

      def normalize_compatibility_rows(content)
        content.lines.filter_map do |line|
          next line unless compatibility_row?(line)

          cells = line.split("|", -1)
          badge_cell = normalize_compatibility_badge_cell(cells[2])
          next if badge_cell.empty?

          cells[2] = " #{badge_cell}"
          cells.join("|")
        end.join
      end

      def normalize_compatibility_badge_cell(cell)
        cell.to_s
          .split(/<br\/>/i)
          .filter_map do |segment|
            normalized = segment.gsub(/[ \t]+/, " ").strip
            normalized unless normalized.empty?
          end
          .join(" <br/> ")
      end

      def compatibility_row?(line)
        COMPATIBILITY_ROW_PREFIX_RE.match?(line)
      end

      def prune_unused_compatibility_reference_definitions(content)
        referenced_labels = {}

        content.lines.each do |line|
          next if line.match?(/^\[[^\]]+\]:/)

          line.scan(/\]\[([^\]]+)\]/) do |match|
            referenced_labels[match.first] = true
          end
        end

        content.lines.reject do |line|
          label = line[/^\[([^\]]+)\]:/, 1]
          label && COMPATIBILITY_REFERENCE_LABEL_RE.match?(label) && !referenced_labels[label]
        end.join
      end
    end
  end
end
