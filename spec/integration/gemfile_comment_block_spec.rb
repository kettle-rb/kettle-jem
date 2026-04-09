# frozen_string_literal: true

# Repro specs for two Gemfile regression bugs:
#   Bug 1: IMPORTANT comment block removed even though it matches template
#   Bug 2: Raw unresolved {KJ|GEM_NAME} token written to Gemfile output
#
# These must fail (red) before the fix, and pass (green) after.

RSpec.describe "Gemfile comment block and token resolution" do
  # Shared content fragments used by multiple examples below.
  let(:important_block) do
    <<~COMMENT
      #### IMPORTANT #######################################################
      # Gemfile is for local development ONLY; Gemfile is NOT loaded in CI #
      ####################################################### IMPORTANT ####
    COMMENT
  end

  let(:gemfile_header) do
    <<~HEADER
      # frozen_string_literal: true

      source "https://gem.coop"

      git_source(:codeberg) { |repo_name| "https://codeberg.org/\#{repo_name}" }
      git_source(:gitlab) { |repo_name| "https://gitlab.com/\#{repo_name}" }

    HEADER
  end

  # Helper: call PrismGemfile.merge with the same options that SourceMerger.apply_merge
  # uses for :gemfile file type (freeze_token: "kettle-jem", preference: :template,
  # add_template_only_nodes: true).  This mirrors the real production merge path so
  # the repro tests exercise the same code the kettle-jem CLI does.
  def production_merge(template, destination)
    config = Kettle::Jem::Presets::Gemfile.template_wins(freeze_token: "kettle-jem")
    gemfile_options = config.to_h.dup
    gemfile_options.delete(:signature_generator)
    Kettle::Jem::PrismGemfile.merge(
      template,
      destination,
      merger_options: gemfile_options,
      filter_template: false,
      path: "Gemfile",
    )
  end

  describe "Bug 1: IMPORTANT comment block preserved during merge (production merge path)" do
    # When template and destination both contain the IMPORTANT comment block,
    # the merged output MUST retain that block verbatim.  A template-wins merge
    # should carry the template's leading comments through to the output.
    it "retains IMPORTANT block when template and dest are identical" do
      content = gemfile_header + important_block + <<~REST
        # Include dependencies from my-gem.gemspec
        gemspec
      REST

      result = production_merge(content, content)

      expect(result).to include("#### IMPORTANT"),
        "IMPORTANT comment block must survive an identity merge"
      expect(result).to include("Gemfile is for local development ONLY"),
        "Body of IMPORTANT comment must be preserved"
    end

    it "retains IMPORTANT block when only the gemspec include comment differs between template and dest" do
      # template has {KJ|GEM_NAME} (simulating an unresolved token reaching prism-merge)
      template = gemfile_header + important_block + <<~REST
        # Include dependencies from {KJ|GEM_NAME}.gemspec
        gemspec
      REST

      # destination has the real gem name
      destination = gemfile_header + important_block + <<~REST
        # Include dependencies from my-gem.gemspec
        gemspec
      REST

      result = production_merge(template, destination)

      expect(result).to include("#### IMPORTANT"),
        "IMPORTANT comment block must not be dropped when comments differ only in gem name"
      expect(result).to include("Gemfile is for local development ONLY"),
        "Body of IMPORTANT comment must survive when comments partially differ"
    end
  end

  describe "Bug 2: unresolved token contract (production merge path)" do
    # When both sides agree the merged output should be clean.
    it "does not write raw {KJ|GEM_NAME} token when template and dest agree on resolved gem name" do
      content = gemfile_header + important_block + <<~REST
        # Include dependencies from my-gem.gemspec
        gemspec
      REST

      result = production_merge(content, content)

      expect(result).not_to include("{KJ|GEM_NAME}"),
        "Resolved token must not appear in merge output"
    end

    # This test documents WHY token resolution must happen BEFORE calling
    # PrismGemfile.merge.  With template-wins preference the template comment
    # wins — so if the template content still carries {KJ|GEM_NAME}, it leaks
    # into the output.  The fix is upstream: TemplateTask.run must ensure that
    # @@token_replacements is configured (non-nil) before any read_template call.
    it "propagates raw {KJ|GEM_NAME} token when template is not resolved (documents the need for upstream fix)" do
      template_unresolved = gemfile_header + important_block + <<~REST
        # Include dependencies from {KJ|GEM_NAME}.gemspec
        gemspec
      REST

      destination_resolved = gemfile_header + important_block + <<~REST
        # Include dependencies from my-gem.gemspec
        gemspec
      REST

      result = production_merge(template_unresolved, destination_resolved)

      # Template preference means the raw token wins — this is the failure mode
      # that the upstream fix (return early when prerequisites != :ready) prevents.
      expect(result).to include("{KJ|GEM_NAME}"),
        "Without upstream token resolution, template preference leaks raw token — " \
          "this is the failure mode the TemplateTask.run guard must prevent"
    end
  end

  describe "TemplateHelpers token resolution: tokens must remain configured after sync_existing_kettle_config!" do
    # seeded_kettle_config_content always calls clear_tokens! in its ensure block.
    # TemplateTask.run calls configure_tokens! again after sync_existing_kettle_config!
    # to restore token state.  If that second call silently fails, read_template
    # returns raw unresolved content for every subsequent file (including Gemfile).

    it "keeps @@token_replacements configured after seeded_kettle_config_content clears them" do
      helpers = Kettle::Jem::TemplateHelpers

      helpers.clear_tokens!
      expect(helpers.tokens_configured?).to be(false)

      # Simulate first successful configure_tokens! call (as PrepareTask / TemplateTask does)
      helpers.configure_tokens!(
        org: "my-org",
        gem_name: "my-gem",
        namespace: "MyGem",
        namespace_shield: "MY_GEM",
        gem_shield: "my_gem",
        funding_org: "my-org",
        min_ruby: "3.1",
      )
      expect(helpers.tokens_configured?).to be(true)

      # Simulate what seeded_kettle_config_content does in its ensure block
      helpers.clear_tokens!
      expect(helpers.tokens_configured?).to be(false),
        "Tokens should be cleared after seeded_kettle_config_content ensure"

      # Simulate the second configure_tokens! call that TemplateTask.run makes at line 1007
      helpers.configure_tokens!(
        org: "my-org",
        gem_name: "my-gem",
        namespace: "MyGem",
        namespace_shield: "MY_GEM",
        gem_shield: "my_gem",
        funding_org: "my-org",
        min_ruby: "3.1",
      )
      expect(helpers.tokens_configured?).to be(true),
        "Tokens must be re-configured after sync_existing_kettle_config! restores them"

      # Verify that read_template resolves {KJ|GEM_NAME} correctly
      raw = "# Include dependencies from {KJ|GEM_NAME}.gemspec"
      resolved = helpers.resolve_tokens(raw)
      expect(resolved).to include("my-gem"),
        "Token {KJ|GEM_NAME} must resolve to gem name when tokens are configured"
      expect(resolved).not_to include("{KJ|GEM_NAME}"),
        "Raw token must not appear in resolved output"
    ensure
      helpers.clear_tokens!
    end

    it "raises when tokens are NOT configured and content contains {KJ|...} patterns" do
      helpers = Kettle::Jem::TemplateHelpers
      helpers.clear_tokens!

      raw = "# Include dependencies from {KJ|GEM_NAME}.gemspec"

      # resolve_tokens now raises when tokens are nil and content has {KJ|...} patterns.
      # This prevents unresolved tokens from ever leaking to output.
      expect {
        helpers.resolve_tokens(raw)
      }.to raise_error(Kettle::Dev::Error, /resolve_tokens called with unconfigured tokens/)
    ensure
      helpers.clear_tokens!
    end
  end
end
