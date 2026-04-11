# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"

RSpec.describe Kettle::Jem::Tasks::SelfTestTask do
  describe ".copy_gem_tree" do
    let(:src_dir) { Dir.mktmpdir("selftest_src") }
    let(:dest_dir) { Dir.mktmpdir("selftest_dest") }

    after do
      FileUtils.rm_rf(src_dir)
      FileUtils.rm_rf(dest_dir)
    end

    before do
      # Create a small fake gem tree
      FileUtils.mkdir_p(File.join(src_dir, "lib/kettle/jem"))
      FileUtils.mkdir_p(File.join(src_dir, ".github/workflows"))
      FileUtils.mkdir_p(File.join(src_dir, "tmp/junk"))
      FileUtils.mkdir_p(File.join(src_dir, ".git/objects"))
      FileUtils.mkdir_p(File.join(src_dir, "coverage"))
      File.write(File.join(src_dir, "Gemfile"), "source 'https://rubygems.org'\n")
      File.write(File.join(src_dir, "lib/kettle/jem.rb"), "# jem\n")
      File.write(File.join(src_dir, ".github/workflows/ci.yml"), "name: CI\n")
      File.write(File.join(src_dir, "tmp/junk/x.txt"), "junk\n")
      File.write(File.join(src_dir, ".git/objects/pack"), "binary\n")
      File.write(File.join(src_dir, "coverage/report.html"), "<html></html>\n")
    end

    it "copies files excluding EXCLUDED_DIRS" do
      # Force the fallback path (no git)
      allow(described_class).to receive(:git_ls_files).and_return(nil)

      described_class.copy_gem_tree(src_dir, dest_dir)

      # Included
      expect(File).to exist(File.join(dest_dir, "Gemfile"))
      expect(File).to exist(File.join(dest_dir, "lib/kettle/jem.rb"))
      expect(File).to exist(File.join(dest_dir, ".github/workflows/ci.yml"))

      # Excluded
      expect(File).not_to exist(File.join(dest_dir, "tmp/junk/x.txt"))
      expect(File).not_to exist(File.join(dest_dir, ".git/objects/pack"))
      expect(File).not_to exist(File.join(dest_dir, "coverage/report.html"))
    end

    it "copies files using git ls-files when available" do
      # Simulate git ls-files returning a known list
      allow(described_class).to receive(:git_ls_files).and_return(
        ["Gemfile", "lib/kettle/jem.rb", ".github/workflows/ci.yml"],
      )

      described_class.copy_gem_tree(src_dir, dest_dir)

      expect(File).to exist(File.join(dest_dir, "Gemfile"))
      expect(File).to exist(File.join(dest_dir, "lib/kettle/jem.rb"))
      expect(File).to exist(File.join(dest_dir, ".github/workflows/ci.yml"))
    end

    it "excludes files in EXCLUDED_DIRS even from git ls-files" do
      allow(described_class).to receive(:git_ls_files).and_return(
        ["Gemfile", "tmp/junk/x.txt", ".git/objects/pack"],
      )

      described_class.copy_gem_tree(src_dir, dest_dir)

      expect(File).to exist(File.join(dest_dir, "Gemfile"))
      expect(File).not_to exist(File.join(dest_dir, "tmp/junk/x.txt"))
      expect(File).not_to exist(File.join(dest_dir, ".git/objects/pack"))
    end
  end

  describe ".git_ls_files" do
    it "returns an array of relative paths for a valid git repo" do
      Dir.mktmpdir do |dir|
        # Initialize a minimal git repo
        system("git", "-C", dir, "init", "-q", out: File::NULL, err: File::NULL)
        system("git", "-C", dir, "config", "user.email", "test@test.com", out: File::NULL, err: File::NULL)
        system("git", "-C", dir, "config", "user.name", "Test", out: File::NULL, err: File::NULL)
        File.write(File.join(dir, "hello.txt"), "hello")
        system("git", "-C", dir, "add", ".", out: File::NULL, err: File::NULL)
        system("git", "-C", dir, "commit", "-m", "init", "-q", out: File::NULL, err: File::NULL)

        result = described_class.git_ls_files(dir)
        expect(result).to be_an(Array)
        expect(result).to include("hello.txt")
      end
    end

    it "returns nil for a non-git directory" do
      Dir.mktmpdir do |dir|
        result = described_class.git_ls_files(dir)
        # git ls-files in a non-repo may return empty or fail
        # Either nil or empty array is acceptable
        expect(result.nil? || result.empty?).to be(true)
      end
    end
  end

  describe ".allow_project_root" do
    let(:helpers) { Kettle::Jem::TemplateHelpers }

    after do
      # Safety net: ensure override is always cleared
      helpers.send(:class_variable_set, :@@project_root_override, nil)
    end

    it "temporarily overrides project_root" do
      original = helpers.project_root

      described_class.allow_project_root(helpers, "/tmp/fake_root") do
        expect(helpers.project_root).to eq("/tmp/fake_root")
      end

      # Should be restored
      expect(helpers.project_root).to eq(original)
    end

    it "restores project_root even when block raises" do
      original = helpers.project_root

      expect {
        described_class.allow_project_root(helpers, "/tmp/fake_root") do
          raise "boom"
        end
      }.to raise_error(RuntimeError, "boom")

      expect(helpers.project_root).to eq(original)
    end
  end

  describe "EXCLUDED_DIRS" do
    it "contains expected entries" do
      expect(described_class::EXCLUDED_DIRS).to include(".git", "tmp", "coverage", "pkg")
    end

    it "is frozen" do
      expect(described_class::EXCLUDED_DIRS).to be_frozen
    end
  end

  describe "SKIPPED_PREFIXES" do
    it "includes source code prefixes" do
      expect(described_class::SKIPPED_PREFIXES).to include("lib/", "spec/", "template/", "exe/", "sig/")
    end

    it "is frozen" do
      expect(described_class::SKIPPED_PREFIXES).to be_frozen
    end
  end

  describe ".expected_non_templated_path?" do
    let(:project_root) { Dir.mktmpdir("selftest_expected_paths") }

    after { FileUtils.rm_rf(project_root) }

    before do
      File.write(File.join(project_root, "kettle-jem.gemspec"), "Gem::Specification.new do |spec|\nend\n")
    end

    it "treats Appraisal-generated gemfiles as expected non-templated files" do
      expect(described_class.expected_non_templated_path?("gemfiles/audit.gemfile", project_root: project_root)).to be(true)
      expect(described_class.expected_non_templated_path?("gemfiles/modular/templating.gemfile", project_root: project_root)).to be(false)
    end

    it "treats the project gemspec as expected even though the template uses a generic basename" do
      expect(described_class.expected_non_templated_path?("kettle-jem.gemspec", project_root: project_root)).to be(true)
      expect(described_class.expected_non_templated_path?("nested/kettle-jem.gemspec", project_root: project_root)).to be(false)
    end
  end

  describe ".run" do
    let(:helpers) { Kettle::Jem::TemplateHelpers }
    let(:manifest) { Kettle::Jem::SelfTest::Manifest }
    let(:reporter) { Kettle::Jem::SelfTest::Reporter }
    let(:gem_root) { Dir.mktmpdir("selftest_run_src") }
    let(:base_dir) { File.join(gem_root, "tmp", "template_test") }

    after {
      FileUtils.rm_rf(gem_root)
      helpers.clear_kettle_config!
    }

    before do
      # Set up a minimal gem tree for the run
      FileUtils.mkdir_p(File.join(gem_root, "lib"))
      FileUtils.mkdir_p(File.join(gem_root, "spec"))
      FileUtils.mkdir_p(File.join(gem_root, "template"))
      File.write(File.join(gem_root, "Gemfile"), "source 'https://rubygems.org'\n")
      File.write(File.join(gem_root, "kettle-jem.gemspec"), "Gem::Specification.new do |spec|\nend\n")
      File.write(File.join(gem_root, "lib/foo.rb"), "# foo\n")
      File.write(File.join(gem_root, "spec/foo_spec.rb"), "# spec\n")

      allow(helpers).to receive_messages(
        project_root: gem_root,
        template_root: File.join(gem_root, "template"),
        kettle_config: {},
      )
      allow(described_class).to receive(:copy_gem_tree)
      allow(described_class).to receive(:run_template)
    end

    it "creates the directory structure" do
      allow(manifest).to receive_messages(generate: {}, compare: {
        matched: %w[Gemfile], changed: [], added: [], removed: [],
      })
      allow(reporter).to receive_messages(diff: "", summary: "# Report\n")

      described_class.run

      expect(File).to exist(File.join(base_dir, "destination"))
      expect(File).to exist(File.join(base_dir, "output"))
      expect(File).to exist(File.join(base_dir, "report"))
      expect(File).to exist(File.join(base_dir, "report", "diffs"))
    end

    it "copies the current project root rather than the kettle-jem gem root" do
      other_template_owner = Dir.mktmpdir("selftest_template_owner")
      allow(helpers).to receive_messages(
        project_root: gem_root,
        template_root: File.join(other_template_owner, "template"),
      )
      allow(manifest).to receive_messages(generate: {}, compare: {
        matched: %w[Gemfile], changed: [], added: [], removed: [],
      })
      allow(reporter).to receive(:summary).and_return("# Report\n")

      described_class.run

      expect(described_class).to have_received(:copy_gem_tree).with(
        gem_root,
        File.join(base_dir, "destination"),
      )
    ensure
      FileUtils.rm_rf(other_template_owner)
    end

    it "writes before and after manifests as JSON" do
      allow(manifest).to receive_messages(
        generate: {"Gemfile" => "abc123"},
        compare: {matched: %w[Gemfile], changed: [], added: [], removed: []},
      )
      allow(reporter).to receive(:summary).and_return("# Report\n")

      described_class.run

      before_json = File.join(base_dir, "report", "before.json")
      after_json = File.join(base_dir, "report", "after.json")
      expect(File).to exist(before_json)
      expect(File).to exist(after_json)
      expect(JSON.parse(File.read(before_json))).to eq("Gemfile" => "abc123")
    end

    it "writes a summary report" do
      allow(manifest).to receive_messages(generate: {}, compare: {
        matched: %w[Gemfile], changed: [], added: [], removed: [],
      })
      allow(reporter).to receive(:summary).and_return("# My Report\n")

      described_class.run

      summary_path = File.join(base_dir, "report", "summary.md")
      expect(File).to exist(summary_path)
      expect(File.read(summary_path)).to include("# My Report")
    end

    it "passes the templating environment snapshot to the reporter" do
      allow(manifest).to receive_messages(generate: {}, compare: {
        matched: %w[Gemfile], changed: [], added: [], removed: [],
      })
      allow(reporter).to receive(:summary).and_return("# Report\n")
      templating_environment = {merge_gems: [{name: "ast-merge", version: "4.0.6", loaded: true, local_path: true}]}
      allow(Kettle::Jem::TemplatingReport).to receive(:snapshot).and_return(templating_environment)

      described_class.run

      expect(reporter).to have_received(:summary).with(
        anything,
        output_dir: File.join(base_dir, "output"),
        templating_environment: templating_environment,
        diff_count: 0,
      )
    end

    it "ignores generated per-run templating reports in the added-file list" do
      before_manifest = {}
      after_manifest = {
        "tmp/kettle-jem/templating-report-20260316-123456-000000-4321.md" => "abc123",
      }
      allow(manifest).to receive(:generate).and_return(before_manifest, after_manifest)
      allow(reporter).to receive(:summary).and_return("# Report\n")

      described_class.run

      expect(reporter).to have_received(:summary).with(
        hash_including(added: []),
        output_dir: File.join(base_dir, "output"),
        templating_environment: anything,
        diff_count: 0,
      )
    end

    it "filters identical force-copied template additions out of the added-file list" do
      template_root = File.join(gem_root, "template")
      FileUtils.mkdir_p(File.join(template_root, "bin"))
      FileUtils.mkdir_p(File.join(template_root, "tmp"))
      File.write(File.join(template_root, "bin", "setup.example"), "#!/usr/bin/env ruby\nputs 'setup'\n")
      File.write(File.join(template_root, "tmp", ".gitignore.example"), "*\n!.gitignore\n")

      allow(helpers).to receive(:template_root).and_return(template_root)
      allow(manifest).to receive_messages(generate: {}, compare: {
        matched: [],
        changed: [],
        added: %w[bin/setup tmp/.gitignore unexpected.txt],
        removed: [],
      })
      allow(described_class).to receive(:run_template) do |_helpers, _dest_dir, output_dir|
        FileUtils.mkdir_p(File.join(output_dir, "bin"))
        FileUtils.mkdir_p(File.join(output_dir, "tmp"))
        File.write(File.join(output_dir, "bin", "setup"), File.read(File.join(template_root, "bin", "setup.example")))
        File.write(File.join(output_dir, "tmp", ".gitignore"), File.read(File.join(template_root, "tmp", ".gitignore.example")))
        File.write(File.join(output_dir, "unexpected.txt"), "surprise\n")
      end
      captured_comparison = nil
      allow(reporter).to receive(:summary) do |comparison, **|
        captured_comparison = comparison
        "# Report\n"
      end

      expect { described_class.run }.not_to raise_error

      expect(captured_comparison[:added]).to eq(["unexpected.txt"])
    end

    it "treats expected template outputs that are missing from output as unexpected removals" do
      template_root = File.join(gem_root, "template")
      FileUtils.mkdir_p(File.join(template_root, ".github"))
      File.write(File.join(template_root, ".github", ".codecov.yml.example"), "codecov:\n  require_ci_to_pass: true\n")

      allow(helpers).to receive(:template_root).and_return(template_root)
      allow(manifest).to receive(:generate).and_return({}, {})
      allow(described_class).to receive(:run_template)

      captured_comparison = nil
      allow(reporter).to receive(:summary) do |comparison, **|
        captured_comparison = comparison
        "# Report\n"
      end

      expect { described_class.run }.not_to raise_error

      expect(captured_comparison[:removed]).to include(".github/.codecov.yml")
    end

    it "partitions expected non-templated removals into skipped and leaves only true surprises as removed" do
      allow(manifest).to receive_messages(generate: {}, compare: {
        matched: [],
        changed: [],
        added: [],
        removed: %w[
          lib/foo.rb
          spec/bar_spec.rb
          exe/run
          Gemfile.lock
          template/x.rb
          gemfiles/audit.gemfile
          kettle-jem.gemspec
          unexpected.txt
        ],
      })
      captured_comparison = nil
      allow(reporter).to receive(:summary) do |comparison, **|
        captured_comparison = comparison
        "# Report\n"
      end

      expect { described_class.run }.not_to raise_error

      expect(captured_comparison[:skipped]).to include(
        "lib/foo.rb",
        "spec/bar_spec.rb",
        "exe/run",
        "Gemfile.lock",
        "template/x.rb",
        "gemfiles/audit.gemfile",
        "kettle-jem.gemspec",
      )
      expect(captured_comparison[:removed]).to eq(["unexpected.txt"])
    end

    it "writes diff files for changed files" do
      allow(manifest).to receive_messages(generate: {}, compare: {
        matched: [], changed: %w[Gemfile], added: [], removed: [],
      })
      allow(reporter).to receive_messages(diff: "--- a/Gemfile\n+++ b/Gemfile\n", summary: "# Report\n")

      described_class.run

      diff_path = File.join(base_dir, "report", "diffs", "Gemfile.diff")
      expect(File).to exist(diff_path)
      expect(File.read(diff_path)).to include("--- a/Gemfile")
    end

    it "filters dynamic shunted.gemfile changes out of the changed-file list" do
      allow(manifest).to receive_messages(generate: {}, compare: {
        matched: [],
        changed: %w[gemfiles/modular/shunted.gemfile Gemfile],
        added: [],
        removed: [],
      })
      captured_comparison = nil
      allow(reporter).to receive(:summary) do |comparison, **|
        captured_comparison = comparison
        "# Report\n"
      end
      allow(reporter).to receive(:diff).and_return("")

      expect { described_class.run }.not_to raise_error

      expect(captured_comparison[:changed]).to eq(["Gemfile"])
    end

    it "skips writing diff for empty diff output" do
      allow(manifest).to receive_messages(generate: {}, compare: {
        matched: [], changed: %w[Gemfile], added: [], removed: [],
      })
      allow(reporter).to receive_messages(diff: "", summary: "# Report\n")

      described_class.run

      diff_path = File.join(base_dir, "report", "diffs", "Gemfile.diff")
      expect(File).not_to exist(diff_path)
    end

    it "calculates score as 0.0 when no files processed" do
      allow(manifest).to receive_messages(generate: {}, compare: {
        matched: [], changed: [], added: [], removed: [],
      })
      allow(reporter).to receive(:summary).and_return("# Report\n")

      # Should not raise even with 0 total files
      expect { described_class.run }.not_to raise_error
    end

    it "raises when divergence exceeds the env threshold" do
      stub_env("KJ_MIN_DIVERGENCE_THRESHOLD" => "90")
      allow(manifest).to receive_messages(generate: {}, compare: {
        matched: [], changed: %w[a.txt b.txt], added: [], removed: [],
      })
      allow(reporter).to receive_messages(diff: "", summary: "# Report\n")

      expect { described_class.run }.to raise_error(Kettle::Dev::Error, /FAIL/)
    end

    it "does not raise when divergence matches the env threshold" do
      stub_env("KJ_MIN_DIVERGENCE_THRESHOLD" => "50")
      allow(manifest).to receive_messages(generate: {}, compare: {
        matched: %w[a.txt], changed: %w[b.txt], added: [], removed: [],
      })
      allow(reporter).to receive_messages(diff: "", summary: "# Report\n")

      expect { described_class.run }.not_to raise_error
    end

    it "raises when divergence exceeds the configured min_divergence_threshold" do
      allow(helpers).to receive(:kettle_config).and_return({"min_divergence_threshold" => 40})
      allow(manifest).to receive_messages(generate: {}, compare: {
        matched: %w[a.txt], changed: %w[b.txt], added: [], removed: [],
      })
      allow(reporter).to receive_messages(diff: "", summary: "# Report\n")

      expect { described_class.run }.to raise_error(Kettle::Dev::Error, /divergence 50.0%/)
    end

    it "lets KJ_MIN_DIVERGENCE_THRESHOLD override min_divergence_threshold" do
      stub_env("KJ_MIN_DIVERGENCE_THRESHOLD" => "50")
      allow(helpers).to receive(:kettle_config).and_return({"min_divergence_threshold" => 40})
      allow(manifest).to receive_messages(generate: {}, compare: {
        matched: %w[a.txt], changed: %w[b.txt], added: [], removed: [],
      })
      allow(reporter).to receive_messages(diff: "", summary: "# Report\n")

      expect { described_class.run }.not_to raise_error
    end
  end

  describe ".score_and_divergence" do
    it "counts unexpected removals against divergence" do
      score, divergence = described_class.score_and_divergence(
        matched: %w[a.txt],
        changed: [],
        added: [],
        removed: %w[.github/.codecov.yml],
      )

      expect(score).to eq(50.0)
      expect(divergence).to eq(50.0)
    end
  end

  describe ".run_template" do
    let(:helpers) { Kettle::Jem::TemplateHelpers }
    let(:dest_dir) { Dir.mktmpdir("selftest_rt_dest") }
    let(:output_dir) { Dir.mktmpdir("selftest_rt_out") }

    after do
      FileUtils.rm_rf(dest_dir)
      FileUtils.rm_rf(output_dir)
      # Ensure state is restored
      helpers.send(:output_dir=, nil)
      helpers.send(:class_variable_set, :@@project_root_override, nil)
    end

    it "sets up redirection and restores state afterwards" do
      original_output_dir = helpers.output_dir
      original_results = helpers.send(:class_variable_get, :@@template_results).dup

      allow(Kettle::Jem::Tasks::TemplateTask).to receive(:run)

      described_class.run_template(helpers, dest_dir, output_dir)

      # State should be restored
      expect(helpers.output_dir).to eq(original_output_dir)
      expect(helpers.send(:class_variable_get, :@@template_results)).to eq(original_results)
    end

    it "restores state even when TemplateTask.run raises" do
      original_output_dir = helpers.output_dir

      allow(Kettle::Jem::Tasks::TemplateTask).to receive(:run).and_raise(RuntimeError, "boom")

      expect {
        described_class.run_template(helpers, dest_dir, output_dir)
      }.to raise_error(RuntimeError, "boom")

      # State should still be restored
      expect(helpers.output_dir).to eq(original_output_dir)
    end

    it "calls TemplateTask.run during execution" do
      allow(Kettle::Jem::Tasks::TemplateTask).to receive(:run)

      described_class.run_template(helpers, dest_dir, output_dir)

      expect(Kettle::Jem::Tasks::TemplateTask).to have_received(:run)
    end

    it "restores ensure_clean_git! singleton override after run" do
      allow(Kettle::Jem::Tasks::TemplateTask).to receive(:run)

      # Before run_template, ensure_clean_git! is a module_function.
      # During run_template, it's overridden with a noop singleton method.
      # After run_template, the singleton method is removed, restoring the module_function.
      described_class.run_template(helpers, dest_dir, output_dir)

      # The singleton noop should have been removed;
      # the module_function should be the one responding now.
      # We verify the singleton was removed (not that the module_function works,
      # since that depends on git state)
      expect(helpers.singleton_methods).not_to include(:ensure_clean_git!)
    end

    it "redirects project_root to dest_dir during run" do
      captured_root = nil

      allow(Kettle::Jem::Tasks::TemplateTask).to receive(:run) {
        captured_root = helpers.project_root
      }

      described_class.run_template(helpers, dest_dir, output_dir)

      expect(captured_root).to eq(dest_dir)
      # Should be restored afterwards
      expect(helpers.project_root).not_to eq(dest_dir)
    end

    it "backfills the sandbox config in dest_dir while still writing rendered files to output_dir" do
      Dir.mktmpdir("selftest_template_root") do |gem_root|
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

        File.write(File.join(dest_dir, ".kettle-jem.yml"), <<~YAML)
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
        File.write(File.join(dest_dir, "demo.gemspec"), <<~GEMSPEC)
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

        stub_env("KJ_FUNDING_KOFI" => "SelftestSafe")
        stub_env("KJ_PROJECT_EMOJI" => "🔧")

        allow(helpers).to receive_messages(
          template_root: template_root,
          ask: true,
        )

        expect { described_class.run_template(helpers, dest_dir, output_dir) }.not_to raise_error

        expect(File.read(File.join(dest_dir, ".kettle-jem.yml"))).to include('kofi: "SelftestSafe"')
        expect(File.read(File.join(output_dir, "README.md"))).to include("https://ko-fi.com/SelftestSafe")
      end
    end

    it "does not prompt for hook template destination and writes hooks into the redirected output sandbox" do
      Dir.mktmpdir("selftest_template_root") do |gem_root|
        template_root = File.join(gem_root, "template")
        hooks_root = File.join(template_root, ".git-hooks")
        FileUtils.mkdir_p(hooks_root)

        File.write(File.join(dest_dir, ".kettle-jem.yml"), <<~YAML)
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
        File.write(File.join(dest_dir, "demo.gemspec"), <<~GEMSPEC)
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

        File.write(File.join(hooks_root, "commit-subjects-goalie.txt.example"), "subject-prefix\n")
        File.write(File.join(hooks_root, "footer-template.erb.txt.example"), "footer\n")

        allow(helpers).to receive_messages(
          template_root: template_root,
          ask: true,
        )
        stub_env("KJ_PROJECT_EMOJI" => "🔧")
        expect(Kettle::Dev::InputAdapter).not_to receive(:gets)

        expect { described_class.run_template(helpers, dest_dir, output_dir) }.not_to raise_error

        expect(File).to exist(File.join(output_dir, ".git-hooks", "commit-subjects-goalie.txt"))
        expect(File).to exist(File.join(output_dir, ".git-hooks", "footer-template.erb.txt"))
      end
    end
  end

  describe ".copy_gem_tree edge cases" do
    let(:src_dir) { Dir.mktmpdir("selftest_edge_src") }
    let(:dest_dir) { Dir.mktmpdir("selftest_edge_dest") }

    after do
      FileUtils.rm_rf(src_dir)
      FileUtils.rm_rf(dest_dir)
    end

    it "skips non-file entries returned by git ls-files" do
      FileUtils.mkdir_p(File.join(src_dir, "lib"))
      File.write(File.join(src_dir, "Gemfile"), "test\n")
      # git ls-files returns a directory path, which won't be a file
      allow(described_class).to receive(:git_ls_files).and_return(%w[Gemfile lib])

      described_class.copy_gem_tree(src_dir, dest_dir)

      expect(File).to exist(File.join(dest_dir, "Gemfile"))
    end

    # BUG REPRO: .idea/ is in EXCLUDED_DIRS but the template task produces
    # .idea/.gitignore. Excluding .idea from the before snapshot causes it
    # to show as a false "New File" in the self-test report.
    it "includes .idea/ files in the copy so they appear in the before snapshot" do
      FileUtils.mkdir_p(File.join(src_dir, ".idea"))
      File.write(File.join(src_dir, ".idea/.gitignore"), "# managed\n")
      File.write(File.join(src_dir, "Gemfile"), "test\n")

      allow(described_class).to receive(:git_ls_files).and_return(
        %w[Gemfile .idea/.gitignore],
      )

      described_class.copy_gem_tree(src_dir, dest_dir)

      expect(File).to exist(File.join(dest_dir, ".idea/.gitignore"))
    end
  end

  describe "SKIPPED_FILES" do
    it "includes Gemfile.lock" do
      expect(described_class::SKIPPED_FILES).to include("Gemfile.lock")
    end

    # BUG REPRO: .kettle-jem.yml and .rubocop_gradual.lock are source-only files
    # with no template equivalents. Without SKIPPED_FILES entries, they show as
    # "Unexpected Removals" in the self-test report.
    it "includes .kettle-jem.yml" do
      expect(described_class::SKIPPED_FILES).to include(".kettle-jem.yml")
    end

    it "includes .rubocop_gradual.lock" do
      expect(described_class::SKIPPED_FILES).to include(".rubocop_gradual.lock")
    end

    it "is frozen" do
      expect(described_class::SKIPPED_FILES).to be_frozen
    end
  end
end
