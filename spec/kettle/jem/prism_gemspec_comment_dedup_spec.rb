# frozen_string_literal: true

RSpec.describe Kettle::Jem::PrismGemspec do
  describe "gemspec NOTE comment block deduplication" do
    # The NOTE comment block is a positional comment that belongs between the
    # runtime dependency section and the development dependency section.
    # It is NOT attached to any specific dependency node — it documents a
    # project policy. When nodes around it change (deps added/removed), the
    # parser may attach it as leading comments to different nodes in template
    # vs destination. The merge must produce exactly one copy.

    let(:note_block) do
      <<~COMMENT.chomp
        # NOTE: It is preferable to list development dependencies in the gemspec due to increased
        #       visibility and discoverability.
        #       However, development dependencies in gemspec will install on
        #       all versions of Ruby that will run in CI.
        #       This gem, and its gemspec runtime dependencies, will install on Ruby down to 2.3.0.
        #       This gem, and its gemspec development dependencies, will install on Ruby down to 2.3.0.
        #       Thus, dev dependencies in gemspec must have
        #
        #       required_ruby_version ">= 2.3.0" (or lower)
        #
        #       Development dependencies that require strictly newer Ruby versions should be in a "gemfile",
        #       and preferably a modular one (see gemfiles/modular/*.gemfile).
      COMMENT
    end

    let(:context) do
      {
        min_ruby: Gem::Version.new("2.3.0"),
        entrypoint_require: "example/gem",
        namespace: "Example::Gem",
      }
    end

    context "when dest has an extra dep between NOTE block and template's first dev dep" do
      # This is the real-world scenario: template has NOTE → kettle-dev,
      # but dest has NOTE → kettle-test → kettle-dev. The self-dep (kettle-test)
      # is removed from the template before merge, so the template's kettle-dev
      # node inherits the NOTE block as leading comments.

      let(:template_content) do
        <<~RUBY
          Gem::Specification.new do |spec|
            spec.name = "example-gem"
            spec.version = Example::Gem::Version::VERSION

            spec.add_dependency("version_gem", "~> 1.1", ">= 1.1.9")

          #{note_block}

            # Dev, Test, & Release Tasks
            spec.add_development_dependency("kettle-dev", "~> 2.0")

            spec.add_development_dependency("rake", "~> 13.0")
          end
        RUBY
      end

      let(:dest_content) do
        <<~RUBY
          Gem::Specification.new do |spec|
            spec.name = "example-gem"
            spec.version = Example::Gem::Version::VERSION

            spec.add_dependency("version_gem", "~> 1.1", ">= 1.1.9")

            ### Testing is runtime for this gem!
            spec.add_dependency("rspec", "~> 3.0")

          #{note_block}

            spec.add_development_dependency("example-gem-test", "~> 1.0")
            # Dev, Test, & Release Tasks
            spec.add_development_dependency("kettle-dev", "~> 2.0")

            spec.add_development_dependency("rake", "~> 13.0")
          end
        RUBY
      end

      it "produces exactly one NOTE block via PrismGemspec.merge" do
        result = described_class.merge(
          template_content,
          dest_content,
          context: context,
        )

        count = result.scan("NOTE: It is preferable").count
        expect(count).to eq(1),
          "Expected exactly 1 NOTE block in merged gemspec, got #{count}.\n\nMerged output:\n#{result}"
      end

      it "produces exactly one NOTE block via SourceMerger.apply" do
        result = Kettle::Jem::SourceMerger.apply(
          strategy: :merge,
          src: template_content,
          dest: dest_content,
          path: "example-gem.gemspec",
          context: context,
          force: true,
        )

        count = result.scan("NOTE: It is preferable").count
        expect(count).to eq(1),
          "Expected exactly 1 NOTE block in merged gemspec, got #{count}.\n\nMerged output:\n#{result}"
      end
    end

    context "when running merge twice (idempotency)" do
      let(:template_content) do
        <<~RUBY
          Gem::Specification.new do |spec|
            spec.name = "example-gem"
            spec.version = Example::Gem::Version::VERSION

            spec.add_dependency("version_gem", "~> 1.1")

          #{note_block}

            # Dev tools
            spec.add_development_dependency("kettle-dev", "~> 2.0")

            spec.add_development_dependency("rake", "~> 13.0")
          end
        RUBY
      end

      let(:dest_content) do
        <<~RUBY
          Gem::Specification.new do |spec|
            spec.name = "example-gem"
            spec.version = Example::Gem::Version::VERSION

            spec.add_dependency("version_gem", "~> 1.1")

          #{note_block}

            spec.add_development_dependency("my-helper", "~> 1.0")
            # Dev tools
            spec.add_development_dependency("kettle-dev", "~> 2.0")

            spec.add_development_dependency("rake", "~> 13.0")
          end
        RUBY
      end

      it "does not accumulate NOTE blocks across successive merges" do
        # First merge
        first_result = described_class.merge(
          template_content,
          dest_content,
          context: context,
        )
        expect(first_result.scan("NOTE: It is preferable").count).to eq(1),
          "First merge produced #{first_result.scan("NOTE: It is preferable").count} NOTE blocks"

        # Second merge (merged output becomes the new dest)
        second_result = described_class.merge(
          template_content,
          first_result,
          context: context,
        )
        expect(second_result.scan("NOTE: It is preferable").count).to eq(1),
          "Second merge produced #{second_result.scan("NOTE: It is preferable").count} NOTE blocks"

        # Third merge (belt and suspenders)
        third_result = described_class.merge(
          template_content,
          second_result,
          context: context,
        )
        expect(third_result.scan("NOTE: It is preferable").count).to eq(1),
          "Third merge produced #{third_result.scan("NOTE: It is preferable").count} NOTE blocks"
      end
    end
  end
end
