# frozen_string_literal: true

RSpec.describe Kettle::Jem::Classifiers::AppraisalBlock do
  subject(:classifier) { described_class.new }

  describe "#classify" do
    context "with appraise block" do
      let(:node) do
        code = <<~RUBY
          appraise "ruby-3-3" do
            gem "test", "~> 1.0"
            eval_gemfile "modular/base.gemfile"
          end
        RUBY
        Prism.parse(code).value.statements.body.first
      end

      it "returns a TypedSection" do
        result = classifier.classify(node)
        expect(result).to be_a(Ast::Merge::SectionTyping::TypedSection)
      end

      it "has :appraise type" do
        result = classifier.classify(node)
        expect(result.type).to eq(:appraise)
      end

      it "extracts the appraisal name" do
        result = classifier.classify(node)
        expect(result.name).to eq("ruby-3-3")
      end

      it "preserves the original node" do
        result = classifier.classify(node)
        expect(result.node).to eq(node)
      end

      it "extracts metadata about contained gems" do
        result = classifier.classify(node)
        expect(result.metadata[:gems]).to include("test")
      end

      it "extracts metadata about eval_gemfiles" do
        result = classifier.classify(node)
        expect(result.metadata[:eval_gemfiles]).to include("modular/base.gemfile")
      end
    end

    context "with non-appraise call" do
      let(:node) do
        Prism.parse('gem "test"').value.statements.body.first
      end

      it "returns nil" do
        expect(classifier.classify(node)).to be_nil
      end
    end

    context "with appraise without block" do
      let(:node) do
        Prism.parse('appraise "test"').value.statements.body.first
      end

      it "returns nil" do
        expect(classifier.classify(node)).to be_nil
      end
    end
  end

  describe "#classify_all" do
    let(:code) do
      <<~RUBY
        # frozen_string_literal: true

        source "https://rubygems.org"

        appraise "ruby-3-2" do
          gem "test"
        end

        appraise "ruby-3-3" do
          gem "test"
        end

        gem "shared"
      RUBY
    end
    let(:nodes) { Prism.parse(code).value.statements.body }

    it "classifies appraise blocks" do
      sections = classifier.classify_all(nodes)
      appraise_sections = sections.select { |s| s.type == :appraise }

      expect(appraise_sections.length).to eq(2)
      expect(appraise_sections.map(&:name)).to eq(["ruby-3-2", "ruby-3-3"])
    end

    it "groups unclassified nodes" do
      sections = classifier.classify_all(nodes)
      unclassified = sections.select(&:unclassified?)

      expect(unclassified).not_to be_empty
    end
  end
end
