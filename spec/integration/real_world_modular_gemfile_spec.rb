# frozen_string_literal: true

RSpec.describe "Real-world modular gemfile deduplication" do
  def merge_modular(template, dest)
    Kettle::Jem::SourceMerger.apply(
      strategy: :merge,
      src: template,
      dest: dest,
      path: "gemfiles/modular/coverage.gemfile",
    )
  end

  let(:fixture_content) do
    File.read("spec/fixtures/modular_gemfile_with_duplicates.gemfile")
  end

  let(:template_source_content) do
    <<~GEMFILE
      # frozen_string_literal: true

      # We run code coverage on the latest version of Ruby only.

      # Coverage
    GEMFILE
  end

  let(:expected_shape) { merge_modular(template_source_content, template_source_content) }

  describe "Simulating kettle-dev-setup flow" do
    it "deduplicates magic comments but preserves all other content when merging" do
      # This simulates what happens when kettle-dev-setup runs:
      # 1. Source (template) is the simple coverage.gemfile from kettle-dev
      # 2. Dest is the existing file in the target project with accumulated duplicates
      # prism-merge deduplicates magic comments but preserves all other content

      result = merge_modular(template_source_content, fixture_content)

      expect(result).to eq(expected_shape)
      expect(result.scan("# frozen_string_literal: true").count).to eq(1)
      expect(result.scan("# We run code coverage").count).to eq(1)
      expect(result).not_to include("# See gemspec")

      # Running again should be idempotent
      second_result = merge_modular(template_source_content, result)

      expect(second_result).to eq(result), "Second run should produce identical output"
    end

    it "removes duplicated frozen_string_literal comments, but not other duplicate comments" do
      # Starting state: file with 4 frozen_string_literal comments
      starting_dest = <<~GEMFILE
        # frozen_string_literal: true
        # frozen_string_literal: true
        # frozen_string_literal: true
        # frozen_string_literal: true

        # We run code coverage on the latest version of Ruby only.

        # Coverage
        # See gemspec
        # To retain during kettle-jem templating:
        #     kettle-jem:freeze
        #     # ... your code
        #     kettle-jem:unfreeze

        # We run code coverage on the latest version of Ruby only.

        # Coverage
        # To retain during kettle-jem templating:
        #     kettle-jem:freeze
        #     # ... your code
        #     kettle-jem:unfreeze
      GEMFILE

      # Template source is simple
      template = <<~GEMFILE
        # frozen_string_literal: true

        # We run code coverage on the latest version of Ruby only.

        # Coverage
      GEMFILE

      first_run = merge_modular(template, starting_dest)

      expected = merge_modular(template, template)

      expect(first_run).to eq(expected)
      expect(first_run.scan("# frozen_string_literal: true").count).to eq(1)
      expect(first_run.scan("# We run code coverage").count).to eq(1)

      # Second run (simulating running kettle-dev-setup again)
      second_run = merge_modular(template, first_run)

      expect(second_run).to eq(first_run), "Second run should not add more duplicates"
    end
  end
end
