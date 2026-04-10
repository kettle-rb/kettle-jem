# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"

RSpec.describe "bundle gem scaffold + kettle-jem", :system do
  let(:exe_path) { File.expand_path("../../exe/kettle-jem", __dir__) }
  let(:duplicates_exe_path) { File.expand_path("../../exe/kettle-jem-validate-duplicates", __dir__) }
  let(:sandbox_root) { File.expand_path("../../../tmp/sandbox", __dir__) }
  let(:dummy_gem_dir) { File.join(sandbox_root, "dummy-gem") }
  let(:duplicates_report_path) { File.join(dummy_gem_dir, "tmp", "kettle-jem", "dup-check.json") }
  let(:max_duplicate_warnings) { 1 }

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

  it "templates the scaffolded gem and stays within the expected duplicate warning threshold" do
    # Run kettle-jem --skip-commit (CLI handles bin/setup and all preflight internally)
    stdout, stderr, status = Open3.capture3(
      kettle_jem_env,
      RbConfig.ruby, exe_path, "--skip-commit", "--accept-config",
      chdir: dummy_gem_dir,
    )
    expect(status.success?).to be(true),
      "kettle-jem failed\nstdout=#{stdout}\nstderr=#{stderr}"

    # Duplicate validation: selftest relies on tracked files and is not valid
    # for this skip-commit scenario where templated files remain untracked.
    dup_out, dup_err, dup_status = Open3.capture3(
      RbConfig.ruby, duplicates_exe_path, dummy_gem_dir, "--json=#{duplicates_report_path}",
      chdir: dummy_gem_dir,
    )
    warning_count =
      if dup_out.include?("No duplicate lines detected")
        0
      else
        dup_out[/(\d+) duplicate line warning/, 1].to_i
      end

    report = File.exist?(duplicates_report_path) ? JSON.parse(File.read(duplicates_report_path)) : {}

    expect(dup_err).to eq("")
    expect(warning_count).to be <= max_duplicate_warnings,
      "duplicate validation exceeded threshold #{max_duplicate_warnings}\nstdout=#{dup_out}\nstderr=#{dup_err}\nreport=#{report}"
    expect(dup_status.success? || warning_count <= max_duplicate_warnings).to be(true)
  end
end
