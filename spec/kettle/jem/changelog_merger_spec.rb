# frozen_string_literal: true

RSpec.describe Kettle::Jem::ChangelogMerger do
  describe ".merge" do
    let(:recipe) { Kettle::Jem.recipe(:changelog) }

    it "returns template_content when destination_content is nil" do
      result = described_class.merge(
        template_content: "# Changelog\n\n## [Unreleased]\n### Added\n",
        destination_content: nil,
      )
      expect(result).to include("# Changelog")
    end

    it "returns template_content when destination_content is empty" do
      result = described_class.merge(
        template_content: "# Changelog\n\n## [Unreleased]\n### Added\n",
        destination_content: "  ",
      )
      expect(result).to include("# Changelog")
    end

    it "preserves destination Unreleased items under standard headings" do
      template = <<~MD
        # Changelog

        ## [Unreleased]
        ### Added
        ### Changed
        ### Deprecated
        ### Removed
        ### Fixed
        ### Security
      MD

      destination = <<~MD
        # Changelog

        ## [Unreleased]
        ### Added
        - New feature A
        - New feature B
        ### Fixed
        - Bug fix X

        ## [1.0.0] - 2025-01-01
        ### Added
        - Initial release
      MD

      result = described_class.merge(
        template_content: template,
        destination_content: destination,
      )

      expect(result).to include("- New feature A")
      expect(result).to include("- New feature B")
      expect(result).to include("- Bug fix X")
      # All six standard subheadings should be present
      expect(result).to include("### Added")
      expect(result).to include("### Changed")
      expect(result).to include("### Deprecated")
      expect(result).to include("### Removed")
      expect(result).to include("### Fixed")
      expect(result).to include("### Security")
    end

    it "preserves version history from destination" do
      template = <<~MD
        # Changelog

        ## [Unreleased]
        ### Added
      MD

      destination = <<~MD
        # Changelog

        ## [Unreleased]
        ### Added

        ## [2.0.0] - 2025-06-01
        ### Changed
        - Major rewrite

        ## [1.0.0] - 2025-01-01
        ### Added
        - Initial release
      MD

      result = described_class.merge(
        template_content: template,
        destination_content: destination,
      )

      expect(result).to include("## [2.0.0] - 2025-06-01")
      expect(result).to include("- Major rewrite")
      expect(result).to include("## [1.0.0] - 2025-01-01")
      expect(result).to include("- Initial release")
    end

    it "uses template header content" do
      template = <<~MD
        # Changelog

        All notable changes to this project will be documented in this file.

        ## [Unreleased]
        ### Added
      MD

      destination = <<~MD
        # Change Log

        Old header text.

        ## [Unreleased]
        ### Added
        - Something
      MD

      result = described_class.merge(
        template_content: template,
        destination_content: destination,
      )

      expect(result).to include("All notable changes to this project")
      expect(result).not_to include("Old header text")
    end

    it "normalizes whitespace in release headers" do
      template = "# Changelog\n\n## [Unreleased]\n### Added\n"
      destination = "# Changelog\n\n## [Unreleased]\n### Added\n\n## [1.0.0]  -  2025-01-01\n### Added\n- Thing\n"

      result = described_class.merge(
        template_content: template,
        destination_content: destination,
      )

      expect(result).to include("## [1.0.0] - 2025-01-01")
      expect(result).not_to include("## [1.0.0]  -  2025-01-01")
    end

    it "inserts blank lines between subheadings in the Unreleased section" do
      template = <<~MD
        # Changelog

        ## [Unreleased]
        ### Added
        ### Changed
        ### Deprecated
        ### Removed
        ### Fixed
        ### Security
      MD

      destination = <<~MD
        # Changelog

        ## [Unreleased]

        ### Added

        ### Changed

        ### Deprecated

        ### Removed

        ### Fixed

        ### Security

        ## [1.0.0] - 2025-01-01
        ### Added
        - Initial release
      MD

      result = described_class.merge(
        template_content: template,
        destination_content: destination,
      )

      # Each subheading should be preceded by a blank line
      expect(result).to include("## [Unreleased]\n\n### Added"),
        "Expected blank line between ## [Unreleased] and ### Added, got:\n#{result}"
      expect(result).to include("### Added\n\n### Changed"),
        "Expected blank line between ### Added and ### Changed, got:\n#{result}"
      expect(result).to include("### Changed\n\n### Deprecated"),
        "Expected blank line between ### Changed and ### Deprecated, got:\n#{result}"
      expect(result).to include("### Deprecated\n\n### Removed"),
        "Expected blank line between ### Deprecated and ### Removed, got:\n#{result}"
      expect(result).to include("### Removed\n\n### Fixed"),
        "Expected blank line between ### Removed and ### Fixed, got:\n#{result}"
      expect(result).to include("### Fixed\n\n### Security"),
        "Expected blank line between ### Fixed and ### Security, got:\n#{result}"
    end

    it "inserts blank lines between subheadings that have content" do
      template = <<~MD
        # Changelog

        ## [Unreleased]
        ### Added
        ### Changed
        ### Deprecated
        ### Removed
        ### Fixed
        ### Security
      MD

      destination = <<~MD
        # Changelog

        ## [Unreleased]

        ### Added

        - New feature

        ### Changed

        ### Deprecated

        ### Removed

        ### Fixed

        - Bug fix

        ### Security

        ## [1.0.0] - 2025-01-01
        ### Added
        - Initial release
      MD

      result = described_class.merge(
        template_content: template,
        destination_content: destination,
      )

      # Subheadings with items: items follow heading directly
      expect(result).to include("### Added\n- New feature"),
        "Expected items to follow heading directly, got:\n#{result}"
      expect(result).to include("### Fixed\n- Bug fix"),
        "Expected items to follow heading directly, got:\n#{result}"
      # Blank lines between sections (after items, before next heading)
      expect(result).to include("- New feature\n\n### Changed"),
        "Expected blank line after items before next heading, got:\n#{result}"
      expect(result).to include("- Bug fix\n\n### Security"),
        "Expected blank line after items before next heading, got:\n#{result}"
    end

    it "accepts an explicit executable recipe" do
      template = <<~MD
        # Changelog

        ## [Unreleased]
        ### Added
        ### Fixed
      MD

      destination = <<~MD
        # Changelog

        ## [Unreleased]
        ### Fixed
        - Bug fix X
      MD

      result = described_class.merge(
        template_content: template,
        destination_content: destination,
        preset: recipe,
      )

      expect(result).to include("### Added")
      expect(result).to include("### Fixed\n- Bug fix X")
    end

    it "preserves nested bullets and fenced code blocks before trailing link references" do
      template = <<~MD
        # Changelog

        ## [Unreleased]
        ### Added
        ### Changed
        ### Deprecated
        ### Removed
        ### Fixed
        ### Security
      MD

      destination = <<~MD
        # Changelog

        ## [Unreleased]
        ### Added

        - Add helper with example usage

          ```ruby
          puts "hello"
          ```
        - Nested bullets too
          - first nested item
          - second nested item

        ### Fixed
        - Keep this fix

        [Unreleased]: https://github.com/org/repo/compare/v1.0.0...HEAD
        [1.0.0]: https://github.com/org/repo/compare/abc...v1.0.0
      MD

      result = described_class.merge(
        template_content: template,
        destination_content: destination,
      )

      expect(result).to include("### Added\n- Add helper with example usage")
      expect(result).to include("```ruby")
      expect(result).to include("puts \"hello\"")
      expect(result).to include("- Nested bullets too")
      expect(result).to include("  - first nested item")
      expect(result).to include("  - second nested item")
      expect(result).to include("### Fixed\n- Keep this fix")
      expect(result).to include("[Unreleased]: https://github.com/org/repo/compare/v1.0.0...HEAD")
      expect(result).to include("[1.0.0]: https://github.com/org/repo/compare/abc...v1.0.0")
    end
  end

  describe ".parse_items" do
    it "parses list items under subheadings" do
      lines = [
        "### Added",
        "- Item one",
        "- Item two",
        "### Fixed",
        "- Fix one",
      ]
      result = described_class.parse_items(lines)

      expect(result["### Added"]).to eq(["- Item one", "- Item two"])
      expect(result["### Fixed"]).to eq(["- Fix one"])
    end

    it "handles multi-line list items with indentation" do
      lines = [
        "### Added",
        "- Item one",
        "  with continuation",
        "- Item two",
      ]
      result = described_class.parse_items(lines)

      expect(result["### Added"]).to eq(["- Item one", "  with continuation", "- Item two"])
    end

    it "handles fenced code blocks within list items" do
      lines = [
        "### Added",
        "- Item with code",
        "  ```ruby",
        "  puts 'hello'",
        "  ```",
        "- Next item",
      ]
      result = described_class.parse_items(lines)

      expect(result["### Added"].length).to eq(5)
      expect(result["### Added"]).to include("  ```ruby")
    end

    it "uses markdown analysis to group H3 sections when source is provided" do
      source = <<~MD
        ### Added

        - Item one
          - nested item

          ```ruby
          puts "hello"
          ```

        ### Fixed

        - Fix one
      MD

      result = described_class.parse_items([], source: source)

      expect(result["### Added"]).to eq([
        "- Item one",
        "  - nested item",
        "",
        "  ```ruby",
        "  puts \"hello\"",
        "  ```",
      ])
      expect(result["### Fixed"]).to eq(["- Fix one"])
    end
  end

  describe ".find_section_end" do
    it "finds end at next version heading" do
      lines = [
        "# Changelog",
        "",
        "## [Unreleased]",
        "### Added",
        "- Thing",
        "",
        "## [1.0.0] - 2025-01-01",
        "### Added",
        "- Initial",
      ]
      result = described_class.find_section_end(lines, 2)
      expect(result).to eq(5)
    end

    it "returns last line when no next heading" do
      lines = [
        "## [Unreleased]",
        "### Added",
        "- Thing",
      ]
      result = described_class.find_section_end(lines, 0)
      expect(result).to eq(2)
    end

    it "returns nil when idx is nil" do
      result = described_class.find_section_end(["line"], nil)
      expect(result).to be_nil
    end

    it "stops before link reference definitions" do
      lines = [
        "## [Unreleased]",
        "### Added",
        "- Thing",
        "",
        "### Security",
        "",
        "[Unreleased]: https://github.com/org/repo/compare/v1.0.0...HEAD",
        "[1.0.0]: https://github.com/org/repo/compare/abc...v1.0.0",
      ]
      result = described_class.find_section_end(lines, 0)
      expect(result).to eq(5)
    end
  end

  describe "link reference preservation" do
    it "preserves destination link references at the bottom of the file" do
      template = <<~MD
        # Changelog

        ## [Unreleased]
        ### Added
        ### Security

        [Unreleased]: https://github.com/org/repo/compare/v1.0.0...HEAD
        [1.0.0]: https://github.com/org/repo/compare/abc...v1.0.0
        [1.0.0t]: https://github.com/org/repo/tags/v1.0.0
      MD

      destination = <<~MD
        # Changelog

        ## [Unreleased]
        ### Added
        ### Security

        [Unreleased]: https://github.com/org/repo/compare/v1.0.0...HEAD
        [1.0.0]: https://github.com/org/repo/compare/deadbeef...v1.0.0
        [1.0.0t]: https://github.com/org/repo/tags/v1.0.0
      MD

      result = described_class.merge(
        template_content: template,
        destination_content: destination,
      )

      expect(result).to include("[Unreleased]: https://github.com/org/repo/compare/v1.0.0...HEAD")
      expect(result).to include("[1.0.0]: https://github.com/org/repo/compare/deadbeef...v1.0.0")
      expect(result).to include("[1.0.0t]: https://github.com/org/repo/tags/v1.0.0")
    end

    it "preserves link references when destination has no version headings" do
      template = <<~MD
        # Changelog

        ## [Unreleased]
        ### Added
        ### Security
      MD

      destination = <<~MD
        # Changelog

        ## [Unreleased]
        ### Added
        ### Fixed
        - Some fix

        ### Security

        [Unreleased]: https://github.com/org/repo/compare/v1.0.0...HEAD
        [1.0.0]: https://github.com/org/repo/compare/abc...v1.0.0
      MD

      result = described_class.merge(
        template_content: template,
        destination_content: destination,
      )

      expect(result).to include("### Security")
      expect(result).to include("[Unreleased]: https://github.com/org/repo/compare/v1.0.0...HEAD")
      expect(result).to include("[1.0.0]: https://github.com/org/repo/compare/abc...v1.0.0")
      expect(result).to include("- Some fix")
    end
  end

  describe "trailing newline" do
    it "ensures output ends with a newline" do
      result = described_class.merge(
        template_content: "# Changelog\n\n## [Unreleased]\n### Added\n### Security\n",
        destination_content: "# Changelog\n\n## [Unreleased]\n### Added\n### Security\n",
      )
      expect(result).to end_with("\n")
    end
  end
end
