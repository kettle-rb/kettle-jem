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

    it "detects duplicate 2-line chunks in a single file" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "duped.rb")
        # Lines 1-2 and 3-4 form the same chunk
        content = <<~RUBY
          require "foo"
          require "bar"
          require "foo"
          require "bar"
          require "baz"
        RUBY
        File.write(path, content)
        results = described_class.scan(files: [path])
        expect(results).to have_key("require \"foo\"\nrequire \"bar\"")
        entry = results["require \"foo\"\nrequire \"bar\""].first
        expect(entry[:file]).to eq(path)
        expect(entry[:lines]).to eq([1, 3])
      end
    end

    it "does not flag a line that repeats without a matching successor" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "solo.rb")
        # "require foo" repeats but always with different successors
        content = <<~RUBY
          require "foo"
          require "bar"
          require "foo"
          require "baz"
        RUBY
        File.write(path, content)
        results = described_class.scan(files: [path])
        expect(results).to be_empty
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

    it "ignores consecutive dependency pairs in Appraisals files (eval_gemfile + eval_gemfile)" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "Appraisals")
        content = <<~RUBY
          appraise "unlocked_deps" do
            eval_gemfile "modular/rspec.gemfile"
            eval_gemfile "modular/style.gemfile"
          end

          appraise "head" do
            eval_gemfile "modular/rspec.gemfile"
            eval_gemfile "modular/style.gemfile"
          end
        RUBY
        File.write(path, content)
        results = described_class.scan(files: [path])
        expect(results).to be_empty
      end
    end

    it "ignores consecutive gem declaration pairs in Appraisals files (gem + gem)" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "Appraisals")
        content = <<~RUBY
          appraise "ruby-3-3" do
            eval_gemfile "modular/x_std_libs/r3/libs.gemfile"
            gem "mutex_m", "~> 0.2"
          end

          appraise "ruby-3-4" do
            eval_gemfile "modular/x_std_libs/r3/libs.gemfile"
            gem "mutex_m", "~> 0.2"
          end
        RUBY
        File.write(path, content)
        results = described_class.scan(files: [path])
        expect(results).to be_empty
      end
    end

    it "ignores eval_gemfile + gem mixed pairs in Appraisals files" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "Appraisals")
        content = <<~RUBY
          appraise "ruby-3-3" do
            eval_gemfile "modular/x_std_libs/r3/libs.gemfile"
            gem "mutex_m", "~> 0.2"
            gem "stringio", "~> 3.0"
          end

          appraise "ruby-3-4" do
            eval_gemfile "modular/x_std_libs/r3/libs.gemfile"
            gem "mutex_m", "~> 0.2"
            gem "stringio", "~> 3.0"
          end
        RUBY
        File.write(path, content)
        results = described_class.scan(files: [path])
        expect(results).to be_empty
      end
    end

    it "ignores a comment line preceding a dep line in Appraisals files" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "Appraisals")
        content = <<~RUBY
          appraise "ruby-3-3" do
            # runtime dependencies that we can't add to gemspec due to platform differences
            eval_gemfile "modular/tree_sitter.gemfile"
          end

          appraise "ruby-3-4" do
            # runtime dependencies that we can't add to gemspec due to platform differences
            eval_gemfile "modular/tree_sitter.gemfile"
          end
        RUBY
        File.write(path, content)
        results = described_class.scan(files: [path])
        expect(results).to be_empty
      end
    end

    it "suppresses markdown table header+separator pairs in .md files" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "README.md")
        content = <<~MD
          ## Configuration

          | Variable | CLI Flag | Default | Description |
          |----------|----------|---------|-------------|
          | FOO      | --foo    | false   | enables foo |

          ## Reference

          | Variable | CLI Flag | Default | Description |
          |----------|----------|---------|-------------|
          | BAR      | --bar    | true    | enables bar |
        MD
        File.write(path, content)
        results = described_class.scan(files: [path])
        expect(results).to be_empty
      end
    end

    it "flags a duplicated appraisal block in an Appraisals file (corruption signal)" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "Appraisals")
        content = <<~RUBY
          appraise "ruby-3-3" do
            eval_gemfile "modular/x_std_libs/r3/libs.gemfile"
          end

          appraise "ruby-3-3" do
            eval_gemfile "modular/x_std_libs/r3/libs.gemfile"
          end
        RUBY
        File.write(path, content)
        results = described_class.scan(files: [path])
        # The chunk appraise/eval_gemfile is NOT suppressed: line1 is not a dep line
        expect(results).to have_key("appraise \"ruby-3-3\" do\neval_gemfile \"modular/x_std_libs/r3/libs.gemfile\"")
      end
    end

    it "still flags a duplicate eval_gemfile pair in a non-Appraisals file" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "Gemfile")
        content = <<~RUBY
          eval_gemfile "modular/rspec.gemfile"
          eval_gemfile "modular/style.gemfile"
          eval_gemfile "modular/rspec.gemfile"
          eval_gemfile "modular/style.gemfile"
        RUBY
        File.write(path, content)
        results = described_class.scan(files: [path])
        expect(results).to have_key("eval_gemfile \"modular/rspec.gemfile\"\neval_gemfile \"modular/style.gemfile\"")
      end
    end

    it "skips CODE_OF_CONDUCT.md entirely" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "CODE_OF_CONDUCT.md")
        # Identical consecutive pairs that would otherwise trigger detection
        content = <<~MD
          This is our pledge to the community.
          We will be inclusive and welcoming.
          This is our pledge to the community.
          We will be inclusive and welcoming.
        MD
        File.write(path, content)
        results = described_class.scan(files: [path])
        expect(results).to be_empty
      end
    end

    it "suppresses auto-generated coverage metric pairs in CHANGELOG.md" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "CHANGELOG.md")
        content = <<~MD
          ## [1.1.0] - 2026-06-01
          - COVERAGE: 94.38% -- 4066/4308 lines in 26 files
          - BRANCH COVERAGE: 78.77% -- 1673/2124 branches in 26 files
          - 79.89% documented

          ## [1.0.0] - 2026-01-01
          - COVERAGE: 94.38% -- 4066/4308 lines in 26 files
          - BRANCH COVERAGE: 78.77% -- 1673/2124 branches in 26 files
          - 79.89% documented
        MD
        File.write(path, content)
        results = described_class.scan(files: [path])
        expect(results).to be_empty
      end
    end

    it "suppresses duplicate chunks inside markdown code fences" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "README.md")
        content = <<~MD
          ## Quick Start

          ```ruby
          require "my_gem"
          result = do_something
          ```

          ## Advanced Usage

          ```ruby
          require "my_gem"
          result = do_something
          ```
        MD
        File.write(path, content)
        results = described_class.scan(files: [path])
        expect(results).to be_empty
      end
    end

    it "suppresses consecutive ENV assignment pairs in Rakefiles" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "Rakefile")
        content = <<~RUBY
          task(:run_ffi_specs) do
            ENV["K_SOUP_COV_MIN_HARD"] = "false"
            ENV["MAX_ROWS"] = "0"
            sh "bundle exec rspec spec/ffi"
          end

          task(:run_matrix_specs) do
            ENV["K_SOUP_COV_MIN_HARD"] = "false"
            ENV["MAX_ROWS"] = "0"
            sh "bundle exec rspec spec/matrix"
          end
        RUBY
        File.write(path, content)
        results = described_class.scan(files: [path])
        expect(results).to be_empty
      end
    end

    it "suppresses rescue LoadError + # :nocov: pairs in any file" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "Rakefile")
        content = <<~RUBY
          begin
            require "optional_gem"
          rescue LoadError
            # :nocov:
            task(:optional_task) { warn "unavailable" }
            # :nocov:
          end

          begin
            require "another_gem"
          rescue LoadError
            # :nocov:
            task(:another_task) { warn "unavailable" }
            # :nocov:
          end
        RUBY
        File.write(path, content)
        results = described_class.scan(files: [path])
        expect(results).to be_empty
      end
    end

    it "does not flag fenced blocks with different inner content" do
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

    it "respects custom min_chars" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "short.rb")
        # Both lines must exceed min_chars to form a candidate chunk
        content = "end\nend\nend\nend\n"
        File.write(path, content)
        results = described_class.scan(files: [path], min_chars: 2)
        expect(results).to have_key("end\nend")
      end
    end

    it "handles multiple files independently" do
      Dir.mktmpdir do |dir|
        path1 = File.join(dir, "a.rb")
        path2 = File.join(dir, "b.rb")
        chunk = "require \"foo\"\nrequire \"bar\"\n"
        File.write(path1, chunk + chunk)
        File.write(path2, chunk + chunk)
        results = described_class.scan(files: [path1, path2])
        key = "require \"foo\"\nrequire \"bar\""
        expect(results[key].size).to eq(2)
        files = results[key].map { |e| e[:file] }
        expect(files).to contain_exactly(path1, path2)
      end
    end

    it "handles triple chunk repetition in one file" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "triple.rb")
        content = <<~RUBY
          gem "parser"
          gem "ast"
          something_else_here
          gem "parser"
          gem "ast"
          another_line_here
          gem "parser"
          gem "ast"
        RUBY
        File.write(path, content)
        results = described_class.scan(files: [path])
        entry = results["gem \"parser\"\ngem \"ast\""].first
        expect(entry[:lines]).to eq([1, 4, 7])
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
        # Two consecutive identical pairs to trigger chunk detection
        File.write(written, "gem \"foo\"\ngem \"bar\"\ngem \"foo\"\ngem \"bar\"\n")
        File.write(skipped, "gem \"baz\"\ngem \"qux\"\ngem \"baz\"\ngem \"qux\"\n")

        template_results = {
          written => {action: :replace, timestamp: Time.now},
          skipped => {action: :skip, timestamp: Time.now},
        }

        results = described_class.scan_template_results(template_results: template_results)
        expect(results).to have_key("gem \"foo\"\ngem \"bar\"")
        expect(results).not_to have_key("gem \"baz\"\ngem \"qux\"")
      end
    end
  end

  describe ".warning_count" do
    it "returns total count of duplicate entries" do
      results = {
        "line_a\nline_b" => [{file: "a.rb", lines: [1, 5]}, {file: "b.rb", lines: [2, 3]}],
        "line_c\nline_d" => [{file: "c.rb", lines: [10, 20]}],
      }
      expect(described_class.warning_count(results)).to eq(3)
    end
  end

  describe ".to_json" do
    it "produces valid JSON" do
      results = {
        "gem \"foo\"\ngem \"bar\"" => [{file: "/a.rb", lines: [1, 3]}],
      }
      json = described_class.to_json(results)
      parsed = JSON.parse(json)
      expect(parsed).to have_key("gem \"foo\"\ngem \"bar\"")
      expect(parsed["gem \"foo\"\ngem \"bar\""].first["lines"]).to eq([1, 3])
    end

    it "normalizes /var/home file paths for emitted reports" do
      result = described_class.to_json(
        "dup" => [
          {file: "/var/home/pboling/src/kettle-rb/tree_haver/CHANGELOG.md", lines: [10, 20]},
        ],
      )

      expect(result).to include('"/home/pboling/src/kettle-rb/tree_haver/CHANGELOG.md"')
      expect(result).not_to include('"/var/home/pboling/src/kettle-rb/tree_haver/CHANGELOG.md"')
    end
  end

  describe ".write_json" do
    it "writes JSON to disk" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "report.json")
        results = {"line_a\nline_b" => [{file: "a.rb", lines: [1, 2]}]}
        described_class.write_json(results, path)
        expect(File.exist?(path)).to be(true)
        parsed = JSON.parse(File.read(path))
        expect(parsed).to have_key("line_a\nline_b")
      end
    end
  end

  describe ".report_summary" do
    it "returns clean message when no duplicates" do
      expect(described_class.report_summary({})).to include("No duplicate lines")
    end

    it "returns markdown table when duplicates found" do
      results = {
        "gem \"foo\"\ngem \"bar\"" => [{file: "/project/a.rb", lines: [1, 3]}],
      }
      summary = described_class.report_summary(results, project_root: "/project")
      expect(summary).to include("Duplicate Line Report")
      expect(summary).to include("a.rb")
      expect(summary).to include("1, 3")
      expect(summary).to include("↵")
    end

    it "normalizes /var/home paths before rendering markdown" do
      result = described_class.report_summary(
        {
          "alpha\nbeta" => [
            {file: "/var/home/pboling/src/kettle-rb/tree_haver/CHANGELOG.md", lines: [782, 785]},
          ],
        },
      )

      expect(result).to include("/home/pboling/src/kettle-rb/tree_haver/CHANGELOG.md")
      expect(result).not_to include("/var/home/pboling/src/kettle-rb/tree_haver/CHANGELOG.md")
    end
  end

  describe ".baseline" do
    it "returns a Set of chunk contents duplicated in the template directory" do
      Dir.mktmpdir do |dir|
        # Two consecutive identical pairs trigger chunk detection
        File.write(File.join(dir, "a.yml.example"), "key: value\nother: thing\nkey: value\nother: thing\n")
        File.write(File.join(dir, "b.rb.example"), "unique_line_here\nanother_unique_line\n")

        result = described_class.baseline(template_dir: dir, min_chars: 6)
        expect(result).to be_a(Set)
        expect(result).to include("key: value\nother: thing")
        expect(result).not_to include("unique_line_here\nanother_unique_line")
      end
    end

    it "returns empty set when no template directory exists" do
      result = described_class.baseline(template_dir: "/nonexistent/path")
      expect(result).to eq(Set.new)
    end
  end

  describe ".subtract_baseline" do
    it "removes entries whose chunk content appears in the baseline set" do
      results = {
        "gem \"foo\"\ngem \"bar\"" => [{file: "a.rb", lines: [1, 3]}],
        "gem \"baz\"\ngem \"qux\"" => [{file: "b.rb", lines: [2, 4]}],
        "unique_problem\nline_here_ok" => [{file: "c.rb", lines: [5, 10]}],
      }
      baseline_set = Set.new(["gem \"foo\"\ngem \"bar\"", "gem \"baz\"\ngem \"qux\""])

      filtered = described_class.subtract_baseline(results, baseline_set: baseline_set)
      expect(filtered).to have_key("unique_problem\nline_here_ok")
      expect(filtered).not_to have_key("gem \"foo\"\ngem \"bar\"")
      expect(filtered).not_to have_key("gem \"baz\"\ngem \"qux\"")
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
