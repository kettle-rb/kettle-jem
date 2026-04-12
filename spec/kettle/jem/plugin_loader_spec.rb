# frozen_string_literal: true

require "tmpdir"

require "spec_helper"

RSpec.describe Kettle::Jem::PluginLoader do
  it "loads plugin callbacks from the configured plugin handle" do
    plugin_module = Module.new do
      class << self
        def register_kettle_jem_plugin(registrar)
          registrar.after_phase(:remaining_files) do |context:, **|
            context.out.report_detail("plugin hook ran")
          end
        end
      end
    end
    stub_const("Example::Plugin", plugin_module)
    allow(described_class).to receive(:require).with("example/plugin").and_return(true)

    registry = described_class.load!(plugin_names: ["example-plugin"])
    out = double("out", report_detail: nil)

    expect {
      registry.run(
        timing: :after,
        phase: :remaining_files,
        context: double("context", out: out),
        actor: double("phase"),
        phase_stats: double("phase_stats"),
      )
    }.not_to raise_error

    expect(out).to have_received(:report_detail).with("plugin hook ran")
  end

  it "loads the kettle-drift plugin and injects rake tasks into the Rakefile" do
    registry = described_class.load!(plugin_names: ["kettle-drift"])

    Dir.mktmpdir do |dir|
      rakefile_path = File.join(dir, "Rakefile")
      File.write(rakefile_path, <<~RUBY)
        # frozen_string_literal: true

        require "kettle/dev"
      RUBY

      helpers = double("helpers", record_template_result: nil)
      out = double("out", report_detail: nil)
      context = double(
        "context",
        project_root: dir,
        helpers: helpers,
        out: out,
      )

      registry.run(
        timing: :after,
        phase: :remaining_files,
        context: context,
        actor: double("phase"),
        phase_stats: double("phase_stats"),
      )

      content = File.read(rakefile_path)
      expect(content).to include('require "kettle/drift"')
      expect(content).to include("Kettle::Drift.install_tasks")
      expect(helpers).to have_received(:record_template_result).with(rakefile_path, :replace)
    end
  end
end
