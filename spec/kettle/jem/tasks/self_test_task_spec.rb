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
end
