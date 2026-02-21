# frozen_string_literal: true

RSpec.describe Kettle::Jem::Presets::Gemfile do
  describe ".destination_wins" do
    subject(:config) { described_class.destination_wins }

    it "returns a MergerConfig" do
      expect(config).to be_a(Ast::Merge::MergerConfig)
    end

    it "has :destination preference" do
      expect(config.preference).to eq(:destination)
    end

    it "does not add template-only nodes" do
      expect(config.add_template_only_nodes).to be false
    end

    it "has kettle-jem freeze token" do
      expect(config.freeze_token).to eq("kettle-jem")
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

    it "returns a MergerConfig" do
      expect(config).to be_a(Ast::Merge::MergerConfig)
    end

    it "has :template preference" do
      expect(config.preference).to eq(:template)
    end

    it "adds template-only nodes" do
      expect(config.add_template_only_nodes).to be true
    end
  end

  describe ".custom" do
    subject(:config) do
      described_class.custom(
        preference: {default: :destination, lint_gem: :template},
        add_template_only: true,
        freeze_token: "custom-token",
      )
    end

    it "accepts custom preference" do
      expect(config.preference).to eq({default: :destination, lint_gem: :template})
    end

    it "accepts custom freeze token" do
      expect(config.freeze_token).to eq("custom-token")
    end

    it "accepts custom add_template_only setting" do
      expect(config.add_template_only_nodes).to be true
    end
  end

  describe "signature generator" do
    let(:generator) { described_class.signature_generator }

    context "with source() call" do
      let(:node) { parse_call("source 'https://rubygems.org'") }

      it "returns [:source] signature" do
        expect(generator.call(node)).to eq([:source])
      end
    end

    context "with gem() call" do
      let(:node) { parse_call('gem "rspec"') }

      it "returns [:gem, gem_name] signature" do
        expect(generator.call(node)).to eq([:gem, "rspec"])
      end
    end

    context "with eval_gemfile() call" do
      let(:node) { parse_call('eval_gemfile "modular/test.gemfile"') }

      it "returns [:eval_gemfile, path] signature" do
        expect(generator.call(node)).to eq([:eval_gemfile, "modular/test.gemfile"])
      end
    end

    context "with ruby() call" do
      let(:node) { parse_call('ruby "3.2.0"') }

      it "returns [:ruby] signature" do
        expect(generator.call(node)).to eq([:ruby])
      end
    end

    context "with git_source() call" do
      let(:node) { parse_call('git_source(:github) { |repo| "https://github.com/#{repo}" }') }

      it "returns [:git_source, source_name] signature" do
        expect(generator.call(node)).to eq([:git_source, "github"])
      end
    end

    def parse_call(code)
      result = Prism.parse(code)
      result.value.statements.body.first
    end
  end
end
