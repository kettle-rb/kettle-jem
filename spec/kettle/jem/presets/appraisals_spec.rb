# frozen_string_literal: true

RSpec.describe Kettle::Jem::Presets::Appraisals do
  describe ".destination_wins" do
    subject(:config) { described_class.destination_wins }

    it "returns a MergerConfig" do
      expect(config).to be_a(Ast::Merge::MergerConfig)
    end

    it "has :destination preference" do
      expect(config.preference).to eq(:destination)
    end

    it "has a signature generator" do
      expect(config.signature_generator).to be_a(Proc)
    end

    it "has node typing configuration" do
      expect(config.node_typing).to be_a(Hash)
      expect(config.node_typing).to have_key(:CallNode)
    end
  end

  describe ".template_wins" do
    subject(:config) { described_class.template_wins }

    it "has :template preference" do
      expect(config.preference).to eq(:template)
    end

    it "adds template-only nodes" do
      expect(config.add_template_only_nodes).to be true
    end
  end

  describe "signature generator" do
    let(:generator) { described_class.signature_generator }

    context "with appraise() call" do
      let(:node) do
        code = <<~RUBY
          appraise "ruby-3-3" do
            gem "test"
          end
        RUBY
        result = Prism.parse(code)
        result.value.statements.body.first
      end

      it "returns [:appraise, appraisal_name] signature" do
        expect(generator.call(node)).to eq([:appraise, "ruby-3-3"])
      end
    end

    context "with gem() call" do
      let(:node) do
        result = Prism.parse('gem "rspec"')
        result.value.statements.body.first
      end

      it "returns [:gem, gem_name] signature (from gemfile generator)" do
        expect(generator.call(node)).to eq([:gem, "rspec"])
      end
    end
  end

  describe "node typing categorization" do
    let(:node_typing) { described_class.default_node_typing }
    let(:typing_callable) { node_typing[:CallNode] }

    context "with ruby version appraisal" do
      let(:node) do
        code = 'appraise "ruby-3-3" do; end'
        Prism.parse(code).value.statements.body.first
      end

      it "categorizes as :ruby_version" do
        result = typing_callable.call(node)
        expect(result.merge_type).to eq(:ruby_version)
      end
    end

    context "with deps appraisal" do
      let(:node) do
        code = 'appraise "unlocked_deps" do; end'
        Prism.parse(code).value.statements.body.first
      end

      it "categorizes as :deps_appraisal" do
        result = typing_callable.call(node)
        expect(result.merge_type).to eq(:deps_appraisal)
      end
    end

    context "with feature appraisal" do
      let(:node) do
        code = 'appraise "coverage" do; end'
        Prism.parse(code).value.statements.body.first
      end

      it "categorizes as :feature_appraisal" do
        result = typing_callable.call(node)
        expect(result.merge_type).to eq(:feature_appraisal)
      end
    end

    context "with runtime appraisal" do
      let(:node) do
        code = 'appraise "head" do; end'
        Prism.parse(code).value.statements.body.first
      end

      it "categorizes as :runtime_appraisal" do
        result = typing_callable.call(node)
        expect(result.merge_type).to eq(:runtime_appraisal)
      end
    end
  end
end
