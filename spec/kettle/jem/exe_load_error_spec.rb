# frozen_string_literal: true

require "open3"
require "rbconfig"

require "spec_helper"

RSpec.describe "exe/kettle-jem bootstrap loading" do # rubocop:disable RSpec/DescribeClass
  let(:exe_path) { File.expand_path("../../../exe/kettle-jem", __dir__) }
  let(:exe_content) { File.read(exe_path) }

  it "loads the full runtime from the gem itself via require" do
    expect(exe_content).to include('require "kettle/jem"')
  end

  it "does not depend on separately requiring setup_cli or version in the exe" do
    expect(exe_content).not_to include('require_relative "../lib/kettle/jem/setup_cli"')
    expect(exe_content).not_to include('require_relative "../lib/kettle/jem/version"')
  end

  it "can seed bootstrap config after loading the full runtime" do
    runtime_path = File.expand_path("../../../lib/kettle/jem", __dir__)
    template_path = File.expand_path("../../../template/.kettle-jem.yml.example", __dir__)
    script = <<~RUBY
      require "yaml"
      require_relative #{runtime_path.inspect}

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

  it "can merge bootstrap Gemfile content after loading the full runtime" do
    runtime_path = File.expand_path("../../../lib/kettle/jem", __dir__)
    template_path = File.expand_path("../../../template/Gemfile.example", __dir__)
    initial_gemfile = "source \"https://gem.coop\"\n"
    script = <<~RUBY
      require "tmpdir"
      require_relative #{runtime_path.inspect}

      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          File.write("Gemfile", #{initial_gemfile.inspect})
          cli = Kettle::Jem::SetupCLI.allocate
          allow_path = #{template_path.inspect}
          cli.define_singleton_method(:installed_path) do |rel|
            rel == "Gemfile.example" ? allow_path : nil
          end

          cli.send(:ensure_gemfile_from_example!, eval_paths: ["gemfiles/modular/templating.gemfile"])
          content = File.read("Gemfile")
          abort("expected Gemfile bootstrap eval_gemfile") unless content.include?('eval_gemfile "gemfiles/modular/templating.gemfile"')
        end
      end
    RUBY

    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-e", script)

    expect(status.success?).to be(true), "stdout=#{stdout.inspect}\nstderr=#{stderr.inspect}"
    expect(stderr).to eq("")
  end
end
