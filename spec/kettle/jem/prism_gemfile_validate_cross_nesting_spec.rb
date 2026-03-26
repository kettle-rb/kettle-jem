# frozen_string_literal: true

RSpec.describe Kettle::Jem::PrismGemfile, ".validate_no_cross_nesting_duplicates" do
  def validate(merged, template, path: "test.gemfile")
    described_class.validate_no_cross_nesting_duplicates(merged, template, path: path)
  end

  context "when same gem at same nesting level" do
    let(:merged) do
      <<~RUBY
        gem "foo", "~> 1.0"
        gem "bar", "~> 2.0"
      RUBY
    end
    let(:template) { merged }

    it "does not raise" do
      expect { validate(merged, template) }.not_to raise_error
    end
  end

  context "when different gems at different nesting levels" do
    let(:merged) do
      <<~RUBY
        gem "foo", "~> 1.0"
        platform :mri do
          gem "bar", "~> 2.0"
        end
      RUBY
    end
    let(:template) { merged }

    it "does not raise" do
      expect { validate(merged, template) }.not_to raise_error
    end
  end

  context "when same gem at top-level and inside platform block" do
    let(:merged) do
      <<~RUBY
        gem "foo", path: "../foo"
        platform :mri do
          gem "foo", path: "../other/foo"
        end
      RUBY
    end
    let(:template) do
      <<~RUBY
        platform :mri do
          gem "foo", path: "../ast-merge/vendor/foo"
        end
      RUBY
    end

    it "raises Kettle::Jem::Error" do
      expect { validate(merged, template) }.to raise_error(Kettle::Jem::Error, /duplicate gem declarations in blocks with different signatures/)
    end

    it "mentions the gem name" do
      expect { validate(merged, template) }.to raise_error(Kettle::Jem::Error, /gem "foo"/)
    end

    it "includes the template version as guidance" do
      expect { validate(merged, template) }.to raise_error(Kettle::Jem::Error, /Template version/)
    end

    it "includes the file path" do
      expect { validate(merged, template, path: "gemfiles/modular/templating_local.gemfile") }
        .to raise_error(Kettle::Jem::Error, /templating_local\.gemfile/)
    end
  end

  context "when same gem at top-level and inside if block" do
    let(:merged) do
      <<~RUBY
        gem "bash-merge", path: "../ast-merge/vendor/bash-merge"
        unless ENV.fetch("KETTLE_RB_DEV", "false").casecmp("false").zero?
          gem "bash-merge", path: "../../../bash-merge"
        end
      RUBY
    end
    let(:template) do
      <<~RUBY
        platform :mri do
          gem "bash-merge", path: "../ast-merge/vendor/bash-merge"
        end
      RUBY
    end

    it "raises Kettle::Jem::Error" do
      expect { validate(merged, template) }.to raise_error(Kettle::Jem::Error, /duplicate gem declarations in blocks with different signatures/)
    end

    it "shows both block signature contexts" do
      expect { validate(merged, template) }.to raise_error(Kettle::Jem::Error) do |error|
        expect(error.message).to include("top-level")
        expect(error.message).to match(/unless /)
      end
    end
  end

  context "when same gem inside two different block types" do
    let(:merged) do
      <<~RUBY
        platform :mri do
          gem "foo", path: "../foo"
        end
        group :development do
          gem "foo", path: "../other/foo"
        end
      RUBY
    end
    let(:template) do
      <<~RUBY
        platform :mri do
          gem "foo", path: "../foo"
        end
      RUBY
    end

    it "raises Kettle::Jem::Error" do
      expect { validate(merged, template) }.to raise_error(Kettle::Jem::Error, /duplicate gem declarations in blocks with different signatures/)
    end

    it "shows both block contexts" do
      expect { validate(merged, template) }.to raise_error(Kettle::Jem::Error) do |error|
        expect(error.message).to include("platform(:mri)")
        expect(error.message).to include("group(:development)")
      end
    end
  end

  context "when multiple gems have cross-nesting conflicts" do
    let(:merged) do
      <<~RUBY
        gem "foo"
        gem "bar"
        platform :mri do
          gem "foo", path: "../foo"
          gem "bar", path: "../bar"
        end
      RUBY
    end
    let(:template) do
      <<~RUBY
        gem "foo"
        gem "bar"
      RUBY
    end

    it "reports all conflicting gems" do
      expect { validate(merged, template) }.to raise_error(Kettle::Jem::Error) do |error|
        expect(error.message).to include('"foo"')
        expect(error.message).to include('"bar"')
      end
    end
  end

  context "when same gem appears twice at the same nesting level (not cross-nesting)" do
    let(:merged) do
      <<~RUBY
        platform :mri do
          gem "foo", "~> 1.0"
          gem "foo", "~> 2.0"
        end
      RUBY
    end
    let(:template) { merged }

    it "does not raise (same context, not cross-nesting)" do
      expect { validate(merged, template) }.not_to raise_error
    end
  end

  context "when content is empty or unparseable" do
    it "does not raise for empty content" do
      expect { validate("", "") }.not_to raise_error
    end

    it "does not raise for content with no gem calls" do
      content = "source 'https://rubygems.org'\n"
      expect { validate(content, content) }.not_to raise_error
    end
  end
end

