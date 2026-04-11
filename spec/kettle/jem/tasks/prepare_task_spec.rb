# frozen_string_literal: true

RSpec.describe Kettle::Jem::Tasks::PrepareTask do
  after do
    helpers = Kettle::Jem::TemplateHelpers
    helpers.send(:class_variable_set, :@@template_results, {})
    helpers.send(:class_variable_set, :@@output_dir, nil)
    helpers.send(:class_variable_set, :@@project_root_override, nil)
    helpers.send(:class_variable_set, :@@template_warnings, [])
    helpers.send(:class_variable_set, :@@manifestation, nil)
    helpers.send(:class_variable_set, :@@kettle_config, nil)
    helpers.clear_template_run_outcome! if helpers.respond_to?(:clear_template_run_outcome!)
  end

  let(:helpers) { Kettle::Jem::TemplateHelpers }

  before do
    stub_env("FUNDING_ORG" => "false")
  end

  it "writes .kettle-jem.yml and returns bootstrap_only when the project config is missing" do
    Dir.mktmpdir do |gem_root|
      Dir.mktmpdir do |project_root|
        template_root = File.join(gem_root, "template")
        FileUtils.mkdir_p(template_root)
        File.write(File.join(template_root, ".kettle-jem.yml.example"), <<~YAML)
          defaults:
            preference: template
            add_template_only_nodes: true
            freeze_token: kettle-jem
          tokens:
            forge:
              gh_user: ""
          patterns: []
          files: {}
        YAML
        File.write(File.join(project_root, "demo.gemspec"), <<~GEMSPEC)
          Gem::Specification.new do |spec|
            spec.name = "demo"
            spec.version = "0.1.0"
            spec.summary = "test"
            spec.authors = ["Test User"]
            spec.email = ["test@example.com"]
            spec.required_ruby_version = ">= 3.1"
            spec.homepage = "https://github.com/acme/demo"
          end
        GEMSPEC

        allow(helpers).to receive_messages(
          project_root: project_root,
          template_root: template_root,
          ask: true,
        )

        result = described_class.run(
          helpers: helpers,
          project_root: project_root,
          template_root: template_root,
          meta: helpers.gemspec_metadata(project_root),
        )

        expect(result).to eq(:bootstrap_only)
        expect(File).to exist(File.join(project_root, ".kettle-jem.yml"))
        expect(helpers.template_run_outcome).to eq(:bootstrap_only)
      end
    end
  end

  it "backfills missing token values in an existing config and returns ready" do
    Dir.mktmpdir do |gem_root|
      Dir.mktmpdir do |project_root|
        template_root = File.join(gem_root, "template")
        FileUtils.mkdir_p(template_root)
        File.write(File.join(template_root, ".kettle-jem.yml.example"), <<~YAML)
          defaults:
            preference: template
            add_template_only_nodes: true
            freeze_token: kettle-jem
          tokens:
            forge:
              gh_user: ""
            funding:
              kofi: ""
          patterns: []
          files: {}
        YAML
        File.write(File.join(template_root, "README.md.example"), "Donate: https://ko-fi.com/{KJ|FUNDING:KOFI}\n")
        File.write(File.join(project_root, ".kettle-jem.yml"), <<~YAML)
          defaults:
            preference: template
            add_template_only_nodes: true
            freeze_token: kettle-jem
          tokens:
            forge:
              gh_user: ""
            funding:
              kofi: ""
          patterns: []
          files: {}
        YAML
        File.write(File.join(project_root, "demo.gemspec"), <<~GEMSPEC)
          Gem::Specification.new do |spec|
            spec.name = "demo"
            spec.version = "0.1.0"
            spec.summary = "test"
            spec.authors = ["Test User"]
            spec.email = ["test@example.com"]
            spec.required_ruby_version = ">= 3.1"
            spec.homepage = "https://github.com/acme/demo"
          end
        GEMSPEC

        stub_env("KJ_FUNDING_KOFI" => "PrepareOnly")

        allow(helpers).to receive_messages(
          project_root: project_root,
          template_root: template_root,
          ask: true,
        )

        result = described_class.run(
          helpers: helpers,
          project_root: project_root,
          template_root: template_root,
          meta: helpers.gemspec_metadata(project_root),
        )

        expect(result).to eq(:ready)
        expect(File.read(File.join(project_root, ".kettle-jem.yml"))).to include('kofi: "PrepareOnly"')
        expect(File).not_to exist(File.join(project_root, "README.md"))
      end
    end
  end

  # Repro for Bug 2: when gem_name cannot be derived (gemspec has no name),
  # PrepareTask.run must return :unavailable so TemplateTask.run can guard against
  # processing files with un-configured (nil) token replacements.
  #
  # Note: forge_org falls back to "kettle-rb" when no homepage is present, so the
  # :unavailable path is triggered by missing gem_name.
  it "returns :unavailable when gemspec has no name (gem_name cannot be derived)" do
    Dir.mktmpdir do |gem_root|
      Dir.mktmpdir do |project_root|
        template_root = File.join(gem_root, "template")
        FileUtils.mkdir_p(template_root)
        File.write(File.join(template_root, ".kettle-jem.yml.example"), <<~YAML)
          defaults:
            preference: template
          tokens: {}
          patterns: []
          files: {}
        YAML
        # Gemspec deliberately has NO name — gem_name will be nil/empty
        File.write(File.join(project_root, "unnamed.gemspec"), <<~GEMSPEC)
          Gem::Specification.new do |spec|
            spec.version = "0.1.0"
            spec.summary = "test"
            spec.authors = ["Test User"]
            spec.email = ["test@example.com"]
            spec.required_ruby_version = ">= 3.1"
          end
        GEMSPEC
        # Supply .kettle-jem.yml so bootstrap does not trigger
        File.write(File.join(project_root, ".kettle-jem.yml"), <<~YAML)
          defaults:
            preference: template
          tokens: {}
          patterns: []
          files: {}
        YAML

        allow(helpers).to receive_messages(
          project_root: project_root,
          template_root: template_root,
          ask: true,
        )

        result = described_class.run(
          helpers: helpers,
          project_root: project_root,
          template_root: template_root,
          meta: helpers.gemspec_metadata(project_root),
        )

        expect(result).to eq(:unavailable),
          "PrepareTask.run must return :unavailable when gem_name cannot be derived; " \
            "TemplateTask.run must then abort instead of writing files with raw tokens"
      end
    end
  end

  describe "mise trust refresh" do
    let(:project_root) { "/tmp/demo-project" }
    let(:template_root) { "/tmp/demo-template" }
    let(:meta) do
      {
        gh_org: "acme",
        gem_name: "demo",
        namespace: "Demo",
        namespace_shield: "Demo",
        gem_shield: "demo",
        funding_org: "acme",
        min_ruby: Gem::Version.new("3.1"),
      }
    end

    before do
      allow(helpers).to receive_messages(
        project_root: project_root,
        template_root: template_root,
        clear_warnings: nil,
        clear_template_run_outcome!: nil,
        clear_kettle_config!: nil,
        configure_tokens!: nil,
      )
      allow(Kettle::Jem::Tasks::TemplateTask).to receive(:ensure_kettle_config_bootstrap!).and_return(:ready)
      allow(Kettle::Jem::Tasks::TemplateTask).to receive(:backfill_project_kettle_config_tokens!)
      allow(Kettle::Jem::Tasks::TemplateTask).to receive(:validate_required_token_values!)
    end

    it "runs mise trust automatically when mise.toml changed in non-interactive mode" do
      allow(helpers).to receive(:modified_by_template?).with(File.join(project_root, "mise.toml")).and_return(true)
      allow(helpers).to receive(:force_mode?).and_return(true)
      expect(helpers).not_to receive(:ask)
      allow(Kettle::Jem::Tasks::TemplateTask).to receive(:system)
        .with("mise", "trust", "-C", project_root, out: $stdout, err: $stderr)
        .and_return(true)

      result = described_class.run(
        helpers: helpers,
        project_root: project_root,
        template_root: template_root,
        meta: meta,
      )

      expect(result).to eq(:ready)
      expect(Kettle::Jem::Tasks::TemplateTask).to have_received(:system)
        .with("mise", "trust", "-C", project_root, out: $stdout, err: $stderr)
    end

    it "prompts before running mise trust in interactive mode" do
      allow(helpers).to receive(:modified_by_template?).with(File.join(project_root, "mise.toml")).and_return(true)
      allow(helpers).to receive(:force_mode?).and_return(false)
      allow(helpers).to receive(:ask).with("Run `mise trust -C #{project_root}` now?", true).and_return(true)
      allow(Kettle::Jem::Tasks::TemplateTask).to receive(:system)
        .with("mise", "trust", "-C", project_root, out: $stdout, err: $stderr)
        .and_return(true)

      result = described_class.run(
        helpers: helpers,
        project_root: project_root,
        template_root: template_root,
        meta: meta,
      )

      expect(result).to eq(:ready)
      expect(helpers).to have_received(:ask).with("Run `mise trust -C #{project_root}` now?", true)
      expect(Kettle::Jem::Tasks::TemplateTask).to have_received(:system)
        .with("mise", "trust", "-C", project_root, out: $stdout, err: $stderr)
    end

    it "aborts when interactive mode declines the mise trust refresh" do
      allow(helpers).to receive(:modified_by_template?).with(File.join(project_root, "mise.toml")).and_return(true)
      allow(helpers).to receive(:force_mode?).and_return(false)
      allow(helpers).to receive(:ask).with("Run `mise trust -C #{project_root}` now?", true).and_return(false)
      expect(Kettle::Jem::Tasks::TemplateTask).not_to receive(:system)

      expect do
        described_class.run(
          helpers: helpers,
          project_root: project_root,
          template_root: template_root,
          meta: meta,
        )
      end.to raise_error(Kettle::Dev::Error, /mise trust refresh required before continuing/)
      expect(helpers).to have_received(:ask).with("Run `mise trust -C #{project_root}` now?", true)
    end

    it "continues without running mise trust when mise.toml was unchanged" do
      allow(helpers).to receive(:modified_by_template?).with(File.join(project_root, "mise.toml")).and_return(false)
      expect(helpers).not_to receive(:force_mode?)
      expect(helpers).not_to receive(:ask)
      expect(Kettle::Jem::Tasks::TemplateTask).not_to receive(:system)

      result = described_class.run(
        helpers: helpers,
        project_root: project_root,
        template_root: template_root,
        meta: meta,
      )

      expect(result).to eq(:ready)
    end
  end

  # Repro for Bug 2 (token leakage): seeded_kettle_config_content always clears
  # @@token_replacements in its ensure block.  TemplateTask.run calls configure_tokens!
  # again afterwards to restore them (line ~1007).  If that restoration call fails,
  # subsequent read_template calls return raw unresolved content.
  #
  # This test verifies that PrepareTask.run leaves @@token_replacements configured
  # so that callers have a clean starting state (tokens ready).
  it "leaves @@token_replacements configured after a successful run" do
    Dir.mktmpdir do |gem_root|
      Dir.mktmpdir do |project_root|
        template_root = File.join(gem_root, "template")
        FileUtils.mkdir_p(template_root)
        File.write(File.join(template_root, ".kettle-jem.yml.example"), <<~YAML)
          defaults:
            preference: template
          tokens: {}
          patterns: []
          files: {}
        YAML
        File.write(File.join(project_root, "demo.gemspec"), <<~GEMSPEC)
          Gem::Specification.new do |spec|
            spec.name = "demo"
            spec.version = "0.1.0"
            spec.summary = "test"
            spec.authors = ["Test User"]
            spec.email = ["test@example.com"]
            spec.required_ruby_version = ">= 3.1"
            spec.homepage = "https://github.com/acme/demo"
          end
        GEMSPEC
        File.write(File.join(project_root, ".kettle-jem.yml"), <<~YAML)
          defaults:
            preference: template
          tokens: {}
          patterns: []
          files: {}
        YAML

        stub_env("KJ_PROJECT_EMOJI" => "🧪")

        allow(helpers).to receive_messages(
          project_root: project_root,
          template_root: template_root,
          ask: true,
        )

        described_class.run(
          helpers: helpers,
          project_root: project_root,
          template_root: template_root,
          meta: helpers.gemspec_metadata(project_root),
        )

        expect(helpers.tokens_configured?).to be(true),
          "PrepareTask.run must leave @@token_replacements configured so subsequent " \
            "read_template calls resolve tokens correctly"

        resolved = helpers.resolve_tokens("# Include dependencies from {KJ|GEM_NAME}.gemspec")
        expect(resolved).to include("demo"),
          "Token {KJ|GEM_NAME} must be resolved to gem name after PrepareTask.run"
        expect(resolved).not_to include("{KJ|GEM_NAME}"),
          "Raw unresolved token must not appear in resolved output"
      end
    end
  ensure
    helpers.clear_tokens!
  end
end
