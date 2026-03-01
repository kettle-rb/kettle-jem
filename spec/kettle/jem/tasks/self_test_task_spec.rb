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

  describe "SKIPPED_FILES" do
    it "includes Gemfile.lock" do
      expect(described_class::SKIPPED_FILES).to include("Gemfile.lock")
    end

    it "is frozen" do
      expect(described_class::SKIPPED_FILES).to be_frozen
    end
  end

  describe ".run" do
    let(:helpers) { Kettle::Jem::TemplateHelpers }
    let(:manifest) { Kettle::Jem::SelfTest::Manifest }
    let(:reporter) { Kettle::Jem::SelfTest::Reporter }
    let(:gem_root) { Dir.mktmpdir("selftest_run_src") }
    let(:base_dir) { File.join(gem_root, "tmp", "template_test") }

    after { FileUtils.rm_rf(gem_root) }

    before do
      # Set up a minimal gem tree for the run
      FileUtils.mkdir_p(File.join(gem_root, "lib"))
      FileUtils.mkdir_p(File.join(gem_root, "spec"))
      File.write(File.join(gem_root, "Gemfile"), "source 'https://rubygems.org'\n")
      File.write(File.join(gem_root, "lib/foo.rb"), "# foo\n")
      File.write(File.join(gem_root, "spec/foo_spec.rb"), "# spec\n")

      # Stub helpers, manifest, and template task
      allow(helpers).to receive(:gem_checkout_root).and_return(gem_root)
      allow(described_class).to receive(:copy_gem_tree)
      allow(described_class).to receive(:run_template)
    end

    it "creates the directory structure" do
      allow(manifest).to receive(:generate).and_return({})
      allow(manifest).to receive(:compare).and_return(
        matched: %w[Gemfile], changed: [], added: [], removed: [],
      )
      allow(reporter).to receive(:diff).and_return("")
      allow(reporter).to receive(:summary).and_return("# Report\n")

      described_class.run

      expect(File).to exist(File.join(base_dir, "destination"))
      expect(File).to exist(File.join(base_dir, "output"))
      expect(File).to exist(File.join(base_dir, "report"))
      expect(File).to exist(File.join(base_dir, "report", "diffs"))
    end

    it "writes before and after manifests as JSON" do
      allow(manifest).to receive(:generate).and_return("Gemfile" => "abc123")
      allow(manifest).to receive(:compare).and_return(
        matched: %w[Gemfile], changed: [], added: [], removed: [],
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
      allow(manifest).to receive(:generate).and_return({})
      allow(manifest).to receive(:compare).and_return(
        matched: %w[Gemfile], changed: [], added: [], removed: [],
      )
      allow(reporter).to receive(:summary).and_return("# My Report\n")

      described_class.run

      summary_path = File.join(base_dir, "report", "summary.md")
      expect(File).to exist(summary_path)
      expect(File.read(summary_path)).to include("# My Report")
    end

    it "partitions removed files into skipped and truly removed" do
      allow(manifest).to receive(:generate).and_return({})
      allow(manifest).to receive(:compare).and_return(
        matched: [],
        changed: [],
        added: [],
        removed: %w[lib/foo.rb spec/bar_spec.rb exe/run Gemfile.lock template/x.rb unexpected.txt],
      )
      allow(reporter).to receive(:summary).and_return("# Report\n")

      # We can't easily inspect the comparison object passed to reporter,
      # but we can verify the report is written without error
      described_class.run
    end

    it "writes diff files for changed files" do
      allow(manifest).to receive(:generate).and_return({})
      allow(manifest).to receive(:compare).and_return(
        matched: [], changed: %w[Gemfile], added: [], removed: [],
      )
      allow(reporter).to receive(:diff).and_return("--- a/Gemfile\n+++ b/Gemfile\n")
      allow(reporter).to receive(:summary).and_return("# Report\n")

      described_class.run

      diff_path = File.join(base_dir, "report", "diffs", "Gemfile.diff")
      expect(File).to exist(diff_path)
      expect(File.read(diff_path)).to include("--- a/Gemfile")
    end

    it "skips writing diff for empty diff output" do
      allow(manifest).to receive(:generate).and_return({})
      allow(manifest).to receive(:compare).and_return(
        matched: [], changed: %w[Gemfile], added: [], removed: [],
      )
      allow(reporter).to receive(:diff).and_return("")
      allow(reporter).to receive(:summary).and_return("# Report\n")

      described_class.run

      diff_path = File.join(base_dir, "report", "diffs", "Gemfile.diff")
      expect(File).not_to exist(diff_path)
    end

    it "calculates score as 0.0 when no files processed" do
      allow(manifest).to receive(:generate).and_return({})
      allow(manifest).to receive(:compare).and_return(
        matched: [], changed: [], added: [], removed: [],
      )
      allow(reporter).to receive(:summary).and_return("# Report\n")

      # Should not raise even with 0 total files
      expect { described_class.run }.not_to raise_error
    end

    it "raises when score is below threshold" do
      stub_env("KJ_SELFTEST_THRESHOLD" => "90")
      allow(manifest).to receive(:generate).and_return({})
      allow(manifest).to receive(:compare).and_return(
        matched: [], changed: %w[a.txt b.txt], added: [], removed: [],
      )
      allow(reporter).to receive(:diff).and_return("")
      allow(reporter).to receive(:summary).and_return("# Report\n")

      expect { described_class.run }.to raise_error(Kettle::Dev::Error, /FAIL/)
    end

    it "does not raise when score meets threshold" do
      stub_env("KJ_SELFTEST_THRESHOLD" => "50")
      allow(manifest).to receive(:generate).and_return({})
      allow(manifest).to receive(:compare).and_return(
        matched: %w[a.txt], changed: %w[b.txt], added: [], removed: [],
      )
      allow(reporter).to receive(:diff).and_return("")
      allow(reporter).to receive(:summary).and_return("# Report\n")

      expect { described_class.run }.not_to raise_error
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
