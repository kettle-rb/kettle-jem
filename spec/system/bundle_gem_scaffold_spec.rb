# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "shellwords"
require "turbo_tests2/rspec/shared_contexts/simplecov_spawn"

RSpec.describe "bundle gem scaffold + kettle-jem", :system do
  let(:exe_path) { File.expand_path("../../exe/kettle-jem", __dir__) }
  let(:base_env) { {"allowed" => "true"} }
  let(:kettle_jem_env) do
    base_env.merge(
      "KJ_PROJECT_EMOJI" => "⭐️",
      "KJ_MIN_DIVERGENCE_THRESHOLD" => "0",
    )
  end
  let(:duplicates_exe_path) { File.expand_path("../../exe/kettle-jem-validate-duplicates", __dir__) }
  let(:sandbox_root) { File.expand_path("../../../tmp/sandbox", __dir__) }
  let(:dummy_gem_dir) { File.join(sandbox_root, "dummy-gem") }
  let(:duplicates_report_path) { File.join(dummy_gem_dir, "tmp", "kettle-jem", "dup-check.json") }
  let(:max_duplicate_warnings) { 1 }
  let(:expected_hidden_directories) do
    %w[
      .config
      .config/mise
      .devcontainer
      .devcontainer/apt-install
      .devcontainer/scripts
      .git-hooks
      .github
      .github/workflows
      .idea
      .qlty
    ]
  end
  let(:expected_hidden_files) do
    %w[
      .config/mise/env.sh
      .devcontainer/apt-install/devcontainer-feature.json
      .devcontainer/apt-install/install.sh
      .devcontainer/devcontainer.json
      .devcontainer/scripts/setup-tree-sitter.sh
      .git-hooks/commit-msg
      .git-hooks/commit-subjects-goalie.txt
      .git-hooks/footer-template.erb.txt
      .git-hooks/prepare-commit-msg
      .github/.codecov.yml
      .github/COPILOT_INSTRUCTIONS.md
      .github/dependabot.yml
      .github/workflows/templating.yml
      .idea/.gitignore
      .qlty/qlty.toml
    ]
  end

  include_context "with simplecov spawn coverage"

  before do
    FileUtils.rm_rf(dummy_gem_dir)
    FileUtils.mkdir_p(sandbox_root)
    system("bundle gem dummy-gem --no-git --no-ci --no-mit", chdir: sandbox_root, exception: true)
  end

  after do
    FileUtils.rm_rf(dummy_gem_dir)
  end

  def run_kettle_jem!(*args, env: kettle_jem_env)
    Open3.capture3(
      env,
      RbConfig.ruby,
      exe_path,
      *args,
      chdir: dummy_gem_dir,
    )
  end

  def git_commit_all!(message)
    system("git init", chdir: dummy_gem_dir, exception: true) unless Dir.exist?(File.join(dummy_gem_dir, ".git"))
    system("git config user.name 'Test User'", chdir: dummy_gem_dir, exception: true)
    system("git config user.email 'test@example.com'", chdir: dummy_gem_dir, exception: true)
    system("git add -A", chdir: dummy_gem_dir, exception: true)
    system("git commit -m #{Shellwords.escape(message)}", chdir: dummy_gem_dir, exception: true)
  end

  def set_project_emoji!(emoji)
    config_path = File.join(dummy_gem_dir, ".kettle-jem.yml")
    content = File.read(config_path)
    File.write(config_path, content.sub('project_emoji: ""', %(project_emoji: "#{emoji}")))
  end

  it "templates the scaffolded gem and stays within the expected duplicate warning threshold" do
    # Run kettle-jem --skip-commit (CLI handles bin/setup and all preflight internally)
    stdout, stderr, status = run_kettle_jem!("--skip-commit", "--accept-config")
    expect(status.success?).to be(true),
      "kettle-jem failed\nstdout=#{stdout}\nstderr=#{stderr}"
    expect(stderr.scan("Could not determine funding org").count).to be <= 2,
      "expected funding warning to appear at most once per kettle-jem phase\nstdout=#{stdout}\nstderr=#{stderr}"
    expect(stderr.scan("Could not determine forge org").count).to be <= 2,
      "expected forge warning to appear at most once per kettle-jem phase\nstdout=#{stdout}\nstderr=#{stderr}"
    expect(stderr).not_to include("sync_shunted_gemfile!"),
      "expected shunted gemfile generation not to emit helper-method warnings\nstdout=#{stdout}\nstderr=#{stderr}"

    # Duplicate validation: selftest relies on tracked files and is not valid
    # for this skip-commit scenario where templated files remain untracked.
    dup_out, dup_err, dup_status = Open3.capture3(
      RbConfig.ruby,
      duplicates_exe_path,
      dummy_gem_dir,
      "--json=#{duplicates_report_path}",
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

  it "preserves hidden template directories and files across a second templating run" do
    stdout1, stderr1, status1 = run_kettle_jem!("--skip-commit", "--accept-config")
    expect(status1.success?).to be(true),
      "first kettle-jem run failed\nstdout=#{stdout1}\nstderr=#{stderr1}"

    stdout2, stderr2, status2 = run_kettle_jem!("--skip-commit", "--accept-config")
    expect(status2.success?).to be(true),
      "second kettle-jem run failed\nstdout=#{stdout2}\nstderr=#{stderr2}"

    aggregate_failures "hidden template directories" do
      expected_hidden_directories.each do |rel|
        expect(Dir).to exist(File.join(dummy_gem_dir, rel)), "expected #{rel} to exist after re-templating"
      end
    end

    aggregate_failures "hidden template files" do
      expected_hidden_files.each do |rel|
        expect(File).to exist(File.join(dummy_gem_dir, rel)), "expected #{rel} to exist after re-templating"
      end
    end
  end

  it "does not duplicate the trailing HTTP recording block after config bootstrap and a second full run" do
    FileUtils.rm_rf(dummy_gem_dir)
    system("bundle gem dummy-gem", chdir: sandbox_root, exception: true)
    git_commit_all!("initial scaffold")

    stdout1, stderr1, status1 = run_kettle_jem!("--bootstrap-mode", env: base_env)
    expect(status1.success?).to be(true),
      "first plain kettle-jem run failed\nstdout=#{stdout1}\nstderr=#{stderr1}"
    expect(File).to exist(File.join(dummy_gem_dir, ".kettle-jem.yml"))

    set_project_emoji!("🔔")
    system("git add .kettle-jem.yml", chdir: dummy_gem_dir, exception: true)
    system("git commit -m 'config'", chdir: dummy_gem_dir, exception: true)

    stdout2, stderr2, status2 = run_kettle_jem!("--bootstrap-mode", env: base_env)
    expect(status2.success?).to be(true),
      "second plain kettle-jem run failed\nstdout=#{stdout2}\nstderr=#{stderr2}"

    gemspec_path = File.join(dummy_gem_dir, "dummy-gem.gemspec")
    gemspec = File.read(gemspec_path)
    count = gemspec.scan("HTTP recording for deterministic specs").count

    expect(count).to eq(1),
      "Expected exactly 1 HTTP recording block after the second full CLI run, got #{count}.\n\nstdout=#{stdout2}\nstderr=#{stderr2}\n\nGemspec:\n#{gemspec}"
  end
end
