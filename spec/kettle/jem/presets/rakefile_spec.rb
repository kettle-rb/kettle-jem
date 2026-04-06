# frozen_string_literal: true

RSpec.describe Kettle::Jem::Presets::Rakefile do
  describe ".signature_generator" do
    it "returns the Signatures.rakefile generator" do
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
    let(:callable) { typing[:CallNode] }

    def parse_call(code)
      Prism.parse(code).value.statements.body.first
    end

    it "returns a hash with a CallNode key" do
      expect(typing).to be_a(Hash)
      expect(typing).to have_key(:CallNode)
      expect(callable).to respond_to(:call)
    end

    context "when node is not a task call" do
      it "returns the node unchanged for non-task methods" do
        node = parse_call('puts "hello"')
        expect(callable.call(node)).to eq(node)
      end
    end

    context "when node is a task with string arg" do
      it "categorizes build task" do
        node = parse_call("task :build")
        result = callable.call(node)
        expect(result).to respond_to(:merge_type)
        expect(result.merge_type).to eq(:build_task)
      end

      it "categorizes test task" do
        node = parse_call("task :test")
        result = callable.call(node)
        expect(result.merge_type).to eq(:test_task)
      end

      it "categorizes spec task" do
        node = parse_call("task :spec")
        result = callable.call(node)
        expect(result.merge_type).to eq(:test_task)
      end

      it "categorizes release task" do
        node = parse_call("task :release")
        result = callable.call(node)
        expect(result.merge_type).to eq(:release_task)
      end

      it "categorizes rubocop task" do
        node = parse_call("task :rubocop")
        result = callable.call(node)
        expect(result.merge_type).to eq(:lint_task)
      end

      it "categorizes yard task" do
        node = parse_call("task :yard")
        result = callable.call(node)
        expect(result.merge_type).to eq(:doc_task)
      end

      it "categorizes clean task" do
        node = parse_call("task :clean")
        result = callable.call(node)
        expect(result.merge_type).to eq(:clean_task)
      end

      it "categorizes coverage task" do
        node = parse_call("task :coverage")
        result = callable.call(node)
        expect(result.merge_type).to eq(:coverage_task)
      end
    end

    context "when node is a task with unrecognized name" do
      it "returns the node unchanged" do
        node = parse_call("task :custom_task_xyz")
        result = callable.call(node)
        expect(result).to eq(node)
      end
    end

    context "when node is task with hash arg (task :name => [:deps])" do
      it "categorizes by the key name" do
        code = "task test: [:lint]"
        node = parse_call(code)
        result = callable.call(node)
        expect(result).to respond_to(:merge_type)
        expect(result.merge_type).to eq(:test_task)
      end
    end

    context "when node is task with no arguments" do
      it "returns the node unchanged (nil first_arg)" do
        node = parse_call("task")
        result = callable.call(node)
        expect(result).to eq(node)
      end
    end

    context "when node is task with numeric arg (not unescaped/elements)" do
      it "returns the node unchanged (task_name is nil)" do
        node = parse_call("task 42")
        result = callable.call(node)
        expect(result).to eq(node)
      end
    end

    context "when node is not a task call" do
      it "returns the node unchanged" do
        node = parse_call('puts "hello"')
        result = callable.call(node)
        expect(result).to eq(node)
      end
    end
  end
end