RSpec.describe Kettle::Jem::PrismGemfile::DeclarationContextPolicy, ".collect_gem_declarations" do
  def collect(content)
    described_class.collect_gem_declarations(content)
  end

  it "returns empty array for empty content" do
    expect(collect("")).to eq([])
  end

  it "collects top-level gems" do
    content = <<~RUBY
      gem "foo", "~> 1.0"
      gem "bar"
    RUBY
    decls = collect(content)
    expect(decls.size).to eq(2)
    expect(decls.map { |d| d[:name] }).to eq(%w[foo bar])
    expect(decls.map { |d| d[:context] }).to eq(%w[top-level top-level])
  end

  it "collects gems inside platform blocks" do
    content = <<~RUBY
      platform :mri do
        gem "native-thing"
      end
    RUBY
    decls = collect(content)
    expect(decls.size).to eq(1)
    expect(decls.first[:name]).to eq("native-thing")
    expect(decls.first[:context]).to eq("platform(:mri)")
  end

  it "collects gems inside if blocks" do
    content = <<~RUBY
      if ENV["DEV"]
        gem "debug-gem"
      end
    RUBY
    decls = collect(content)
    expect(decls.size).to eq(1)
    expect(decls.first[:context]).to match(/^if /)
  end

  it "collects gems inside nested blocks" do
    content = <<~RUBY
      platform :mri do
        group :development do
          gem "deep-gem"
        end
      end
    RUBY
    decls = collect(content)
    expect(decls.size).to eq(1)
    expect(decls.first[:context]).to eq("platform(:mri) > group(:development)")
  end

  it "collects gems in else branches with same context as if branch" do
    content = <<~RUBY
      if ENV["DEV"]
        gem "dev-only"
      else
        gem "prod-only"
      end
    RUBY
    decls = collect(content)
    expect(decls.size).to eq(2)
    contexts = decls.map { |d| d[:context] }
    # Both branches share the same conditional context
    expect(contexts.uniq.size).to eq(1)
    expect(contexts.first).to match(/^if /)
  end

  it "includes line numbers" do
    content = <<~RUBY
      gem "first"
      platform :mri do
        gem "second"
      end
    RUBY
    decls = collect(content)
    expect(decls.find { |d| d[:name] == "first" }[:line]).to eq(1)
    expect(decls.find { |d| d[:name] == "second" }[:line]).to eq(3)
  end
end

RSpec.describe Kettle::Jem::PrismGemfile::MergeRuntimePolicy, ".collect_commented_gem_tombstones" do
  def collect(content)
    described_class.collect_commented_gem_tombstones(content)
  end

  it "collects explained commented-out gems at top-level" do
    content = <<~RUBY
      # Ex-Standard Library gems
      # irb is included in the main Gemfile.
      # gem "irb", "~> 1.15", ">= 1.15.2"
    RUBY

    tombstones = collect(content)

    expect(tombstones).to contain_exactly(
      include(
        name: "irb",
        context: "top-level",
        line: 3,
      ),
    )
  end

  it "assigns the enclosing block context to explained commented-out gems" do
    content = <<~RUBY
      platform :mri do
        # Only loaded elsewhere.
        # gem "debug", ">= 1.1"
      end
    RUBY

    tombstones = collect(content)

    expect(tombstones).to contain_exactly(include(name: "debug", context: "platform(:mri)"))
  end

  it "ignores lone commented gem lines without explanatory comments" do
    content = <<~RUBY
      # gem "rubocop", "~> 1.73", ">= 1.73.2" # constrained by standard
    RUBY

    expect(collect(content)).to eq([])
  end
end

RSpec.describe Kettle::Jem::SourceMerger, "gemfile duplicate-signature validation" do
  let(:template) do
    <<~RUBY
      platform :mri do
        gem "foo", path: "../foo"
      end
    RUBY
  end
  let(:destination) do
    <<~RUBY
      gem "foo", path: "../other/foo"
    RUBY
  end
  let(:merged_with_conflict) do
    <<~RUBY
      gem "foo", path: "../other/foo"
      platform :mri do
        gem "foo", path: "../foo"
      end
    RUBY
  end

  context "without explicit force" do
    it "propagates duplicate-validation errors raised by PrismGemfile" do
      expect(Kettle::Jem::PrismGemfile).to receive(:merge).with(
        template,
        destination,
        merger_options: kind_of(Hash),
        filter_template: false,
        path: "test.gemfile",
        force: false,
        preset: nil,
        context: nil,
      ).and_raise(Kettle::Jem::Error, "duplicate gem declarations in blocks with different signatures")

      expect {
        described_class.apply(strategy: :merge, src: template, dest: destination, path: "test.gemfile")
      }.to raise_error(Kettle::Jem::Error, /duplicate gem declarations in blocks with different signatures/)
    end
  end

  context "with explicit force" do
    it "passes force through to PrismGemfile and returns its fallback content" do
      expect(Kettle::Jem::PrismGemfile).to receive(:merge).with(
        template,
        destination,
        merger_options: kind_of(Hash),
        filter_template: false,
        path: "test.gemfile",
        force: true,
        preset: nil,
        context: nil,
      ).and_return(template)

      result = described_class.apply(
        strategy: :merge,
        src: template,
        dest: destination,
        path: "test.gemfile",
        force: true,
      )

      expect(result).to include('gem "foo", path: "../foo"')
      expect(result).to include("platform :mri do")
      expect(result.scan('gem "foo"').size).to eq(1)
    end
  end

  it "does not raise for non-gemfile types" do
    merged = <<~RUBY
      gem "foo"
      platform :mri do
        gem "foo"
      end
    RUBY
    allow(described_class).to receive(:apply_merge).and_return(merged)

    expect {
      described_class.apply(strategy: :merge, src: merged, dest: "", path: "Rakefile")
    }.not_to raise_error
  end
end
