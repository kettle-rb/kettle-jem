# frozen_string_literal: true

module Kettle
  module Jem
    # Identifies whether a LICENSE.txt file contains MIT license text and
    # extracts any copyright lines from its preamble.
    #
    # Uses Ast::Merge::Text::FileAnalysis with its +searchable_text+ helper
    # so that phrase matching works regardless of how the author broke lines
    # (MIT license files vary significantly in whitespace and line placement).
    #
    # @example Detect MIT and grab copyright lines
    #   migrator = LicenseTxtMigrator.new(File.read("LICENSE.txt"))
    #   if migrator.mit_license?
    #     puts migrator.copyright_lines.inspect
    #   end
    class LicenseTxtMigrator
      # Key phrases that unambiguously identify MIT license body text.
      # Both must appear (collapsed whitespace) for a positive identification.
      MIT_PHRASES = [
        "permission is hereby granted",
        "without restriction",
      ].freeze

      # @param content [String] Raw text content of the LICENSE.txt file
      def initialize(content)
        @content = content.to_s
        @analysis = Ast::Merge::Text::FileAnalysis.new(@content)
      end

      # @return [Boolean] true when the content is recognisably MIT-licensed
      def mit_license?
        text = @analysis.searchable_text.downcase
        MIT_PHRASES.all? { |phrase| text.include?(phrase) }
      end

      # Extract copyright lines from the preamble — the portion of the file
      # that precedes the first occurrence of "Permission is hereby granted".
      #
      # Each line node is tested individually (via a single-node +searchable_text+
      # call) so that intra-line whitespace is collapsed before matching, making
      # the boundary detection robust to leading/trailing spaces.
      #
      # @return [Array<String>] Lines whose content matches /copyright/i,
      #   preserving original casing and whitespace
      def copyright_lines
        line_nodes = @analysis.statements.select { |n| n.is_a?(Ast::Merge::Text::LineNode) }

        # Find the index of the first line whose collapsed text contains the
        # permission grant — that line and everything after it is the license body.
        boundary_index = line_nodes.index do |node|
          @analysis.searchable_text(nodes: [node]).downcase.include?("permission is hereby granted")
        end

        preamble = boundary_index ? line_nodes.first(boundary_index) : line_nodes
        preamble
          .select { |node| node.content.match?(/copyright/i) }
          .map(&:content)
      end
    end
  end
end
