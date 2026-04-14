# frozen_string_literal: true

require "spec_helper"

RSpec.describe Kettle::Jem::Crispr do
  let(:anchor) { Struct.new(:start_line, :end_line, :node).new(2, 2, nil) }
  let(:injection_point) { Struct.new(:anchor).new(anchor) }

  describe described_class::Limit do
    it "normalizes operator-string arrays into a cardinality predicate" do
      limit = described_class.new([">= 1", "<= 3"])

      expect(limit.allows?(0)).to be(false)
      expect(limit.allows?(2)).to be(true)
      expect(limit.allows?(4)).to be(false)
      expect(limit.describe).to eq(">= 1 and <= 3")
    end
  end

  describe described_class::Selectors do
    let(:target) do
      described_class.comment_region_owned_owner(
        marker: "### MANAGED SNIPPET",
        limit: {exactly: 1},
      )
    end

    it "finds the comment-region-owned structural owner span" do
      content = <<~RUBY
        ### MANAGED SNIPPET
        begin
          puts "managed"
        rescue LoadError
          nil
        end

        task :default do
          puts "ok"
        end
      RUBY

      context = Kettle::Jem::Crispr::DocumentContext.new(content: content, source_label: "Rakefile")
      matches = target.locate_matches(context)

      expect(matches.size).to eq(1)
      expect(matches.first.start_line).to eq(1)
      expect(matches.first.end_line).to eq(7)
      expect(matches.first.slice_from(content)).to include('puts "managed"')
    end

    it "finds a markdown heading-owned section span via the Markly adapter" do
      content = <<~MARKDOWN
        # Title

        ## Synopsis

        Custom synopsis.

        ### Details

        Deep detail.

        ## Install

        Install text.
      MARKDOWN

      target = described_class.heading_section(heading_text: "Synopsis", level: 2)
      context = Kettle::Jem::Crispr::DocumentContext.new(
        content: content,
        source_label: "README.md",
        adapter: Kettle::Jem::Crispr::Adapters::MarkdownMarkly.new,
      )

      matches = target.locate_matches(context)

      expect(matches.size).to eq(1)
      expect(matches.first.start_line).to eq(3)
      expect(matches.first.end_line).to eq(10)
      expect(matches.first.slice_from(content)).to include("### Details")
      expect(matches.first.slice_from(content)).not_to include("## Install")
    end
  end

  describe described_class::Replace do
    it "fails closed when target cardinality is out of bounds" do
      content = <<~RUBY
        ### MANAGED SNIPPET
        puts "one"

        ### MANAGED SNIPPET
        puts "two"
      RUBY

      target = Kettle::Jem::Crispr::Selectors.comment_region_owned_owner(marker: "### MANAGED SNIPPET")
      actor = described_class.result(content: content, target: target, replacement: "puts \"fresh\"\n")

      expect(actor.failure?).to be(true)
      expect(actor.error).to include("matched 2 node(s); expected == 1")
    end

    it "replaces a markdown heading-owned section without touching sibling sections" do
      content = <<~MARKDOWN
        # Title

        ## Synopsis

        Old synopsis.

        ## Install

        Install text.
      MARKDOWN

      actor = described_class.call(
        content: content,
        target: Kettle::Jem::Crispr::Selectors.heading_section(heading_text: "Synopsis", level: 2),
        replacement: "## Synopsis\n\nNew synopsis.\n",
        source_label: "README.md",
      )

      expect(actor.changed).to be(true)
      expect(actor.updated_content).to include("New synopsis.")
      expect(actor.updated_content).not_to include("Old synopsis.")
      expect(actor.updated_content).to include("## Install\n\nInstall text.")
    end
  end

  describe described_class::Delete do
    it "deletes the structurally owned statement span" do
      content = <<~RUBY
        ### MANAGED SNIPPET
        begin
          puts "managed"
        rescue LoadError
          nil
        end

        task :default do
          puts "ok"
        end
      RUBY

      target = Kettle::Jem::Crispr::Selectors.comment_region_owned_owner(marker: "### MANAGED SNIPPET")
      actor = described_class.call(content: content, target: target)

      expect(actor.changed).to be(true)
      expect(actor.updated_content).not_to include("### MANAGED SNIPPET")
      expect(actor.updated_content).to include("task :default")
    end
  end

  describe described_class::Insert do
    it "appends when configured and no destination is resolved" do
      content = <<~RUBY
        task :default do
          puts "ok"
        end
      RUBY

      actor = described_class.call(
        content: content,
        text: "### MANAGED SNIPPET\nputs \"managed\"\n",
        destination: nil,
        if_missing: :append,
      )

      expect(actor.updated_content.rstrip).to end_with(<<~RUBY.rstrip)
        ### MANAGED SNIPPET
        puts "managed"
      RUBY
    end
  end

  describe described_class::Move do
    it "removes a stale managed span and reinserts the new text at the destination anchor" do
      content = <<~RUBY
        ### MANAGED SNIPPET
        begin
          puts "old"
        rescue LoadError
          nil
        end

        # frozen_string_literal: true
        require "kettle/dev"

        ### TEMPLATING TASKS
      RUBY

      target = Kettle::Jem::Crispr::Selectors.comment_region_owned_owner(
        marker: "### MANAGED SNIPPET",
        limit: {at_least: 0},
      )

      actor = described_class.call(
        content: content,
        source_target: target,
        destination: lambda do |context|
          line_number = context.content.lines.find_index { |line| line.include?('require "kettle/dev"') } + 1
          Struct.new(:anchor).new(Struct.new(:start_line, :end_line, :node).new(line_number, line_number, nil))
        end,
        replacement: <<~RUBY,
          ### MANAGED SNIPPET
          begin
            puts "new"
          rescue LoadError
            warn("missing")
          end
        RUBY
        if_missing: :append,
      )

      expect(actor.changed).to be(true)
      expect(actor.source_match_count).to eq(1)
      expect(actor.updated_content.scan("### MANAGED SNIPPET").size).to eq(1)
      expect(actor.updated_content).not_to include('puts "old"')
      expect(actor.updated_content.index('require "kettle/dev"')).to be < actor.updated_content.index("### MANAGED SNIPPET")
      expect(actor.updated_content.index("### MANAGED SNIPPET")).to be < actor.updated_content.index("### TEMPLATING TASKS")
    end
  end
end
