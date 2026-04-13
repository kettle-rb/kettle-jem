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

        ### TEMPLATING TASKS
        begin
          require "kettle/jem"
        rescue LoadError
          nil
        end
      RUBY

      helpers = double("helpers", record_template_result: nil)
      out = double("out", report_detail: nil, warning: nil)
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
      expect(content.index('require "kettle/dev"')).to be < content.index("### DUPLICATE DRIFT TASKS")
      expect(content.index("### DUPLICATE DRIFT TASKS")).to be < content.index("### TEMPLATING TASKS")
      expect(helpers).to have_received(:record_template_result).with(rakefile_path, :replace)
    end
  end

  it "appends the kettle-drift snippet to the end of the Rakefile when no anchor is available" do
    registry = described_class.load!(plugin_names: ["kettle-drift"])

    Dir.mktmpdir do |dir|
      rakefile_path = File.join(dir, "Rakefile")
      File.write(rakefile_path, <<~RUBY)
        # frozen_string_literal: true

        task :default do
          puts "ok"
        end
      RUBY

      helpers = double("helpers", record_template_result: nil)
      out = double("out", report_detail: nil, warning: nil)
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
      expect(content.rstrip).to end_with(<<~'RUBY'.rstrip)
        ### DUPLICATE DRIFT TASKS
        begin
          require "kettle/drift"
          Kettle::Drift.install_tasks
        rescue LoadError
          desc("(stub) kettle:drift:check is unavailable")
          task("kettle:drift:check") do
            warn("NOTE: kettle-drift isn't installed, or is disabled for #{RUBY_VERSION} in the current environment")
          end
          desc("(stub) kettle:drift:update is unavailable")
          task("kettle:drift:update") do
            warn("NOTE: kettle-drift isn't installed, or is disabled for #{RUBY_VERSION} in the current environment")
          end
          desc("(stub) kettle:drift:force_update is unavailable")
          task("kettle:drift:force_update") do
            warn("NOTE: kettle-drift isn't installed, or is disabled for #{RUBY_VERSION} in the current environment")
          end
          desc("(stub) kettle:drift is unavailable")
          task("kettle:drift" => "kettle:drift:update")
        end
      RUBY
      expect(helpers).to have_received(:record_template_result).with(rakefile_path, :replace)
    end
  end

  it "relocates a single previously injected drift snippet to the anchored position" do
    registry = described_class.load!(plugin_names: ["kettle-drift"])

    Dir.mktmpdir do |dir|
      rakefile_path = File.join(dir, "Rakefile")
      File.write(rakefile_path, <<~RUBY)
        ### DUPLICATE DRIFT TASKS
        begin
          require "kettle/drift"
          Kettle::Drift.install_tasks
        rescue LoadError
          desc("(stub) kettle:drift:check is unavailable")
          task("kettle:drift:check") do
            warn("NOTE: kettle-drift isn't installed, or is disabled for \#{RUBY_VERSION} in the current environment")
          end
          desc("(stub) kettle:drift:update is unavailable")
          task("kettle:drift:update") do
            warn("NOTE: kettle-drift isn't installed, or is disabled for \#{RUBY_VERSION} in the current environment")
          end
          desc("(stub) kettle:drift:force_update is unavailable")
          task("kettle:drift:force_update") do
            warn("NOTE: kettle-drift isn't installed, or is disabled for \#{RUBY_VERSION} in the current environment")
          end
          desc("(stub) kettle:drift is unavailable")
          task("kettle:drift" => "kettle:drift:update")
        end

        # frozen_string_literal: true

        require "kettle/dev"

        ### TEMPLATING TASKS
        begin
          require "kettle/jem"
        rescue LoadError
          nil
        end
      RUBY

      helpers = double("helpers", record_template_result: nil)
      out = double("out", report_detail: nil, warning: nil)
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
      expect(content.scan("### DUPLICATE DRIFT TASKS").size).to eq(1)
      expect(content.index('require "kettle/dev"')).to be < content.index("### DUPLICATE DRIFT TASKS")
      expect(content.index("### DUPLICATE DRIFT TASKS")).to be < content.index("### TEMPLATING TASKS")
      expect(helpers).to have_received(:record_template_result).with(rakefile_path, :replace)
    end
  end
end
