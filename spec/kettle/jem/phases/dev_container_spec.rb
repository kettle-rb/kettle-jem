# frozen_string_literal: true

require "tmpdir"
require "kettle/jem/phases/phase_context"
require "kettle/jem/phases/dev_container"

RSpec.describe Kettle::Jem::Phases::DevContainer do
  def build_context(helpers:, out:, project_root:, template_root:)
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
    )
  end

  def install_copy_stub(helpers, template_results)
    allow(helpers).to receive(:copy_file_with_prompt) do |src, dest, allow_create:, allow_replace:, raw: false, &block|
      FileUtils.mkdir_p(File.dirname(dest))
      content = File.read(src)
      content = block.call(content) if block
      File.write(dest, content)
      template_results[dest] = {action: ((File.exist?(dest) && !raw) ? :replace : :create)}
    end
  end

  it "returns cleanly when the template has no .devcontainer directory" do
    Dir.mktmpdir do |project_root|
      Dir.mktmpdir do |template_root|
        helpers = double("helpers", template_results: {})
        out = double("out", phase: nil)

        expect { described_class.call(context: build_context(helpers: helpers, out: out, project_root: project_root, template_root: template_root)) }
          .not_to raise_error
      end
    end
  end

  it "merges JSON files and raw-copies files flagged for raw copy" do
    Dir.mktmpdir do |project_root|
      Dir.mktmpdir do |template_root|
        devcontainer_root = File.join(template_root, ".devcontainer")
        FileUtils.mkdir_p(devcontainer_root)
        File.write(File.join(devcontainer_root, "devcontainer.json.example"), %({"name":"template"}\n))
        File.write(File.join(devcontainer_root, "notes.txt.example"), "template notes\n")

        existing_json = File.join(project_root, ".devcontainer", "devcontainer.json")
        FileUtils.mkdir_p(File.dirname(existing_json))
        File.write(existing_json, %({"name":"destination"}\n))

        template_results = {}
        helpers = double("helpers", template_results: template_results)
        out = double("out", phase: nil)
        install_copy_stub(helpers, template_results)
        allow(helpers).to receive(:prefer_example) { |path| path }
        allow(helpers).to receive(:strategy_for) do |dest|
          (File.extname(dest) == ".txt") ? :raw_copy : :merge
        end

        merger = instance_double(Json::Merge::SmartMerger, merge: %({"name":"merged"}\n))
        allow(Json::Merge::SmartMerger).to receive(:new).and_return(merger)

        described_class.call(context: build_context(helpers: helpers, out: out, project_root: project_root, template_root: template_root))

        expect(File.read(existing_json)).to eq(%({"name":"merged"}\n))
        expect(File.read(File.join(project_root, ".devcontainer", "notes.txt"))).to eq("template notes\n")
      end
    end
  end

  it "keeps destination content when AST merging is skipped for parse errors" do
    Dir.mktmpdir do |project_root|
      Dir.mktmpdir do |template_root|
        devcontainer_root = File.join(template_root, ".devcontainer")
        FileUtils.mkdir_p(devcontainer_root)
        File.write(File.join(devcontainer_root, "setup.sh.example"), "#!/usr/bin/env bash\necho template\n")

        dest = File.join(project_root, ".devcontainer", "setup.sh")
        FileUtils.mkdir_p(File.dirname(dest))
        File.write(dest, "#!/usr/bin/env bash\necho destination\n")

        template_results = {}
        helpers = double("helpers", template_results: template_results)
        out = double("out", phase: nil)
        install_copy_stub(helpers, template_results)
        allow(helpers).to receive(:prefer_example) { |path| path }
        allow(helpers).to receive(:strategy_for).and_return(:merge)
        allow(Bash::Merge::SmartMerger).to receive(:new).and_raise(Ast::Merge::ParseError.new("parser missing"))
        allow(Kettle::Jem::Tasks::TemplateTask).to receive(:parse_error_mode).and_return(:skip)
        allow(Kernel).to receive(:warn)

        described_class.call(context: build_context(helpers: helpers, out: out, project_root: project_root, template_root: template_root))

        expect(File.read(dest)).to eq("#!/usr/bin/env bash\necho destination\n")
      end
    end
  end
end
