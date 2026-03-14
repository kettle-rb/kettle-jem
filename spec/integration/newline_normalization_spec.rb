# frozen_string_literal: true

RSpec.describe "Newline normalization in templating" do
  describe "SourceMerger newline handling" do
    def template_only(content, path:)
      Kettle::Jem::SourceMerger.apply(
        strategy: :accept_template,
        src: content,
        dest: "",
        path: path,
      )
    end

    def merge_template(template, dest:, path:)
      Kettle::Jem::SourceMerger.apply(
        strategy: :merge,
        src: template,
        dest: dest,
        path: path,
      )
    end

    it "preserves original formatting (prism-merge behavior)" do
      content = <<~RUBY
        # frozen_string_literal: true
        # We run code coverage
      RUBY

      result = template_only(content, path: "test.rb")

      expect(result).to eq(content)
    end

    it "preserves blank lines as-is (prism-merge behavior)" do
      content = <<~RUBY
        # frozen_string_literal: true


        # Comment 1



        # Comment 2
      RUBY

      result = template_only(content, path: "test.rb")

      expect(result).to eq(content)
    end

    it "ensures single newline at end of file" do
      content = "# frozen_string_literal: true\n# Comment"

      result = template_only(content, path: "test.rb")

      expect(result).to end_with("\n")
      expect(result).not_to end_with("\n\n")
    end

    it "handles irregular empty lines fixture correctly" do
      fixture_content = File.read("spec/fixtures/modular_gemfile_with_irregular_empty_lines.rb")

      result = template_only(fixture_content, path: "coverage.gemfile")

      expect(result).to eq(fixture_content)
    end

    it "preserves template content when merging" do
      template = <<~RUBY
        # frozen_string_literal: true

        # We run code coverage on the latest version of Ruby only.

        # Coverage
      RUBY

      # Destination with bad spacing
      dest = <<~RUBY
        # frozen_string_literal: true
        # See gemspec


        # Old comment
      RUBY

      result = merge_template(template, dest: dest, path: "coverage.gemfile")

      expect(result.lines.first).to eq("# frozen_string_literal: true\n")
      expect(result).to include("# We run code coverage on the latest version of Ruby only.")
      expect(result).to include("# Coverage")
      expect(result).not_to include("# Old comment")
      expect(result).to end_with("\n")
      expect(result).not_to end_with("\n\n")
    end

    it "handles shebang with frozen_string_literal" do
      content = <<~RUBY
        #!/usr/bin/env ruby
        # frozen_string_literal: true
        # Comment
      RUBY

      result = template_only(content, path: "test.rb")

      expect(result).to eq(content)
    end

    it "preserves content in real-world coverage.gemfile" do
      template_content = File.read("gemfiles/modular/coverage.gemfile")

      result = template_only(template_content, path: "coverage.gemfile")

      expect(result).to eq(template_content)
    end
  end
end
