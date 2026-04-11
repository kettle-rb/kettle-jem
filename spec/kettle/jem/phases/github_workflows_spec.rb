# frozen_string_literal: true

require "tmpdir"
require "kettle/jem/phases/phase_context"
require "kettle/jem/phases/github_workflows"

RSpec.describe Kettle::Jem::Phases::GithubWorkflows do
  def build_context(helpers:, out:, project_root:, template_root:, removed_appraisals: [])
    Kettle::Jem::Phases::PhaseContext.new(
      helpers: helpers,
      out: out,
      project_root: project_root,
      template_root: template_root,
      gem_name: "demo",
      namespace: "Demo",
      namespace_shield: "Demo",
      gem_shield: "demo",
      forge_org: "acme",
      funding_org: nil,
      min_ruby: "3.1",
      entrypoint_require: "demo",
      meta: {},
      removed_appraisals: removed_appraisals,
    )
  end

  def install_copy_stub(helpers, template_results)
    allow(helpers).to receive(:copy_file_with_prompt) do |src, dest, allow_create:, allow_replace:, raw: false, &block|
      existed = File.exist?(dest)
      FileUtils.mkdir_p(File.dirname(dest))
      content = File.read(src)
      content = block.call(content) if block
      File.write(dest, content)
      template_results[dest] = {action: ((existed || raw) ? :replace : :create)}
    end
  end

  it "prefers .example workflow templates over plain YAML files" do
    Dir.mktmpdir do |root|
      github_dir = File.join(root, ".github", "workflows")
      FileUtils.mkdir_p(github_dir)
      File.write(File.join(github_dir, "ci.yml"), "plain\n")
      File.write(File.join(github_dir, "ci.yml.example"), "example\n")

      phase = described_class.new(context: build_context(
        helpers: double("helpers", template_results: {}),
        out: double("out", phase: nil),
        project_root: root,
        template_root: root,
      ))

      selected = phase.send(:discover_github_yaml_templates, File.join(root, ".github"))

      expect(selected.values).to contain_exactly(File.join(github_dir, "ci.yml.example"))
      expect(phase.send(:github_yaml_template_path?, File.join(github_dir, "ci.yml.example"))).to be(true)
      expect(phase.send(:github_yaml_template_path?, File.join(github_dir, "README.md"))).to be(false)
    end
  end

  it "merges funding and workflow files, honors include filters, and removes obsolete workflows" do
    Dir.mktmpdir do |project_root|
      Dir.mktmpdir do |template_root|
        github_dir = File.join(template_root, ".github", "workflows")
        FileUtils.mkdir_p(github_dir)
        File.write(File.join(template_root, ".github", "FUNDING.yml.example"), "---\ngithub: [acme]\n")
        File.write(File.join(github_dir, "ci.yml.example"), "---\nname: CI\n")
        File.write(File.join(github_dir, "discord-notifier.yml.example"), "---\nname: Discord\n")

        ci_dest = File.join(project_root, ".github", "workflows", "ci.yml")
        funding_dest = File.join(project_root, ".github", "FUNDING.yml")
        obsolete_dest = File.join(project_root, ".github", "workflows", Kettle::Jem::Tasks::TemplateTask::OBSOLETE_WORKFLOWS.first)
        FileUtils.mkdir_p(File.dirname(ci_dest))
        File.write(ci_dest, "name: Old CI\n")
        File.write(funding_dest, "github: [dest]\n")
        File.write(obsolete_dest, "obsolete\n")

        template_results = {}
        helpers = double("helpers", template_results: template_results)
        out = double("out", phase: nil, report_detail: nil, detail: nil)
        install_copy_stub(helpers, template_results)
        allow(helpers).to receive_messages(
          prefer_example_with_osc_check: nil,
          framework_matrix?: false,
          add_warning: nil,
          engines_config: {},
          ask: true,
          output_dir: nil,
        )
        allow(helpers).to receive(:prefer_example_with_osc_check) { |path| path }
        allow(helpers).to receive(:strategy_for) do |dest|
          (File.basename(dest) == "discord-notifier.yml") ? :raw_copy : :merge
        end
        allow(helpers).to receive_messages(
          skip_for_disabled_opencollective?: false,
          skip_for_disabled_engine?: false,
        )
        allow(helpers).to receive(:read_template) { |path| File.read(path) }
        allow(Psych::Merge::SmartMerger).to receive(:new).and_return(instance_double(Psych::Merge::SmartMerger, merge: "---\nmerged: true\n"))
        allow(Kettle::Jem::Tasks::TemplateTask).to receive_messages(
          prune_workflow_matrix_by_appraisals: ["---\nmerged: true\n", 0, 0, false],
          prune_workflow_matrix_by_engines: ["---\nmerged: true\n", 0, 0, false],
        )

        stub_env("include" => ".github/workflows/discord-notifier.yml")

        described_class.call(context: build_context(helpers: helpers, out: out, project_root: project_root, template_root: template_root))

        expect(File.read(ci_dest)).to eq("---\nmerged: true\n")
        expect(File.read(funding_dest)).to eq("---\nmerged: true\n")
        expect(File.read(File.join(project_root, ".github", "workflows", "discord-notifier.yml"))).to eq("---\nname: Discord\n")
        expect(File.exist?(obsolete_dest)).to be(false)
      end
    end
  end
end
