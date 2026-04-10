# frozen_string_literal: true

require "kettle/jem/duplicate_line_validator"
require "tmpdir"
require "fileutils"

RSpec.describe Kettle::Jem::DuplicateLineValidator do
  describe ".scan" do
    it "returns empty hash when no duplicates" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "clean.rb")
        File.write(path, "line one\nline two\nline three\n")
        results = described_class.scan(files: [path])
        expect(results).to be_empty
      end
    end

    it "detects duplicate lines in a single file" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "duped.rb")
        File.write(path, "require \"foo\"\nrequire \"bar\"\nrequire \"foo\"\n")
        results = described_class.scan(files: [path])
        expect(results).to have_key('require "foo"')
        entry = results['require "foo"'].first
        expect(entry[:file]).to eq(path)
        expect(entry[:lines]).to eq([1, 3])
      end
    end

    it "ignores lines with <= min_chars non-whitespace characters" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "short.rb")
        # "end" has 3 non-ws chars — should be ignored at default min_chars=6
        File.write(path, "end\nend\nend\n")
        results = described_class.scan(files: [path])
        expect(results).to be_empty
      end
    end

    it "exempts standard changelog release subheadings from duplicate detection" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "CHANGELOG.md")
        content = <<~MD
          ## [1.0.0] - 2026-01-01
          ### Added
          - Feature A
          ### Fixed
          - Bug B
          ## [0.9.0] - 2025-12-01
          ### Added
          - Feature C
          ### Fixed
          - Bug D
        MD
        File.write(path, content)
        results = described_class.scan(files: [path])
        expect(results).to be_empty
      end
    end

    it "ignores repeated eval_gemfile lines in Appraisals files" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "Appraisals")
        content = <<~RUBY
          appraise "current" do
            eval_gemfile "modular/rspec.gemfile"
          end

          appraise "head" do
            eval_gemfile "modular/rspec.gemfile"
          end
        RUBY
        File.write(path, content)
        results = described_class.scan(files: [path])
        expect(results).to be_empty
      end
    end

    it "still reports repeated eval_gemfile lines outside Appraisals files" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "Gemfile")
        content = <<~RUBY
          eval_gemfile "modular/rspec.gemfile"
          eval_gemfile "modular/rspec.gemfile"
        RUBY
        File.write(path, content)
        results = described_class.scan(files: [path])
        expect(results).to have_key('eval_gemfile "modular/rspec.gemfile"')
      end
    end

    it "ignores repeated fenced code block markers in markdown files" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "README.md")
        content = <<~MD
          ```ruby
          puts "one"
          ```

          ```ruby
          puts "two"
          ```
        MD
        File.write(path, content)
        results = described_class.scan(files: [path])
        expect(results).to be_empty
      end
    end

    it "still reports repeated fenced code block markers outside markdown files" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "example.txt")
        content = <<~TEXT
          ```ruby
          ```ruby
        TEXT
        File.write(path, content)
        results = described_class.scan(files: [path], min_chars: 1)
        expect(results).to have_key("```ruby")
      end
    end

    it "respects custom min_chars" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "short.rb")
        File.write(path, "end\nend\n")
        results = described_class.scan(files: [path], min_chars: 2)
        expect(results).to have_key("end")
      end
    end

    it "handles multiple files independently" do
      Dir.mktmpdir do |dir|
        path1 = File.join(dir, "a.rb")
        path2 = File.join(dir, "b.rb")
        File.write(path1, "require \"foo\"\nrequire \"foo\"\n")
        File.write(path2, "require \"foo\"\nrequire \"foo\"\n")
        results = described_class.scan(files: [path1, path2])
        expect(results['require "foo"'].size).to eq(2)
        files = results['require "foo"'].map { |e| e[:file] }
        expect(files).to contain_exactly(path1, path2)
      end
    end

    it "handles triple duplicates in one file" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "triple.rb")
        File.write(path, "gem \"parser\"\nother line\ngem \"parser\"\nmore stuff\ngem \"parser\"\n")
        results = described_class.scan(files: [path])
        entry = results['gem "parser"'].first
        expect(entry[:lines]).to eq([1, 3, 5])
      end
    end

    it "skips non-existent files gracefully" do
      results = described_class.scan(files: ["/nonexistent/file.rb"])
      expect(results).to be_empty
    end
  end

  describe ".scan_template_results" do
    it "only scans files with :create or :replace actions" do
      Dir.mktmpdir do |dir|
        written = File.join(dir, "written.rb")
        skipped = File.join(dir, "skipped.rb")
        File.write(written, "gem \"foo\"\ngem \"foo\"\n")
        File.write(skipped, "gem \"bar\"\ngem \"bar\"\n")

        template_results = {
          written => {action: :replace, timestamp: Time.now},
          skipped => {action: :skip, timestamp: Time.now},
        }

        results = described_class.scan_template_results(template_results: template_results)
        expect(results).to have_key('gem "foo"')
        expect(results).not_to have_key('gem "bar"')
      end
    end
  end

  describe ".warning_count" do
    it "returns total count of duplicate entries" do
      results = {
        "line_a" => [{file: "a.rb", lines: [1, 5]}, {file: "b.rb", lines: [2, 3]}],
        "line_b" => [{file: "c.rb", lines: [10, 20]}],
      }
      expect(described_class.warning_count(results)).to eq(3)
    end
  end

  describe ".to_json" do
    it "produces valid JSON" do
      results = {
        'gem "foo"' => [{file: "/a.rb", lines: [1, 3]}],
      }
      json = described_class.to_json(results)
      parsed = JSON.parse(json)
      expect(parsed).to have_key('gem "foo"')
      expect(parsed['gem "foo"'].first["lines"]).to eq([1, 3])
    end
  end

  describe ".write_json" do
    it "writes JSON to disk" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "report.json")
        results = {"line" => [{file: "a.rb", lines: [1, 2]}]}
        described_class.write_json(results, path)
        expect(File.exist?(path)).to be(true)
        parsed = JSON.parse(File.read(path))
        expect(parsed).to have_key("line")
      end
    end
  end

  describe ".report_summary" do
    it "returns clean message when no duplicates" do
      expect(described_class.report_summary({})).to include("No duplicate lines")
    end

    it "returns markdown table when duplicates found" do
      results = {
        'gem "foo"' => [{file: "/project/a.rb", lines: [1, 3]}],
      }
      summary = described_class.report_summary(results, project_root: "/project")
      expect(summary).to include("Duplicate Line Report")
      expect(summary).to include("a.rb")
      expect(summary).to include("1, 3")
    end
  end

  describe ".baseline" do
    it "returns a Set of line contents duplicated in the template directory" do
      Dir.mktmpdir do |dir|
        # Create a fake template directory with known duplicates
        File.write(File.join(dir, "a.yml.example"), "key: value\nkey: value\nother: thing\n")
        File.write(File.join(dir, "b.rb.example"), "unique_line_here\n")

        result = described_class.baseline(template_dir: dir, min_chars: 6)
        expect(result).to be_a(Set)
        expect(result).to include("key: value")
        expect(result).not_to include("unique_line_here")
      end
    end

    it "returns empty set when no template directory exists" do
      result = described_class.baseline(template_dir: "/nonexistent/path")
      expect(result).to eq(Set.new)
    end
  end

  describe ".subtract_baseline" do
    it "removes entries whose line content appears in the baseline set" do
      results = {
        'gem "foo"' => [{file: "a.rb", lines: [1, 3]}],
        'gem "bar"' => [{file: "b.rb", lines: [2, 4]}],
        "unique_problem_line" => [{file: "c.rb", lines: [5, 10]}],
      }
      baseline_set = Set.new(['gem "foo"', 'gem "bar"'])

      filtered = described_class.subtract_baseline(results, baseline_set: baseline_set)
      expect(filtered).to have_key("unique_problem_line")
      expect(filtered).not_to have_key('gem "foo"')
      expect(filtered).not_to have_key('gem "bar"')
    end

    it "returns all results when baseline is empty" do
      results = {"line" => [{file: "a.rb", lines: [1, 2]}]}
      filtered = described_class.subtract_baseline(results, baseline_set: Set.new)
      expect(filtered).to eq(results)
    end
  end

  describe ".template_managed_files" do
    it "returns existing files that match template patterns" do
      Dir.mktmpdir do |dir|
        # Create a fake template dir
        tpl_dir = File.join(dir, "template")
        FileUtils.mkdir_p(tpl_dir)
        File.write(File.join(tpl_dir, "Rakefile.example"), "# rake\n")
        File.write(File.join(tpl_dir, "missing.yml.example"), "key: val\n")

        # Create a project dir with only one matching file
        proj_dir = File.join(dir, "project")
        FileUtils.mkdir_p(proj_dir)
        File.write(File.join(proj_dir, "Rakefile"), "# actual rake\n")

        files = described_class.template_managed_files(project_root: proj_dir, template_dir: tpl_dir)
        expect(files).to include(File.join(proj_dir, "Rakefile"))
        expect(files).not_to include(File.join(proj_dir, "missing.yml"))
      end
    end
  end
end
