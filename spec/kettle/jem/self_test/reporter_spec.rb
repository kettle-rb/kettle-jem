# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Kettle::Jem::SelfTest::Reporter do
  subject(:reporter) { described_class }

  describe ".diff" do
    let(:tmpdir) { Dir.mktmpdir("reporter_diff_test") }
    let(:file_a) { File.join(tmpdir, "a.txt") }
    let(:file_b) { File.join(tmpdir, "b.txt") }

    after { FileUtils.rm_rf(tmpdir) }

    it "returns an empty string for identical files" do
      File.write(file_a, "same content\n")
      File.write(file_b, "same content\n")

      result = reporter.diff(file_a, file_b)
      expect(result).to eq("")
    end

    it "returns unified diff output for differing files" do
      File.write(file_a, "line one\nline two\n")
      File.write(file_b, "line one\nline three\n")

      result = reporter.diff(file_a, file_b)
      expect(result).to include("---")
      expect(result).to include("+++")
      expect(result).to include("-line two")
      expect(result).to include("+line three")
    end

    it "handles a file that exists only on one side" do
      File.write(file_a, "only in a\n")
      # file_b does not exist — diff uses /dev/null as substitute

      result = reporter.diff(file_a, file_b)
      expect(result).to include("---")
      expect(result).to include("-only in a")
    end
  end

  describe ".summary" do
    let(:output_dir) { "/tmp/selftest/output" }

    it "reports 100% when all files match" do
      comparison = {matched: %w[a.txt b.txt], changed: [], added: [], removed: []}
      result = reporter.summary(comparison, output_dir: output_dir)

      expect(result).to include("# Template Self-Test Report")
      expect(result).to include("100.0%")
      expect(result).to include("2/2 files unchanged")
      expect(result).to include("All files match!")
    end

    it "reports correct score with changed files" do
      comparison = {
        matched: %w[a.txt],
        changed: %w[b.txt],
        added: [],
        removed: [],
      }
      result = reporter.summary(comparison, output_dir: output_dir)

      expect(result).to include("50.0%")
      expect(result).to include("1/2 files unchanged")
      expect(result).to include("## Changed Files (1)")
      expect(result).to include("| b.txt | modified |")
    end

    it "includes added files section" do
      comparison = {matched: [], changed: [], added: %w[new.txt], removed: []}
      result = reporter.summary(comparison, output_dir: output_dir)

      expect(result).to include("## New Files (1)")
      expect(result).to include("| new.txt |")
    end

    it "includes removed files section" do
      comparison = {matched: [], changed: [], added: [], removed: %w[old.txt]}
      result = reporter.summary(comparison, output_dir: output_dir)

      expect(result).to include("## Removed Files (1)")
      expect(result).to include("| old.txt |")
    end

    it "includes the output_dir in the report" do
      comparison = {matched: %w[a.txt], changed: [], added: [], removed: []}
      result = reporter.summary(comparison, output_dir: output_dir)

      expect(result).to include(output_dir)
    end

    it "includes an ISO 8601 date" do
      comparison = {matched: [], changed: [], added: [], removed: []}
      result = reporter.summary(comparison, output_dir: output_dir)

      # Matches ISO 8601 date pattern
      expect(result).to match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/)
    end

    it "handles 0% score gracefully" do
      comparison = {matched: [], changed: %w[a.txt b.txt], added: [], removed: []}
      result = reporter.summary(comparison, output_dir: output_dir)

      expect(result).to include("0.0%")
      expect(result).to include("0/2 files unchanged")
    end

    it "links to diffs directory when there are changes" do
      comparison = {matched: [], changed: %w[a.txt], added: [], removed: []}
      result = reporter.summary(comparison, output_dir: output_dir)

      expect(result).to include("report/diffs/")
    end
  end
end
