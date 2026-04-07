# frozen_string_literal: true

RSpec.describe Kettle::Jem::Presets::Gemspec do
  def parse_call(code)
    Prism.parse(code).value.statements.body.first
  end

  describe ".signature_generator" do
    it "returns the Signatures.gemspec generator" do
      generator = described_class.signature_generator
      expect(generator).to be_a(Proc)
    end
  end

  describe ".destination_wins" do
    it "returns a MergerConfig with destination preference" do
      config = described_class.destination_wins
      expect(config).to be_a(Ast::Merge::MergerConfig)
      expect(config.to_h[:preference]).to eq(:destination)
      expect(config.to_h[:add_template_only_nodes]).to be(false)
      expect(config.to_h[:freeze_token]).to eq("kettle-jem")
    end
  end

  describe ".template_wins" do
    it "returns a MergerConfig with template preference" do
      config = described_class.template_wins
      expect(config).to be_a(Ast::Merge::MergerConfig)
      expect(config.to_h[:preference]).to eq(:template)
      expect(config.to_h[:add_template_only_nodes]).to be(true)
    end
  end

  describe ".custom" do
    it "returns a MergerConfig with custom options" do
      config = described_class.custom(preference: :destination, add_template_only: true)
      expect(config).to be_a(Ast::Merge::MergerConfig)
      expect(config.to_h[:preference]).to eq(:destination)
      expect(config.to_h[:add_template_only_nodes]).to be(true)
    end
  end

  describe ".default_node_typing" do
    let(:typing) { described_class.default_node_typing }
    let(:call_node_typing) { typing[:CallNode] }
    let(:call_op_write_typing) { typing[:CallOperatorWriteNode] }

    it "returns a Hash with :CallNode and :CallOperatorWriteNode keys" do
      expect(typing).to be_a(Hash)
      expect(typing).to have_key(:CallNode)
      expect(typing).to have_key(:CallOperatorWriteNode)
      expect(call_node_typing).to respond_to(:call)
      expect(call_op_write_typing).to respond_to(:call)
    end

    context "with CallNode for spec assignments" do
      context "when spec.name = (identity)" do
        it "adds :spec_identity merge type" do
          node = parse_call('spec.name = "my-gem"')
          result = call_node_typing.call(node)
          expect(result.merge_type).to eq(:spec_identity)
        end
      end

      context "when spec.version = (identity)" do
        it "adds :spec_identity merge type" do
          node = parse_call('spec.version = "1.0.0"')
          result = call_node_typing.call(node)
          expect(result.merge_type).to eq(:spec_identity)
        end
      end

      context "when spec.summary = (metadata)" do
        it "adds :spec_metadata merge type" do
          node = parse_call('spec.summary = "A gem"')
          result = call_node_typing.call(node)
          expect(result.merge_type).to eq(:spec_metadata)
        end
      end

      context "when spec.description = (metadata)" do
        it "adds :spec_metadata merge type" do
          node = parse_call('spec.description = "A description"')
          result = call_node_typing.call(node)
          expect(result.merge_type).to eq(:spec_metadata)
        end
      end

      context "when spec.homepage = (metadata)" do
        it "adds :spec_metadata merge type" do
          node = parse_call('spec.homepage = "https://example.com"')
          result = call_node_typing.call(node)
          expect(result.merge_type).to eq(:spec_metadata)
        end
      end

      context "when spec.license = (metadata)" do
        it "adds :spec_metadata merge type" do
          node = parse_call('spec.license = "MIT"')
          result = call_node_typing.call(node)
          expect(result.merge_type).to eq(:spec_metadata)
        end
      end

      context "when spec.licenses = (metadata)" do
        it "adds :spec_metadata merge type" do
          node = parse_call('spec.licenses = ["MIT"]')
          result = call_node_typing.call(node)
          expect(result.merge_type).to eq(:spec_metadata)
        end
      end

      context "when spec.authors = (metadata)" do
        it "adds :spec_metadata merge type" do
          node = parse_call('spec.authors = ["Jane"]')
          result = call_node_typing.call(node)
          expect(result.merge_type).to eq(:spec_metadata)
        end
      end

      context "when spec.email = (metadata)" do
        it "adds :spec_metadata merge type" do
          node = parse_call('spec.email = ["a@b.com"]')
          result = call_node_typing.call(node)
          expect(result.merge_type).to eq(:spec_metadata)
        end
      end

      context "when spec.metadata = (metadata)" do
        it "adds :spec_metadata merge type" do
          node = parse_call("spec.metadata = {}")
          result = call_node_typing.call(node)
          expect(result.merge_type).to eq(:spec_metadata)
        end
      end

      context "when spec.files = (files)" do
        it "adds :spec_files merge type" do
          node = parse_call('spec.files = Dir["lib/**/*"]')
          result = call_node_typing.call(node)
          expect(result.merge_type).to eq(:spec_files)
        end
      end

      context "when spec.require_paths = (files)" do
        it "adds :spec_files merge type" do
          node = parse_call('spec.require_paths = ["lib"]')
          result = call_node_typing.call(node)
          expect(result.merge_type).to eq(:spec_files)
        end
      end

      context "when spec.executables = (files)" do
        it "adds :spec_files merge type" do
          node = parse_call('spec.executables = ["my-exe"]')
          result = call_node_typing.call(node)
          expect(result.merge_type).to eq(:spec_files)
        end
      end

      context "when spec.bindir = (files)" do
        it "adds :spec_files merge type" do
          node = parse_call('spec.bindir = "exe"')
          result = call_node_typing.call(node)
          expect(result.merge_type).to eq(:spec_files)
        end
      end

      context "when spec.extra_rdoc_files = (files)" do
        it "adds :spec_files merge type" do
          node = parse_call("spec.extra_rdoc_files = []")
          result = call_node_typing.call(node)
          expect(result.merge_type).to eq(:spec_files)
        end
      end

      context "when spec.rdoc_options = (files)" do
        it "adds :spec_files merge type" do
          node = parse_call('spec.rdoc_options = ["--quiet"]')
          result = call_node_typing.call(node)
          expect(result.merge_type).to eq(:spec_files)
        end
      end

      context "when spec.add_dependency call (dependency)" do
        it "adds :spec_dependency merge type" do
          node = parse_call('spec.add_dependency("foo", "~> 1.0")')
          result = call_node_typing.call(node)
          expect(result.merge_type).to eq(:spec_dependency)
        end
      end

      context "when spec.add_development_dependency call (dependency)" do
        it "adds :spec_dependency merge type" do
          node = parse_call('spec.add_development_dependency("rspec")')
          result = call_node_typing.call(node)
          expect(result.merge_type).to eq(:spec_dependency)
        end
      end

      context "when spec.required_ruby_version = (requirements)" do
        it "adds :spec_requirements merge type" do
          node = parse_call('spec.required_ruby_version = ">= 2.7"')
          result = call_node_typing.call(node)
          expect(result.merge_type).to eq(:spec_requirements)
        end
      end

      context "when spec.required_rubygems_version = (requirements)" do
        it "adds :spec_requirements merge type" do
          node = parse_call('spec.required_rubygems_version = ">= 0"')
          result = call_node_typing.call(node)
          expect(result.merge_type).to eq(:spec_requirements)
        end
      end

      context "when spec.cert_chain = (signing)" do
        it "adds :spec_signing merge type" do
          node = parse_call('spec.cert_chain = ["certs/cert.pem"]')
          result = call_node_typing.call(node)
          expect(result.merge_type).to eq(:spec_signing)
        end
      end

      context "when spec.signing_key = (signing)" do
        it "adds :spec_signing merge type" do
          node = parse_call('spec.signing_key = "certs/key.pem"')
          result = call_node_typing.call(node)
          expect(result.merge_type).to eq(:spec_signing)
        end
      end

      context "when receiver is not spec" do
        it "returns the node unchanged" do
          node = parse_call('other.name = "test"')
          result = call_node_typing.call(node)
          expect(result).to eq(node)
        end
      end

      context "when spec method is unrecognized" do
        it "returns the node unchanged" do
          node = parse_call('spec.unknown_attribute = "value"')
          result = call_node_typing.call(node)
          expect(result).to eq(node)
        end
      end

      context "when receiver starts with spec but is not plain :spec" do
        it "treats spec_something receivers as spec calls" do
          node = parse_call('spec_obj.name = "test"')
          result = call_node_typing.call(node)
          expect(result.merge_type).to eq(:spec_identity)
        end
      end
    end

    context "with CallOperatorWriteNode" do
      context "when spec.rdoc_options += (files)" do
        it "adds :spec_files merge type" do
          node = parse_call('spec.rdoc_options += ["--quiet"]')
          result = call_op_write_typing.call(node)
          expect(result.merge_type).to eq(:spec_files)
        end
      end

      context "when spec.version += (identity)" do
        it "adds :spec_identity merge type" do
          node = parse_call('spec.version += ".pre"')
          result = call_op_write_typing.call(node)
          expect(result.merge_type).to eq(:spec_identity)
        end
      end

      context "when receiver is not spec" do
        it "returns the node unchanged" do
          node = parse_call('other.version += ".pre"')
          result = call_op_write_typing.call(node)
          expect(result).to eq(node)
        end
      end

      context "when operator write has unrecognized method" do
        it "returns the node unchanged" do
          node = parse_call('spec.unknown_field += "x"')
          result = call_op_write_typing.call(node)
          expect(result).to eq(node)
        end
      end
    end
  end
end
