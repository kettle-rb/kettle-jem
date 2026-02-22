# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "digest"

RSpec.describe Kettle::Jem::SelfTest::Manifest do
  subject(:manifest) { described_class }

  describe ".generate" do
    let(:tmpdir) { Dir.mktmpdir("manifest_test") }

    after { FileUtils.rm_rf(tmpdir) }

    it "returns an empty hash for an empty directory" do
      expect(manifest.generate(tmpdir)).to eq({})
    end

    it "returns an empty hash for a non-existent directory" do
      expect(manifest.generate("/nonexistent/path/#{SecureRandom.hex}")).to eq({})
    end

    it "computes SHA256 digests for files" do
      File.write(File.join(tmpdir, "hello.txt"), "hello world")
      result = manifest.generate(tmpdir)

      expected_digest = Digest::SHA256.hexdigest("hello world")
      expect(result).to eq({"hello.txt" => expected_digest})
    end

    it "handles nested directories" do
      FileUtils.mkdir_p(File.join(tmpdir, "a/b"))
      File.write(File.join(tmpdir, "a/b/nested.txt"), "nested content")
      File.write(File.join(tmpdir, "root.txt"), "root content")

      result = manifest.generate(tmpdir)

      expect(result.keys).to contain_exactly("root.txt", "a/b/nested.txt")
      expect(result["root.txt"]).to eq(Digest::SHA256.hexdigest("root content"))
      expect(result["a/b/nested.txt"]).to eq(Digest::SHA256.hexdigest("nested content"))
    end

    it "skips directories themselves (only includes files)" do
      FileUtils.mkdir_p(File.join(tmpdir, "subdir"))
      File.write(File.join(tmpdir, "subdir/file.txt"), "data")

      result = manifest.generate(tmpdir)
      expect(result.keys).to eq(["subdir/file.txt"])
    end
  end

  describe ".compare" do
    it "classifies identical files as matched" do
      before = {"a.txt" => "abc123", "b.txt" => "def456"}
      after  = {"a.txt" => "abc123", "b.txt" => "def456"}

      result = manifest.compare(before, after)
      expect(result[:matched]).to contain_exactly("a.txt", "b.txt")
      expect(result[:changed]).to be_empty
      expect(result[:added]).to be_empty
      expect(result[:removed]).to be_empty
    end

    it "classifies files with different digests as changed" do
      before = {"a.txt" => "abc123"}
      after  = {"a.txt" => "xyz789"}

      result = manifest.compare(before, after)
      expect(result[:changed]).to eq(["a.txt"])
      expect(result[:matched]).to be_empty
    end

    it "classifies files only in after as added" do
      before = {}
      after  = {"new.txt" => "abc123"}

      result = manifest.compare(before, after)
      expect(result[:added]).to eq(["new.txt"])
      expect(result[:matched]).to be_empty
      expect(result[:changed]).to be_empty
      expect(result[:removed]).to be_empty
    end

    it "classifies files only in before as removed" do
      before = {"old.txt" => "abc123"}
      after  = {}

      result = manifest.compare(before, after)
      expect(result[:removed]).to eq(["old.txt"])
    end

    it "handles a mix of all categories" do
      before = {
        "same.txt" => "aaa",
        "modified.txt" => "bbb",
        "deleted.txt" => "ccc",
      }
      after = {
        "same.txt" => "aaa",
        "modified.txt" => "ddd",
        "created.txt" => "eee",
      }

      result = manifest.compare(before, after)
      expect(result[:matched]).to eq(["same.txt"])
      expect(result[:changed]).to eq(["modified.txt"])
      expect(result[:added]).to eq(["created.txt"])
      expect(result[:removed]).to eq(["deleted.txt"])
    end

    it "returns sorted keys" do
      before = {"z.txt" => "1", "a.txt" => "2"}
      after  = {"z.txt" => "1", "a.txt" => "2"}

      result = manifest.compare(before, after)
      expect(result[:matched]).to eq(["a.txt", "z.txt"])
    end
  end
end
