# frozen_string_literal: true

RSpec.describe Kettle::Jem::WorkflowSnippetMerger do
  let(:snippet_root) { File.join(Kettle::Jem::TemplateHelpers.template_root, ".github", "workflow-snippets") }

  describe "#apply_all" do
    it "updates action SHA pins in destination workflow" do
      destination = <<~YAML
        name: CI
        on:
          push:
            branches: [master]
        jobs:
          test:
            runs-on: ubuntu-latest
            steps:
              - uses: actions/checkout@v3
              - uses: ruby/setup-ruby@v1
                with:
                  ruby-version: "3.3"
      YAML

      merger = described_class.new(
        snippet_root: snippet_root,
        destination_content: destination,
      )
      result = merger.apply_all

      expect(result).to include("actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd")
      expect(result).to include("ruby/setup-ruby@e65c17d16e57e481586a6a5a0282698790062f92")
      expect(result).not_to include("actions/checkout@v3")
      expect(result).not_to include("ruby/setup-ruby@v1")
    end

    it "preserves destination matrix strategy" do
      destination = <<~YAML
        name: CI
        on:
          push:
            branches: [master]
        jobs:
          test:
            runs-on: ubuntu-latest
            strategy:
              matrix:
                ruby: ['3.1', '3.2', '3.3']
                activerecord: ['7.0', '7.1']
            steps:
              - uses: actions/checkout@v3
      YAML

      merger = described_class.new(
        snippet_root: snippet_root,
        destination_content: destination,
      )
      result = merger.apply_all

      # Matrix is preserved
      expect(result).to include("activerecord")
      expect(result).to include("'3.1'")
    end

    it "adds concurrency section when missing" do
      destination = <<~YAML
        name: CI
        on:
          push:
            branches: [master]
        jobs:
          test:
            runs-on: ubuntu-latest
            steps:
              - uses: actions/checkout@v3
      YAML

      merger = described_class.new(
        snippet_root: snippet_root,
        destination_content: destination,
      )
      result = merger.apply_all

      expect(result).to include("concurrency")
      expect(result).to include("cancel-in-progress")
    end
  end

  describe "#apply_sections_only" do
    it "applies section snippets without updating pins" do
      destination = <<~YAML
        name: CI
        on:
          push:
            branches: [master]
        jobs:
          test:
            steps:
              - uses: actions/checkout@v3
      YAML

      merger = described_class.new(
        snippet_root: snippet_root,
        destination_content: destination,
      )
      result = merger.apply_sections_only

      # Pins are NOT updated
      expect(result).to include("actions/checkout@v3")
      # But concurrency IS added
      expect(result).to include("concurrency")
    end
  end

  describe "#apply_pins_only" do
    it "updates pins without modifying sections" do
      destination = <<~YAML
        name: CI
        on:
          push:
            branches: [master]
        jobs:
          test:
            steps:
              - uses: actions/checkout@old-sha
      YAML

      merger = described_class.new(
        snippet_root: snippet_root,
        destination_content: destination,
      )
      result = merger.apply_pins_only

      expect(result).to include("actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd")
      expect(result).not_to include("concurrency") # No section changes
    end
  end

  describe "pin collection" do
    it "collects pins from all step snippet files" do
      merger = described_class.new(
        snippet_root: snippet_root,
        destination_content: "",
      )
      pins = merger.send(:collect_step_pins)

      expect(pins).to have_key("actions/checkout")
      expect(pins).to have_key("ruby/setup-ruby")
      expect(pins).to have_key("coverallsapp/github-action")
      expect(pins).to have_key("codecov/codecov-action")
    end
  end
end
