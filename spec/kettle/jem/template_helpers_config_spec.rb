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

    it "falls back to template/.kettle-jem.yml.example when the destination has no config" do
      Dir.mktmpdir do |dir|
        template_root = File.join(dir, "template")
        project_root = File.join(dir, "project")
        FileUtils.mkdir_p(template_root)
        FileUtils.mkdir_p(project_root)
        File.write(File.join(template_root, ".kettle-jem.yml.example"), <<~YAML)
          defaults:
            preference: destination
            add_template_only_nodes: false
            freeze_token: from-template
          patterns: []
          files: {}
        YAML

        allow(described_class).to receive_messages(
          template_root: template_root,
          project_root: project_root,
        )

        config = described_class.kettle_config
        expect(config.dig("defaults", "freeze_token")).to eq("from-template")
        expect(config.dig("defaults", "preference")).to eq("destination")
        expect(config.dig("defaults", "add_template_only_nodes")).to be(false)
      end
    end
  end

  describe ".strategy_for" do
    let(:project_root) { described_class.project_root }

    context "when destination config declares explicit per-file strategies" do
      it "returns :accept_template for a file configured to replace without merge" do
        Dir.mktmpdir do |dir|
          project_root = File.join(dir, "project")
          template_root = File.join(dir, "template")
          FileUtils.mkdir_p(project_root)
          FileUtils.mkdir_p(template_root)
          File.write(File.join(project_root, ".kettle-jem.yml"), <<~YAML)
            defaults:
              preference: template
              add_template_only_nodes: true
              freeze_token: kettle-jem
            patterns: []
            files:
              README.md:
                strategy: accept_template
          YAML

          allow(described_class).to receive_messages(project_root: project_root, template_root: template_root)
          described_class.clear_kettle_config!

          path = File.join(project_root, "README.md")
          expect(described_class.strategy_for(path)).to eq(:accept_template)
        end
      end

      it "returns :keep_destination for a file configured to ignore template changes" do
        Dir.mktmpdir do |dir|
          project_root = File.join(dir, "project")
          template_root = File.join(dir, "template")
          FileUtils.mkdir_p(project_root)
          FileUtils.mkdir_p(template_root)
          File.write(File.join(project_root, ".kettle-jem.yml"), <<~YAML)
            defaults:
              preference: template
              add_template_only_nodes: true
              freeze_token: kettle-jem
            patterns: []
            files:
              README.md:
                strategy: keep_destination
          YAML

          allow(described_class).to receive_messages(project_root: project_root, template_root: template_root)
          described_class.clear_kettle_config!

          path = File.join(project_root, "README.md")
          expect(described_class.strategy_for(path)).to eq(:keep_destination)
        end
      end
    end

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

  describe ".build_config_entry" do
    it "rejects legacy replace strategy" do
      expect {
        described_class.build_config_entry(nil, {"strategy" => "replace"})
      }.to raise_error(Kettle::Jem::Error, /Unknown templating strategy/i)
    end

    it "rejects legacy append strategy" do
      expect {
        described_class.build_config_entry(nil, {"strategy" => "append"})
      }.to raise_error(Kettle::Jem::Error, /Unknown templating strategy/i)
    end

    it "rejects legacy skip strategy" do
      expect {
        described_class.build_config_entry(nil, {"strategy" => "skip"})
      }.to raise_error(Kettle::Jem::Error, /Unknown templating strategy/i)
    end
  end
end
