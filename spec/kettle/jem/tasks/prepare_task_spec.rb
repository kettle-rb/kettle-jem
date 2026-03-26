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
end
