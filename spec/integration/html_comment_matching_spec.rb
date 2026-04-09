# frozen_string_literal: true

RSpec.describe "HTML comment block matching via CompositeMatchRefiner" do
  # Verifies that the MARKDOWN_MATCH_REFINER composite correctly fuzzy-matches
  # HTML comment blocks (<!-- ... -->) between template and destination, preventing
  # them from being duplicated as template-only nodes.

  def do_merge(src, dest)
    Markdown::Merge::SmartMerger.new(
      src,
      dest,
      backend: :markly,
      preference: :template,
      add_template_only_nodes: true,
      match_refiner: Kettle::Jem::Tasks::TemplateTask::MARKDOWN_MATCH_REFINER,
      inner_merge_lists: true,
    ).merge
  end

  context "when HTML comment wording differs slightly" do
    let(:template) do
      <<~MD
        # Project

        <!-- Template documentation section -->

        ## Installation

        Install the gem.

        <!-- End of installation section -->
      MD
    end

    let(:destination) do
      <<~MD
        # Project

        <!-- Template docs section -->

        ## Installation

        Install the gem via bundler.

        <!-- End of the installation section -->
      MD
    end

    it "does not duplicate HTML comment blocks" do
      result = do_merge(template, destination)

      # Each comment should appear at most once (fuzzy matched, not re-added)
      template_doc_count = result.scan("Template doc").count
      expect(template_doc_count).to eq(1),
        "Expected 1 'Template doc*' comment, got #{template_doc_count}.\n\nResult:\n#{result}"

      install_end_count = result.scan(/End of.*installation/).count
      expect(install_end_count).to eq(1),
        "Expected 1 'End of installation' comment, got #{install_end_count}.\n\nResult:\n#{result}"
    end

    it "is idempotent across multiple merge runs" do
      result1 = do_merge(template, destination)
      result2 = do_merge(template, result1)
      result3 = do_merge(template, result2)

      expect(result3).to eq(result2),
        "Merge is not idempotent!\n\nRun 2:\n#{result2}\n\nRun 3:\n#{result3}"
    end
  end

  context "when destination has an HTML comment absent from template" do
    let(:template) do
      <<~MD
        # Project

        <!-- Template header -->

        Content here.
      MD
    end

    let(:destination) do
      <<~MD
        # Project

        <!-- Template header -->

        <!-- Project-specific note: do not remove -->

        Content here.
      MD
    end

    it "preserves destination-only HTML comments" do
      result = do_merge(template, destination)

      expect(result).to include("Project-specific note"),
        "Destination-only HTML comment was removed.\n\nResult:\n#{result}"
    end
  end
end
