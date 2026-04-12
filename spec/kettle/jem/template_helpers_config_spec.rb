# frozen_string_literal: true

RSpec.describe Kettle::Jem::TemplateHelpers do
  # Reset memoized config between tests
  before do
    described_class.class_variable_set(:@@kettle_config, nil)
    described_class.class_variable_set(:@@manifestation, nil)
    described_class.clear_warnings
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

    it "loads min_divergence_threshold when present" do
      Dir.mktmpdir do |dir|
        project_root = File.join(dir, "project")
        template_root = File.join(dir, "template")
        FileUtils.mkdir_p(project_root)
        FileUtils.mkdir_p(template_root)
        File.write(File.join(project_root, ".kettle-jem.yml"), <<~YAML)
          min_divergence_threshold: 12.5
          defaults:
            preference: template
            add_template_only_nodes: true
            freeze_token: kettle-jem
          patterns: []
          files: {}
        YAML

        allow(described_class).to receive_messages(project_root: project_root, template_root: template_root)
        described_class.clear_kettle_config!

        expect(described_class.kettle_config["min_divergence_threshold"]).to eq(12.5)
      end
    end

    it "falls back to template/.kettle-jem.yml.example when the destination has no config" do
      Dir.mktmpdir do |dir|
        template_root = File.join(dir, "template")
        project_root = File.join(dir, "project")
        FileUtils.mkdir_p(template_root)
        FileUtils.mkdir_p(project_root)
        File.write(File.join(template_root, ".kettle-jem.yml.example"), <<~YAML)
          min_divergence_threshold: 25
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
        expect(config["min_divergence_threshold"]).to eq(25)
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

      it "returns :merge for .devcontainer files when no explicit override exists" do
        path = File.join(project_root, ".devcontainer/apt-install/install.sh")
        expect(described_class.strategy_for(path)).to eq(:merge)
      end

      it "returns :merge for GitHub workflow files when no explicit override exists" do
        path = File.join(project_root, ".github/workflows/current.yml")
        expect(described_class.strategy_for(path)).to eq(:merge)
      end

      it "returns :merge for .gitlab-ci.yml when no explicit override exists" do
        path = File.join(project_root, ".gitlab-ci.yml")
        expect(described_class.strategy_for(path)).to eq(:merge)
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

      it "returns :merge for mise.toml" do
        path = File.join(project_root, "mise.toml")
        expect(described_class.strategy_for(path)).to eq(:merge)
      end
    end
  end

  describe ".merge_options_for_path" do
    it "falls back to default merge options for unconfigured files" do
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
          files: {}
        YAML

        allow(described_class).to receive_messages(project_root: project_root, template_root: template_root)
        described_class.clear_kettle_config!

        expect(described_class.merge_options_for_path(".yardopts")).to include(
          preference: :template,
          add_template_only_nodes: true,
          freeze_token: "kettle-jem",
        )
      end
    end
  end

  describe ".readme_top_logo_mode" do
    it "defaults to org_and_project when readme config is absent" do
      allow(described_class).to receive(:kettle_config).and_return({})

      expect(described_class.readme_top_logo_mode).to eq("org_and_project")
    end

    it "accepts org" do
      allow(described_class).to receive(:kettle_config).and_return(
        {"readme" => {"top_logo_mode" => "org"}},
      )

      expect(described_class.readme_top_logo_mode).to eq("org")
    end

    it "normalizes dashed values to underscored values" do
      allow(described_class).to receive(:kettle_config).and_return(
        {"readme" => {"top_logo_mode" => "org-and-project"}},
      )

      expect(described_class.readme_top_logo_mode).to eq("org_and_project")
    end

    it "falls back to org_and_project for invalid values and records a warning" do
      allow(described_class).to receive(:kettle_config).and_return(
        {"readme" => {"top_logo_mode" => "banana"}},
      )

      expect(described_class.readme_top_logo_mode).to eq("org_and_project")
      expect(described_class.warnings.join("\n")).to include("Unknown readme.top_logo_mode 'banana'")
    end
  end

  describe ".config_for" do
    it "returns configured file_type for an extensionless hook script" do
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
            ".git-hooks":
              commit-msg:
                strategy: merge
                file_type: ruby
        YAML

        allow(described_class).to receive_messages(project_root: project_root, template_root: template_root)
        described_class.clear_kettle_config!

        config = described_class.config_for(".git-hooks/commit-msg")
        expect(config[:strategy]).to eq(:merge)
        expect(config[:file_type]).to eq(:ruby)
        expect(described_class.configured_file_type_for(File.join(project_root, ".git-hooks/commit-msg"))).to eq(:ruby)
        expect(described_class.ruby_template?(File.join(project_root, ".git-hooks/commit-msg"))).to be(true)
      end
    end

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

    it "resolves a dotslash-prefixed path identically to its bare form" do
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
            AGENTS.md:
              strategy: accept_template
        YAML

        allow(described_class).to receive_messages(project_root: project_root, template_root: template_root)
        described_class.clear_kettle_config!

        # Both forms must resolve to the same config — a leading "./" must not
        # cause the lookup to walk config["files"]["."]["AGENTS.md"] and miss.
        expect(described_class.find_file_config("AGENTS.md")).to include(strategy: :accept_template)
        expect(described_class.find_file_config("./AGENTS.md")).to include(strategy: :accept_template)
      end
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

    it "does not include a dedicated .devcontainer/**/* override" do
      manifest = described_class.load_manifest
      entry = manifest.find { |e| e[:path] == ".devcontainer/**/*" }
      expect(entry).to be_nil
    end
  end

  describe ".build_config_entry" do
    it "normalizes merge-specific option values from config" do
      allow(described_class).to receive(:kettle_config).and_return(
        {
          "defaults" => {
            "preference" => "destination",
            "add_template_only_nodes" => "false",
            "freeze_token" => " custom-freeze ",
            "max_recursion_depth" => "7",
          },
        },
      )

      result = described_class.build_config_entry(nil, {"strategy" => "merge"})

      expect(result[:preference]).to eq(:destination)
      expect(result[:add_template_only_nodes]).to be(false)
      expect(result[:freeze_token]).to eq("custom-freeze")
      expect(result[:max_recursion_depth]).to eq(7)
    end

    it "retains a merge recipe override" do
      result = described_class.build_config_entry(nil, {"strategy" => "merge", "recipe" => " .kettle-jem/recipes/custom.yml "})

      expect(result[:recipe]).to eq(".kettle-jem/recipes/custom.yml")
    end

    it "accepts a supported file_type hint" do
      result = described_class.build_config_entry(nil, {"strategy" => "merge", "file_type" => "ruby"})

      expect(result[:strategy]).to eq(:merge)
      expect(result[:file_type]).to eq(:ruby)
    end

    it "rejects unknown file_type hints" do
      expect {
        described_class.build_config_entry(nil, {"strategy" => "merge", "file_type" => "banana"})
      }.to raise_error(Kettle::Jem::Error, /Unknown templating file_type/i)
    end

    it "rejects unknown merge preferences" do
      expect {
        described_class.build_config_entry(nil, {"strategy" => "merge", "preference" => "banana"})
      }.to raise_error(Kettle::Jem::Error, /Unknown merge preference/i)
    end

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

    it "rejects recipe overrides on non-merge strategies" do
      expect {
        described_class.build_config_entry(nil, {"strategy" => "accept_template", "recipe" => ".kettle-jem/recipes/custom.yml"})
      }.to raise_error(Kettle::Jem::Error, /recipe overrides require strategy 'merge'/i)
    end
  end

  describe ".apply_strategy" do
    it "forwards configured merge options for Ruby merges" do
      project_root = "/tmp/kettle-jem-project"
      dest_path = File.join(project_root, "Gemfile")
      config_entry = {
        strategy: :merge,
        file_type: :gemfile,
        preference: :destination,
        add_template_only_nodes: false,
        freeze_token: "custom-freeze",
        max_recursion_depth: 7,
      }

      allow(described_class).to receive_messages(project_root: project_root, force_mode?: true)
      allow(described_class).to receive(:config_for).with("Gemfile").and_return(config_entry)
      allow(File).to receive(:exist?).with(dest_path).and_return(true)
      allow(File).to receive(:read).with(dest_path).and_return("destination")

      allow(Kettle::Jem::SourceMerger).to receive(:apply).with(
        strategy: :merge,
        src: "template",
        dest: "destination",
        path: "Gemfile",
        file_type: :gemfile,
        context: nil,
        preference: :destination,
        add_template_only_nodes: false,
        freeze_token: "custom-freeze",
        max_recursion_depth: 7,
        force: true,
      ).and_return("merged")

      expect(described_class.apply_strategy("template", dest_path)).to eq("merged")
    end

    it "resolves project-relative recipe paths before invoking SourceMerger" do
      project_root = "/tmp/kettle-jem-project"
      dest_path = File.join(project_root, "gemfiles/modular/templating_local.gemfile")
      config_entry = {
        strategy: :merge,
        file_type: :gemfile,
        recipe: ".kettle-jem/recipes/nomono_local_gemfile.yml",
      }

      allow(described_class).to receive_messages(project_root: project_root, force_mode?: false)
      allow(described_class).to receive(:config_for).with("gemfiles/modular/templating_local.gemfile").and_return(config_entry)
      allow(File).to receive(:exist?).with(dest_path).and_return(true)
      allow(File).to receive(:read).with(dest_path).and_return("destination")

      allow(Kettle::Jem::SourceMerger).to receive(:apply).with(
        strategy: :merge,
        src: "template",
        dest: "destination",
        path: "gemfiles/modular/templating_local.gemfile",
        file_type: :gemfile,
        context: nil,
        recipe: File.join(project_root, ".kettle-jem/recipes/nomono_local_gemfile.yml"),
        force: false,
      ).and_return("merged")

      expect(described_class.apply_strategy("template", dest_path)).to eq("merged")
    end
  end

  describe ".workflows_config" do
    it "returns empty hash when no workflows key" do
      allow(described_class).to receive(:kettle_config).and_return({})
      expect(described_class.workflows_config).to eq({})
    end

    it "returns empty hash when workflows is not a hash" do
      allow(described_class).to receive(:kettle_config).and_return({"workflows" => "invalid"})
      expect(described_class.workflows_config).to eq({})
    end

    it "returns the workflows hash when present" do
      config = {"preset" => "framework"}
      allow(described_class).to receive(:kettle_config).and_return({"workflows" => config})
      expect(described_class.workflows_config).to eq(config)
    end
  end

  describe ".workflow_preset" do
    it "defaults to modern when absent" do
      allow(described_class).to receive(:kettle_config).and_return({})
      expect(described_class.workflow_preset).to eq("modern")
    end

    it "returns framework when set" do
      allow(described_class).to receive(:kettle_config).and_return({"workflows" => {"preset" => "framework"}})
      expect(described_class.workflow_preset).to eq("framework")
    end

    it "returns legacy-compat when set" do
      allow(described_class).to receive(:kettle_config).and_return({"workflows" => {"preset" => "legacy-compat"}})
      expect(described_class.workflow_preset).to eq("legacy-compat")
    end

    it "warns and falls back for unknown preset" do
      allow(described_class).to receive(:kettle_config).and_return({"workflows" => {"preset" => "bogus"}})
      expect(described_class.workflow_preset).to eq("modern")
      expect(described_class.warnings).to include(a_string_matching(/Unknown workflows\.preset/))
    end
  end

  describe ".framework_matrix?" do
    it "returns false when preset is modern" do
      allow(described_class).to receive(:kettle_config).and_return({})
      expect(described_class.framework_matrix?).to be(false)
    end

    it "returns false when preset is framework but no matrix config" do
      allow(described_class).to receive(:kettle_config).and_return({"workflows" => {"preset" => "framework"}})
      expect(described_class.framework_matrix?).to be(false)
    end

    it "returns true when fully configured" do
      config = {
        "workflows" => {
          "preset" => "framework",
          "framework_matrix" => {
            "dimension" => "activerecord",
            "versions" => ["7.0", "7.1", "7.2"],
            "gemfile_pattern" => "ar-{version}.x",
          },
        },
      }
      allow(described_class).to receive(:kettle_config).and_return(config)
      expect(described_class.framework_matrix?).to be(true)
    end
  end

  describe ".framework_matrix_config" do
    it "returns empty hash when no framework_matrix key" do
      allow(described_class).to receive(:kettle_config).and_return({"workflows" => {"preset" => "framework"}})
      expect(described_class.framework_matrix_config).to eq({})
    end

    it "returns empty hash when dimension is missing" do
      config = {
        "workflows" => {
          "framework_matrix" => {
            "versions" => ["7.0"],
            "gemfile_pattern" => "ar-{version}.x",
          },
        },
      }
      allow(described_class).to receive(:kettle_config).and_return(config)
      expect(described_class.framework_matrix_config).to eq({})
    end

    it "returns empty hash when versions is empty" do
      config = {
        "workflows" => {
          "framework_matrix" => {
            "dimension" => "activerecord",
            "versions" => [],
            "gemfile_pattern" => "ar-{version}.x",
          },
        },
      }
      allow(described_class).to receive(:kettle_config).and_return(config)
      expect(described_class.framework_matrix_config).to eq({})
    end

    it "returns validated config hash when fully configured" do
      config = {
        "workflows" => {
          "framework_matrix" => {
            "dimension" => "activerecord",
            "versions" => ["7.0", "7.1", "7.2", "8.0"],
            "gemfile_pattern" => "ar-{version}.x",
          },
        },
      }
      allow(described_class).to receive(:kettle_config).and_return(config)
      result = described_class.framework_matrix_config
      expect(result["dimension"]).to eq("activerecord")
      expect(result["versions"]).to eq(["7.0", "7.1", "7.2", "8.0"])
      expect(result["gemfile_pattern"]).to eq("ar-{version}.x")
    end
  end

  describe ".expand_gemfile_pattern" do
    it "replaces {version} with dots for dash-separated patterns" do
      expect(described_class.expand_gemfile_pattern("ar-{version}.x", "7.0")).to eq("ar-7.0.x")
    end

    it "replaces dots with underscores when pattern has underscore around placeholder" do
      expect(described_class.expand_gemfile_pattern("rails_{version}", "7.0")).to eq("rails_7_0")
    end

    it "keeps dots when no underscore context" do
      expect(described_class.expand_gemfile_pattern("fw-{version}", "7.0")).to eq("fw-7.0")
    end
  end

  describe ".framework_matrix_gemfiles" do
    it "returns empty when no framework matrix" do
      allow(described_class).to receive(:kettle_config).and_return({})
      expect(described_class.framework_matrix_gemfiles).to eq([])
    end

    it "expands all versions with the pattern" do
      config = {
        "workflows" => {
          "preset" => "framework",
          "framework_matrix" => {
            "dimension" => "activerecord",
            "versions" => ["7.0", "7.1", "7.2", "8.0"],
            "gemfile_pattern" => "ar-{version}.x",
          },
        },
      }
      allow(described_class).to receive(:kettle_config).and_return(config)
      expect(described_class.framework_matrix_gemfiles).to eq(["ar-7.0.x", "ar-7.1.x", "ar-7.2.x", "ar-8.0.x"])
    end

    it "handles underscore-based patterns" do
      config = {
        "workflows" => {
          "preset" => "framework",
          "framework_matrix" => {
            "dimension" => "rails",
            "versions" => ["7.0", "7.1", "8.0"],
            "gemfile_pattern" => "rails_{version}",
          },
        },
      }
      allow(described_class).to receive(:kettle_config).and_return(config)
      expect(described_class.framework_matrix_gemfiles).to eq(["rails_7_0", "rails_7_1", "rails_8_0"])
    end
  end
end
