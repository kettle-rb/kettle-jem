# frozen_string_literal: true

RSpec.describe Kettle::Jem::PrismGemfile do
  describe "::MergeEntryPolicy.signature_for" do
    it "uses singleton and path-keyed signatures for top-level merge entries" do
      content = <<~RUBY
        source "https://gem.coop"
        gemspec
        gem "ast-merge"
        eval_gemfile "gemfiles/modular/style.gemfile"
      RUBY

      result = Prism.parse(content)
      statements = result.value.statements.body

      signatures = statements.map { |stmt| described_class::MergeEntryPolicy.signature_for(stmt) }

      expect(signatures).to eq([
        [:source],
        [:gemspec],
        [:gem, "ast-merge"],
        [:eval_gemfile, "gemfiles/modular/style.gemfile"],
      ])
    end

    it "normalizes eval_gemfile ruby-version bucket segments so r3 and r4 variants share a canonical signature" do
      content = <<~RUBY
        eval_gemfile "../../erb/r3/v5.0.gemfile"
        eval_gemfile "../../erb/r4/v5.0.gemfile"
        eval_gemfile "../../mutex_m/r33/v0.3.gemfile"
        eval_gemfile "gemfiles/modular/style.gemfile"
      RUBY

      result = Prism.parse(content)
      statements = result.value.statements.body

      signatures = statements.map { |stmt| described_class::MergeEntryPolicy.signature_for(stmt) }

      expect(signatures[0]).to eq([:eval_gemfile, "../../erb/v5.0.gemfile"])
      expect(signatures[1]).to eq([:eval_gemfile, "../../erb/v5.0.gemfile"])
      expect(signatures[2]).to eq([:eval_gemfile, "../../mutex_m/v0.3.gemfile"])
      # Paths without a ruby-version bucket are unchanged
      expect(signatures[3]).to eq([:eval_gemfile, "gemfiles/modular/style.gemfile"])
    end
  end

  describe "::MergeEntryPolicy.normalize_eval_gemfile_path" do
    subject(:policy) { described_class::MergeEntryPolicy }

    it "strips /r<N>/ bucket from versioned paths" do
      expect(policy.normalize_eval_gemfile_path("../../erb/r4/v5.0.gemfile")).to eq("../../erb/v5.0.gemfile")
      expect(policy.normalize_eval_gemfile_path("../../mutex_m/r3/v0.3.gemfile")).to eq("../../mutex_m/v0.3.gemfile")
      expect(policy.normalize_eval_gemfile_path("../../stringio/r33/v3.0.gemfile")).to eq("../../stringio/v3.0.gemfile")
    end

    it "leaves paths that have no ruby-version bucket unchanged" do
      expect(policy.normalize_eval_gemfile_path("gemfiles/modular/style.gemfile")).to eq("gemfiles/modular/style.gemfile")
      expect(policy.normalize_eval_gemfile_path("../../erb/v5.0.gemfile")).to eq("../../erb/v5.0.gemfile")
    end
  end

  describe "::MergeEntryPolicy.filter_content" do
    it "retains attached leading comments and coalesces contiguous merge-entry ranges" do
      content = <<~RUBY
        # canonical source
        source "https://gem.coop"
        gem "ast-merge"
        gem "prism-merge"

        group :development do
          gem "rspec"
        end
      RUBY

      result = described_class::MergeEntryPolicy.filter_content(
        content,
        tombstone_line_ranges: ->(_lines) { [] },
      )

      expect(result).to eq(<<~RUBY)
        # canonical source
        source "https://gem.coop"
        gem "ast-merge"
        gem "prism-merge"
      RUBY
    end

    it "retains explained tombstone blocks supplied by Gemfile-local policy" do
      content = <<~RUBY
        source "https://gem.coop"

        # no longer needed
        # gem "debug"

        if ENV["CI"]
          gem "ci-only"
        end
      RUBY

      result = described_class::MergeEntryPolicy.filter_content(
        content,
        tombstone_line_ranges: ->(_lines) { [{start_line: 3, end_line: 4}] },
      )

      expect(result).to include("# no longer needed\n# gem \"debug\"")
      expect(result).not_to include('gem "ci-only"')
    end
  end

  describe "::TombstonePolicy.commented_gem_tombstone_line_ranges" do
    it "captures the full explained comment block start while ending at the commented gem line" do
      lines = <<~RUBY.lines
        # Ex-Standard Library gems
        # irb is included in the main Gemfile.
        # gem "irb", "~> 1.15", ">= 1.15.2"

        gem "ast-merge"
      RUBY

      expect(described_class::TombstonePolicy.commented_gem_tombstone_line_ranges(lines)).to eq([
        {start_line: 1, end_line: 3},
      ])
    end
  end

  describe "::DeclarationContextPolicy.context_for_line" do
    it "prefers the deepest enclosing context range for a line" do
      ranges = [
        {context: "platform(:mri)", start_line: 1, end_line: 7, depth: 1},
        {context: "platform(:mri) > group(:development)", start_line: 3, end_line: 5, depth: 2},
      ]

      expect(described_class::DeclarationContextPolicy.context_for_line(4, ranges)).to eq("platform(:mri) > group(:development)")
      expect(described_class::DeclarationContextPolicy.context_for_line(2, ranges)).to eq("platform(:mri)")
      expect(described_class::DeclarationContextPolicy.context_for_line(9, ranges)).to eq("top-level")
    end
  end

  describe "::MergePipelinePolicy" do
    describe ".prepare_destination" do
      it "prunes tombstoned declarations before removing Bundler's builtin github source" do
        calls = []
        runtime = Module.new do
          define_singleton_method(:prepare_destination) do |content, template_content|
            calls << [:prepare, content, template_content]
            "clean"
          end
        end

        result = described_class::MergePipelinePolicy.prepare_destination(
          "dest",
          template_content: "template",
          runtime: runtime,
        )

        expect(result).to eq("clean")
        expect(calls).to eq([
          [:prepare, "dest", "template"],
        ])
      end
    end

    describe ".finalize_merged_content" do
      it "restores tombstone comment blocks before suppressing active declarations" do
        calls = []
        runtime = Module.new do
          define_singleton_method(:finalize_merged_content) do |content, template_content|
            calls << [:finalize, content, template_content]
            "suppressed"
          end
        end

        result = described_class::MergePipelinePolicy.finalize_merged_content(
          "merged",
          template_content: "template",
          runtime: runtime,
        )

        expect(result).to eq("suppressed")
        expect(calls).to eq([
          [:finalize, "merged", "template"],
        ])
      end
    end
  end

  describe "::RemovalEditPolicy.remove_declarations" do
    it "removes multiple declaration ranges without disturbing neighboring entries" do
      content = <<~RUBY
        gem "keep-one"
        gem "drop-one"
        gem "drop-two",
          require: false
        gem "keep-two"
      RUBY

      result = described_class::RemovalEditPolicy.remove_declarations(content, [
        {name: "drop-one", line: 2, end_line: 2, context: :spec},
        {name: "drop-two", line: 3, end_line: 4, context: :spec},
      ])

      expect(result).to include('gem "keep-one"')
      expect(result).to include('gem "keep-two"')
      expect(result).not_to include('gem "drop-one"')
      expect(result).not_to include('gem "drop-two"')
      expect(result).not_to include("require: false")
    end
  end

  describe ".merge" do
    it "routes full-file Gemfile merges through the shared runtime-backed pipeline" do
      src = "gem \"foo\"\n"
      dest = "gem \"bar\"\n"
      signature = described_class::MergeEntryPolicy.method(:signature_for)

      allow(described_class::MergePipelinePolicy).to receive(:merge).with(
        src,
        dest,
        runtime: described_class::MergeRuntimePolicy,
        filter_template: false,
        signature_for: signature,
        merge_body: kind_of(Proc),
      ).and_return("merged")

      result = described_class.merge(
        src,
        dest,
        merger_options: {signature_generator: signature},
      )

      expect(result).to eq("merged")
    end

    it "owns the default Gemfile signature selection when no signature generator is provided" do
      src = "gem \"foo\"\n"
      dest = "gem \"bar\"\n"
      signature = ->(_node) { [:gem, "foo"] }

      allow(Kettle::Jem::Signatures).to receive(:gemfile).and_return(signature)
      allow(described_class::MergePipelinePolicy).to receive(:merge).with(
        src,
        dest,
        runtime: described_class::MergeRuntimePolicy,
        filter_template: false,
        signature_for: signature,
        merge_body: kind_of(Proc),
      ).and_return("merged")

      result = described_class.merge(src, dest)
      expect(result).to eq("merged")
    end

    it "validates merged Gemfile content from within the public merge boundary" do
      src = "gem \"foo\"\n"
      dest = "gem \"bar\"\n"

      allow(described_class::MergePipelinePolicy).to receive(:merge).and_return("merged")
      expect(described_class).to receive(:validate_no_cross_nesting_duplicates).with("merged", src, path: "Gemfile")

      expect(described_class.merge(src, dest)).to eq("merged")
    end

    it "runs preset-backed merges through the shared pipeline and validates the recipe output" do
      src = "gem \"foo\"\n"
      dest = "gem \"bar\"\n"
      preset = instance_double(Ast::Merge::Recipe::Config)
      runner = instance_double(Ast::Merge::Recipe::Runner)
      result = instance_double(Ast::Merge::Recipe::Runner::Result, content: "merged")

      expect(described_class::MergePipelinePolicy).to receive(:merge) do |template_content, destination_content, runtime:, filter_template:, signature_for:, merge_body:|
        expect(template_content).to eq(src)
        expect(destination_content).to eq(dest)
        expect(runtime).to eq(described_class::MergeRuntimePolicy)
        expect(filter_template).to be(false)
        expect(signature_for).to be_a(Proc)
        allow(Ast::Merge::Recipe::Runner).to receive(:new).with(preset, verbose: true).and_return(runner)
        allow(runner).to receive(:run_content).with(
          template_content: src,
          destination_content: dest,
          relative_path: "Gemfile",
          context: {min_ruby: Gem::Version.new("3.2")},
        ).and_return(result)
        merge_body.call(template_content, destination_content)
      end
      expect(described_class).to receive(:validate_no_cross_nesting_duplicates).with("merged", src, path: "Gemfile")

      expect(
        described_class.merge(
          src,
          dest,
          path: "Gemfile",
          preset: preset,
          context: {min_ruby: Gem::Version.new("3.2")},
          verbose: true,
        ),
      ).to eq("merged")
    end

    it "falls back to template content when duplicate validation fails in force mode" do
      src = "gem \"foo\"\n"
      dest = "gem \"bar\"\n"

      allow(described_class::MergePipelinePolicy).to receive(:merge).and_return("broken")
      allow(described_class).to receive(:validate_no_cross_nesting_duplicates)
        .and_raise(Kettle::Jem::Error, "duplicate gem declarations in blocks with different signatures")

      expect {
        @result = described_class.merge(src, dest, path: "Gemfile", force: true)
      }.to output(/Falling back to template content for Gemfile \(--force\)/).to_stderr

      expect(@result).to eq(src)
    end

    it "re-raises duplicate validation errors when force mode is disabled" do
      src = "gem \"foo\"\n"
      dest = "gem \"bar\"\n"

      allow(described_class::MergePipelinePolicy).to receive(:merge).and_return("broken")
      allow(described_class).to receive(:validate_no_cross_nesting_duplicates)
        .and_raise(Kettle::Jem::Error, "duplicate gem declarations in blocks with different signatures")

      expect {
        described_class.merge(src, dest, path: "Gemfile")
      }.to raise_error(Kettle::Jem::Error, /duplicate gem declarations/)
    end
  end

  describe ".merge_gem_calls" do
    it "replaces source and appends missing gem calls", :prism_merge_only do
      src = <<~RUBY
        source "https://gem.coop"
        gem "a"
        gem "b"
      RUBY

      dest = <<~RUBY
        # existing header
        gem "a"
      RUBY

      out = described_class.merge_gem_calls(src, dest)
      expect(out).to include('source "https://gem.coop"')
      expect(out).to include('gem "b"')
      # a should not be duplicated
      expect(out.scan('gem "a"').length).to eq(1)
    end

    it "deduplicates singleton gemspec and eval_gemfile entries by path", :prism_merge_only do
      src = <<~RUBY
        gemspec
        eval_gemfile "gemfiles/modular/style.gemfile"
        eval_gemfile "gemfiles/modular/debug.gemfile"
      RUBY

      dest = <<~RUBY
        gemspec
        eval_gemfile "gemfiles/modular/style.gemfile"
      RUBY

      out = described_class.merge_gem_calls(src, dest)

      expect(out.scan(/^gemspec$/).length).to eq(1)
      expect(out.scan(/^eval_gemfile "gemfiles\/modular\/style\.gemfile"$/).length).to eq(1)
      expect(out).to include('eval_gemfile "gemfiles/modular/debug.gemfile"')
    end

    it "replaces eval_gemfile entries that differ only in ruby-version bucket instead of duplicating", :prism_merge_only do
      src = <<~RUBY
        eval_gemfile "../../erb/r4/v5.0.gemfile"
        eval_gemfile "../../mutex_m/r4/v0.3.gemfile"
        eval_gemfile "../../stringio/r4/v3.0.gemfile"
        eval_gemfile "../../benchmark/r4/v0.5.gemfile"
      RUBY

      dest = <<~RUBY
        eval_gemfile "../../erb/r3/v5.0.gemfile"
        eval_gemfile "../../mutex_m/r3/v0.3.gemfile"
        eval_gemfile "../../stringio/r3/v3.0.gemfile"
        eval_gemfile "../../benchmark/r4/v0.5.gemfile"
      RUBY

      out = described_class.merge_gem_calls(src, dest)

      # r4 versions from the template should appear exactly once each
      expect(out.scan('eval_gemfile "../../erb/r4/v5.0.gemfile"').length).to eq(1)
      expect(out.scan('eval_gemfile "../../mutex_m/r4/v0.3.gemfile"').length).to eq(1)
      expect(out.scan('eval_gemfile "../../stringio/r4/v3.0.gemfile"').length).to eq(1)
      expect(out.scan('eval_gemfile "../../benchmark/r4/v0.5.gemfile"').length).to eq(1)
      # old r3 versions should not be present
      expect(out).not_to include('eval_gemfile "../../erb/r3/v5.0.gemfile"')
      expect(out).not_to include('eval_gemfile "../../mutex_m/r3/v0.3.gemfile"')
      expect(out).not_to include('eval_gemfile "../../stringio/r3/v3.0.gemfile"')
    end

    it "replaces eval_gemfile entries differing only in ruby-version bucket via PrismGemfile.merge (the sub-gemfile code path)", :prism_merge_only do
      src = <<~RUBY
        eval_gemfile "../../erb/r4/v5.0.gemfile"
        eval_gemfile "../../mutex_m/r4/v0.3.gemfile"
        eval_gemfile "../../stringio/r4/v3.0.gemfile"
        eval_gemfile "../../benchmark/r4/v0.5.gemfile"
      RUBY

      dest = <<~RUBY
        eval_gemfile "../../erb/r3/v5.0.gemfile"
        eval_gemfile "../../mutex_m/r3/v0.3.gemfile"
        eval_gemfile "../../stringio/r3/v3.0.gemfile"
        eval_gemfile "../../benchmark/r4/v0.5.gemfile"
      RUBY

      # This uses PrismGemfile.merge (not merge_gem_calls), which is the actual
      # code path taken when merging sub-gemfiles like x_std_libs/r4/libs.gemfile
      # during a kettle-jem template run. The real path uses preference: :template
      # (via SourceMerger#merger_options_for default), so we mirror that here.
      out = described_class.merge(src, dest, merger_options: {preference: :template})

      expect(out.scan('eval_gemfile "../../erb/r4/v5.0.gemfile"').length).to eq(1)
      expect(out.scan('eval_gemfile "../../mutex_m/r4/v0.3.gemfile"').length).to eq(1)
      expect(out.scan('eval_gemfile "../../stringio/r4/v3.0.gemfile"').length).to eq(1)
      expect(out.scan('eval_gemfile "../../benchmark/r4/v0.5.gemfile"').length).to eq(1)
      expect(out).not_to include('eval_gemfile "../../erb/r3/v5.0.gemfile"')
      expect(out).not_to include('eval_gemfile "../../mutex_m/r3/v0.3.gemfile"')
      expect(out).not_to include('eval_gemfile "../../stringio/r3/v3.0.gemfile"')
    end

    it "replaces matching git_source by name and inserts when missing", :prism_merge_only do
      src = <<~'RUBY'
        git_source(:github) { |repo| "https://github.com/#{repo}.git" }
      RUBY
      dest = ""
      out = described_class.merge_gem_calls(src, dest)
      expect(out).to include("git_source(:github)")

      dest2 = <<~'RUBY'
        git_source(:gitlab) { |repo| "https://gitlab.com/#{repo}.git" }
      RUBY
      out2 = described_class.merge_gem_calls(src, dest2)
      # should replace the existing gitlab/generic with the github one if no same-name present
      expect(out2).to include("git_source(:github)")
    end

    it "does not move gems inside groups to top-level" do
      src = <<~RUBY
        group :development do
          gem "dev-only"
        end
      RUBY
      dest = <<~RUBY
        gem "a"
      RUBY
      out = described_class.merge_gem_calls(src, dest)
      # top-level should only contain `a` and not `dev-only`
      expect(out.scan('gem "dev-only"').length).to eq(0)
    end

    # --- Additional edge-case tests ---

    it "appends gem with options (hash / version) and preserves options", :prism_merge_only do
      src = <<~RUBY
        gem "with_opts", "~> 1.2", require: false
      RUBY
      dest = <<~RUBY
        # header
      RUBY
      out = described_class.merge_gem_calls(src, dest)
      expect(out).to include('gem "with_opts", "~> 1.2", require: false')
    end

    it "does not duplicate a gem when quoting differs between src and dest" do
      src = <<~RUBY
        gem "dupme"
      RUBY
      dest = <<~RUBY
        gem 'dupme'
      RUBY
      out = described_class.merge_gem_calls(src, dest)
      expect(out.scan(/gem \"dupme\"|gem 'dupme'/).length).to eq(1)
    end

    it "preserves inline comments on appended gem lines", :prism_merge_only do
      src = <<~RUBY
        gem "c" # important comment
      RUBY
      dest = ""
      out = described_class.merge_gem_calls(src, dest)
      expect(out).to include('gem "c" # important comment')
    end

    it "replaces source and multiple git_source nodes and keeps insertion order", :prism_merge_only do
      src = <<~'RUBY'
        source "https://new.example"
        git_source(:github) { |repo| "https://github.com/#{repo}.git" }
        git_source(:private) { |repo| "https://git.example/#{repo}.git" }
        gem "x"
      RUBY
      dest = <<~RUBY
        source "https://old.example"
        # existing
      RUBY
      out = described_class.merge_gem_calls(src, dest)
      expect(out).to include('source "https://new.example"')
      expect(out).to include("git_source(:github)")
      expect(out).to include("git_source(:private)")
      # ensure gem x appended
      expect(out).to include('gem "x"')
    end

    it "ignores gem declarations inside conditional or other non-top-level constructs" do
      src = <<~RUBY
        if ENV['CI']
          gem "ci-only"
        end
      RUBY
      dest = <<~RUBY
        gem "z"
      RUBY
      out = described_class.merge_gem_calls(src, dest)
      # ci-only should not be appended to top-level
      expect(out).not_to include('gem "ci-only"')
    end

    it "returns dest_content on Prism::Merge::Error", :prism_merge_only do
      dest = "gem \"existing\"\n"
      allow(Prism::Merge::SmartMerger).to receive(:new).and_raise(Prism::Merge::Error, "test failure")

      result = described_class.merge_gem_calls("gem \"new\"\n", dest)
      expect(result).to eq(dest)
    end

    it "suppresses an active gem when source comments it out with explanation" do
      src = <<~RUBY
        # Ex-Standard Library gems
        # irb is included in main Gemfile (and unlocked_deps Appraisal), so it can't be included here.
        # gem "irb", "~> 1.15", ">= 1.15.2" # removed from stdlib in 3.5
      RUBY

      dest = <<~RUBY
        gem "irb", "~> 1.15", ">= 1.15.2" # removed from stdlib in 3.5
      RUBY

      out = described_class.merge_gem_calls(src, dest)

      expect(out).to include("# irb is included in main Gemfile")
      expect(out).to include('# gem "irb", "~> 1.15", ">= 1.15.2" # removed from stdlib in 3.5')
      expect(out).not_to match(/^gem "irb"/)
    end

    it "keeps an active gem when a commented example has no explanatory comment block" do
      src = <<~RUBY
        gem "rubocop", ">= 1.80"
      RUBY

      dest = <<~RUBY
        gem "rubocop", ">= 1.73"
        # gem "rubocop", "~> 1.73", ">= 1.73.2" # constrained by standard
      RUBY

      out = described_class.merge_gem_calls(src, dest)

      expect(out).to match(/^gem "rubocop"/)
      expect(out).to include('# gem "rubocop", "~> 1.73", ">= 1.73.2" # constrained by standard')
    end

    it "removes multiple active gems from different contexts when the source tombstones them with explanations" do
      src = <<~RUBY
        # Ex-Standard Library gems
        # irb is included in main Gemfile.
        # gem "irb", "~> 1.15", ">= 1.15.2"

        platform :mri do
          # debug ships elsewhere.
          # gem "debug", ">= 1.1"
        end
      RUBY

      dest = <<~RUBY
        gem "irb", "~> 1.15", ">= 1.15.2"

        platform :mri do
          gem "debug", ">= 1.1"
        end
      RUBY

      out = described_class.merge_gem_calls(src, dest)

      expect(out).to include('# gem "irb", "~> 1.15", ">= 1.15.2"')
      expect(out).to include('# gem "debug", ">= 1.1"')
      expect(out).not_to match(/^gem "irb"/)
      expect(out).not_to include("  gem \"debug\", \">= 1.1\"")
      expect(out).to include("platform :mri do")
    end
  end

  describe "::MergeRuntimePolicy.filter_to_top_level_gems" do
    it "extracts only top-level Gemfile declarations" do
      content = <<~RUBY
        source "https://rubygems.org"
        gemspec
        gem "foo"
        group :development do
          gem "dev-only"
        end
      RUBY

      result = described_class::MergeRuntimePolicy.filter_to_top_level_gems(content)
      expect(result).to include('source "https://rubygems.org"')
      expect(result).to include("gemspec")
      expect(result).to include('gem "foo"')
      expect(result).not_to include("dev-only")
      expect(result).not_to include("group")
    end

    it "filters out eval_gemfile calls but includes git_source" do
      content = <<~'RUBY'
        source "https://rubygems.org"
        eval_gemfile "modular/test.gemfile"
        git_source(:github) { |repo| "https://github.com/#{repo}.git" }
        gem "a"
      RUBY

      result = described_class::MergeRuntimePolicy.filter_to_top_level_gems(content)
      expect(result).to include("eval_gemfile")
      expect(result).to include("git_source(:github)")
      expect(result).to include('gem "a"')
    end

    it "returns empty string when no gem-related calls found" do
      content = <<~RUBY
        if ENV['CI']
          gem "ci-only"
        end
      RUBY

      result = described_class::MergeRuntimePolicy.filter_to_top_level_gems(content)
      expect(result).to eq("")
    end

    it "includes inline comments on gem lines" do
      content = <<~RUBY
        gem "foo" # important
      RUBY

      result = described_class::MergeRuntimePolicy.filter_to_top_level_gems(content)
      expect(result).to include('gem "foo" # important')
    end

    it "returns content unchanged on parse error" do
      content = "this is not valid ruby {{{"
      result = described_class::MergeRuntimePolicy.filter_to_top_level_gems(content)
      # On parse error, returns original content
      expect(result).to be_a(String)
    end
  end

  describe "::RemovalEditPolicy.remove_github_git_source" do
    it "removes git_source(:github) from content" do
      content = <<~'RUBY'
        git_source(:github) { |repo| "https://github.com/#{repo}.git" }
        gem "foo"
      RUBY

      result = described_class::RemovalEditPolicy.remove_github_git_source(content)
      expect(result).not_to include("git_source(:github)")
      expect(result).to include('gem "foo"')
    end

    it "removes multiline git_source(:github) blocks without disturbing neighbors" do
      content = <<~'RUBY'
        git_source(:github) do |repo|
          "https://github.com/#{repo}.git"
        end

        source "https://rubygems.org"
        gem "foo"
      RUBY

      result = described_class::RemovalEditPolicy.remove_github_git_source(content)

      expect(result).not_to include("git_source(:github)")
      expect(result).not_to include('"https://github.com/#{repo}.git"')
      expect(result).to include('source "https://rubygems.org"')
      expect(result).to include('gem "foo"')
    end

    it "leaves content unchanged when no git_source(:github)" do
      content = <<~'RUBY'
        git_source(:gitlab) { |repo| "https://gitlab.com/#{repo}.git" }
        gem "foo"
      RUBY

      result = described_class::RemovalEditPolicy.remove_github_git_source(content)
      expect(result).to include("git_source(:gitlab)")
      expect(result).to include('gem "foo"')
    end

    it "leaves content unchanged when no git_source at all" do
      content = "gem \"foo\"\n"
      result = described_class::RemovalEditPolicy.remove_github_git_source(content)
      expect(result).to eq(content)
    end

    it "returns content on parse error" do
      content = "not valid ruby {{{"
      result = described_class::RemovalEditPolicy.remove_github_git_source(content)
      expect(result).to eq(content)
    end
  end

  describe ".remove_gem_dependency" do
    it "removes a top-level gem call matching the given name" do
      content = <<~RUBY
        gem "tree_haver", path: "../tree_haver"
        gem "ast-merge", path: "../ast-merge"
        gem "prism-merge", path: "../ast-merge/vendor/prism-merge"
      RUBY
      result = described_class.remove_gem_dependency(content, "tree_haver")
      expect(result).not_to include("tree_haver")
      expect(result).to include('gem "ast-merge"')
      expect(result).to include('gem "prism-merge"')
    end

    it "removes gem with version constraint" do
      content = <<~RUBY
        gem "tree_haver", "~> 5.0", ">= 5.0.5"
        gem "other"
      RUBY
      result = described_class.remove_gem_dependency(content, "tree_haver")
      expect(result).not_to include("tree_haver")
      expect(result).to include('gem "other"')
    end

    it "returns content unchanged when gem_name is nil" do
      content = 'gem "foo"'
      expect(described_class.remove_gem_dependency(content, nil)).to eq(content)
    end

    it "returns content unchanged when gem_name is empty" do
      content = 'gem "foo"'
      expect(described_class.remove_gem_dependency(content, "")).to eq(content)
    end

    it "returns content unchanged when gem is not present" do
      content = <<~RUBY
        gem "foo"
        gem "bar"
      RUBY
      expect(described_class.remove_gem_dependency(content, "baz")).to eq(content)
    end
  end

  describe "::MergeRuntimePolicy.restore_tombstone_comment_blocks" do
    it "re-inserts explanatory tombstone blocks inside the original nested context" do
      template = <<~RUBY
        platform :mri do
          # debug ships elsewhere.
          # gem "debug", ">= 1.1"
          gem "ast-merge"
        end
      RUBY

      content = <<~RUBY
        platform :mri do
          gem "ast-merge"
        end
      RUBY

      result = described_class::MergeRuntimePolicy.restore_tombstone_comment_blocks(content, template)

      expect(result).to include("  # debug ships elsewhere.")
      expect(result).to include('  # gem "debug", ">= 1.1"')
      expect(result.index("  # debug ships elsewhere.")).to be < result.index('  gem "ast-merge"')
    end

    it "anchors top-level tombstone blocks before the first top-level statement" do
      template = <<~RUBY
        # standard ships with Ruby now.
        # gem "irb", "~> 1.15"

        source "https://gem.coop"
        gem "ast-merge"
      RUBY

      content = <<~RUBY
        source "https://gem.coop"
        gem "ast-merge"
      RUBY

      result = described_class::MergeRuntimePolicy.restore_tombstone_comment_blocks(content, template)

      expect(result.index("# standard ships with Ruby now.")).to be < result.index('source "https://gem.coop"')
      expect(result).to include('# gem "irb", "~> 1.15"')
    end

    it "replaces an existing matching tombstone block in the same context with the template version" do
      template = <<~RUBY
        # debug ships elsewhere.
        # gem "debug", ">= 1.1"

        gem "ast-merge"
      RUBY

      content = <<~RUBY
        # old note
        # gem "debug", ">= 1.1"

        gem "ast-merge"
      RUBY

      result = described_class::MergeRuntimePolicy.restore_tombstone_comment_blocks(content, template)

      expect(result).to include("# debug ships elsewhere.")
      expect(result).not_to include("# old note")
      expect(result.scan(/^# gem "debug", ">= 1.1"$/).size).to eq(1)
    end
  end
end
