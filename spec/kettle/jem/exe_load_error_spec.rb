# frozen_string_literal: true

require "open3"
require "rbconfig"

require "spec_helper"

RSpec.describe "exe/kettle-jem bootstrap loading" do # rubocop:disable RSpec/DescribeClass
  let(:exe_path) { File.expand_path("../../../exe/kettle-jem", __dir__) }
  let(:exe_content) { File.read(exe_path) }

  it "loads the bootstrap runtime from the gem itself via require_relative" do
    expect(exe_content).to include('require_relative "../lib/kettle/jem/setup_cli"')
    expect(exe_content).to include('require_relative "../lib/kettle/jem/version"')
  end

  it "does not eagerly require the full bundled runtime before bootstrap handoff" do
    expect(exe_content).not_to include('require "kettle/jem"')
    expect(exe_content).not_to include('require "psych-merge"')
  end

  it "can seed bootstrap config after loading only setup_cli and version" do
    version_path = File.expand_path("../../../lib/kettle/jem/version", __dir__)
    setup_cli_path = File.expand_path("../../../lib/kettle/jem/setup_cli", __dir__)
    template_path = File.expand_path("../../../template/.kettle-jem.yml.example", __dir__)
    script = <<~RUBY
      require "yaml"
      require_relative #{version_path.inspect}
      require_relative #{setup_cli_path.inspect}

      cli = Kettle::Jem::SetupCLI.allocate
      seeded = cli.send(:seed_bootstrap_template_config, File.read(#{template_path.inspect}))
      parsed = YAML.safe_load(seeded, permitted_classes: [], aliases: false)
      abort("expected gh_user to be seeded") unless parsed.dig("tokens", "forge", "gh_user") == "pboling"
    RUBY

    stdout, stderr, status = Open3.capture3({"KJ_GH_USER" => "pboling"}, RbConfig.ruby, "-e", script)

    expect(status.success?).to be(true), "stdout=#{stdout.inspect}\nstderr=#{stderr.inspect}"
    expect(stdout).to eq("")
    expect(stderr).to eq("")
  end
end
