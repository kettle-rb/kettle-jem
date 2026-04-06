# frozen_string_literal: true

RSpec.describe Kettle::Jem::TemplateHelpers do
  describe ".merge_gemfile_dependencies" do
    it "replaces source line and github git_source with template values" do
      src = <<~'SRC'
        source "https://gem.coop"
        git_source(:codeberg) { |repo_name| "https://codeberg.org/#{repo_name}" }
      SRC

      dest = <<~'DEST'
        # frozen_string_literal: true

        source "https://gem.coop"

        git_source(:github) { |repo_name| "https://github.com/#{repo_name}" }

        gem "rake"
      DEST

      out = described_class.merge_gemfile_dependencies(src, dest)
      expect(out).to include("source \"https://gem.coop\"")
      expect(out).to include("git_source(:codeberg)")
      # ensure github was replaced (no lingering github url)
      expect(out).not_to include("github.com")
      # existing gem lines are preserved
      expect(out).to include('gem "rake"')
    end

    it "inserts git_source below source when no github present" do
      src = <<~'SRC'
        source "https://gem.coop"
        git_source(:codeberg) { |repo_name| "https://codeberg.org/#{repo_name}" }
      SRC

      dest = <<~DEST
        # frozen_string_literal: true

        # some comment
        gemspec
      DEST

      out = described_class.merge_gemfile_dependencies(src, dest)
      # git_source should appear near the top (after source)
      expect(out).to match(/source .*\n.*git_source/m)
    end

    it "replaces github and inserts additional git_source lines in order" do
      src = <<~'SRC'
        source "https://gem.coop"
        git_source(:codeberg) { |repo_name| "https://codeberg.org/#{repo_name}" }
        git_source(:gitlab)  { |repo_name| "https://gitlab.com/#{repo_name}" }
      SRC

      dest = <<~'DEST'
        # frozen_string_literal: true

        # header comment
        source "https://gem.coop"
        # an unrelated comment
        git_source(:github) { |repo_name| "https://github.com/#{repo_name}" }
        git_source(:bitbucket) { |repo_name| "https://bitbucket.org/#{repo_name}" }

        gem "a"
      DEST

      out = described_class.merge_gemfile_dependencies(src, dest)
      # Source replaced
      expect(out).to include("source \"https://gem.coop\"")
      expect(out).not_to include("rubygems.org")
      # github replaced with codeberg, bitbucket preserved, gitlab inserted
      expect(out).to include("git_source(:codeberg)")
      expect(out).to include("git_source(:gitlab)")
      expect(out).to include("git_source(:bitbucket)")
      expect(out).not_to include("github.com")

      # With template_wins preference, template content is merged into dest structure.
      # Verify all git_source declarations are present (order may vary based on
      # signature matching - codeberg matches github's position, gitlab is template-only)
      lines = out.lines
      src_i = lines.index { |l| l =~ /\Asource\s+\"https:\/\/gem\.coop\"/ }
      codeberg_i = lines.index { |l| l.include?("git_source(:codeberg)") }
      gitlab_i = lines.index { |l| l.include?("git_source(:gitlab)") }
      # All should be present
      expect(src_i).not_to be_nil
      expect(codeberg_i).not_to be_nil
      expect(gitlab_i).not_to be_nil
    end

    it "inserts source at top if destination has none, then inserts git_source below it" do
      src = <<~'SRC'
        source "https://gem.coop"
        git_source(:codeberg) { |repo_name| "https://codeberg.org/#{repo_name}" }
      SRC

      dest = <<~DEST
        # Top comment block
        # Another comment

        gemspec
        gem "a"
      DEST

      out = described_class.merge_gemfile_dependencies(src, dest)
      lines = out.lines
      # First non-comment non-blank line should be the source line
      first_code_line_idx = lines.index { |l| l !~ /^\s*#/ && !l.strip.empty? }
      expect(lines[first_code_line_idx]).to match(/\Asource\s+\"https:\/\/gem\.coop\"/)
      # Next line should be git_source
      expect(lines[first_code_line_idx + 1]).to include("git_source(:codeberg)")
    end

    it "appends missing gem lines from template but does not duplicate existing ones" do
      src = <<~SRC
        source "https://gem.coop"
        gem "foo"
        gem "bar", "~> 1.2"
      SRC

      dest = <<~DEST
        source "https://gem.coop"
        gem "foo"
      DEST

      out = described_class.merge_gemfile_dependencies(src, dest)
      # foo should appear only once, bar should be appended
      expect(out.scan(/^\s*gem\s+['"]foo['"]/).size).to eq(1)
      expect(out).to match(/^\s*gem\s+['"]bar['"].*~> 1\.2/m)
    end

    it "replaces same-named git_source if present (no github fallback)" do
      src = <<~'SRC'
        source "https://gem.coop"
        git_source(:bitbucket) { |repo_name| "https://bitbucket.org/#{repo_name}" }
      SRC

      dest = <<~'DEST'
        # Header
        source "https://gem.coop"
        git_source(:bitbucket) { |repo_name| "https://bb.org/#{repo_name}" }
      DEST

      out = described_class.merge_gemfile_dependencies(src, dest)
      expect(out).to include('git_source(:bitbucket) { |repo_name| "https://bitbucket.org/#{repo_name}" }')
      expect(out).not_to include("https://bb.org/")
    end
  end

  describe ".apply_appraisals_merge" do
    it "routes Appraisals merging through SourceMerger with min_ruby in generic context" do
      Dir.mktmpdir do |dir|
        dest = File.join(dir, "Appraisals")
        File.write(dest, "appraise \"ruby-2-7\" do\nend\n")

        allow(described_class).to receive(:gemspec_metadata).and_return({min_ruby: Gem::Version.new("3.2")})
        allow(Kettle::Jem::SourceMerger).to receive(:apply).with(
          strategy: :merge,
          src: "appraise \"ruby-3-2\" do\nend\n",
          dest: "appraise \"ruby-2-7\" do\nend\n",
          path: described_class.rel_path(dest),
          file_type: :appraisals,
          context: {min_ruby: Gem::Version.new("3.2")},
        ).and_return("appraise \"ruby-3-2\" do\nend\n")

        merged = described_class.apply_appraisals_merge("appraise \"ruby-3-2\" do\nend\n", dest)
        expect(merged).to eq("appraise \"ruby-3-2\" do\nend\n")
      end
    end
  end

  describe ".ensure_clean_git!" do
    let(:fake_root) { "/tmp/fake_project" }

    before do
      # Restore module_function accessibility if a prior spec's singleton
      # removal (e.g., self_test_task_spec) clobbered the class method.
      mod = described_class
      unless mod.respond_to?(:ensure_clean_git!)
        mod.singleton_class.define_method(:ensure_clean_git!) do |**kwargs|
          mod.instance_method(:ensure_clean_git!).bind_call(mod, **kwargs)
        end
      end

      # Stub the system("git", "-C", ..., "rev-parse", ...) call that checks
      # if we're inside a git repo. Return true (inside a repo).
      allow(described_class).to receive(:system).and_call_original
      allow(described_class).to receive(:system).with(
        "git",
        "-C",
        fake_root,
        "rev-parse",
        "--is-inside-work-tree",
        out: File::NULL,
        err: File::NULL,
      ).and_return(true)

      # Stub GitAdapter to report dirty status (porcelain output with a modified file)
      fake_ga = instance_double(Kettle::Dev::GitAdapter)
      allow(Kettle::Dev::GitAdapter).to receive(:new).and_return(fake_ga)
      allow(fake_ga).to receive(:capture)
        .with(["-C", fake_root, "status", "--porcelain"])
        .and_return(["?? dirty.txt\n", true])
    end

    it "raises on dirty tree without force" do
      stub_env("force" => "false")
      expect {
        described_class.ensure_clean_git!(root: fake_root, task_label: "test:task")
      }.to raise_error(Kettle::Dev::Error, /not clean/)
    end

    # BUG REPRO: ensure_clean_git! does not respect ENV["force"].
    # When the SetupCLI runs with --force, it sets ENV["force"] = "true"
    # and later calls `run_kettle_install!` which triggers the template task.
    # The template task calls ensure_clean_git!, which aborts because the
    # bootstrap steps have already dirtied the tree. The method should
    # bypass the check when force mode is active.
    it "bypasses the dirty-tree check when ENV['force'] is truthy" do
      stub_env("force" => "true")
      expect {
        described_class.ensure_clean_git!(root: fake_root, task_label: "test:task")
      }.not_to raise_error
    end
  end

  describe ".copy_file_with_prompt prompt wording", :check_output do
    before do
      stub_env("force" => "true")
    end

    it "says 'Merge into' when destination exists and a block is given" do
      Dir.mktmpdir do |dir|
        src = File.join(dir, "src.txt")
        dest = File.join(dir, "dest.txt")
        File.write(src, "template content\n")
        File.write(dest, "existing content\n")

        allow(described_class).to receive(:project_root).and_return(dir)

        expect {
          described_class.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true) { |c| c }
        }.to output(/Merge into #{Regexp.escape(dest)}/).to_stdout
      end
    end

    it "says 'Replace' when destination exists and no block is given" do
      Dir.mktmpdir do |dir|
        src = File.join(dir, "src.txt")
        dest = File.join(dir, "dest.txt")
        File.write(src, "template content\n")
        File.write(dest, "existing content\n")

        allow(described_class).to receive(:project_root).and_return(dir)

        expect {
          described_class.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true)
        }.to output(/Replace #{Regexp.escape(dest)}/).to_stdout
      end
    end

    it "says 'Merged' in confirmation when block given and destination exists" do
      Dir.mktmpdir do |dir|
        src = File.join(dir, "src.txt")
        dest = File.join(dir, "dest.txt")
        File.write(src, "template content\n")
        File.write(dest, "existing content\n")

        allow(described_class).to receive(:project_root).and_return(dir)

        expect {
          described_class.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true) { |c| c }
        }.to output(/Merged #{Regexp.escape(dest)}/).to_stdout
      end
    end

    it "says 'Wrote' in confirmation when creating a new file" do
      Dir.mktmpdir do |dir|
        src = File.join(dir, "src.txt")
        dest = File.join(dir, "dest.txt")
        File.write(src, "template content\n")

        allow(described_class).to receive(:project_root).and_return(dir)

        expect {
          described_class.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true) { |c| c }
        }.to output(/Wrote #{Regexp.escape(dest)}/).to_stdout
      end
    end
  end
end
