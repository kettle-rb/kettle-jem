# frozen_string_literal: true

# These tests isolate issues discovered during kettle-dev → kettle-jem migration
# to determine if the problem is in the kettle-jem/prism-merge layer.
#
# Originally derived from kettle-dev specs:
# - spec/kettle/dev/template_helpers_spec.rb:104 - "inserts source at top"
# - spec/integration/real_world_modular_gemfile_spec.rb:39 - coverage comments

RSpec.describe "SmartMerger gemfile integration" do
  describe "template-only node positioning" do
    # This test mirrors kettle-dev's template_helpers_spec.rb:104
    # "inserts source at top if destination has none, then inserts git_source below it"
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

      config = Kettle::Jem::Presets::Gemfile.template_wins(freeze_token: "kettle-dev")

      merger = Prism::Merge::SmartMerger.new(
        src,
        dest,
        **config.to_h,
      )
      result = merger.merge

      lines = result.lines
      # First non-comment non-blank line should be the source line
      first_code_line_idx = lines.index { |l| l !~ /^\s*#/ && !l.strip.empty? }
      expect(lines[first_code_line_idx]).to match(/\Asource\s+\"https:\/\/gem\.coop\"/),
        "Expected first code line to be source, but got:\n#{lines[first_code_line_idx]}\n\nFull result:\n#{result}"
      # Next non-blank line should be git_source
      remaining = lines[(first_code_line_idx + 1)..]
      git_source_idx = remaining.index { |l| !l.strip.empty? }
      expect(remaining[git_source_idx]).to include("git_source(:codeberg)"),
        "Expected git_source after source, but got:\n#{remaining[git_source_idx]}\n\nFull result:\n#{result}"
    end

    # Additional test: source should come before gemspec even with leading comments
    it "positions source before other code statements regardless of dest order" do
      src = <<~SRC
        source "https://gem.coop"
      SRC

      dest = <<~DEST
        gemspec
        gem "a"
      DEST

      config = Kettle::Jem::Presets::Gemfile.template_wins(freeze_token: "kettle-dev")

      merger = Prism::Merge::SmartMerger.new(
        src,
        dest,
        **config.to_h,
      )
      result = merger.merge

      lines = result.lines.reject { |l| l.strip.empty? }
      # source should come first
      expect(lines.first).to match(/\Asource/),
        "Expected source to be first, but got:\n#{lines.first}\n\nFull result:\n#{result}"
    end
  end

  describe "comment preservation during merge" do
    # This test mirrors kettle-dev's real_world_modular_gemfile_spec.rb:39
    # "deduplicates magic comments but preserves all other content"
    it "preserves all coverage comments from destination" do
      fixture_content = <<~GEMFILE
        # frozen_string_literal: true

        # We run code coverage on the latest version of Ruby only.

        # Coverage
        # See gemspec
        # To retain during kettle-jem templating:
        #     kettle-jem:freeze
        #     # ... your code
        #     kettle-jem:unfreeze

        # We run code coverage on the latest version of Ruby only.

        # Coverage

        # To retain during kettle-jem templating:
        #     kettle-jem:freeze
        #     # ... your code
        #     kettle-jem:unfreeze

        # We run code coverage on the latest version of Ruby only.

        # Coverage

        # To retain during kettle-jem templating:
        #     kettle-jem:freeze
        #     # ... your code
        #     kettle-jem:unfreeze
        # We run code coverage on the latest version of Ruby only.
        # Coverage

      GEMFILE

      template_source_content = <<~'GEMFILE'
        # frozen_string_literal: true

        # We run code coverage on the latest version of Ruby only.

        # Coverage
      GEMFILE

      config = Kettle::Jem::Presets::Gemfile.template_wins(freeze_token: "kettle-dev")

      merger = Prism::Merge::SmartMerger.new(
        template_source_content,
        fixture_content,
        **config.to_h,
      )
      result = merger.merge

      # Should have exactly 1 frozen_string_literal (magic comments are deduplicated)
      frozen_count = result.scan("# frozen_string_literal: true").count
      expect(frozen_count).to eq(1), "Expected 1 frozen_string_literal, got #{frozen_count}\nResult:\n#{result}"

      # With preference: :template, Phase 2 (dest-only nodes) is skipped.
      # The template has 1 coverage comment, which matches the first dest occurrence.
      # The other 3 dest occurrences are dest-only (no matching template node),
      # so they are NOT preserved when preference is :template.
      # This is the expected "template wins" behavior - template content takes precedence.
      coverage_count = result.scan("# We run code coverage").count
      expect(coverage_count).to eq(1), "Expected 1 coverage comment (template wins skips dest-only), got #{coverage_count}\nResult:\n#{result}"
    end

    it "is idempotent on second merge" do
      fixture_content = <<~GEMFILE
        # frozen_string_literal: true

        # We run code coverage on the latest version of Ruby only.

        # Coverage
        # See gemspec

        # We run code coverage on the latest version of Ruby only.

        # Coverage
      GEMFILE

      template_source_content = <<~'GEMFILE'
        # frozen_string_literal: true

        # We run code coverage on the latest version of Ruby only.

        # Coverage
      GEMFILE

      config = Kettle::Jem::Presets::Gemfile.template_wins(freeze_token: "kettle-dev")

      merger = Prism::Merge::SmartMerger.new(
        template_source_content,
        fixture_content,
        **config.to_h,
      )
      first_result = merger.merge

      # Run again
      merger2 = Prism::Merge::SmartMerger.new(
        template_source_content,
        first_result,
        **config.to_h,
      )
      second_result = merger2.merge

      expect(second_result).to eq(first_result), "Second run should produce identical output"
    end

    it "keeps a single blank line between the magic comment and the first leading comment" do
      template_source_content = <<~'GEMFILE'
        # frozen_string_literal: true

        # kettle-jem:freeze
        # To retain chunks of comments & code during nomono templating:
        # Wrap custom sections with freeze markers (e.g., as above and below this comment chunk).
        # nomono will then preserve content between those markers across template runs.
        # kettle-jem:unfreeze

        source "https://gem.coop"

        git_source(:codeberg) { |repo_name| "https://codeberg.org/#{repo_name}" }
        git_source(:gitlab) { |repo_name| "https://gitlab.com/#{repo_name}" }

        #### IMPORTANT #######################################################
        # Gemfile is for local development ONLY; Gemfile is NOT loaded in CI #
        ####################################################### IMPORTANT ####

        # Include dependencies from nomono.gemspec
        gemspec

        # Templating (env-switched: KETTLE_RB_DEV=true for local paths)
        eval_gemfile "gemfiles/modular/templating.gemfile"

        # Debugging
        eval_gemfile "gemfiles/modular/debug.gemfile"

        # Code Coverage (env-switched: KETTLE_RB_DEV=true for local paths)
        eval_gemfile "gemfiles/modular/coverage.gemfile"

        # Linting
        eval_gemfile "gemfiles/modular/style.gemfile"

        # Documentation
        eval_gemfile "gemfiles/modular/documentation.gemfile"

        # Optional
        eval_gemfile "gemfiles/modular/optional.gemfile"

        ### Std Lib Extracted Gems
        eval_gemfile "gemfiles/modular/x_std_libs.gemfile"

        # See unlocked_deps appraisal for more details on irb inclusion
        gem "irb", "~> 1.17" # ruby >= 2.7
      GEMFILE

      destination_content = <<~'GEMFILE'
        # frozen_string_literal: true

        # See unlocked_deps appraisal for more details on irb inclusion
        gem "irb", "~> 1.17" # ruby >= 2.7
        # kettle-jem:freeze
        # To retain chunks of comments & code during nomono templating:
        # Wrap custom sections with freeze markers (e.g., as above and below this comment chunk).
        # nomono will then preserve content between those markers across template runs.
        # kettle-jem:unfreeze

        source "https://gem.coop"

        git_source(:codeberg) { |repo_name| "https://codeberg.org/#{repo_name}" }
        git_source(:gitlab) { |repo_name| "https://gitlab.com/#{repo_name}" }

        #### IMPORTANT #######################################################
        # Gemfile is for local development ONLY; Gemfile is NOT loaded in CI #
        ####################################################### IMPORTANT ####

        # Include dependencies from nomono.gemspec
        gemspec

        # Templating (env-switched: KETTLE_RB_DEV=true for local paths)
        eval_gemfile "gemfiles/modular/templating.gemfile"

        # Debugging
        eval_gemfile "gemfiles/modular/debug.gemfile"

        # Code Coverage (env-switched: KETTLE_RB_DEV=true for local paths)
        eval_gemfile "gemfiles/modular/coverage.gemfile"

        # Linting
        eval_gemfile "gemfiles/modular/style.gemfile"

        # Documentation
        eval_gemfile "gemfiles/modular/documentation.gemfile"

        # Optional
        eval_gemfile "gemfiles/modular/optional.gemfile"

        ### Std Lib Extracted Gems
        eval_gemfile "gemfiles/modular/x_std_libs.gemfile"
      GEMFILE

      result = Kettle::Jem::SourceMerger.apply(
        strategy: :merge,
        src: template_source_content,
        dest: destination_content,
        path: "/home/pboling/src/kettle-rb/nomono/Gemfile",
        file_type: :gemfile,
      )

      expect(result).to start_with(
        <<~GEMFILE
          # frozen_string_literal: true

          # See unlocked_deps appraisal for more details on irb inclusion
        GEMFILE
      )
      expect(result).not_to include("# frozen_string_literal: true\n\n\n")
    end
  end

  describe "direct SmartMerger usage (bypassing PrismGemfile)" do
    # Test with minimal SmartMerger config to isolate the issue
    it "adds template-only source before dest-only gemspec with add_template_only_nodes" do
      src = <<~SRC
        source "https://gem.coop"
      SRC

      dest = <<~DEST
        gemspec
      DEST

      # Simple signature generator
      signature_generator = ->(node) do
        return unless node.is_a?(Prism::CallNode)
        return [:source] if node.name == :source
        return [:gemspec] if node.name == :gemspec
        nil
      end

      merger = Prism::Merge::SmartMerger.new(
        src,
        dest,
        preference: :template,
        add_template_only_nodes: true,
        signature_generator: signature_generator,
      )
      result = merger.merge

      lines = result.lines.reject(&:empty?)
      expect(lines.first.strip).to eq('source "https://gem.coop"'),
        "Expected source first, got: #{lines.first}\n\nFull result:\n#{result}"
    end
  end
end
