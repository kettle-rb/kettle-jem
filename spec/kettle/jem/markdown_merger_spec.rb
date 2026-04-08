# frozen_string_literal: true

RSpec.describe Kettle::Jem::MarkdownMerger do
  describe ".merge" do
    let(:recipe) { Kettle::Jem.recipe(:readme) }

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

    it "preserves H1 line from destination when the title text meaning differs" do
      template = "# Template Title\n\nSome content\n"
      destination = "# 🔧 My Gem Title\n\nOld content\n"

      result = described_class.merge(
        template_content: template,
        destination_content: destination,
      )
      expect(result).to include("# 🔧 My Gem Title")
      expect(result).not_to include("# Template Title")
    end

    it "keeps the template H1 when destination differs only by decorative leading adornment" do
      template = "# 🍲 Nomono\n\nSome content\n"
      destination = "# 1️⃣ Nomono\n\nOld content\n"

      result = described_class.merge(
        template_content: template,
        destination_content: destination,
      )

      expect(result).to include("# 🍲 Nomono")
      expect(result).not_to include("# 1️⃣ Nomono")
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

    it "preserves critical destination section bodies while refreshing headings from the template" do
      template = <<~MARKDOWN
        # 🍲 Nomono

        ## 🌻 Synopsis


        ## ⚙️ Configuration


        ## 🔧 Basic Usage


        ## ✨ Installation

        Template install.
      MARKDOWN

      destination = <<~MARKDOWN
        # 1️⃣ Nomono

        ## Synopsis

        Destination synopsis.

        ## Configuration

        Destination configuration.

        ## Basic Usage

        Destination usage.

        ## ✨ Installation

        Old install.
      MARKDOWN

      result = described_class.merge(
        template_content: template,
        destination_content: destination,
      )

      aggregate_failures do
        expect(result).to include("# 🍲 Nomono")
        expect(result).to include("## 🌻 Synopsis\n\nDestination synopsis.")
        expect(result).to include("## ⚙️ Configuration\n\nDestination configuration.")
        expect(result).to include("## 🔧 Basic Usage\n\nDestination usage.")
        expect(result).to include("## ✨ Installation\n\nTemplate install.")
        expect(result).not_to include("## Synopsis\n\nDestination synopsis.")
        expect(result).not_to include("## Configuration\n\nDestination configuration.")
        expect(result).not_to include("## Basic Usage\n\nDestination usage.")
      end
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

    it "accepts an explicit executable recipe" do
      template = "# Title\n\n## Synopsis\n\nTemplate synopsis.\n"
      destination = "# Custom Title\n\n## Synopsis\n\nDestination synopsis.\n"

      result = described_class.merge(
        template_content: template,
        destination_content: destination,
        preset: recipe,
      )

      expect(result).to include("# Custom Title")
      expect(result).to include("Destination synopsis.")
      expect(result).not_to include("Template synopsis.")
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
    it "replaces H1 from merged with destination H1 when the title meaning differs" do
      merged = "# New Title\n\nContent\n"
      destination = "# 🎉 Old Title\n\nOld content\n"
      result = described_class.preserve_h1(merged, destination)
      expect(result).to include("# 🎉 Old Title")
      expect(result).not_to include("# New Title")
    end

    it "keeps the merged/template H1 when destination differs only by decorative leading adornment" do
      merged = "# 🍲 Nomono\n\nContent\n"
      destination = "# 1️⃣ Nomono\n\nOld content\n"

      result = described_class.preserve_h1(merged, destination)

      expect(result).to eq(merged)
    end

    it "returns merged unchanged when destination has no H1" do
      merged = "# Title\n\nContent\n"
      destination = "No heading here\n"
      result = described_class.preserve_h1(merged, destination)
      expect(result).to eq(merged)
    end

    it "preserves a setext-style H1 using AST-backed heading ranges" do
      merged = "New Title\n=========\n\nContent\n"
      destination = "🎉 Old Title\n===========\n\nOld content\n"

      result = described_class.preserve_h1(merged, destination)

      expect(result).to include("🎉 Old Title\n===========")
      expect(result).not_to include("New Title\n=========")
    end
  end

  describe ".validate_fenced_code_blocks!" do
    it "does not raise for properly closed fences" do
      content = "# Title\n\n```ruby\nputs 'hi'\n```\n\n````markdown\n## Example\n````\n"
      expect { described_class.validate_fenced_code_blocks!(content) }.not_to raise_error
    end

    it "does not raise for content with no fences" do
      content = "# Title\n\nJust text.\n"
      expect { described_class.validate_fenced_code_blocks!(content) }.not_to raise_error
    end

    it "raises for an unclosed backtick fence" do
      content = "# Title\n\n```ruby\nputs 'hi'\n\n## Next Section\n"
      expect { described_class.validate_fenced_code_blocks!(content) }.to raise_error(
        Kettle::Dev::Error, /Unclosed fenced code block.*line 3.*```/
      )
    end

    it "raises for an unclosed quad-backtick fence" do
      content = "# Title\n\n````markdown\n## Example\n\n## Another\n"
      expect { described_class.validate_fenced_code_blocks!(content) }.to raise_error(
        Kettle::Dev::Error, /Unclosed fenced code block.*line 3.*````/
      )
    end

    it "raises for an unclosed tilde fence" do
      content = "# Title\n\n~~~\ncode\n\n"
      expect { described_class.validate_fenced_code_blocks!(content) }.to raise_error(
        Kettle::Dev::Error, /Unclosed fenced code block.*line 3.*~~~/
      )
    end

    it "does not raise when a longer fence closes a shorter one" do
      # A closing fence must match the exact opening marker
      content = "# Title\n\n````markdown\n## Example\n````\n"
      expect { described_class.validate_fenced_code_blocks!(content) }.not_to raise_error
    end

    it "includes the label in the error message" do
      content = "```\nunclosed\n"
      expect { described_class.validate_fenced_code_blocks!(content, label: "my file") }.to raise_error(
        Kettle::Dev::Error, /my file/
      )
    end
  end

  describe ".resolve_preserve_targets" do
    let(:src_sections) { {sections: [{base: "synopsis"}, {base: "configuration"}, {base: "basic usage"}, {base: "installation"}]} }
    let(:dest_lookup) { {"synopsis" => {body_branch: "s"}, "configuration" => {body_branch: "c"}, "basic usage" => {body_branch: "u"}} }

    it "returns defaults when config is empty" do
      targets = described_class.resolve_preserve_targets(src_sections, dest_lookup, {})
      expect(targets).to include("synopsis", "configuration", "basic usage")
      expect(targets).not_to include("installation")
    end

    it "uses explicit sections from config" do
      targets = described_class.resolve_preserve_targets(src_sections, dest_lookup, {sections: %w[synopsis installation]})
      expect(targets).to include("synopsis", "installation")
      expect(targets).not_to include("configuration")
    end

    it "matches pattern-based sections" do
      src = {sections: [{base: "synopsis"}, {base: "note: important"}, {base: "setup with rails"}]}
      targets = described_class.resolve_preserve_targets(src, dest_lookup, {patterns: ["note:*", "setup*"]})
      expect(targets).to include("note: important", "setup with rails")
    end

    it "resolves aliases from destination to canonical names" do
      dest = {"usage" => {body_branch: "u"}, "synopsis" => {body_branch: "s"}}
      targets = described_class.resolve_preserve_targets(src_sections, dest, {})
      expect(targets).to include("basic usage")
    end
  end

  describe ".find_aliased_dest_entry" do
    it "finds destination entry via reverse alias lookup" do
      dest_lookup = {"usage" => {body_branch: "dest usage content"}}
      entry = described_class.find_aliased_dest_entry("basic usage", dest_lookup, {})
      expect(entry).to eq({body_branch: "dest usage content"})
    end

    it "finds summary as alias for synopsis" do
      dest_lookup = {"summary" => {body_branch: "dest summary"}}
      entry = described_class.find_aliased_dest_entry("synopsis", dest_lookup, {})
      expect(entry).to eq({body_branch: "dest summary"})
    end

    it "returns nil when no alias matches" do
      dest_lookup = {"other" => {body_branch: "x"}}
      entry = described_class.find_aliased_dest_entry("synopsis", dest_lookup, {})
      expect(entry).to be_nil
    end

    it "uses custom aliases from config" do
      dest_lookup = {"howto" => {body_branch: "howto content"}}
      config = {aliases: {"howto" => "basic usage"}}
      entry = described_class.find_aliased_dest_entry("basic usage", dest_lookup, config)
      expect(entry).to eq({body_branch: "howto content"})
    end
  end

  describe ".matches_preserve_pattern?" do
    it "matches note:* pattern" do
      expect(described_class.matches_preserve_pattern?("note: important", ["note:*"])).to be true
    end

    it "matches setup* pattern" do
      expect(described_class.matches_preserve_pattern?("setup with rails", ["setup*"])).to be true
    end

    it "does not match unrelated headings" do
      expect(described_class.matches_preserve_pattern?("installation", ["note:*", "setup*"])).to be false
    end
  end

  describe "alias-based section preservation via .merge" do
    it "preserves destination Usage body when template has Basic Usage" do
      template = "# Title\n\n## Basic Usage\n\nTemplate usage.\n\n## Installation\n\nInstall.\n"
      destination = "# Title\n\n## Usage\n\nMy custom usage instructions.\n\n## Installation\n\nOld.\n"

      result = described_class.merge(
        template_content: template,
        destination_content: destination,
        preserve_config: {},
      )
      expect(result).to include("My custom usage instructions.")
      expect(result).not_to include("Template usage.")
    end

    it "preserves destination Summary body when template has Synopsis" do
      template = "# Title\n\n## Synopsis\n\nTemplate synopsis.\n\n## Installation\n\nInstall.\n"
      destination = "# Title\n\n## Summary\n\nMy custom summary.\n\n## Installation\n\nOld.\n"

      result = described_class.merge(
        template_content: template,
        destination_content: destination,
        preserve_config: {},
      )
      expect(result).to include("My custom summary.")
      expect(result).not_to include("Template synopsis.")
    end

    it "preserves destination Configuration Options when template has Configuration" do
      template = "# Title\n\n## Configuration\n\nDefault config.\n\n## Other\n\nStuff.\n"
      destination = "# Title\n\n## Configuration Options\n\nCustom config.\n\n## Other\n\nOld.\n"

      result = described_class.merge(
        template_content: template,
        destination_content: destination,
        preserve_config: {},
      )
      expect(result).to include("Custom config.")
      expect(result).not_to include("Default config.")
    end

    it "uses custom preserve_sections from config" do
      template = "# Title\n\n## Custom Section\n\nTemplate custom.\n\n## Other\n\nStuff.\n"
      destination = "# Title\n\n## Custom Section\n\nDest custom content.\n\n## Other\n\nOld.\n"

      result = described_class.merge(
        template_content: template,
        destination_content: destination,
        preserve_config: {sections: ["custom section"]},
      )
      expect(result).to include("Dest custom content.")
      expect(result).not_to include("Template custom.")
    end
  end
end
