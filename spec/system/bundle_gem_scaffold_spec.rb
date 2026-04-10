# frozen_string_literal: true

require "open3"
require "rbconfig"

RSpec.describe "bundle gem scaffold + kettle-jem", :system do
  let(:exe_path) { File.expand_path("../../exe/kettle-jem", __dir__) }
  let(:sandbox_root) { File.expand_path("../../../tmp/sandbox", __dir__) }
  let(:dummy_gem_dir) { File.join(sandbox_root, "dummy-gem") }

  # Inject SimpleCov spawn shim into subprocesses when coverage is active.
  around do |example|
    if defined?(SimpleCov) && SimpleCov.running
      original_rubyopt = ENV.fetch("RUBYOPT", nil)
      ENV["RUBYOPT"] = "-r./.simplecov_spawn #{original_rubyopt}".strip
      example.run
      ENV["RUBYOPT"] = original_rubyopt
    else
      example.run
    end
  end

  before do
    FileUtils.rm_rf(dummy_gem_dir)
    FileUtils.mkdir_p(sandbox_root)
    system("bundle gem dummy-gem --no-git --no-ci --no-mit", chdir: sandbox_root, exception: true)
  end

  after do
    FileUtils.rm_rf(dummy_gem_dir)
  end

  let(:kettle_jem_env) do
    {
      "KJ_PROJECT_EMOJI" => "⭐️",
      "KJ_MIN_DIVERGENCE_THRESHOLD" => "0",
    }
  end

  it "templates the scaffolded gem and selftest reports zero divergence" do
    # Run kettle-jem --skip-commit (CLI handles bin/setup and all preflight internally)
    stdout, stderr, status = Open3.capture3(
      kettle_jem_env,
      RbConfig.ruby, exe_path, "--skip-commit", "--accept-config",
      chdir: dummy_gem_dir,
    )
    expect(status.success?).to be(true),
      "kettle-jem failed\nstdout=#{stdout}\nstderr=#{stderr}"

    # Selftest: validate no divergence from template
    st_out, st_err, st_status = Open3.capture3(
      RbConfig.ruby, "-S", "rake", "kettle:jem:selftest",
      chdir: dummy_gem_dir,
    )
    expect(st_status.success?).to be(true),
      "selftest failed\nstdout=#{st_out}\nstderr=#{st_err}"
    expect(st_out).to include("Divergence:")
  end
end
