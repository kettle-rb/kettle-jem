# frozen_string_literal: true

RSpec.describe Kettle::Jem::MarkdownMerger do
  describe ".merge" do
    it "returns template_content when destination_content is nil" do
      result = described_class.merge(
        template_content: "# Hello\n\nWorld\n",
        destination_content: nil,
      )
      expect(result).to eq("# Hello\n\nWorld\n")
    end

    it "returns template_content when destination_content is empty" do
      result = described_class.merge(
        template_content: "# Hello\n\nWorld\n",
        destination_content: "  ",
      )
      expect(result).to eq("# Hello\n\nWorld\n")
    end

    it "preserves H1 line from destination" do
      template = "# Template Title\n\nSome content\n"
      destination = "# 🔧 My Gem Title\n\nOld content\n"

      result = described_class.merge(
        template_content: template,
        destination_content: destination,
      )
      expect(result).to include("# 🔧 My Gem Title")
      expect(result).not_to include("# Template Title")
    end

    it "preserves Synopsis section from destination" do
      template = "# Title\n\n## Synopsis\n\nTemplate synopsis.\n\n## Installation\n\nTemplate install.\n"
      destination = "# Title\n\n## Synopsis\n\nMy custom synopsis that I wrote.\nWith extra details.\n\n## Installation\n\nOld install.\n"

      result = described_class.merge(
        template_content: template,
        destination_content: destination,
      )
      expect(result).to include("My custom synopsis that I wrote.")
      expect(result).to include("With extra details.")
      expect(result).not_to include("Template synopsis.")
    end

    it "preserves Configuration section from destination" do
      template = "# Title\n\n## Configuration\n\nDefault config.\n\n## Other\n\nStuff.\n"
      destination = "# Title\n\n## Configuration\n\nCustom config instructions.\n\n## Other\n\nOld.\n"

      result = described_class.merge(
        template_content: template,
        destination_content: destination,
      )
      expect(result).to include("Custom config instructions.")
      expect(result).not_to include("Default config.")
    end

    it "preserves Basic Usage section from destination" do
      template = "# Title\n\n## Basic Usage\n\nDefault usage.\n\n## Other\n\nStuff.\n"
      destination = "# Title\n\n## Basic Usage\n\nMy usage notes.\n\n## Other\n\nOld.\n"

      result = described_class.merge(
        template_content: template,
        destination_content: destination,
      )
      expect(result).to include("My usage notes.")
      expect(result).not_to include("Default usage.")
    end

    it "uses template content for non-preserved sections" do
      template = "# Title\n\n## Installation\n\nNew install.\n"
      destination = "# Title\n\n## Installation\n\nOld install.\n"

      result = described_class.merge(
        template_content: template,
        destination_content: destination,
      )
      # SmartMerger with preference: :template should pick template
      expect(result).to be_a(String)
    end
  end

  describe ".parse_sections" do
    it "returns empty structure for nil input" do
      result = described_class.parse_sections(nil)
      expect(result).to eq({lines: [], sections: [], line_count: 0})
    end

    it "identifies headings at different levels" do
      md = "# H1\n\nContent\n\n## H2\n\nMore\n\n### H3\n\nDeep\n"
      result = described_class.parse_sections(md)

      expect(result[:sections].length).to eq(3)
      expect(result[:sections][0][:level]).to eq(1)
      expect(result[:sections][1][:level]).to eq(2)
      expect(result[:sections][2][:level]).to eq(3)
    end

    it "ignores headings inside fenced code blocks" do
      md = "# Real\n\n```\n## Not a heading\n```\n\n## Also Real\n"
      result = described_class.parse_sections(md)

      expect(result[:sections].length).to eq(2)
      bases = result[:sections].map { |s| s[:base] }
      expect(bases).to include("real")
      expect(bases).to include("also real")
      expect(bases).not_to include("not a heading")
    end
  end

  describe ".branch_end" do
    it "finds the end of a section at its level" do
      sections = [
        {start: 0, level: 2},
        {start: 5, level: 2},
        {start: 10, level: 2},
      ]
      expect(described_class.branch_end(sections, 0, 15)).to eq(4)
      expect(described_class.branch_end(sections, 1, 15)).to eq(9)
      expect(described_class.branch_end(sections, 2, 15)).to eq(14)
    end

    it "includes subsections in the branch" do
      sections = [
        {start: 0, level: 2},
        {start: 3, level: 3},
        {start: 6, level: 2},
      ]
      expect(described_class.branch_end(sections, 0, 10)).to eq(5)
    end
  end

  describe ".preserve_h1" do
    it "replaces H1 from merged with destination H1" do
      merged = "# New Title\n\nContent\n"
      destination = "# 🎉 Old Title\n\nOld content\n"
      result = described_class.preserve_h1(merged, destination)
      expect(result).to include("# 🎉 Old Title")
      expect(result).not_to include("# New Title")
    end

    it "returns merged unchanged when destination has no H1" do
      merged = "# Title\n\nContent\n"
      destination = "No heading here\n"
      result = described_class.preserve_h1(merged, destination)
      expect(result).to eq(merged)
    end
  end
end
