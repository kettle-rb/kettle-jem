# frozen_string_literal: true

RSpec.describe Kettle::Jem::TemplateHelpers do
  # Reset memoized config between tests
  before do
    described_class.class_variable_set(:@@kettle_config, nil)
    described_class.class_variable_set(:@@manifestation, nil)
  end

  describe ".kettle_config" do
    it "loads the .kettle-jem.yml configuration file" do
      config = described_class.kettle_config
      expect(config).to be_a(Hash)
      expect(config).to have_key("defaults")
      expect(config).to have_key("patterns")
      expect(config).to have_key("files")
    end

    it "returns defaults with expected merge options" do
      defaults = described_class.kettle_config["defaults"]
      expect(defaults["preference"]).to eq("template")
      expect(defaults["add_template_only_nodes"]).to be(true)
      expect(defaults["freeze_token"]).to eq("kettle-jem")
    end
  end

  describe ".strategy_for" do
    let(:project_root) { described_class.project_root }

    context "when file matches a glob pattern" do
      it "returns :raw_copy for certs/pboling.pem via certs/** glob" do
        path = File.join(project_root, "certs/pboling.pem")
        expect(described_class.strategy_for(path)).to eq(:raw_copy)
      end
    end

    context "when file is not found in config (defaults to merge)" do
      it "returns :merge for completely unknown file" do
        path = File.join(project_root, "some/random/unknown_file.txt")
        expect(described_class.strategy_for(path)).to eq(:merge)
      end

      it "returns :merge for .gitignore" do
        path = File.join(project_root, ".gitignore")
        expect(described_class.strategy_for(path)).to eq(:merge)
      end

      it "returns :merge for Gemfile" do
        path = File.join(project_root, "Gemfile")
        expect(described_class.strategy_for(path)).to eq(:merge)
      end

      it "returns :merge for Rakefile" do
        path = File.join(project_root, "Rakefile")
        expect(described_class.strategy_for(path)).to eq(:merge)
      end

      it "returns :merge for .kettle-jem.yml" do
        path = File.join(project_root, ".kettle-jem.yml")
        expect(described_class.strategy_for(path)).to eq(:merge)
      end

      it "returns :merge for .tool-versions" do
        path = File.join(project_root, ".tool-versions")
        expect(described_class.strategy_for(path)).to eq(:merge)
      end
    end
  end

  describe ".config_for" do
    it "returns config for certs/pboling.pem via pattern (raw_copy)" do
      config = described_class.config_for("certs/pboling.pem")
      expect(config[:strategy]).to eq(:raw_copy)
      expect(config[:path]).to eq("certs/**")
    end

    it "returns nil for file not in config (defaults to merge via strategy_for)" do
      config = described_class.config_for("totally/unknown/path.xyz")
      expect(config).to be_nil
    end

    it "returns nil for .kettle-jem.yml (no longer an explicit override)" do
      config = described_class.config_for(".kettle-jem.yml")
      expect(config).to be_nil
    end
  end

  describe ".find_file_config" do
    it "returns nil for .kettle-jem.yml (no longer in files section)" do
      config = described_class.find_file_config(".kettle-jem.yml")
      expect(config).to be_nil
    end

    it "returns nil for file not in files section" do
      config = described_class.find_file_config("nonexistent/file.rb")
      expect(config).to be_nil
    end
  end

  describe ".load_manifest" do
    it "returns array of pattern entries" do
      manifest = described_class.load_manifest
      expect(manifest).to be_an(Array)
      expect(manifest).not_to be_empty
    end

    it "each entry has :path and :strategy" do
      manifest = described_class.load_manifest
      expect(manifest).to all(have_key(:path).and(have_key(:strategy)))
    end

    it "includes raw_copy strategy for certs/**" do
      manifest = described_class.load_manifest
      certs_entry = manifest.find { |e| e[:path] == "certs/**" }
      expect(certs_entry).not_to be_nil
      expect(certs_entry[:strategy]).to eq(:raw_copy)
    end
  end
end
