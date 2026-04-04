# frozen_string_literal: true

# Unit specs for Kettle::Jem::Tasks::TemplateTask
# Mirrors a subset of behavior covered by the rake integration spec, but
# calls the class API directly for focused unit testing.

require "rake"
require "open3"

RSpec.describe Kettle::Jem::Tasks::TemplateTask do
  # Reset TemplateHelpers global state between every example to prevent
  # test-ordering pollution (class variables persist across tests).
  after do
    helpers = Kettle::Jem::TemplateHelpers
    helpers.send(:class_variable_set, :@@template_results, {})
    helpers.send(:class_variable_set, :@@output_dir, nil)
    helpers.send(:class_variable_set, :@@project_root_override, nil)
    helpers.send(:class_variable_set, :@@template_warnings, [])
    helpers.send(:class_variable_set, :@@manifestation, nil)
    helpers.send(:class_variable_set, :@@kettle_config, nil)
  end

  describe "run/install behaviors" do
    let(:helpers) { Kettle::Jem::TemplateHelpers }

    before do
      stub_env("allowed" => "true") # allow env file changes without abort
      stub_env("FUNDING_ORG" => "false") # bypass funding org requirement in unit tests unless explicitly set
    end

    describe "::task_abort" do
      it "raises Kettle::Dev::Error" do
        expect {
          described_class.task_abort("STOP ME")
        }.to raise_error(Kettle::Dev::Error, /STOP ME/)
      end
    end

    describe "::normalize_markdown_spacing", :markly_merge do
      subject(:normalize) { described_class.normalize_markdown_spacing(input) }

      context "with a standard heading missing blank lines" do
        let(:input) { "Some text\n## Heading\nMore text" }

        it "inserts blank lines around the heading" do
          expect(normalize).to eq("Some text\n\n## Heading\n\nMore text")
        end
      end

      context "with an indented code block containing # lines" do
        let(:input) do
          <<~MD.chomp
            Some text

                # To force retention during kettle-jem templating:
                #     kettle-jem:freeze
                #     # ... your code
                #     kettle-jem:unfreeze

            More text
          MD
        end

        it "does not insert blank lines between indented code block lines" do
          expect(normalize).not_to include("kettle-jem:freeze\n\n")
          expect(normalize).to include("kettle-jem:freeze\n    #     # ... your code")
        end
      end

      context "with a line indented 4+ spaces starting with #" do
        let(:input) { "Text\n\n    # comment line\n    # another line\n\nMore" }

        it "does not treat 4-space-indented # lines as headings" do
          expect(normalize).to include("    # comment line\n    # another line")
        end
      end

      context "when inside a fenced code block" do
        let(:input) { "Text\n\n```\n# not a heading\n```\n\nMore" }

        it "does not modify lines inside fenced code blocks" do
          expect(normalize).to include("```\n# not a heading\n```")
        end
      end

      context "with consecutive headings separated by blank lines" do
        let(:input) { "## First\n\n## Second" }

        it "preserves the single blank line between headings" do
          expect(normalize).to eq("## First\n\n## Second")
        end
      end

      context "with well-formatted content" do
        let(:input) do
          <<~MD.chomp
            # Title

            Some text.

            ## Section One

            Content here.

            ### Subsection

            More content.
          MD
        end

        it "is identity for already well-formatted content" do
          expect(normalize).to eq(input)
        end
      end

      context "with a heading followed immediately by a subheading" do
        let(:input) { "## Parent\n### Child\nContent" }

        it "inserts blank lines between them" do
          expect(normalize).to include("## Parent\n\n### Child\n\nContent")
        end
      end

      context "when AST parsing would fail" do
        it "returns the input unchanged" do
          # Empty strings are valid markdown, so test the rescue path
          # by verifying graceful behavior
          expect(described_class.normalize_markdown_spacing("")).to eq("")
        end
      end
    end

    describe "file type detection helpers" do
      describe "::yaml_file?" do
        it("detects .yml") { expect(described_class.send(:yaml_file?, "config.yml")).to be true }
        it("detects .yaml") { expect(described_class.send(:yaml_file?, "config.yaml")).to be true }
        it("detects CITATION.cff") { expect(described_class.send(:yaml_file?, "CITATION.cff")).to be true }
        it("rejects .rb") { expect(described_class.send(:yaml_file?, "lib/foo.rb")).to be false }
      end

      describe "::bash_file?" do
        it("detects .sh") { expect(described_class.send(:bash_file?, "script.sh")).to be true }
        it("detects .envrc") { expect(described_class.send(:bash_file?, ".envrc")).to be true }
        it("rejects .rb") { expect(described_class.send(:bash_file?, "lib/foo.rb")).to be false }
      end

      describe "::accept_template_path?" do
        it("detects bin/setup") { expect(described_class.send(:accept_template_path?, "bin/setup")).to be true }
        it("rejects arbitrary files") { expect(described_class.send(:accept_template_path?, "bin/other")).to be false }
      end

      describe "::tool_versions_file?" do
        it("detects .tool-versions") { expect(described_class.send(:tool_versions_file?, ".tool-versions")).to be true }
        it("rejects .ruby-version") { expect(described_class.send(:tool_versions_file?, ".ruby-version")).to be false }
        it("rejects .yml") { expect(described_class.send(:tool_versions_file?, "config.yml")).to be false }
      end
    end

    describe ".tool-versions merging" do
      it "matches lines by tool name and template version wins" do
        template = "ruby 4.0.0\nnodejs 20.0.0\n"
        dest = "ruby 3.2.0\nnodejs 18.0.0\npython 3.11\n"

        merged = Ast::Merge::Text::SmartMerger.new(
          template,
          dest,
          preference: :template,
          add_template_only_nodes: true,
          signature_generator: described_class::TOOL_VERSIONS_SIGNATURE_GENERATOR,
        ).merge

        # Template versions should win for shared tools
        expect(merged).to include("ruby 4.0.0")
        expect(merged).not_to include("ruby 3.2.0")
        expect(merged).to include("nodejs 20.0.0")
        expect(merged).not_to include("nodejs 18.0.0")
        # Destination-only tool is preserved
        expect(merged).to include("python 3.11")
      end

      it "adds template-only tools to destination" do
        template = "ruby 4.0.0\ngolang 1.21\n"
        dest = "ruby 3.2.0\n"

        merged = Ast::Merge::Text::SmartMerger.new(
          template,
          dest,
          preference: :template,
          add_template_only_nodes: true,
          signature_generator: described_class::TOOL_VERSIONS_SIGNATURE_GENERATOR,
        ).merge

        expect(merged).to include("ruby 4.0.0")
        expect(merged).to include("golang 1.21")
      end
    end

    describe ".kettle-jem.yml token backfill merging" do
      it "does not duplicate the destination-only per-file configuration comment block" do
        destination_content = <<~YAML
          # Default merge options
          defaults:
            preference: "template"
            add_template_only_nodes: true
            freeze_token: "kettle-jem"

          # Token replacement values.
          #
          # General rules:
          #   - Empty strings are treated as unset.
          #   - Use the bare identifier/slug/handle expected by the inline comment.
          #   - Do NOT paste full URLs unless the comment explicitly says to.
          #
          # Tip:
          #   The author fields in a newly created destination config are normally seeded
          #   from the gemspec via safe derivation. After that, destination values win.
          tokens:
            forge:
              gh_user: "pboling"        # GitHub username only, no @, no URL. Used for GitHub Sponsors and profile links. ENV: KJ_GH_USER
              gl_user: "pboling"        # GitLab username only, no @, no URL. Used for profile links. ENV: KJ_GL_USER
              cb_user: "pboling"        # Codeberg username only, no @, no URL. Used for profile links. ENV: KJ_CB_USER
              sh_user: "galtzo"         # SourceHut username only, no leading ~, no URL. Used as https://sr.ht/~<value>/. ENV: KJ_SH_USER
            author:
              name: "{KJ|AUTHOR:NAME}"                 # Full display name. Example: Ada Lovelace. ENV: KJ_AUTHOR_NAME. Auto-seeded from gemspec authors.first
              given_names: "{KJ|AUTHOR:GIVEN_NAMES}"   # Given/personal names only. Example: Ada. ENV: KJ_AUTHOR_GIVEN_NAMES. Auto-seeded when AUTHOR:NAME can be split
              family_names: "{KJ|AUTHOR:FAMILY_NAMES}" # Family/surname only. Example: Lovelace. ENV: KJ_AUTHOR_FAMILY_NAMES. Auto-seeded when AUTHOR:NAME can be split
              email: "floss@glatzo.com"                # Primary public email address. Example: floss@galtzo.com. ENV: KJ_AUTHOR_EMAIL. Auto-seeded from gemspec email.first
              domain: "galtzo.com"                     # Bare domain only, no scheme, no email. Example: galtzo.com. ENV: KJ_AUTHOR_DOMAIN. Auto-seeded from AUTHOR:EMAIL
              orcid: "0009-0008-8519-441X"             # ORCID identifier only, not the full URL. Example: 0000-0001-2345-6789. ENV: KJ_AUTHOR_ORCID
            funding:
              patreon: "galtzo"       # Patreon account slug only. Used as https://patreon.com/<value>. ENV: KJ_FUNDING_PATREON
              kofi: "pboling"         # Ko-fi handle/slug only. Used as https://ko-fi.com/<value>. ENV: KJ_FUNDING_KOFI
              paypal: "pboling"       # PayPal.Me slug only. Used as https://www.paypal.com/paypalme/<value>. ENV: KJ_FUNDING_PAYPAL
              buymeacoffee: "pboling" # Buy Me a Coffee slug only. Used as https://www.buymeacoffee.com/<value>. ENV: KJ_FUNDING_BUYMEACOFFEE
              polar: "pboling"        # Polar handle/slug only. Used as https://polar.sh/<value>. ENV: KJ_FUNDING_POLAR
              liberapay: "pboling"    # Liberapay account slug only. Used as https://liberapay.com/<value>/donate. ENV: KJ_FUNDING_LIBERAPAY
              issuehunt: "pboling"    # IssueHunt identifier/handle only, not a URL. ENV: KJ_FUNDING_ISSUEHUNT
            social:
              mastodon: "galtzo"      # Local handle only for the instance assumed by the template link. Current template uses https://ruby.social/@<value>. ENV: KJ_SOCIAL_MASTODON
              bluesky: "galtzo.com"   # Full Bluesky handle. Example: peterboling.dev or alice.bsky.social. Used as https://bsky.app/profile/<value>. ENV: KJ_SOCIAL_BLUESKY
              linktree: "pboling"     # Linktree username only. Used as https://linktr.ee/<value>. ENV: KJ_SOCIAL_LINKTREE
              devto: "galtzo"         # DEV Community username only. Used as https://dev.to/<value>. ENV: KJ_SOCIAL_DEVTO
          # Glob patterns evaluated in order (first match wins)
          patterns:
            - path: "certs/**"
              strategy: raw_copy

          # Per-file configuration (nested directory structure)
          # Only files that need overrides belong here. Everything else defaults to merge.
          files:
            ".git-hooks":
              commit-msg:
                strategy: accept_template
                file_type: ruby
        YAML

        result = described_class.send(
          :merge_missing_backfilled_token_values,
          destination_content,
          {
            "forge" => {"gh_user" => "pboling"},
          },
        )

        expect(result.scan("# Glob patterns evaluated in order (first match wins)").size).to eq(1)
        expect(result.scan("# Per-file configuration (nested directory structure)").size).to eq(1)
        expect(result.scan("# Only files that need overrides belong here. Everything else defaults to merge.").size).to eq(1)
        expect(result.scan("files:").size).to eq(1)
      end
    end

    describe ".kettle-jem.yml bootstrap seeding" do
      it "fills env-backed token values into blank config slots on first write" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            template_root = File.join(gem_root, "template")
            FileUtils.mkdir_p(template_root)

            File.write(File.join(template_root, ".kettle-jem.yml.example"), <<~YAML)
              defaults:
                preference: template
                add_template_only_nodes: true
                freeze_token: kettle-jem

              tokens:
                forge:
                  gh_user: ""
                author:
                  name: "{KJ|AUTHOR:NAME}"
                  email: "{KJ|AUTHOR:EMAIL}"
                  orcid: ""
                funding:
                  kofi: ""
                social:
                  mastodon: ""
              files: {}
            YAML

            stub_env(
              "KJ_GH_USER" => "pboling",
              "KJ_AUTHOR_NAME" => "Peter H. Boling",
              "KJ_AUTHOR_EMAIL" => "floss@glatzo.com",
              "KJ_AUTHOR_ORCID" => "0009-0008-8519-441X",
              "KJ_FUNDING_KOFI" => "pboling",
              "KJ_SOCIAL_MASTODON" => "galtzo",
            )

            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: template_root,
              ask: true,
            )

            result = described_class.send(
              :ensure_kettle_config_bootstrap!,
              helpers: helpers,
              project_root: project_root,
              template_root: template_root,
              token_options: {
                org: "acme",
                gem_name: "demo",
                namespace: "Demo",
                namespace_shield: "Demo",
                gem_shield: "demo",
                funding_org: "acme",
                min_ruby: "3.1",
              },
            )

            expect(result).to eq(:bootstrap_only)

            parsed = YAML.safe_load_file(
              File.join(project_root, ".kettle-jem.yml"),
              permitted_classes: [],
              aliases: false,
            )

            expect(parsed.dig("tokens", "forge", "gh_user")).to eq("pboling")
            expect(parsed.dig("tokens", "author", "name")).to eq("Peter H. Boling")
            expect(parsed.dig("tokens", "author", "email")).to eq("floss@glatzo.com")
            expect(parsed.dig("tokens", "author", "orcid")).to eq("0009-0008-8519-441X")
            expect(parsed.dig("tokens", "funding", "kofi")).to eq("pboling")
            expect(parsed.dig("tokens", "social", "mastodon")).to eq("galtzo")
          end
        end
      end
    end

    describe ".kettle-jem.yml syncing" do
      it "restores template-only trailing instructional comments" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            template_root = File.join(gem_root, "template")
            FileUtils.mkdir_p(template_root)

            File.write(File.join(template_root, ".kettle-jem.yml.example"), <<~YAML)
              defaults:
                preference: template
                add_template_only_nodes: true
                freeze_token: kettle-jem
              files: {}

              # To override specific files, add entries like:
              #
              # files:
              #   README.md:
              #     strategy: accept_template
            YAML

            File.write(File.join(project_root, ".kettle-jem.yml"), <<~YAML)
              defaults:
                preference: destination
                add_template_only_nodes: true
                freeze_token: kettle-jem
              files: {}
            YAML

            File.write(File.join(project_root, "demo.gemspec"), <<~GEMSPEC)
              Gem::Specification.new do |spec|
                spec.name = "demo"
                spec.version = "0.1.0"
                spec.summary = "test"
                spec.authors = ["Test User"]
                spec.email = ["test@example.com"]
                spec.required_ruby_version = ">= 3.1"
                spec.homepage = "https://github.com/acme/demo"
              end
            GEMSPEC

            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: template_root,
              ask: true,
            )

            described_class.send(
              :sync_existing_kettle_config!,
              helpers: helpers,
              project_root: project_root,
              template_root: template_root,
              token_options: {
                org: "acme",
                gem_name: "demo",
                namespace: "Demo",
                namespace_shield: "Demo",
                gem_shield: "demo",
                funding_org: "acme",
                min_ruby: "3.1",
              },
            )

            synced = File.read(File.join(project_root, ".kettle-jem.yml"))

            expect(synced).to include("defaults:\n  preference: destination")
            expect(synced).to include("# To override specific files, add entries like:")
            expect(synced).to end_with(<<~YAML)

              # To override specific files, add entries like:
              #
              # files:
              #   README.md:
              #     strategy: accept_template
            YAML
          end
        end
      end

      it "does not preserve duplicated destination scaffolding comments" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            template_root = File.join(gem_root, "template")
            FileUtils.mkdir_p(template_root)

            File.write(File.join(template_root, ".kettle-jem.yml.example"), <<~YAML)
              defaults:
                preference: destination
                add_template_only_nodes: true
                freeze_token: kettle-jem
              patterns:
                - path: "certs/**"
                  strategy: raw_copy

              # Per-file configuration (nested directory structure)
              # Only files that need overrides belong here. Everything else defaults to merge.
              files: {}

              # Self-test / templating CI threshold.
              # Set to a number from 0 to 100 to fail `rake kettle:jem:selftest` once
              min_divergence_threshold:
            YAML

            File.write(File.join(project_root, ".kettle-jem.yml"), <<~YAML)
              defaults:
                preference: destination
                add_template_only_nodes: true
                freeze_token: kettle-jem
              patterns:
                - path: "certs/**"
                  strategy: raw_copy
                - path: "certs/**"
                  strategy: raw_copy

              # Per-file configuration (nested directory structure)
              # Only files that need overrides belong here. Everything else defaults to merge.
              # Per-file configuration (nested directory structure)
              # Only files that need overrides belong here. Everything else defaults to merge.
              files: {}

              # Self-test / templating CI threshold.
              # Set to a number from 0 to 100 to fail `rake kettle:jem:selftest` once
              # Self-test / templating CI threshold.
              # Set to a number from 0 to 100 to fail `rake kettle:jem:selftest` once
              min_divergence_threshold:
            YAML

            File.write(File.join(project_root, "demo.gemspec"), <<~GEMSPEC)
              Gem::Specification.new do |spec|
                spec.name = "demo"
                spec.version = "0.1.0"
                spec.summary = "test"
                spec.authors = ["Test User"]
                spec.email = ["test@example.com"]
                spec.required_ruby_version = ">= 3.1"
                spec.homepage = "https://github.com/acme/demo"
              end
            GEMSPEC

            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: template_root,
              ask: true,
            )

            described_class.send(
              :sync_existing_kettle_config!,
              helpers: helpers,
              project_root: project_root,
              template_root: template_root,
              token_options: {
                org: "acme",
                gem_name: "demo",
                namespace: "Demo",
                namespace_shield: "Demo",
                gem_shield: "demo",
                funding_org: "acme",
                min_ruby: "3.1",
              },
            )

            synced = File.read(File.join(project_root, ".kettle-jem.yml"))

            expect(synced.scan('path: "certs/**"').size).to eq(1)
            expect(synced.scan("# Per-file configuration (nested directory structure)").size).to eq(1)
            expect(synced.scan("# Self-test / templating CI threshold.").size).to eq(1)
          end
        end
      end

      it "does not duplicate trailing comments when destination files: has populated entries" do
        # Repro: template has `files: {}` (compact) with a trailing comment; destination
        # has `files: { AGENTS.md: ... }` (multi-line) with the SAME trailing comment.
        # Psych reports the multi-line MappingEntry's end_line as covering the comment
        # lines, which caused the comment to be classified as :orphan (not :postlude) and
        # thus escape deduplication — resulting in the comment being emitted twice.
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            template_root = File.join(gem_root, "template")
            FileUtils.mkdir_p(template_root)

            File.write(File.join(template_root, ".kettle-jem.yml.example"), <<~YAML)
              defaults:
                preference: destination
                add_template_only_nodes: true
                freeze_token: kettle-jem
              files: {}

              # To override specific files:
              #
              # files:
              #   README.md:
              #     strategy: accept_template
            YAML

            File.write(File.join(project_root, ".kettle-jem.yml"), <<~YAML)
              defaults:
                preference: destination
                add_template_only_nodes: true
                freeze_token: kettle-jem
              files:
                AGENTS.md:
                  strategy: accept_template

              # To override specific files:
              #
              # files:
              #   README.md:
              #     strategy: accept_template
            YAML

            File.write(File.join(project_root, "demo.gemspec"), <<~GEMSPEC)
              Gem::Specification.new do |spec|
                spec.name = "demo"
                spec.version = "0.1.0"
                spec.summary = "test"
                spec.authors = ["Test User"]
                spec.email = ["test@example.com"]
                spec.required_ruby_version = ">= 3.1"
                spec.homepage = "https://github.com/acme/demo"
              end
            GEMSPEC

            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: template_root,
              ask: true,
            )

            described_class.send(
              :sync_existing_kettle_config!,
              helpers: helpers,
              project_root: project_root,
              template_root: template_root,
              token_options: {
                org: "acme",
                gem_name: "demo",
                namespace: "Demo",
                namespace_shield: "Demo",
                gem_shield: "demo",
                funding_org: "acme",
                min_ruby: "3.1",
              },
            )

            synced = File.read(File.join(project_root, ".kettle-jem.yml"))

            expect(synced.scan("# To override specific files:").size).to eq(1)
          end
        end
      end
    end

    describe "::run" do
      it "creates tmp via tmp/.gitignore" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            template_root = File.join(gem_root, "template")
            FileUtils.mkdir_p(File.join(template_root, "tmp"))

            File.write(File.join(template_root, ".kettle-jem.yml.example"), <<~YAML)
              defaults:
                preference: template
                add_template_only_nodes: true
                freeze_token: kettle-jem
              tokens:
                forge:
                  gh_user: ""
              patterns: []
              files: {}
            YAML
            File.write(File.join(template_root, "tmp", ".gitignore.example"), <<~GITIGNORE)
              *
              !.gitignore
            GITIGNORE

            File.write(File.join(project_root, ".kettle-jem.yml"), <<~YAML)
              defaults:
                preference: template
                add_template_only_nodes: true
                freeze_token: kettle-jem
              tokens:
                forge:
                  gh_user: ""
              patterns: []
              files: {}
            YAML
            File.write(File.join(project_root, "demo.gemspec"), <<~GEMSPEC)
              Gem::Specification.new do |spec|
                spec.name = "demo"
                spec.version = "0.1.0"
                spec.summary = "test"
                spec.authors = ["Test User"]
                spec.email = ["test@example.com"]
                spec.required_ruby_version = ">= 3.1"
                spec.homepage = "https://github.com/acme/demo"
              end
            GEMSPEC

            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: template_root,
              ensure_clean_git!: nil,
              ask: true,
            )

            expect { described_class.run }.not_to raise_error

            tmp_gitignore_path = File.join(project_root, "tmp", ".gitignore")

            expect(File).to exist(tmp_gitignore_path)
            expect(File.read(tmp_gitignore_path)).to eq("*\n!.gitignore\n")
            expect(File).to be_directory(File.join(project_root, "tmp"))
          end
        end
      end

      it "refreshes bin/setup from the template instead of leaving a stale copy untouched" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            template_root = File.join(gem_root, "template")
            FileUtils.mkdir_p(File.join(template_root, "bin"))

            File.write(File.join(template_root, ".kettle-jem.yml.example"), <<~YAML)
              defaults:
                preference: template
                add_template_only_nodes: true
                freeze_token: kettle-jem
              tokens:
                forge:
                  gh_user: ""
              patterns: []
              files: {}
            YAML
            template_setup = File.read(File.expand_path("../../../../template/bin/setup.example", __dir__))
            File.write(File.join(template_root, "bin", "setup.example"), template_setup)

            File.write(File.join(project_root, ".kettle-jem.yml"), <<~YAML)
              defaults:
                preference: template
                add_template_only_nodes: true
                freeze_token: kettle-jem
              tokens:
                forge:
                  gh_user: ""
              patterns: []
              files: {}
            YAML
            File.write(File.join(project_root, "demo.gemspec"), <<~GEMSPEC)
              Gem::Specification.new do |spec|
                spec.name = "demo"
                spec.version = "0.1.0"
                spec.summary = "test"
                spec.authors = ["Test User"]
                spec.email = ["test@example.com"]
                spec.required_ruby_version = ">= 3.1"
                spec.homepage = "https://github.com/acme/demo"
              end
            GEMSPEC
            FileUtils.mkdir_p(File.join(project_root, "bin"))
            File.write(File.join(project_root, "bin", "setup"), <<~BASH)
              #!/usr/bin/env bash
              set -euo pipefail
              IFS=$'\n\t'
                set -vx

              bundle install
            BASH

            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: template_root,
              ensure_clean_git!: nil,
              ask: true,
            )

            expect { described_class.run }.not_to raise_error
            expect(File.read(File.join(project_root, "bin", "setup"))).to eq(template_setup)
          end
        end
      end

      it "writes a dedicated per-run templating report under tmp/kettle-jem" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            template_root = File.join(gem_root, "template")
            FileUtils.mkdir_p(File.join(template_root, "tmp"))

            File.write(File.join(template_root, ".kettle-jem.yml.example"), <<~YAML)
              defaults:
                preference: template
                add_template_only_nodes: true
                freeze_token: kettle-jem
              tokens:
                forge:
                  gh_user: ""
              patterns: []
              files: {}
            YAML
            File.write(File.join(template_root, "tmp", ".gitignore.example"), <<~GITIGNORE)
              *
              !.gitignore
            GITIGNORE

            File.write(File.join(project_root, ".kettle-jem.yml"), <<~YAML)
              defaults:
                preference: template
                add_template_only_nodes: true
                freeze_token: kettle-jem
              tokens:
                forge:
                  gh_user: ""
              patterns: []
              files: {}
            YAML
            File.write(File.join(project_root, "demo.gemspec"), <<~GEMSPEC)
              Gem::Specification.new do |spec|
                spec.name = "demo"
                spec.version = "0.1.0"
                spec.summary = "test"
                spec.authors = ["Test User"]
                spec.email = ["test@example.com"]
                spec.required_ruby_version = ">= 3.1"
                spec.homepage = "https://github.com/acme/demo"
              end
            GEMSPEC

            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: template_root,
              ensure_clean_git!: nil,
              ask: true,
              template_run_timestamp: Time.utc(2026, 3, 16, 12, 34, 56),
            )
            allow(Kettle::Jem::TemplatingReport).to receive(:snapshot).and_return(
              {
                kettle_jem: {
                  name: "kettle-jem",
                  version: "1.0.0",
                  path: gem_root,
                  local_path: true,
                  loaded: true,
                },
                workspace_root: "/workspace",
                merge_gems: [
                  {
                    name: "ast-merge",
                    version: "4.0.6",
                    path: File.join(gem_root, "../ast-merge"),
                    local_path: true,
                    loaded: true,
                  },
                ],
              },
            )

            expect { described_class.run }.not_to raise_error

            report_paths = Dir.glob(File.join(project_root, "tmp", "kettle-jem", "templating-report-*.md"))

            expect(report_paths.size).to eq(1)
            report = File.read(report_paths.first)
            expect(report).to include("# kettle-jem Templating Run Report")
            expect(report).to include("**Status**: `complete`")
            expect(report).to include("## Merge Gem Environment")
            expect(report).to include("| ast-merge | 4.0.6 | local path |")
          end
        end
      end

      it "finalizes the per-run report with failed status when setup aborts early" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            template_root = File.join(gem_root, "template")
            FileUtils.mkdir_p(template_root)

            File.write(File.join(project_root, ".kettle-jem.yml"), <<~YAML)
              defaults:
                preference: template
                add_template_only_nodes: true
                freeze_token: kettle-jem
              tokens:
                forge:
                  gh_user: ""
              patterns: []
              files: {}
            YAML

            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: template_root,
              ask: true,
              template_run_timestamp: Time.utc(2026, 3, 16, 12, 34, 56),
            )
            allow(helpers).to receive(:ensure_clean_git!).and_raise(RuntimeError, "dirty tree")
            allow(Kettle::Jem::TemplatingReport).to receive(:snapshot).and_return(
              {
                kettle_jem: {
                  name: "kettle-jem",
                  version: "1.0.0",
                  path: gem_root,
                  local_path: true,
                  loaded: true,
                },
                workspace_root: "/workspace",
                merge_gems: [],
              },
            )

            expect { described_class.run }.to raise_error(RuntimeError, "dirty tree")

            report_paths = Dir.glob(File.join(project_root, "tmp", "kettle-jem", "templating-report-*.md"))

            expect(report_paths.size).to eq(1)
            report = File.read(report_paths.first)
            expect(report).to include("**Status**: `failed`")
            expect(report).to include("RuntimeError: dirty tree")
          end
        end
      end

      it "renders dynamic template metadata for Rakefile, README, LICENSE, and Gemfile comments" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            template_root = File.join(gem_root, "template")
            FileUtils.mkdir_p(template_root)

            File.write(File.join(template_root, ".kettle-jem.yml.example"), <<~YAML)
              defaults:
                preference: template
                add_template_only_nodes: true
                freeze_token: kettle-jem
              tokens:
                forge:
                  gh_user: ""
              patterns: []
              files: {}
            YAML
            File.write(File.join(template_root, "Rakefile.example"), <<~RUBY)
              # {KJ|GEM_NAME} Rakefile v{KJ|KETTLE_JEM_VERSION} - {KJ|TEMPLATE_RUN_DATE}
              # Copyright (c) {KJ|TEMPLATE_RUN_YEAR} {KJ|AUTHOR:NAME} ({KJ|AUTHOR:DOMAIN})
            RUBY
            File.write(File.join(template_root, "README.md.example"), <<~MARKDOWN)
              Copyright (c) {KJ|TEMPLATE_RUN_YEAR} {KJ|AUTHOR:GIVEN_NAMES} {KJ|AUTHOR:FAMILY_NAMES}, of {KJ|GEM_NAME} contributors.
            MARKDOWN
            File.write(File.join(template_root, "LICENSE.txt.example"), <<~TEXT)
              Copyright (c) {KJ|TEMPLATE_RUN_YEAR} {KJ|AUTHOR:GIVEN_NAMES} {KJ|AUTHOR:FAMILY_NAMES}
            TEXT
            File.write(File.join(template_root, "Gemfile.example"), <<~RUBY)
              # Include dependencies from {KJ|GEM_NAME}.gemspec
              gemspec
            RUBY

            File.write(File.join(project_root, ".kettle-jem.yml"), <<~YAML)
              defaults:
                preference: template
                add_template_only_nodes: true
                freeze_token: kettle-jem
              tokens:
                forge:
                  gh_user: ""
              patterns: []
              files: {}
            YAML

            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: template_root,
              ensure_clean_git!: nil,
              ask: true,
              template_run_timestamp: Time.new(2026, 3, 14, 12, 0, 0, "+00:00"),
              kettle_jem_version: "9.9.9",
              gemspec_metadata: {
                gem_name: "demo",
                min_ruby: Gem::Version.create("3.1"),
                forge_org: "acme",
                funding_org: nil,
                namespace: "Demo",
                namespace_shield: "Demo",
                gem_shield: "demo",
                authors: ["Test User"],
                email: ["test@example.com"],
                entrypoint_require: "demo",
              },
            )

            expect { described_class.run }.not_to raise_error

            expect(File.read(File.join(project_root, "Rakefile"))).to include("# demo Rakefile v9.9.9 - 2026-03-14")
            expect(File.read(File.join(project_root, "Rakefile"))).to include("# Copyright (c) 2026 Test User (example.com)")
            expect(File.read(File.join(project_root, "README.md"))).to include("Copyright (c) 2026 Test User")
            expect(File.read(File.join(project_root, "LICENSE.txt"))).to include("Copyright (c) 2026 Test User")
            expect(File.read(File.join(project_root, "Gemfile"))).to include("# Include dependencies from demo.gemspec")
            expect(File.read(File.join(project_root, "Gemfile"))).not_to include("<gem name>")
          end
        end
      end

      it "renders the README top logo block using the configured org-only mode" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            template_root = File.join(gem_root, "template")
            FileUtils.mkdir_p(template_root)

            File.write(File.join(template_root, ".kettle-jem.yml.example"), <<~YAML)
              defaults:
                preference: template
                add_template_only_nodes: true
                freeze_token: kettle-jem
              readme:
                top_logo_mode: org_and_project
              tokens:
                forge:
                  gh_user: ""
              patterns: []
              files: {}
            YAML
            File.write(File.join(template_root, "README.md.example"), <<~MARKDOWN)
              {KJ|README:TOP_LOGO_ROW}

              {KJ|README:TOP_LOGO_REFS}

              # {KJ|NAMESPACE}
            MARKDOWN

            File.write(File.join(project_root, ".kettle-jem.yml"), <<~YAML)
              defaults:
                preference: template
                add_template_only_nodes: true
                freeze_token: kettle-jem
              readme:
                top_logo_mode: org
              tokens:
                forge:
                  gh_user: ""
              patterns: []
              files: {}
            YAML

            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: template_root,
              ensure_clean_git!: nil,
              ask: true,
              gemspec_metadata: {
                gem_name: "nomono",
                min_ruby: Gem::Version.create("3.2"),
                forge_org: "kettle-rb",
                funding_org: nil,
                namespace: "Nomono",
                namespace_shield: "Nomono",
                gem_shield: "nomono",
                authors: ["Test User"],
                email: ["test@example.com"],
                entrypoint_require: "nomono",
              },
            )

            expect { described_class.run }.not_to raise_error

            readme = File.read(File.join(project_root, "README.md"))
            expect(readme).to include("[![kettle-rb Logo by Aboling0, CC BY-SA 4.0][🖼️kettle-rb-i]][🖼️kettle-rb]")
            expect(readme).not_to include("[![nomono Logo by Aboling0, CC BY-SA 4.0][🖼️nomono-i]][🖼️nomono]")
            expect(readme).to include("[🖼️kettle-rb-i]: https://logos.galtzo.com/assets/images/kettle-rb/avatar-192px.svg")
            expect(readme).not_to include("[🖼️nomono-i]: https://logos.galtzo.com/assets/images/kettle-rb/nomono/avatar-192px.svg")
          end
        end
      end

      it "re-templates README compatibility badges when min_ruby increases" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            template_root = File.join(gem_root, "template")
            FileUtils.mkdir_p(template_root)

            File.write(File.join(template_root, ".kettle-jem.yml.example"), <<~YAML)
              defaults:
                preference: template
                add_template_only_nodes: true
                freeze_token: kettle-jem
              tokens:
                forge:
                  gh_user: ""
              patterns: []
              files: {}
            YAML

            readme_template = <<~MARKDOWN
              | Works with JRuby        | ![JRuby 9.1 Compat][💎jruby-9.1i] ![JRuby 9.2 Compat][💎jruby-9.2i] ![JRuby 9.3 Compat][💎jruby-9.3i] <br/> [![JRuby 9.4 Compat][💎jruby-9.4i]][🚎10-j-wf] [![JRuby 10.0 Compat][💎jruby-10.0i]][🚎11-c-wf] [![JRuby current Compat][💎jruby-c-i]][🚎12-j-wf] [![JRuby HEAD Compat][💎jruby-headi]][🚎3-hd-wf] |
              | Works with Truffle Ruby | ![Truffle Ruby 22.3 Compat][💎truby-22.3i] ![Truffle Ruby 23.0 Compat][💎truby-23.0i] ![Truffle Ruby 23.1 Compat][💎truby-23.1i] <br/> [![Truffle Ruby 23.2 Compat][💎truby-23.2i]][🚎9-t-wf] [![Truffle Ruby 24.2 Compat][💎truby-24.2i]][🚎9-t-wf] [![Truffle Ruby 25.0 Compat][💎truby-25.0i]][🚎9-t-wf] [![Truffle Ruby current Compat][💎truby-c-i]][🚎11-c-wf] |
              | Works with MRI Ruby 3   | [![Ruby 3.2 Compat][💎ruby-3.2i]][🚎6-s-wf] [![Ruby 3.3 Compat][💎ruby-3.3i]][🚎6-s-wf] [![Ruby current Compat][💎ruby-c-i]][🚎11-c-wf] [![Ruby HEAD Compat][💎ruby-headi]][🚎3-hd-wf] |

              ### Compatibility

              Compatible with MRI Ruby 3.2+, and concordant releases of JRuby, and TruffleRuby.

              [💎jruby-9.1i]: https://example/jruby-91
              [💎jruby-9.2i]: https://example/jruby-92
              [💎jruby-9.3i]: https://example/jruby-93
              [💎jruby-9.4i]: https://example/jruby-94
              [💎jruby-10.0i]: https://example/jruby-100
              [💎jruby-c-i]: https://example/jruby-current
              [💎jruby-headi]: https://example/jruby-head
              [💎truby-22.3i]: https://example/truby-223
              [💎truby-23.0i]: https://example/truby-230
              [💎truby-23.1i]: https://example/truby-231
              [💎truby-23.2i]: https://example/truby-232
              [💎truby-24.2i]: https://example/truby-242
              [💎truby-25.0i]: https://example/truby-250
              [💎truby-c-i]: https://example/truby-current
              [💎ruby-3.2i]: https://example/ruby-32
              [💎ruby-3.3i]: https://example/ruby-33
              [💎ruby-c-i]: https://example/ruby-current
              [💎ruby-headi]: https://example/ruby-head
              [🚎3-hd-wf]: https://example/head
              [🚎6-s-wf]: https://example/supported
              [🚎9-t-wf]: https://example/truffle
              [🚎10-j-wf]: https://example/jruby
              [🚎11-c-wf]: https://example/current
              [🚎12-j-wf]: https://example/jruby-current
            MARKDOWN

            File.write(File.join(template_root, "README.md.example"), readme_template)
            File.write(File.join(project_root, "README.md"), readme_template)

            File.write(File.join(project_root, ".kettle-jem.yml"), <<~YAML)
              defaults:
                preference: template
                add_template_only_nodes: true
                freeze_token: kettle-jem
              tokens:
                forge:
                  gh_user: ""
              patterns: []
              files: {}
            YAML

            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: template_root,
              ensure_clean_git!: nil,
              ask: true,
              gemspec_metadata: {
                gem_name: "demo",
                min_ruby: Gem::Version.create("3.2"),
                forge_org: "acme",
                funding_org: nil,
                namespace: "Demo",
                namespace_shield: "Demo",
                gem_shield: "demo",
                authors: ["Test User"],
                email: ["test@example.com"],
                entrypoint_require: "demo",
              },
            )

            expect { described_class.run }.not_to raise_error

            edited = File.read(File.join(project_root, "README.md"))
            jruby_line = edited.lines.find { |line| line.start_with?("| Works with JRuby") }
            truby_line = edited.lines.find { |line| line.start_with?("| Works with Truffle Ruby") }

            expect(jruby_line).to include("jruby-10.0i")
            expect(jruby_line).to include("jruby-c-i")
            expect(jruby_line).to include("jruby-headi")
            expect(jruby_line).not_to include("jruby-9.4i")
            expect(truby_line).to include("truby-23.2i")
            expect(truby_line).to include("truby-24.2i")
            expect(truby_line).to include("truby-25.0i")
            expect(truby_line).to include("truby-c-i")
            expect(truby_line).not_to include("truby-23.1i")
            expect(edited).not_to match(/^\[💎jruby-9\.4i\]:/)
            expect(edited).to match(/^\[💎jruby-10\.0i\]:/)
            expect(edited).not_to match(/^\[🚎10-j-wf\]:/)
            expect(edited).to match(/^\[🚎12-j-wf\]:/)
            expect(edited).not_to match(/^\[💎truby-23\.1i\]:/)
            expect(edited).to match(/^\[💎truby-23\.2i\]:/)
            expect(edited).to match(/^\[💎truby-24\.2i\]:/)
            expect(edited).to match(/^\[💎truby-25\.0i\]:/)
            expect(edited).to match(/^\[🚎9-t-wf\]:/)
            expect(edited).to match(/^\[🚎11-c-wf\]:/)
          end
        end
      end

      it "synchronizes gemspec summary and description to the merged README H1 grapheme" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            template_root = File.join(gem_root, "template")
            FileUtils.mkdir_p(template_root)

            File.write(File.join(template_root, ".kettle-jem.yml.example"), <<~YAML)
              defaults:
                preference: template
                add_template_only_nodes: true
                freeze_token: kettle-jem
              tokens:
                forge:
                  gh_user: ""
              patterns: []
              files: {}
            YAML

            File.write(File.join(template_root, "README.md.example"), <<~MARKDOWN)
              # 🍕 Template Title

              ## Synopsis
              Template synopsis.
            MARKDOWN

            File.write(File.join(template_root, "gem.gemspec.example"), <<~'GEMSPEC')
              Gem::Specification.new do |spec|
                spec.name = "kettle-jem"
                spec.version = "1.0.0"
                spec.summary = "🍕 Template summary"
                spec.description = "🍕 Template description"
                spec.homepage = "https://github.com/acme/demo"
              end
            GEMSPEC

            File.write(File.join(project_root, "README.md"), <<~MARKDOWN)
              # 🚀 Existing Title

              ## Synopsis
              Existing synopsis.
            MARKDOWN

            File.write(File.join(project_root, "demo.gemspec"), <<~GEMSPEC)
              Gem::Specification.new do |spec|
                spec.name = "demo"
                spec.version = "0.1.0"
                spec.summary = "🍲 Existing summary"
                spec.description = "🍲 Existing description"
                spec.homepage = "https://github.com/acme/demo"
              end
            GEMSPEC

            File.write(File.join(project_root, ".kettle-jem.yml"), <<~YAML)
              defaults:
                preference: template
                add_template_only_nodes: true
                freeze_token: kettle-jem
              tokens:
                forge:
                  gh_user: ""
              patterns: []
              files: {}
            YAML

            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: template_root,
              ensure_clean_git!: nil,
              ask: true,
              gemspec_metadata: {
                gem_name: "demo",
                min_ruby: Gem::Version.create("3.2"),
                forge_org: "acme",
                funding_org: nil,
                namespace: "Demo",
                namespace_shield: "Demo",
                gem_shield: "demo",
                authors: ["Test User"],
                email: ["test@example.com"],
                entrypoint_require: "demo",
                summary: "🍲 Existing summary",
                description: "🍲 Existing description",
              },
            )

            expect { described_class.run }.not_to raise_error

            expect(File.read(File.join(project_root, "README.md")).lines.first).to eq("# 🚀 Existing Title\n")

            gemspec = File.read(File.join(project_root, "demo.gemspec"))
            expect(gemspec).to match(/spec.summary\s*=\s*"🚀 Existing summary"/)
            expect(gemspec).to match(/spec.description\s*=\s*"🚀 Existing description"/)
          end
        end
      end

      it "writes .kettle-jem.yml and exits before templating when the project config is missing" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            template_root = File.join(gem_root, "template")
            FileUtils.mkdir_p(template_root)
            File.write(File.join(template_root, ".kettle-jem.yml.example"), <<~YAML)
              defaults:
                preference: template
                add_template_only_nodes: true
                freeze_token: kettle-jem
              tokens:
                forge:
                  gh_user: ""
              patterns: []
              files: {}
            YAML
            File.write(File.join(template_root, "README.md.example"), "# {KJ|GEM_NAME}\n")
            File.write(File.join(project_root, "demo.gemspec"), <<~GEMSPEC)
              Gem::Specification.new do |spec|
                spec.name = "demo"
                spec.version = "0.1.0"
                spec.summary = "test"
                spec.authors = ["Test User"]
                spec.email = ["test@example.com"]
                spec.required_ruby_version = ">= 3.1"
                spec.homepage = "https://github.com/acme/demo"
              end
            GEMSPEC

            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: template_root,
              ensure_clean_git!: nil,
              ask: true,
              template_run_timestamp: Time.utc(2026, 3, 16, 12, 34, 56),
            )

            expect(described_class.run).to eq(:bootstrap_only)
            expect(File).to exist(File.join(project_root, ".kettle-jem.yml"))
            expect(File).not_to exist(File.join(project_root, "README.md"))
            expect(helpers.template_run_outcome).to eq(:bootstrap_only)

            report_paths = Dir.glob(File.join(project_root, "tmp", "kettle-jem", "templating-report-*.md"))

            expect(report_paths.size).to eq(1)
            expect(File.read(report_paths.first)).to include("**Status**: `bootstrap_only`")
          end
        end
      end

      it "backfills blank token values in an existing .kettle-jem.yml from ENV before templating" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            template_root = File.join(gem_root, "template")
            FileUtils.mkdir_p(template_root)
            File.write(File.join(template_root, ".kettle-jem.yml.example"), <<~YAML)
              defaults:
                preference: template
                add_template_only_nodes: true
                freeze_token: kettle-jem
              tokens:
                forge:
                  gh_user: ""
                funding:
                  kofi: ""
              patterns: []
              files: {}
            YAML
            File.write(File.join(template_root, "README.md.example"), "Donate: https://ko-fi.com/{KJ|FUNDING:KOFI}\n")
            File.write(File.join(project_root, ".kettle-jem.yml"), <<~YAML)
              defaults:
                preference: template
                add_template_only_nodes: true
                freeze_token: kettle-jem
              tokens:
                forge:
                  gh_user: ""
                funding:
                  kofi: "" # comment preserved
              patterns: []
              files: {}
            YAML
            File.write(File.join(project_root, "demo.gemspec"), <<~GEMSPEC)
              Gem::Specification.new do |spec|
                spec.name = "demo"
                spec.version = "0.1.0"
                spec.summary = "test"
                spec.authors = ["Test User"]
                spec.email = ["test@example.com"]
                spec.required_ruby_version = ">= 3.1"
                spec.homepage = "https://github.com/acme/demo"
              end
            GEMSPEC

            stub_env("KJ_FUNDING_KOFI" => "BackfillMe")

            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: template_root,
              ensure_clean_git!: nil,
              ask: true,
            )

            expect { described_class.run }.not_to raise_error
            expect(File.read(File.join(project_root, ".kettle-jem.yml"))).to include('kofi: "BackfillMe" # comment preserved')
            expect(File.read(File.join(project_root, "README.md"))).to include("https://ko-fi.com/BackfillMe")
          end
        end
      end

      it "backfills missing token keys in an existing .kettle-jem.yml from ENV before templating" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            template_root = File.join(gem_root, "template")
            FileUtils.mkdir_p(template_root)
            File.write(File.join(template_root, ".kettle-jem.yml.example"), <<~YAML)
              defaults:
                preference: template
                add_template_only_nodes: true
                freeze_token: kettle-jem
              tokens:
                forge:
                  gh_user: ""
                funding:
                  kofi: ""
              patterns: []
              files: {}
            YAML
            File.write(File.join(template_root, "README.md.example"), "Donate: https://ko-fi.com/{KJ|FUNDING:KOFI}\n")
            File.write(File.join(project_root, ".kettle-jem.yml"), <<~YAML)
              defaults:
                preference: template
                add_template_only_nodes: true
                freeze_token: kettle-jem
              tokens:
                forge:
                  gh_user: ""
              patterns: []
              files: {}
            YAML
            File.write(File.join(project_root, "demo.gemspec"), <<~GEMSPEC)
              Gem::Specification.new do |spec|
                spec.name = "demo"
                spec.version = "0.1.0"
                spec.summary = "test"
                spec.authors = ["Test User"]
                spec.email = ["test@example.com"]
                spec.required_ruby_version = ">= 3.1"
                spec.homepage = "https://github.com/acme/demo"
              end
            GEMSPEC

            stub_env("KJ_FUNDING_KOFI" => "AddedFromEnv")

            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: template_root,
              ensure_clean_git!: nil,
              ask: true,
            )

            expect { described_class.run }.not_to raise_error
            config = File.read(File.join(project_root, ".kettle-jem.yml"))
            expect(config).to include("funding:")
            expect(config).to match(/kofi:\s+(?:"AddedFromEnv"|AddedFromEnv)/)
            expect(File.read(File.join(project_root, "README.md"))).to include("https://ko-fi.com/AddedFromEnv")
          end
        end
      end

      it "still fails when unresolved tokens remain after ENV backfill" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            template_root = File.join(gem_root, "template")
            FileUtils.mkdir_p(template_root)
            File.write(File.join(template_root, ".kettle-jem.yml.example"), <<~YAML)
              defaults:
                preference: template
                add_template_only_nodes: true
                freeze_token: kettle-jem
              tokens:
                forge:
                  gh_user: ""
                funding:
                  kofi: ""
              patterns: []
              files: {}
            YAML
            File.write(File.join(template_root, "README.md.example"), <<~MD)
              Sponsor: {KJ|GH:USER}
              Donate: https://ko-fi.com/{KJ|FUNDING:KOFI}
            MD
            File.write(File.join(project_root, ".kettle-jem.yml"), <<~YAML)
              defaults:
                preference: template
                add_template_only_nodes: true
                freeze_token: kettle-jem
              tokens:
                forge:
                  gh_user: ""
                funding:
                  kofi: ""
              patterns: []
              files: {}
            YAML
            File.write(File.join(project_root, "demo.gemspec"), <<~GEMSPEC)
              Gem::Specification.new do |spec|
                spec.name = "demo"
                spec.version = "0.1.0"
                spec.summary = "test"
                spec.authors = ["Test User"]
                spec.email = ["test@example.com"]
                spec.required_ruby_version = ">= 3.1"
                spec.homepage = "https://github.com/acme/demo"
              end
            GEMSPEC

            stub_env("KJ_FUNDING_KOFI" => "BackfillOnlyThis")

            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: template_root,
              ensure_clean_git!: nil,
              ask: true,
            )

            expect {
              described_class.run
            }.to raise_error(Kettle::Dev::Error, /Unresolved \{KJ\|\.\.\.\} tokens would be written/)
            config = File.read(File.join(project_root, ".kettle-jem.yml"))
            expect(config).to include('kofi: "BackfillOnlyThis"')
            expect(config).to include('gh_user: ""')
            expect(File).not_to exist(File.join(project_root, "README.md"))
          end
        end
      end

      it "only audits unresolved tokens in written outputs when output is redirected" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            Dir.mktmpdir do |output_dir|
              template_root = File.join(gem_root, "template")
              FileUtils.mkdir_p(template_root)
              FileUtils.mkdir_p(File.join(project_root, "template"))

              File.write(File.join(template_root, ".kettle-jem.yml.example"), <<~YAML)
                defaults:
                  preference: template
                  add_template_only_nodes: true
                  freeze_token: kettle-jem
                tokens:
                  forge:
                    gh_user: ""
                patterns: []
                files: {}
              YAML
              File.write(File.join(template_root, "README.md.example"), "# {KJ|GEM_NAME}\n")
              File.write(File.join(project_root, "template", "README.md.example"), "Unresolved source token: {KJ|AUTHOR:NAME}\n")
              File.write(File.join(project_root, ".kettle-jem.yml"), <<~YAML)
                defaults:
                  preference: template
                  add_template_only_nodes: true
                  freeze_token: kettle-jem
                tokens:
                  forge:
                    gh_user: ""
                patterns: []
                files: {}
              YAML
              File.write(File.join(project_root, "demo.gemspec"), <<~GEMSPEC)
                Gem::Specification.new do |spec|
                  spec.name = "demo"
                  spec.version = "0.1.0"
                  spec.summary = "test"
                  spec.authors = ["Test User"]
                  spec.email = ["test@example.com"]
                  spec.required_ruby_version = ">= 3.1"
                  spec.homepage = "https://github.com/acme/demo"
                end
              GEMSPEC

              allow(helpers).to receive_messages(
                project_root: project_root,
                template_root: template_root,
                ensure_clean_git!: nil,
                ask: true,
              )
              helpers.send(:output_dir=, output_dir)

              expect { described_class.run }.not_to raise_error
              expect(File.read(File.join(output_dir, "README.md"))).to include("# demo")
              expect(File.read(File.join(project_root, "template", "README.md.example"))).to include("{KJ|AUTHOR:NAME}")
            end
          end
        end
      end

      it "backfills the project .kettle-jem.yml before templating when output is redirected" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            Dir.mktmpdir do |output_dir|
              template_root = File.join(gem_root, "template")
              FileUtils.mkdir_p(template_root)

              File.write(File.join(template_root, ".kettle-jem.yml.example"), <<~YAML)
                defaults:
                  preference: template
                  add_template_only_nodes: true
                  freeze_token: kettle-jem
                tokens:
                  forge:
                    gh_user: ""
                  funding:
                    kofi: ""
                patterns: []
                files: {}
              YAML
              File.write(File.join(template_root, "README.md.example"), "Donate: https://ko-fi.com/{KJ|FUNDING:KOFI}\n")
              File.write(File.join(project_root, ".kettle-jem.yml"), <<~YAML)
                defaults:
                  preference: template
                  add_template_only_nodes: true
                  freeze_token: kettle-jem
                tokens:
                  forge:
                    gh_user: ""
                  funding:
                    kofi: ""
                patterns: []
                files: {}
              YAML
              File.write(File.join(project_root, "demo.gemspec"), <<~GEMSPEC)
                Gem::Specification.new do |spec|
                  spec.name = "demo"
                  spec.version = "0.1.0"
                  spec.summary = "test"
                  spec.authors = ["Test User"]
                  spec.email = ["test@example.com"]
                  spec.required_ruby_version = ">= 3.1"
                  spec.homepage = "https://github.com/acme/demo"
                end
              GEMSPEC

              stub_env("KJ_FUNDING_KOFI" => "RedirectSafe")

              allow(helpers).to receive_messages(
                project_root: project_root,
                template_root: template_root,
                ensure_clean_git!: nil,
                ask: true,
              )
              helpers.send(:output_dir=, output_dir)

              expect { described_class.run }.not_to raise_error
              expect(File.read(File.join(project_root, ".kettle-jem.yml"))).to include('kofi: "RedirectSafe"')
              expect(File).not_to exist(File.join(project_root, "README.md"))
              expect(File.read(File.join(output_dir, "README.md"))).to include("https://ko-fi.com/RedirectSafe")
            end
          end
        end
      end

      it "fails before templating when an existing config still leaves required tokens unresolved" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            template_root = File.join(gem_root, "template")
            FileUtils.mkdir_p(template_root)
            File.write(File.join(template_root, ".kettle-jem.yml.example"), <<~YAML)
              defaults:
                preference: template
                add_template_only_nodes: true
                freeze_token: kettle-jem
              tokens:
                forge:
                  gh_user: ""
              patterns: []
              files: {}
            YAML
            File.write(File.join(template_root, "README.md.example"), "Sponsor: {KJ|GH:USER}\n")
            File.write(File.join(project_root, ".kettle-jem.yml"), <<~YAML)
              defaults:
                preference: template
                add_template_only_nodes: true
                freeze_token: kettle-jem
              tokens:
                forge:
                  gh_user: ""
              patterns: []
              files: {}
            YAML
            File.write(File.join(project_root, "demo.gemspec"), <<~GEMSPEC)
              Gem::Specification.new do |spec|
                spec.name = "demo"
                spec.version = "0.1.0"
                spec.summary = "test"
                spec.authors = ["Test User"]
                spec.email = ["test@example.com"]
                spec.required_ruby_version = ">= 3.1"
                spec.homepage = "https://github.com/acme/demo"
              end
            GEMSPEC

            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: template_root,
              ensure_clean_git!: nil,
              ask: true,
            )

            expect {
              described_class.run
            }.to raise_error(Kettle::Dev::Error, /Unresolved \{KJ\|\.\.\.\} tokens would be written/)
            expect(File).not_to exist(File.join(project_root, "README.md"))
          end
        end
      end

      it "keeps the existing .kettle-jem.yml comments, blank lines, and inline comment alignment when syncing config" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            template_root = File.join(gem_root, "template")
            FileUtils.mkdir_p(template_root)

            template_config = <<~YAML
              # kettle-jem configuration file
              #
              # Header docs

              # Default merge options
              defaults:
                preference: "template"
                add_template_only_nodes: true
                freeze_token: "kettle-jem"

              # Token replacement values.
              #
              # General rules:
              tokens:
                forge:
                  gh_user: ""        # GitHub username only, no @, no URL. Used for GitHub Sponsors and profile links. ENV: KJ_GH_USER
                  gl_user: ""        # GitLab username only, no @, no URL. Used for profile links. ENV: KJ_GL_USER

                author:
                  name: "{KJ|AUTHOR:NAME}"                 # Full display name. Example: Peter H. Boling. ENV: KJ_AUTHOR_NAME. Auto-seeded from gemspec authors.first
                  given_names: "{KJ|AUTHOR:GIVEN_NAMES}"   # Given/personal names only. Example: Peter H. ENV: KJ_AUTHOR_GIVEN_NAMES. Auto-seeded when AUTHOR:NAME can be split

              # Glob patterns evaluated in order (first match wins)
              patterns:
                - path: "certs/**"
                  strategy: raw_copy

              # Per-file configuration (nested directory structure)
              # Only files that need overrides belong here. Everything else defaults to merge.
              files: {}

              # To override specific files, add entries like:
              #
              # files:
              #   README.md:
              #     strategy: accept_template
            YAML

            existing_config = <<~YAML
              # kettle-jem configuration file
              #
              # Header docs

              # Default merge options
              defaults:
                preference: "template"
                add_template_only_nodes: true
                freeze_token: "kettle-jem"

              # Token replacement values.
              #
              # General rules:
              tokens:
                forge:
                  gh_user: ""        # GitHub username only, no @, no URL. Used for GitHub Sponsors and profile links. ENV: KJ_GH_USER
                  gl_user: ""        # GitLab username only, no @, no URL. Used for profile links. ENV: KJ_GL_USER

                author:
                  name: "Jane Doe"                       # Full display name. Example: Peter H. Boling. ENV: KJ_AUTHOR_NAME. Auto-seeded from gemspec authors.first
                  given_names: "Jane"                    # Given/personal names only. Example: Peter H. ENV: KJ_AUTHOR_GIVEN_NAMES. Auto-seeded when AUTHOR:NAME can be split

              # Glob patterns evaluated in order (first match wins)
              patterns:
                - path: "certs/**"
                  strategy: raw_copy

              # Per-file configuration (nested directory structure)
              # Only files that need overrides belong here. Everything else defaults to merge.
              files: {}

              # To override specific files, add entries like:
              #
              # files:
              #   README.md:
              #     strategy: accept_template
            YAML

            File.write(File.join(template_root, ".kettle-jem.yml.example"), template_config)
            dest_config = File.join(project_root, ".kettle-jem.yml")
            File.write(dest_config, existing_config)
            File.write(File.join(project_root, "demo.gemspec"), <<~GEMSPEC)
              Gem::Specification.new do |spec|
                spec.name = "demo"
                spec.version = "0.1.0"
                spec.summary = "test"
                spec.authors = ["Jane Doe"]
                spec.email = ["jane@example.com"]
                spec.required_ruby_version = ">= 3.1"
                spec.homepage = "https://github.com/acme/demo"
              end
            GEMSPEC

            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: template_root,
              ensure_clean_git!: nil,
              ask: true,
            )

            expect { described_class.run }.not_to raise_error
            expect(File.read(dest_config)).to eq(existing_config)
          end
        end
      end

      it "does not duplicate the destination-only per-file configuration comment block during full config sync" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            template_root = File.join(gem_root, "template")
            FileUtils.mkdir_p(template_root)

            template_config = <<~YAML
              # kettle-jem configuration file
              #
              # Header docs

              # Default merge options
              defaults:
                preference: "template"
                add_template_only_nodes: true
                freeze_token: "kettle-jem"

              # Token replacement values.
              #
              # General rules:
              tokens:
                forge:
                  gh_user: ""
                  gl_user: ""

              # Glob patterns evaluated in order (first match wins)
              patterns:
                - path: "certs/**"
                  strategy: raw_copy

              # Per-file configuration (nested directory structure)
              # Only files that need overrides belong here. Everything else defaults to merge.
              files: {}
            YAML

            existing_config = <<~YAML
              # Default merge options
              defaults:
                preference: "template"
                add_template_only_nodes: true
                freeze_token: "kettle-jem"

              # Token replacement values.
              #
              # General rules:
              #   - Empty strings are treated as unset.
              tokens:
                forge:
                  gh_user: "pboling"

              # Glob patterns evaluated in order (first match wins)
              patterns:
                - path: "certs/**"
                  strategy: raw_copy

              # Per-file configuration (nested directory structure)
              # Only files that need overrides belong here. Everything else defaults to merge.
              files:
                ".git-hooks":
                  commit-msg:
                    strategy: accept_template
                    file_type: ruby
            YAML

            File.write(File.join(template_root, ".kettle-jem.yml.example"), template_config)
            dest_config = File.join(project_root, ".kettle-jem.yml")
            File.write(dest_config, existing_config)
            File.write(File.join(project_root, "demo.gemspec"), <<~GEMSPEC)
              Gem::Specification.new do |spec|
                spec.name = "demo"
                spec.version = "0.1.0"
                spec.summary = "test"
                spec.authors = ["Jane Doe"]
                spec.email = ["jane@example.com"]
                spec.required_ruby_version = ">= 3.1"
                spec.homepage = "https://github.com/acme/demo"
              end
            GEMSPEC

            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: template_root,
              ensure_clean_git!: nil,
              ask: true,
            )

            expect { described_class.run }.not_to raise_error

            result = File.read(dest_config)
            expect(result.scan("# Per-file configuration (nested directory structure)").size).to eq(1)
            expect(result.scan("# Only files that need overrides belong here. Everything else defaults to merge.").size).to eq(1)
            expect(result.scan(/^files:/).size).to eq(1)
            expect(result).to include('gl_user: ""')
            expect(result).to include("commit-msg:")
            expect(result).to include("file_type: ruby")
          end
        end
      end

      it "prefers .example files under .github/workflows and writes without .example and customizes FUNDING.yml" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            # Arrange template source under template_root
            template_root = File.join(gem_root, "template")
            gh_src = File.join(template_root, ".github", "workflows")
            FileUtils.mkdir_p(gh_src)
            File.write(File.join(gh_src, "ci.yml"), "name: REAL\n")
            File.write(File.join(gh_src, "ci.yml.example"), "name: EXAMPLE\n")
            # FUNDING.yml example with token placeholders (matches real template format)
            FileUtils.mkdir_p(File.join(template_root, ".github"))
            File.write(File.join(template_root, ".github", "FUNDING.yml.example"), <<~YAML)
              open_collective: {KJ|OPENCOLLECTIVE_ORG}
              tidelift: rubygems/{KJ|GEM_NAME}
            YAML

            # Provide gemspec in project to satisfy metadata scanner
            File.write(File.join(project_root, "demo.gemspec"), <<~GEMSPEC)
              Gem::Specification.new do |spec|
                spec.name = "demo"
                spec.version = "0.1.0"
                spec.summary = "test"
                spec.authors = ["Test"]
                spec.required_ruby_version = ">= 3.1"
                spec.homepage = "https://github.com/acme/demo"
              end
            GEMSPEC

            # Stub helpers used by the task
            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: template_root,
              ensure_clean_git!: nil,
              ask: true,
            )

            # Override global funding disable for this example to allow customization
            stub_env("FUNDING_ORG" => "")

            # Exercise
            expect { described_class.run }.not_to raise_error

            # Assert
            dest_ci = File.join(project_root, ".github", "workflows", "ci.yml")
            expect(File).to exist(dest_ci)
            expect(File.read(dest_ci)).to include("EXAMPLE")

            # FUNDING content customized
            funding_dest = File.join(project_root, ".github", "FUNDING.yml")
            expect(File).to exist(funding_dest)
            funding = File.read(funding_dest)
            expect(funding).to include("open_collective: acme")
            expect(funding).to include("tidelift: rubygems/demo")
          end
        end
      end

      # BUG REPRO: Step 2 handles .github/**/*.yml files. Step 7 skips ALL
      # .github/ files via handled_prefixes. Non-yml files like
      # .github/COPILOT_INSTRUCTIONS.md.example are never processed by either
      # step, even though a template exists for them.
      it "templates non-yml files under .github/ such as COPILOT_INSTRUCTIONS.md" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            # Source .github/ with a non-yml file (and a yml for step 2)
            FileUtils.mkdir_p(File.join(gem_root, ".github"))
            File.write(File.join(gem_root, ".github", "COPILOT_INSTRUCTIONS.md"), "# Instructions for {KJ|GEM_NAME}\n")
            File.write(File.join(gem_root, ".github", "COPILOT_INSTRUCTIONS.md.example"), "# Instructions for {KJ|GEM_NAME}\n")
            File.write(File.join(gem_root, ".github", "dependabot.yml"), "version: 2\n")

            # Template entries so the template walk discovers .github/ non-yml files
            FileUtils.mkdir_p(File.join(gem_root, "template", ".github"))
            File.write(File.join(gem_root, "template", ".github", "COPILOT_INSTRUCTIONS.md.example"), "# Instructions for {KJ|GEM_NAME}\n")

            File.write(File.join(project_root, "demo.gemspec"), <<~GEMSPEC)
              Gem::Specification.new do |spec|
                spec.name = "demo"
                spec.version = "0.1.0"
                spec.summary = "test"
                spec.authors = ["Test"]
                spec.required_ruby_version = ">= 3.1"
                spec.homepage = "https://github.com/acme/demo"
              end
            GEMSPEC

            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: File.join(gem_root, "template"),
              ensure_clean_git!: nil,
              ask: true,
            )

            expect { described_class.run }.not_to raise_error

            dest_md = File.join(project_root, ".github", "COPILOT_INSTRUCTIONS.md")
            expect(File).to exist(dest_md)
            content = File.read(dest_md)
            expect(content).to include("demo")
            expect(content).not_to include("{KJ|GEM_NAME}")
          end
        end
      end

      it "copies .env.local.example but does not create .env.local" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            template_root = File.join(gem_root, "template")
            FileUtils.mkdir_p(template_root)
            File.write(File.join(template_root, ".env.local.example"), "SECRET=1\n")
            File.write(File.join(project_root, "demo.gemspec"), <<~GEMSPEC)
              Gem::Specification.new do |spec|
                spec.name = "demo"
                spec.version = "0.1.0"
                spec.summary = "test gem"
                spec.authors = ["Test"]
                spec.required_ruby_version = ">= 3.1"
              end
            GEMSPEC

            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: template_root,
              ensure_clean_git!: nil,
              ask: true,
            )

            expect { described_class.run }.not_to raise_error

            expect(File).to exist(File.join(project_root, ".env.local.example"))
            expect(File).not_to exist(File.join(project_root, ".env.local"))
          end
        end
      end

      # BUG REPRO: When template/.env.local.example exists, step 7's template
      # walk strips .example → rel becomes ".env.local", but handled_files
      # contains ".env.local.example" (the un-stripped name). The check never
      # matches, so the walk creates an unwanted .env.local file.
      it "does not create .env.local when template/.env.local.example exists in template walk" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            # Step 6 source: the real .env.local.example at gem root
            File.write(File.join(gem_root, ".env.local.example"), "SECRET=1\n")

            # Step 7 source: .env.local.example in the template directory
            # (this is the file the template walk discovers)
            FileUtils.mkdir_p(File.join(gem_root, "template"))
            File.write(File.join(gem_root, "template", ".env.local.example"), "SECRET=1\n")

            File.write(File.join(project_root, "demo.gemspec"), <<~GEMSPEC)
              Gem::Specification.new do |spec|
                spec.name = "demo"
                spec.version = "0.1.0"
                spec.summary = "test gem"
                spec.authors = ["Test"]
                spec.required_ruby_version = ">= 3.1"
                spec.homepage = "https://github.com/acme/demo"
              end
            GEMSPEC

            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: File.join(gem_root, "template"),
              ensure_clean_git!: nil,
              ask: true,
            )

            expect { described_class.run }.not_to raise_error

            expect(File).to exist(File.join(project_root, ".env.local.example"))
            # .env.local must NOT be created — it's a user-specific file
            expect(File).not_to exist(File.join(project_root, ".env.local"))
          end
        end
      end

      it "replaces {KJ|GEM_NAME} token in .envrc files" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            template_root = File.join(gem_root, "template")
            FileUtils.mkdir_p(template_root)
            # Create .envrc.example with the token under template_root
            File.write(File.join(template_root, ".envrc.example"), <<~ENVRC)
              export DEBUG=false
              # If {KJ|GEM_NAME} does not have an open source collective set these to false.
              export OPENCOLLECTIVE_HANDLE={KJ|OPENCOLLECTIVE_ORG}
              export FUNDING_ORG={KJ|OPENCOLLECTIVE_ORG}
              dotenv_if_exists .env.local
            ENVRC

            # Provide gemspec in project
            File.write(File.join(project_root, "my-awesome-gem.gemspec"), <<~GEMSPEC)
              Gem::Specification.new do |spec|
                spec.name = "my-awesome-gem"
                spec.version = "0.1.0"
                spec.summary = "test gem"
                spec.authors = ["Test"]
                spec.required_ruby_version = ">= 3.1"
                spec.homepage = "https://github.com/coolorg/my-awesome-gem"
              end
            GEMSPEC

            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: template_root,
              ensure_clean_git!: nil,
              ask: true,
            )

            # Override funding org for this test - stub both ENV vars to prevent bleed from project .envrc
            stub_env("FUNDING_ORG" => "", "OPENCOLLECTIVE_HANDLE" => "")

            expect { described_class.run }.not_to raise_error

            # Assert .envrc was copied
            envrc_dest = File.join(project_root, ".envrc")
            expect(File).to exist(envrc_dest)

            # Assert {KJ|GEM_NAME} was replaced with the actual gem name
            envrc_content = File.read(envrc_dest)
            expect(envrc_content).to include("# If my-awesome-gem does not have an open source collective")
            expect(envrc_content).not_to include("{KJ|GEM_NAME}")

            # Assert other tokens were also replaced (from apply_common_replacements)
            expect(envrc_content).to include("export OPENCOLLECTIVE_HANDLE=coolorg")
            expect(envrc_content).to include("export FUNDING_ORG=coolorg")
          end
        end
      end

      it "updates style.gemfile rubocop-lts constraint based on min_ruby", :check_output do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            # style.gemfile template with placeholder constraint
            style_dir = File.join(gem_root, "template", "gemfiles", "modular")
            FileUtils.mkdir_p(style_dir)
            File.write(File.join(style_dir, "style.gemfile.example"), <<~GEMFILE)
              unless ENV.fetch("RUBOCOP_LTS_LOCAL", "false").casecmp("false").zero?
                gem "rubocop-lts", path: "src/rubocop-lts/rubocop-lts"
                gem "rubocop-lts-rspec", path: "src/rubocop-lts/rubocop-lts-rspec"
                gem "{KJ|RUBOCOP_RUBY_GEM}", path: "src/rubocop-lts/{KJ|RUBOCOP_RUBY_GEM}"
                gem "standard-rubocop-lts", path: "src/rubocop-lts/standard-rubocop-lts"
              else
                gem "rubocop-lts", "{KJ|RUBOCOP_LTS_CONSTRAINT}"
                gem "{KJ|RUBOCOP_RUBY_GEM}"
                gem "rubocop-rspec", "~> 3.6"
              end
            GEMFILE
            # gemspec declares min_ruby 3.2 -> map to "~> 24.0"
            File.write(File.join(project_root, "demo.gemspec"), <<~GEMSPEC)
              Gem::Specification.new do |spec|
                spec.name = "demo"
                spec.version = "0.1.0"
                spec.summary = "test"
                spec.authors = ["Test"]
                spec.required_ruby_version = ">= 3.2"
                spec.homepage = "https://github.com/acme/demo"
              end
            GEMSPEC

            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: File.join(gem_root, "template"),
              ensure_clean_git!: nil,
              ask: true,
            )

            described_class.run

            dest = File.join(project_root, "gemfiles", "modular", "style.gemfile")
            expect(File).to exist(dest)
            txt = File.read(dest)
            expect(txt).to include('gem "rubocop-lts", "~> 24.0"')
            expect(txt).to include('gem "rubocop-ruby3_2"')
          end
        end
      end

      it "keeps style.gemfile constraint unchanged when min_ruby is missing (else branch)" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            style_dir = File.join(gem_root, "template", "gemfiles", "modular")
            FileUtils.mkdir_p(style_dir)
            File.write(File.join(style_dir, "style.gemfile.example"), <<~GEMFILE)
              unless ENV.fetch("RUBOCOP_LTS_LOCAL", "false").casecmp("false").zero?
                gem "rubocop-lts", path: "src/rubocop-lts/rubocop-lts"
                gem "rubocop-lts-rspec", path: "src/rubocop-lts/rubocop-lts-rspec"
                gem "{KJ|RUBOCOP_RUBY_GEM}", path: "src/rubocop-lts/{KJ|RUBOCOP_RUBY_GEM}"
                gem "standard-rubocop-lts", path: "src/rubocop-lts/standard-rubocop-lts"
              else
                gem "rubocop-lts", "{KJ|RUBOCOP_LTS_CONSTRAINT}"
                gem "{KJ|RUBOCOP_RUBY_GEM}"
                gem "rubocop-rspec", "~> 3.6"
              end
            GEMFILE
            # gemspec without any min ruby declaration
            File.write(File.join(project_root, "demo.gemspec"), <<~GEMSPEC)
              Gem::Specification.new do |spec|
                spec.name = "demo"
              end
            GEMSPEC

            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: File.join(gem_root, "template"),
              ensure_clean_git!: nil,
              ask: true,
            )

            described_class.run

            dest = File.join(project_root, "gemfiles", "modular", "style.gemfile")
            expect(File).to exist(dest)
            txt = File.read(dest)
            expect(txt).to include('gem "rubocop-lts", "~> 0.1"')
            expect(txt).to include('gem "rubocop-ruby1_8"')
          end
        end
      end

      it "copies modular directories and additional gemfiles (erb, mutex_m, stringio, x_std_libs; debug/runtime_heads)" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            base = File.join(gem_root, "template", "gemfiles", "modular")
            %w[erb mutex_m stringio x_std_libs].each do |d|
              dir = File.join(base, d)
              FileUtils.mkdir_p(dir)
              # nested/versioned example files
              FileUtils.mkdir_p(File.join(dir, "r2.6"))
              File.write(File.join(dir, "r2.6", "v2.2.gemfile"), "# v2.2\n")
              FileUtils.mkdir_p(File.join(dir, "r3"))
              File.write(File.join(dir, "r3", "libs.gemfile"), "# r3 libs\n")
            end
            # additional specific gemfiles
            File.write(File.join(base, "debug.gemfile"), "# debug\n")
            File.write(File.join(base, "runtime_heads.gemfile"), "# runtime heads\n")

            # minimal gemspec to satisfy metadata scan
            File.write(File.join(project_root, "demo.gemspec"), <<~G)
              Gem::Specification.new do |spec|
                spec.name = "demo"
                spec.version = "0.1.0"
                spec.summary = "test gem"
                spec.authors = ["Test"]
                spec.required_ruby_version = ">= 3.1"
                spec.homepage = "https://github.com/acme/demo"
              end
            G

            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: File.join(gem_root, "template"),
              ensure_clean_git!: nil,
              ask: true,
            )

            expect { described_class.run }.not_to raise_error

            # assert directories copied recursively
            %w[erb mutex_m stringio x_std_libs].each do |d|
              expect(File).to exist(File.join(project_root, "gemfiles", "modular", d, "r3", "libs.gemfile"))
              expect(File).not_to exist(File.join(project_root, "gemfiles", "modular", d, "r2.6", "v2.2.gemfile"))
            end
            # assert specific gemfiles copied
            expect(File).to exist(File.join(project_root, "gemfiles", "modular", "debug.gemfile"))
            expect(File).to exist(File.join(project_root, "gemfiles", "modular", "runtime_heads.gemfile"))
          end
        end
      end

      # Regression: optional.gemfile should prefer the .example version when both exist
      it "prefers optional.gemfile.example over optional.gemfile" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            dir = File.join(gem_root, "template", "gemfiles", "modular")
            FileUtils.mkdir_p(dir)
            File.write(File.join(dir, "optional.gemfile"), "# REAL\nreal\n")
            File.write(File.join(dir, "optional.gemfile.example"), "# EXAMPLE\nexample\n")

            # Minimal gemspec so metadata scan works
            File.write(File.join(project_root, "demo.gemspec"), <<~GEMSPEC)
              Gem::Specification.new do |spec|
                spec.name = "demo"
                spec.version = "0.1.0"
                spec.summary = "test"
                spec.authors = ["Test"]
                spec.required_ruby_version = ">= 3.1"
                spec.homepage = "https://github.com/acme/demo"
              end
            GEMSPEC

            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: File.join(gem_root, "template"),
              ensure_clean_git!: nil,
              ask: true,
            )

            described_class.run

            dest = File.join(project_root, "gemfiles", "modular", "optional.gemfile")
            expect(File).to exist(dest)
            content = File.read(dest)
            lowered = content.downcase
            expect(lowered).to include("example")
            expect(lowered).not_to include("real")
          end
        end
      end

      it "replaces require in spec/spec_helper.rb when confirmed, or skips when declined" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            # Arrange project spec_helper with kettle/dev
            spec_dir = File.join(project_root, "spec")
            FileUtils.mkdir_p(spec_dir)
            File.write(File.join(spec_dir, "spec_helper.rb"), "require 'kettle/dev'\n")
            # gemspec
            File.write(File.join(project_root, "demo.gemspec"), <<~GEMSPEC)
              Gem::Specification.new do |spec|
                spec.name = "demo"
                spec.version = "0.1.0"
                spec.summary = "test gem"
                spec.authors = ["Test"]
                spec.required_ruby_version = ">= 3.1"
                spec.homepage = "https://github.com/acme/demo"
              end
            GEMSPEC

            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: File.join(gem_root, "template"),
              ensure_clean_git!: nil,
            )

            # Case 1: confirm replacement
            allow(helpers).to receive(:ask).and_return(true)
            described_class.run
            content = File.read(File.join(spec_dir, "spec_helper.rb"))
            expect(content).to include('require "demo"')

            # Case 2: decline
            File.write(File.join(spec_dir, "spec_helper.rb"), "require 'kettle/dev'\n")
            allow(helpers).to receive(:ask).and_return(false)
            described_class.run
            content2 = File.read(File.join(spec_dir, "spec_helper.rb"))
            expect(content2).to include("require 'kettle/dev'")
          end
        end
      end

      it "merges README sections and preserves first H1 emojis", :check_output do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            # Arrange
            template_readme = <<~MD
              # 🚀 Template Title
              
              ## Synopsis
              Template synopsis.
              
              ## Configuration
              Template configuration.
              
              ## Basic Usage
              Template usage.
              
              ## NOTE: Something
              Template note.
            MD
            File.write(File.join(gem_root, "README.md"), template_readme)

            existing_readme = <<~MD
              # 🎉 Existing Title
              
              ## Synopsis
              Existing synopsis.
              
              ## Configuration
              Existing configuration.
              
              ## Basic Usage
              Existing usage.
              
              ## NOTE: Something
              Existing note.
            MD
            File.write(File.join(project_root, "README.md"), existing_readme)

            File.write(File.join(project_root, "demo.gemspec"), <<~GEMSPEC)
              Gem::Specification.new do |spec|
                spec.name = "demo"
                spec.version = "0.1.0"
                spec.summary = "test gem"
                spec.authors = ["Test"]
                spec.required_ruby_version = ">= 3.1"
                spec.homepage = "https://github.com/acme/demo"
              end
            GEMSPEC

            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: File.join(gem_root, "template"),
              ensure_clean_git!: nil,
              ask: true,
            )

            # Exercise
            described_class.run

            # Assert merge and H1 full-line preservation
            merged = File.read(File.join(project_root, "README.md"))
            expect(merged.lines.first).to match(/^#\s+🎉\s+Existing Title/)
            expect(merged).to include("Existing synopsis.")
            expect(merged).to include("Existing configuration.")
            expect(merged).to include("Existing usage.")
            expect(merged).to include("Existing note.")
          end
        end
      end

      it "copies gem.gemspec.example to <gem_name>.gemspec with substitutions" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            template_root = File.join(gem_root, "template")
            FileUtils.mkdir_p(template_root)
            # Provide a gem.gemspec.example with tokens to be replaced
            File.write(File.join(template_root, "gem.gemspec.example"), <<~GEMSPEC)
              Gem::Specification.new do |spec|
                spec.name = "{KJ|GEM_NAME}"
                # Namespace token example
                {KJ|NAMESPACE}
              end
            GEMSPEC

            # Destination project gemspec to derive gem_name and org/homepage
            File.write(File.join(project_root, "my-gem.gemspec"), <<~GEMSPEC)
              Gem::Specification.new do |spec|
                spec.name = "my-gem"
                spec.version = "0.1.0"
                spec.summary = "test"
                spec.authors = ["Test"]
                spec.required_ruby_version = ">= 3.1"
                spec.homepage = "https://github.com/acme/my-gem"
              end
            GEMSPEC

            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: template_root,
              ensure_clean_git!: nil,
              ask: true,
            )

            described_class.run

            dest = File.join(project_root, "my-gem.gemspec")
            expect(File).to exist(dest)
            txt = File.read(dest)
            # After Prism merge, destination fields are carried over
            expect(txt).to match(/spec\.name\s*=\s*\"my-gem\"/)
            # Destination fields should be preserved
            expect(txt).to include("my-gem")
          end
        end
      end

      it "inlines spec.version when destination min_ruby is >= 3.1" do
        local_tmp_root = File.expand_path("../../../../tmp/spec/template_task", __dir__)
        FileUtils.mkdir_p(local_tmp_root)

        Dir.mktmpdir("gem-root-", local_tmp_root) do |gem_root|
          Dir.mktmpdir("project-root-", local_tmp_root) do |project_root|
            template_root = File.join(gem_root, "template")
            FileUtils.mkdir_p(template_root)
            File.write(File.join(template_root, "gem.gemspec.example"), <<~GEMSPEC)
              # coding: utf-8
              # frozen_string_literal: true

              # {KJ|FREEZE_TOKEN}:freeze
              # {KJ|FREEZE_TOKEN}:unfreeze

              gem_version =
                if RUBY_VERSION >= "3.1" # rubocop:disable Gemspec/RubyVersionGlobalsUsage
                  Module.new.tap { |mod| Kernel.load("\#{__dir__}/lib/{KJ|GEM_NAME_PATH}/version.rb", mod) }::{KJ|NAMESPACE}::Version::VERSION
                else
                  lib = File.expand_path("lib", __dir__)
                  $LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
                  require "{KJ|GEM_NAME_PATH}/version"
                  {KJ|NAMESPACE}::Version::VERSION
                end

              Gem::Specification.new do |spec|
                spec.name = "{KJ|GEM_NAME}"
                spec.version = gem_version
              end
            GEMSPEC

            File.write(File.join(project_root, "my-gem.gemspec"), <<~GEMSPEC)
              # coding: utf-8
              # frozen_string_literal: true

              # my-gem:freeze
              # my-gem:unfreeze

              gem_version =
                if RUBY_VERSION >= "3.1" # rubocop:disable Gemspec/RubyVersionGlobalsUsage
                  Module.new.tap { |mod| Kernel.load("\#{__dir__}/lib/my/gem/version.rb", mod) }::My::Gem::Version::VERSION
                else
                  lib = File.expand_path("lib", __dir__)
                  $LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
                  require "my/gem/version"
                  My::Gem::Version::VERSION
                end

              Gem::Specification.new do |spec|
                spec.name = "my-gem"
                spec.version = gem_version
                spec.summary = "test"
                spec.authors = ["Test"]
                spec.required_ruby_version = ">= 3.2"
                spec.homepage = "https://github.com/acme/my-gem"
              end
            GEMSPEC
            version_file = File.join(project_root, "lib", "my", "gem")
            FileUtils.mkdir_p(version_file)
            File.write(File.join(version_file, "version.rb"), <<~RUBY)
              module My
                module Gem
                  module Version
                    VERSION = "0.1.0"
                  end
                end
              end
            RUBY

            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: template_root,
              ensure_clean_git!: nil,
              ask: true,
            )

            described_class.run

            txt = File.read(File.join(project_root, "my-gem.gemspec"))
            expect(txt).not_to include("gem_version =")
            expect(txt).not_to include('if RUBY_VERSION >= "3.1"')
            expect(txt).not_to include("$LOAD_PATH.unshift(lib)")
            expect(txt).not_to include('require "my/gem/version"')
            expect(txt).to include('spec.version = Module.new.tap { |mod| Kernel.load("#{__dir__}/lib/my/gem/version.rb", mod) }::My::Gem::Version::VERSION')
          end
        end
      end

      it "keeps gem_version when destination min_ruby is below 3.1" do
        local_tmp_root = File.expand_path("../../../../tmp/spec/template_task", __dir__)
        FileUtils.mkdir_p(local_tmp_root)

        Dir.mktmpdir("gem-root-", local_tmp_root) do |gem_root|
          Dir.mktmpdir("project-root-", local_tmp_root) do |project_root|
            template_root = File.join(gem_root, "template")
            FileUtils.mkdir_p(template_root)
            File.write(File.join(template_root, "gem.gemspec.example"), <<~GEMSPEC)
              # coding: utf-8
              # frozen_string_literal: true

              # {KJ|FREEZE_TOKEN}:freeze
              # {KJ|FREEZE_TOKEN}:unfreeze

              gem_version =
                if RUBY_VERSION >= "3.1" # rubocop:disable Gemspec/RubyVersionGlobalsUsage
                  Module.new.tap { |mod| Kernel.load("\#{__dir__}/lib/{KJ|GEM_NAME_PATH}/version.rb", mod) }::{KJ|NAMESPACE}::Version::VERSION
                else
                  lib = File.expand_path("lib", __dir__)
                  $LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
                  require "{KJ|GEM_NAME_PATH}/version"
                  {KJ|NAMESPACE}::Version::VERSION
                end

              Gem::Specification.new do |spec|
                spec.name = "{KJ|GEM_NAME}"
                spec.version = gem_version
              end
            GEMSPEC

            File.write(File.join(project_root, "my-gem.gemspec"), <<~GEMSPEC)
              Gem::Specification.new do |spec|
                spec.name = "my-gem"
                spec.version = "0.1.0"
                spec.summary = "test"
                spec.authors = ["Test"]
                spec.required_ruby_version = ">= 3.0"
                spec.homepage = "https://github.com/acme/my-gem"
              end
            GEMSPEC

            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: template_root,
              ensure_clean_git!: nil,
              ask: true,
            )

            described_class.run

            txt = File.read(File.join(project_root, "my-gem.gemspec"))
            expect(txt).to include("gem_version =")
            expect(txt).to include('require "my/gem/version"')
            expect(txt).to include("spec.version = gem_version")
          end
        end
      end

      it "bootstraps version_gem touchpoints before templating a turbo_tests2-style gemspec" do
        local_tmp_root = File.expand_path("../../../../tmp/spec/template_task", __dir__)
        FileUtils.mkdir_p(local_tmp_root)

        Dir.mktmpdir("gem-root-", local_tmp_root) do |gem_root|
          Dir.mktmpdir("project-root-", local_tmp_root) do |project_root|
            template_root = File.join(gem_root, "template")
            FileUtils.mkdir_p(template_root)

            File.write(File.join(template_root, ".kettle-jem.yml.example"), <<~YAML)
              defaults:
                preference: template
                add_template_only_nodes: true
                freeze_token: kettle-jem
              tokens:
                forge:
                  gh_user: ""
              patterns: []
              files: {}
            YAML

            File.write(File.join(template_root, "gem.gemspec.example"), <<~GEMSPEC)
              # frozen_string_literal: true

              gem_version =
                if RUBY_VERSION >= "3.1" # rubocop:disable Gemspec/RubyVersionGlobalsUsage
                  Module.new.tap { |mod| Kernel.load("\#{__dir__}/lib/{KJ|GEM_NAME_PATH}/version.rb", mod) }::{KJ|NAMESPACE}::Version::VERSION
                else
                  lib = File.expand_path("lib", __dir__)
                  $LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
                  require "{KJ|GEM_NAME_PATH}/version"
                  {KJ|NAMESPACE}::Version::VERSION
                end

              Gem::Specification.new do |spec|
                spec.name = "{KJ|GEM_NAME}"
                spec.version = gem_version
                spec.summary = "Template summary"
                spec.authors = ["Template Author"]
                spec.email = ["template@example.com"]
                spec.required_ruby_version = ">= 2.7"
                spec.homepage = "https://github.com/acme/{KJ|GEM_NAME}"
              end
            GEMSPEC

            FileUtils.mkdir_p(File.join(project_root, "lib", "turbo_tests"))
            File.write(File.join(project_root, "lib", "turbo_tests", "version.rb"), <<~RUBY)
              module TurboTests
                VERSION = "2.2.5"
              end
            RUBY
            File.write(File.join(project_root, "lib", "turbo_tests.rb"), <<~RUBY)
              # frozen_string_literal: true

              require "securerandom"

              module TurboTests
                autoload :VERSION, "turbo_tests/version"
              end
            RUBY
            File.write(File.join(project_root, "turbo_tests2.gemspec"), <<~GEMSPEC)
              require_relative "lib/turbo_tests/version"

              Gem::Specification.new do |spec|
                spec.name = "turbo_tests2"
                spec.version = TurboTests::VERSION
                spec.summary = "Existing summary"
                spec.authors = ["Peter H. Boling"]
                spec.email = ["floss@galtzo.com"]
                spec.required_ruby_version = ">= 2.7"
                spec.homepage = "https://github.com/acme/turbo_tests2"
              end
            GEMSPEC
            File.write(File.join(project_root, ".kettle-jem.yml"), <<~YAML)
              defaults:
                preference: template
                add_template_only_nodes: true
                freeze_token: kettle-jem
              tokens:
                forge:
                  gh_user: ""
              patterns: []
              files: {}
            YAML

            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: template_root,
              ensure_clean_git!: nil,
              ask: true,
            )

            expect { described_class.run }.not_to raise_error

            version_file = File.read(File.join(project_root, "lib", "turbo_tests", "version.rb"))
            expect(version_file).to include("module TurboTests\n  module Version\n    VERSION = \"2.2.5\"\n  end\n  VERSION = Version::VERSION # Traditional Constant Location\nend")

            entrypoint_file = File.read(File.join(project_root, "lib", "turbo_tests.rb"))
            expect(entrypoint_file).to include('require "version_gem"')
            expect(entrypoint_file).to include('require_relative "turbo_tests/version"')
            expect(entrypoint_file).to include("TurboTests::Version.class_eval do")
            expect(entrypoint_file).not_to include('autoload :VERSION, "turbo_tests/version"')

            gemspec_path = File.join(project_root, "turbo_tests2.gemspec")
            gemspec = File.read(gemspec_path)
            expect(gemspec).to include('Kernel.load("#{__dir__}/lib/turbo_tests/version.rb", mod) }::TurboTests::Version::VERSION')
            expect(gemspec).to include('require "turbo_tests/version"')

            loaded_spec = Dir.chdir(project_root) { Gem::Specification.load(gemspec_path) }
            expect(loaded_spec.version.to_s).to eq("2.2.5")
          end
        end
      end

      it "preserves pre-existing duplicate spec.rdoc_options operator-write blocks without corrupting the destination gemspec" do
        local_tmp_root = File.expand_path("../../../../tmp/spec/template_task", __dir__)
        FileUtils.mkdir_p(local_tmp_root)

        Dir.mktmpdir("gem-root-", local_tmp_root) do |gem_root|
          Dir.mktmpdir("project-root-", local_tmp_root) do |project_root|
            template_root = File.join(gem_root, "template")
            FileUtils.mkdir_p(template_root)
            File.write(File.join(template_root, "gem.gemspec.example"), <<~GEMSPEC)
              # coding: utf-8
              # frozen_string_literal: true

              # {KJ|FREEZE_TOKEN}:freeze
              # {KJ|FREEZE_TOKEN}:unfreeze

              Gem::Specification.new do |spec|
                spec.name = "{KJ|GEM_NAME}"
                spec.version = "0.2.0"
                spec.summary = "template"
                spec.authors = ["{KJ|AUTHOR:NAME}"]
                spec.required_ruby_version = ">= 3.2"
                spec.homepage = "https://github.com/acme/{KJ|GEM_NAME}"
                spec.require_paths = ["lib"]
                spec.rdoc_options += [
                  "--title",
                  "\#{spec.name} - \#{spec.summary}",
                  "--main",
                  "README.md",
                  "--quiet",
                ]
              end
            GEMSPEC

            File.write(File.join(project_root, "my-gem.gemspec"), <<~GEMSPEC)
              # coding: utf-8
              # frozen_string_literal: true

              # my-gem:freeze
              # my-gem:unfreeze

              Gem::Specification.new do |spec|
                spec.name = "my-gem"
                spec.version = "0.1.0"
                spec.summary = "test"
                spec.authors = ["Test"]
                spec.required_ruby_version = ">= 3.2"
                spec.homepage = "https://github.com/acme/my-gem"
                spec.require_paths = ["lib"]
                spec.rdoc_options += [
                  "--title",
                  "\#{spec.name} - \#{spec.summary}",
                  "--main",
                  "README.md",
                  "--quiet",
                ]
                spec.rdoc_options += [
                  "--title",
                  "\#{spec.name} - \#{spec.summary}",
                  "--main",
                  "README.md",
                  "--quiet",
                ]
              end
            GEMSPEC

            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: template_root,
              ensure_clean_git!: nil,
              ask: true,
            )

            described_class.run

            txt = File.read(File.join(project_root, "my-gem.gemspec"))
            parse_result = Prism.parse(txt)

            expect(parse_result.success?).to be(true), <<~MSG
              Expected template task to preserve a valid gemspec even when the destination already contains duplicate spec.rdoc_options += blocks.

              Errors: #{parse_result.errors.map(&:message).join(", ")}

              #{txt}
            MSG

            expect(txt.scan(/^\s*spec\.rdoc_options \+= \[/).length).to eq(2), <<~MSG
              Expected template task to leave pre-existing duplicate spec.rdoc_options += blocks intact rather than slicing through the gemspec.

              #{txt}
            MSG

            expect(txt).to include('spec.require_paths = ["lib"]'), <<~MSG
              Expected template task to preserve statements following duplicate spec.rdoc_options += blocks.

              #{txt}
            MSG
          end
        end
      end

      it "removes self-dependencies in gemspec after templating (runtime and development, paren and no-paren)" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            template_root = File.join(gem_root, "template")
            FileUtils.mkdir_p(template_root)
            # Template gemspec includes dependencies on the template gem name
            File.write(File.join(template_root, "gem.gemspec.example"), <<~GEMSPEC)
              Gem::Specification.new do |spec|
                spec.name = "kettle-dev"
                spec.add_dependency("kettle-dev", "~> 1.0")
                spec.add_dependency 'kettle-dev'
                spec.add_development_dependency("kettle-dev")
                spec.add_development_dependency 'kettle-dev', ">= 0"
                spec.add_dependency("addressable", ">= 2.8", "< 3")
              end
            GEMSPEC

            # Destination project gemspec to derive gem_name and org/homepage
            File.write(File.join(project_root, "my-gem.gemspec"), <<~GEMSPEC)
              Gem::Specification.new do |spec|
                spec.name = "my-gem"
                spec.version = "0.1.0"
                spec.summary = "test"
                spec.authors = ["Test"]
                spec.required_ruby_version = ">= 3.1"
                spec.homepage = "https://github.com/acme/my-gem"
              end
            GEMSPEC

            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: template_root,
              ensure_clean_git!: nil,
              ask: true,
            )

            described_class.run

            dest = File.join(project_root, "my-gem.gemspec")
            expect(File).to exist(dest)
            txt = File.read(dest)
            # Self-dependency variants should be removed (they would otherwise become my-gem)
            expect(txt).not_to match(/spec\.add_(?:development_)?dependency\([\"\']my-gem[\"\']/)
            expect(txt).not_to match(/spec\.add_(?:development_)?dependency\s+[\"\']my-gem[\"\']/)
            # Destination fields should be preserved
            expect(txt).to match(/spec\.name\s*=\s*\"my-gem\"/)
          end
        end
      end

      it "when gem_name is missing, falls back to first existing *.gemspec in project" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            FileUtils.mkdir_p(File.join(gem_root, "template"))
            # Provide template gemspec example with tokens
            File.write(File.join(gem_root, "template", "gem.gemspec.example"), <<~GEMSPEC)
              Gem::Specification.new do |spec|
                spec.name = "{KJ|GEM_NAME}"
                {KJ|NAMESPACE}
              end
            GEMSPEC

            # Destination already has a different gemspec; note: no name set elsewhere to derive gem_name
            File.write(File.join(project_root, "existing.gemspec"), <<~GEMSPEC)
              Gem::Specification.new do |spec|
                spec.name = "existing"
                spec.version = "0.1.0"
                spec.summary = "test"
                spec.authors = ["Test"]
                spec.homepage = "https://github.com/acme/existing"
              end
            GEMSPEC

            # project has no other gemspec affecting gem_name discovery (no spec.name parsing needed beyond existing)
            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: File.join(gem_root, "template"),
              ensure_clean_git!: nil,
              ask: true,
            )

            described_class.run

            # Should have used existing.gemspec as destination
            dest = File.join(project_root, "existing.gemspec")
            expect(File).to exist(dest)
            txt = File.read(dest)
            # Token replacements applied
            expect(txt).to include("existing")
            # Tokens should be resolved
            expect(txt).not_to include("{KJ|GEM_NAME}")
            expect(txt).not_to include("{KJ|NAMESPACE}")
          end
        end
      end

      it "when gem_name is missing and no gemspec exists, uses example basename without .example" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            template_root = File.join(gem_root, "template")
            FileUtils.mkdir_p(template_root)
            # Provide template example only
            File.write(File.join(template_root, "gem.gemspec.example"), <<~GEMSPEC)
              Gem::Specification.new do |spec|
                spec.name = "kettle-dev"
                Kettle::Dev
              end
            GEMSPEC

            # No destination gemspecs present
            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: template_root,
              ensure_clean_git!: nil,
              ask: true,
            )

            described_class.run

            # Should write gem.gemspec (no .example)
            dest = File.join(project_root, "gem.gemspec")
            expect(File).to exist(dest)
            txt = File.read(dest)
            expect(txt).not_to include("gem.gemspec.example")
            # Note: when gem_name is unknown, namespace/gem replacements depending on gem_name may not occur.
            # This test verifies the destination file name logic only.
          end
        end
      end

      it "prefers .gitlab-ci.yml.example over .gitlab-ci.yml and writes destination without .example" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            template_root = File.join(gem_root, "template")
            FileUtils.mkdir_p(template_root)
            # Arrange template files under template_root
            File.write(File.join(template_root, ".gitlab-ci.yml"), "from: REAL\n")
            File.write(File.join(template_root, ".gitlab-ci.yml.example"), "from: EXAMPLE\n")

            # Minimal gemspec so metadata scan works
            File.write(File.join(project_root, "demo.gemspec"), <<~GEMSPEC)
              Gem::Specification.new do |spec|
                spec.name = "demo"
                spec.version = "0.1.0"
                spec.summary = "test"
                spec.authors = ["Test"]
                spec.required_ruby_version = ">= 3.1"
                spec.homepage = "https://github.com/acme/demo"
              end
            GEMSPEC

            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: template_root,
              ensure_clean_git!: nil,
              ask: true,
            )

            # Exercise
            described_class.run

            # Assert destination is the non-example name and content from example
            dest = File.join(project_root, ".gitlab-ci.yml")
            expect(File).to exist(dest)
            expect(File.read(dest)).to include("EXAMPLE")
          end
        end
      end

      it "copies .licenserc.yaml preferring .licenserc.yaml.example when available" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            template_root = File.join(gem_root, "template")
            FileUtils.mkdir_p(template_root)
            # Arrange template files under template_root
            File.write(File.join(template_root, ".licenserc.yaml"), "header:\n  license: REAL\n")
            File.write(File.join(template_root, ".licenserc.yaml.example"), "header:\n  license: EXAMPLE\n")

            # Minimal gemspec so metadata scan works
            File.write(File.join(project_root, "demo.gemspec"), <<~GEMSPEC)
              Gem::Specification.new do |spec|
                spec.name = "demo"
                spec.version = "0.1.0"
                spec.summary = "test gem"
                spec.authors = ["Test"]
                spec.required_ruby_version = ">= 3.1"
                spec.homepage = "https://github.com/acme/demo"
              end
            GEMSPEC

            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: template_root,
              ensure_clean_git!: nil,
              ask: true,
            )

            # Exercise
            described_class.run

            # Assert destination is the non-example name and content from example
            dest = File.join(project_root, ".licenserc.yaml")
            expect(File).to exist(dest)
            expect(File.read(dest)).to include("EXAMPLE")
            expect(File.read(dest)).not_to include("REAL")
          end
        end
      end

      # .idea/ is an autogenerated IDE directory — excluded from templating

      it "prints a warning when copying .env.local.example raises", :check_output do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            template_root = File.join(gem_root, "template")
            FileUtils.mkdir_p(template_root)
            File.write(File.join(template_root, ".env.local.example"), "A=1\n")
            File.write(File.join(project_root, "demo.gemspec"), "Gem::Specification.new{|s| s.name='demo'; s.homepage='https://github.com/acme/demo'}\n")
            allow(helpers).to receive_messages(project_root: project_root, template_root: template_root, ensure_clean_git!: nil, ask: true)
            # Only raise for .env.local.example copy, not for other copies
            allow(helpers).to receive(:copy_file_with_prompt).and_wrap_original do |m, *args, &blk|
              src = args[0].to_s
              if File.basename(src) == ".env.local.example"
                raise ArgumentError, "boom"
              elsif args.last.is_a?(Hash)
                kw = args.pop
                m.call(*args, **kw, &blk)
              else
                m.call(*args, &blk)
              end
            end
            expect { described_class.run }.not_to raise_error
          end
        end
      end

      it "copies certs/pboling.pem when present, and warns on error", :check_output do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            template_cert_dir = File.join(gem_root, "template", "certs")
            FileUtils.mkdir_p(template_cert_dir)
            File.write(File.join(template_cert_dir, "pboling.pem"), "certdata")
            File.write(File.join(project_root, "demo.gemspec"), "Gem::Specification.new{|s| s.name='demo'; s.homepage='https://github.com/acme/demo'}\n")
            allow(helpers).to receive_messages(project_root: project_root, template_root: File.join(gem_root, "template"), ensure_clean_git!: nil, ask: true)

            # Normal run
            expect { described_class.run }.not_to raise_error
            expect(File).to exist(File.join(project_root, "certs", "pboling.pem"))

            # Error run
            allow(helpers).to receive(:copy_file_with_prompt).and_wrap_original do |m, *args, **kw, &blk|
              if args[0].to_s.end_with?(File.join("certs", "pboling.pem"))
                raise "nope"
              else
                m.call(*args, **kw, &blk)
              end
            end
            expect { described_class.run }.not_to raise_error
          end
        end
      end

      context "when reviewing env file changes", :check_output do
        it "proceeds when allowed=true" do
          Dir.mktmpdir do |gem_root|
            Dir.mktmpdir do |project_root|
              template_root = File.join(gem_root, "template")
              FileUtils.mkdir_p(template_root)
              File.write(File.join(template_root, ".envrc"), "export A=1\n")
              File.write(File.join(project_root, "demo.gemspec"), "Gem::Specification.new{|s| s.name='demo'; s.homepage='https://github.com/acme/demo'}\n")
              allow(helpers).to receive_messages(project_root: project_root, template_root: template_root, ensure_clean_git!: nil, ask: true)
              allow(helpers).to receive(:modified_by_template?).and_return(true)
              stub_env("allowed" => "true")
              expect { described_class.run }.not_to raise_error
            end
          end
        end

        it "aborts with mise trust guidance when not allowed" do
          Dir.mktmpdir do |gem_root|
            Dir.mktmpdir do |project_root|
              template_root = File.join(gem_root, "template")
              FileUtils.mkdir_p(template_root)
              File.write(File.join(template_root, ".envrc"), "export A=1\n")
              File.write(File.join(project_root, "demo.gemspec"), "Gem::Specification.new{|s| s.name='demo'; s.homepage='https://github.com/acme/demo'}\n")
              allow(helpers).to receive_messages(project_root: project_root, template_root: template_root, ensure_clean_git!: nil, ask: true)
              allow(helpers).to receive(:modified_by_template?).and_return(true)
              stub_env("allowed" => "")
              expect { described_class.run }
                .to raise_error(Kettle::Dev::Error, /review of environment files required/)
                .and output(/IMPORTANT: The following environment-related files were created\/updated:\n.*If mise prompts you to trust this repo, run:\n  mise trust/m).to_stdout
            end
          end
        end

        it "warns when check raises" do
          Dir.mktmpdir do |gem_root|
            Dir.mktmpdir do |project_root|
              template_root = File.join(gem_root, "template")
              FileUtils.mkdir_p(template_root)
              File.write(File.join(template_root, ".envrc"), "export A=1\n")
              File.write(File.join(project_root, "demo.gemspec"), "Gem::Specification.new{|s| s.name='demo'; s.homepage='https://github.com/acme/demo'}\n")
              allow(helpers).to receive_messages(project_root: project_root, template_root: template_root, ensure_clean_git!: nil, ask: true)
              allow(helpers).to receive(:modified_by_template?).and_raise(StandardError, "oops")
              stub_env("allowed" => "true")
              expect { described_class.run }.not_to raise_error
            end
          end
        end
      end

      it "applies replacements for special root files like CHANGELOG.md and .opencollective.yml and FUNDING.md" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            template_root = File.join(gem_root, "template")
            FileUtils.mkdir_p(template_root)
            File.write(File.join(template_root, "CHANGELOG.md.example"), "{KJ|GH_ORG} {KJ|GEM_NAME} {KJ|NAMESPACE} {KJ|NAMESPACE_SHIELD} {KJ|GEM_SHIELD}\n")
            File.write(File.join(template_root, ".opencollective.yml"), "org: {KJ|GH_ORG} project: {KJ|GEM_NAME}\n")
            File.write(File.join(template_root, ".opencollective.yml.example"), "org: {KJ|GH_ORG} project: {KJ|GEM_NAME}\n")
            # FUNDING with org placeholder to be replaced
            File.write(File.join(template_root, "FUNDING.md"), "Support org {KJ|GH_ORG} and project {KJ|GEM_NAME}\n")
            File.write(File.join(template_root, "FUNDING.md.example"), "Support org {KJ|GH_ORG} and project {KJ|GEM_NAME}\n")

            File.write(File.join(project_root, "demo.gemspec"), <<~GEMSPEC)
              Gem::Specification.new do |spec|
                spec.name = "my-gem"
                spec.version = "0.1.0"
                spec.summary = "test"
                spec.authors = ["Test"]
                spec.required_ruby_version = ">= 3.1"
                spec.homepage = "https://github.com/acme/my-gem"
              end
            GEMSPEC
            allow(helpers).to receive_messages(project_root: project_root, template_root: template_root, ensure_clean_git!: nil, ask: true)

            described_class.run

            changelog = File.read(File.join(project_root, "CHANGELOG.md"))
            expect(changelog).to include("acme")
            expect(changelog).to include("my-gem")
            expect(changelog).to include("My::Gem")
            expect(changelog).to include("My%3A%3AGem")
            expect(changelog).to include("my--gem")

            # FUNDING.md should be copied and have org replaced with funding org (acme)
            funding = File.read(File.join(project_root, "FUNDING.md"))
            expect(funding).to include("acme")
            expect(funding).not_to include("{KJ|GH_ORG}")
          end
        end
      end

      it "does not duplicate Unreleased change-type headings and preserves existing list items under them, including nested bullets" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            # Template CHANGELOG with Unreleased and six standard headings (empty)
            File.write(File.join(gem_root, "CHANGELOG.md.example"), <<~MD)
              # Changelog
              \n
              ## [Unreleased]
              ### Added
              ### Changed
              ### Deprecated
              ### Removed
              ### Fixed
              ### Security
              \n
              ## [0.1.0] - 2020-01-01
              - initial
            MD

            # Create template/ entry so the template walk discovers this file
            FileUtils.mkdir_p(File.join(gem_root, "template"))
            File.write(File.join(gem_root, "template", "CHANGELOG.md.example"), "")

            # Destination project with existing Unreleased having items including nested sub-bullets
            File.write(File.join(project_root, "CHANGELOG.md"), <<~MD)
              # Changelog
              \n
              ## [Unreleased]
              ### Added
              - kettle-dev v1.1.18
              - Internal escape & unescape methods
                - Stop relying on URI / CGI for escaping and unescaping
                - They are both unstable across supported versions of Ruby (including 3.5 HEAD)
              - keep me
              ### Fixed
              - also keep me
              \n
              ## [0.0.1] - 2019-01-01
              - start
            MD

            File.write(File.join(project_root, "demo.gemspec"), "Gem::Specification.new{|s| s.name='demo'; s.homepage='https://github.com/acme/demo'}\n")
            allow(helpers).to receive_messages(project_root: project_root, template_root: gem_root, ensure_clean_git!: nil, ask: true)

            described_class.run

            result = File.read(File.join(project_root, "CHANGELOG.md"))
            # Exactly one of each standard heading under Unreleased
            %w[Added Changed Deprecated Removed Fixed Security].each do |h|
              expect(result.scan(/^### #{h}$/).size).to eq(1)
            end
            # Preserved items, including nested sub-bullets and their indentation
            expect(result).to include("### Added\n\n- kettle-dev v1.1.18")
            expect(result).to include("- Internal escape & unescape methods")
            expect(result).to include("  - Stop relying on URI / CGI for escaping and unescaping")
            expect(result).to include("  - They are both unstable across supported versions of Ruby (including 3.5 HEAD)")
            expect(result).to include("- keep me")
            expect(result).to include("### Fixed\n\n- also keep me")
          end
        end
      end

      it "ensures blank lines before and after headings in CHANGELOG.md" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            File.write(File.join(gem_root, "CHANGELOG.md.example"), <<~MD)
              # Changelog
              ## [Unreleased]
              ### Added
              ### Changed

              ## [0.1.0] - 2020-01-01
              - initial
            MD

            # Create template/ entry so the template walk discovers this file
            FileUtils.mkdir_p(File.join(gem_root, "template"))
            File.write(File.join(gem_root, "template", "CHANGELOG.md.example"), "")
            File.write(File.join(project_root, "demo.gemspec"), "Gem::Specification.new{|s| s.name='demo'; s.homepage='https://github.com/acme/demo'}\n")
            allow(helpers).to receive_messages(project_root: project_root, template_root: gem_root, ensure_clean_git!: nil, ask: true)

            described_class.run

            content = File.read(File.join(project_root, "CHANGELOG.md"))
            # Expect blank line after H1 and before the next heading
            expect(content).to match(/# Changelog\n\n## \[Unreleased\]/)
            # Expect blank line after Unreleased and before the first subheading
            expect(content).to match(/## \[Unreleased\]\n\n### Added/)
            # Expect blank line between consecutive subheadings
            expect(content).to match(/### Added\n\n### Changed/)
          end
        end
      end

      it "preserves GFM fenced code blocks nested under list items in Unreleased sections" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            # Template with empty Unreleased standard headings
            File.write(File.join(gem_root, "CHANGELOG.md.example"), <<~MD)
              # Changelog

              ## [Unreleased]
              ### Added
              ### Changed
              ### Deprecated
              ### Removed
              ### Fixed
              ### Security

              ## [0.1.0] - 2020-01-01
              - initial
            MD

            # Destination with a bullet containing a fenced code block
            File.write(File.join(project_root, "CHANGELOG.md"), <<~MD)
              # Changelog

              ## [Unreleased]
              ### Added
              - Add helper with example usage
                
                ```ruby
                puts "hello"
                1 + 2
                ```
              - Another item

              ## [0.0.1] - 2019-01-01
              - start
            MD

            File.write(File.join(project_root, "demo.gemspec"), "Gem::Specification.new{|s| s.name='demo'; s.homepage='https://github.com/acme/demo'}\n")
            allow(helpers).to receive_messages(project_root: project_root, template_root: gem_root, ensure_clean_git!: nil, ask: true)

            described_class.run

            result = File.read(File.join(project_root, "CHANGELOG.md"))
            # Ensure the fenced block and its contents are preserved under the list item
            expect(result).to include("### Added")
            expect(result).to include("- Add helper with example usage")
            expect(result).to include("```ruby")
            expect(result).to include("puts \"hello\"")
            expect(result).to include("1 + 2")
            expect(result).to include("```")
            expect(result).to include("- Another item")
          end
        end
      end

      context "with .git-hooks present" do
        it "honors only filter by skipping .git-hooks when not selected" do
          Dir.mktmpdir do |gem_root|
            Dir.mktmpdir do |project_root|
              # Arrange .git-hooks in template checkout
              hooks_src = File.join(gem_root, ".git-hooks")
              FileUtils.mkdir_p(hooks_src)
              File.write(File.join(hooks_src, "commit-subjects-goalie.txt"), "x")
              File.write(File.join(hooks_src, "footer-template.erb.txt"), "y")
              File.write(File.join(project_root, "demo.gemspec"), "Gem::Specification.new{|s| s.name='demo'; s.homepage='https://github.com/acme/demo'}\n")
              allow(helpers).to receive_messages(project_root: project_root, template_root: gem_root, ensure_clean_git!: nil, ask: true)

              # Set only to README.md, which should exclude .git-hooks completely
              stub_env("only" => "README.md")
              # If code ignores only for hooks, it would prompt; ensure no blocking by pre-answering
              allow(Kettle::Dev::InputAdapter).to receive(:gets).and_return("")

              described_class.run
              expect(File).not_to exist(File.join(project_root, ".git-hooks", "commit-subjects-goalie.txt"))
              expect(File).not_to exist(File.join(project_root, ".git-hooks", "footer-template.erb.txt"))
            end
          end
        end

        it "copies templates when only includes .git-hooks/**", :check_output do
          Dir.mktmpdir do |gem_root|
            Dir.mktmpdir do |project_root|
              hooks_src = File.join(gem_root, ".git-hooks")
              FileUtils.mkdir_p(hooks_src)
              File.write(File.join(hooks_src, "commit-subjects-goalie.txt"), "x")
              File.write(File.join(hooks_src, "footer-template.erb.txt"), "y")
              File.write(File.join(project_root, "demo.gemspec"), "Gem::Specification.new{|s| s.name='demo'; s.homepage='https://github.com/acme/demo'}\n")
              allow(helpers).to receive_messages(project_root: project_root, template_root: gem_root, ensure_clean_git!: nil, ask: true)
              stub_env("only" => ".git-hooks/**")
              allow(Kettle::Dev::InputAdapter).to receive(:gets).and_return("")
              described_class.run
              expect(File).to exist(File.join(project_root, ".git-hooks", "commit-subjects-goalie.txt"))
              expect(File).to exist(File.join(project_root, ".git-hooks", "footer-template.erb.txt"))
            end
          end
        end

        it "copies templates locally by default", :check_output do
          Dir.mktmpdir do |gem_root|
            Dir.mktmpdir do |project_root|
              hooks_src = File.join(gem_root, ".git-hooks")
              FileUtils.mkdir_p(hooks_src)
              File.write(File.join(hooks_src, "commit-subjects-goalie.txt"), "x")
              File.write(File.join(hooks_src, "footer-template.erb.txt"), "y")
              File.write(File.join(project_root, "demo.gemspec"), "Gem::Specification.new{|s| s.name='demo'; s.homepage='https://github.com/acme/demo'}\n")
              allow(helpers).to receive_messages(project_root: project_root, template_root: gem_root, ensure_clean_git!: nil, ask: true)
              allow(Kettle::Dev::InputAdapter).to receive(:gets).and_return("")
              described_class.run
              expect(File).to exist(File.join(project_root, ".git-hooks", "commit-subjects-goalie.txt"))
            end
          end
        end

        it "does not prompt for hook template destination in force mode", :check_output do
          Dir.mktmpdir do |gem_root|
            Dir.mktmpdir do |project_root|
              hooks_src = File.join(gem_root, ".git-hooks")
              FileUtils.mkdir_p(hooks_src)
              File.write(File.join(hooks_src, "commit-subjects-goalie.txt"), "x")
              File.write(File.join(hooks_src, "footer-template.erb.txt"), "y")
              File.write(File.join(project_root, ".kettle-jem.yml"), <<~YAML)
                defaults:
                  preference: template
                  add_template_only_nodes: true
                  freeze_token: kettle-jem
                tokens:
                  forge:
                    gh_user: ""
                patterns: []
                files: {}
              YAML
              File.write(File.join(project_root, "demo.gemspec"), <<~GEMSPEC)
                Gem::Specification.new do |spec|
                  spec.name = "demo"
                  spec.version = "0.1.0"
                  spec.summary = "test"
                  spec.authors = ["Test User"]
                  spec.email = ["test@example.com"]
                  spec.required_ruby_version = ">= 3.1"
                  spec.homepage = "https://github.com/acme/demo"
                end
              GEMSPEC
              allow(helpers).to receive_messages(project_root: project_root, template_root: gem_root, ensure_clean_git!: nil, ask: true)
              stub_env("force" => "true")
              expect(Kettle::Dev::InputAdapter).not_to receive(:gets)

              described_class.run

              expect(File).to exist(File.join(project_root, ".git-hooks", "commit-subjects-goalie.txt"))
              expect(File).to exist(File.join(project_root, ".git-hooks", "footer-template.erb.txt"))
            end
          end
        end

        it "skips copying templates when user chooses 's'", :check_output do
          Dir.mktmpdir do |gem_root|
            Dir.mktmpdir do |project_root|
              hooks_src = File.join(gem_root, ".git-hooks")
              FileUtils.mkdir_p(hooks_src)
              File.write(File.join(hooks_src, "commit-subjects-goalie.txt"), "x")
              File.write(File.join(hooks_src, "footer-template.erb.txt"), "y")
              File.write(File.join(project_root, "demo.gemspec"), "Gem::Specification.new{|s| s.name='demo'; s.homepage='https://github.com/acme/demo'}\n")
              allow(helpers).to receive_messages(project_root: project_root, template_root: gem_root, ensure_clean_git!: nil, ask: true)
              allow(Kettle::Dev::InputAdapter).to receive(:gets).and_return("s\n")
              described_class.run
              expect(File).not_to exist(File.join(project_root, ".git-hooks", "commit-subjects-goalie.txt"))
            end
          end
        end

        it "installs hook scripts; overwrite yes/no and fresh install", :check_output do
          Dir.mktmpdir do |gem_root|
            Dir.mktmpdir do |project_root|
              hooks_src = File.join(gem_root, ".git-hooks")
              FileUtils.mkdir_p(hooks_src)
              File.write(File.join(hooks_src, "commit-msg"), "echo ruby hook\n")
              File.write(File.join(hooks_src, "prepare-commit-msg"), "echo sh hook\n")
              File.write(File.join(project_root, "demo.gemspec"), "Gem::Specification.new{|s| s.name='demo'; s.homepage='https://github.com/acme/demo'}\n")
              allow(helpers).to receive_messages(project_root: project_root, template_root: gem_root, ensure_clean_git!: nil, ask: true)

              # Force templates conditional to false
              allow(Dir).to receive(:exist?).and_call_original
              allow(Dir).to receive(:exist?).with(File.join(gem_root, ".git-hooks")).and_return(true)
              allow(File).to receive(:file?).and_call_original
              allow(File).to receive(:file?).with(File.join(gem_root, ".git-hooks", "commit-subjects-goalie.txt")).and_return(false)
              allow(File).to receive(:file?).with(File.join(gem_root, ".git-hooks", "footer-template.erb.txt")).and_return(false)

              # First run installs
              described_class.run
              dest_dir = File.join(project_root, ".git-hooks")
              commit_hook = File.join(dest_dir, "commit-msg")
              prepare_hook = File.join(dest_dir, "prepare-commit-msg")
              expect(File).to exist(commit_hook)
              expect(File).to exist(prepare_hook)
              expect(File.executable?(commit_hook)).to be(true)
              expect(File.executable?(prepare_hook)).to be(true)

              # Overwrite yes
              allow(helpers).to receive(:ask).and_return(true)
              described_class.run
              expect(File.executable?(commit_hook)).to be(true)
              expect(File.executable?(prepare_hook)).to be(true)
              # Overwrite no
              allow(helpers).to receive(:ask).and_return(false)
              described_class.run
              expect(File.executable?(commit_hook)).to be(true)
              expect(File.executable?(prepare_hook)).to be(true)
            end
          end
        end

        it "keeps commit-msg syntactically valid by accepting the template when configured" do
          Dir.mktmpdir do |gem_root|
            Dir.mktmpdir do |project_root|
              template_root = File.join(gem_root, "template")
              hooks_src = File.join(template_root, ".git-hooks")
              FileUtils.mkdir_p(hooks_src)

              hook_template = <<~RUBY
                #!/usr/bin/env ruby
                begin
                  denied = <<~EOM
                    hello
                  EOM
                  puts denied
                rescue LoadError => e
                  warn(e.message)
                end
              RUBY
              File.write(File.join(hooks_src, "commit-msg.example"), hook_template)

              File.write(File.join(project_root, ".kettle-jem.yml"), <<~YAML)
                defaults:
                  preference: template
                  add_template_only_nodes: true
                  freeze_token: kettle-jem
                patterns: []
                files:
                  ".git-hooks":
                    commit-msg:
                      strategy: accept_template
                      file_type: ruby
              YAML

              FileUtils.mkdir_p(File.join(project_root, ".git-hooks"))
              File.write(File.join(project_root, ".git-hooks", "commit-msg"), <<~BROKEN)
                #!/usr/bin/env ruby
                begin
                  denied = <<~EOM
                    broken
                rescue LoadError => e
                  warn(e.message)
                end
              BROKEN

              File.write(File.join(project_root, "demo.gemspec"), <<~GEMSPEC)
                Gem::Specification.new do |spec|
                  spec.name = "demo"
                  spec.version = "0.1.0"
                  spec.summary = "test"
                  spec.authors = ["Test User"]
                  spec.email = ["test@example.com"]
                  spec.required_ruby_version = ">= 3.1"
                  spec.homepage = "https://github.com/acme/demo"
                end
              GEMSPEC

              allow(helpers).to receive_messages(
                project_root: project_root,
                template_root: template_root,
                ensure_clean_git!: nil,
                ask: true,
              )

              described_class.run

              result = File.read(File.join(project_root, ".git-hooks", "commit-msg"))
              expect(result).to eq(hook_template)
              expect(Prism.parse(result).errors).to be_empty
            end
          end
        end

        it "prefers prepare-commit-msg.example over prepare-commit-msg when both exist" do
          Dir.mktmpdir do |gem_root|
            Dir.mktmpdir do |project_root|
              hooks_src = File.join(gem_root, ".git-hooks")
              FileUtils.mkdir_p(hooks_src)
              # Provide both real and example; example should be preferred
              File.write(File.join(hooks_src, "prepare-commit-msg"), "REAL\n")
              File.write(File.join(hooks_src, "prepare-commit-msg.example"), "EXAMPLE\n")
              # Commit hook presence isn't required for this behavior, but include to mirror typical state
              File.write(File.join(hooks_src, "commit-msg"), "ruby hook\n")

              # Minimal gemspec in project for metadata
              File.write(File.join(project_root, "demo.gemspec"), "Gem::Specification.new{|s| s.name='demo'; s.homepage='https://github.com/acme/demo'}\n")

              allow(helpers).to receive_messages(project_root: project_root, template_root: gem_root, ensure_clean_git!: nil, ask: true)

              # Ensure the templates (.txt) branch does not trigger prompts/copies, to keep test focused
              allow(File).to receive(:file?).and_call_original
              allow(File).to receive(:file?).with(File.join(gem_root, ".git-hooks", "commit-subjects-goalie.txt")).and_return(false)
              allow(File).to receive(:file?).with(File.join(gem_root, ".git-hooks", "footer-template.erb.txt")).and_return(false)

              described_class.run

              dest = File.join(project_root, ".git-hooks", "prepare-commit-msg")
              expect(File).to exist(dest)
              content = File.read(dest)
              expect(content).to include("EXAMPLE")
              expect(content).not_to include("REAL")
            end
          end
        end

        it "warns when installing hook scripts raises", :check_output do
          Dir.mktmpdir do |gem_root|
            Dir.mktmpdir do |project_root|
              hooks_src = File.join(gem_root, ".git-hooks")
              FileUtils.mkdir_p(hooks_src)
              File.write(File.join(hooks_src, "commit-msg"), "echo ruby hook\n")
              File.write(File.join(project_root, "demo.gemspec"), "Gem::Specification.new{|s| s.name='demo'; s.homepage='https://github.com/acme/demo'}\n")
              allow(helpers).to receive_messages(project_root: project_root, template_root: gem_root, ensure_clean_git!: nil, ask: true)
              allow(FileUtils).to receive(:mkdir_p).and_raise(StandardError, "perm")
              expect { described_class.run }.not_to raise_error
            end
          end
        end
      end

      it "preserves nested subsections under preserved H2 sections during README merge" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            template_readme = <<~MD
              # 🚀 Template Title

              ## Synopsis
              Template synopsis.

              ## Configuration
              Template configuration.

              ## Basic Usage
              Template usage.
            MD
            File.write(File.join(gem_root, "README.md"), template_readme)

            existing_readme = <<~MD
              # 🎉 Existing Title

              ## Synopsis
              Existing synopsis intro.

              ### Details
              Keep this nested detail.

              #### More
              And this deeper detail.

              ## Configuration
              Existing configuration.

              ## Basic Usage
              Existing usage.
            MD
            File.write(File.join(project_root, "README.md"), existing_readme)

            File.write(File.join(project_root, "demo.gemspec"), <<~GEMSPEC)
              Gem::Specification.new do |spec|
                spec.name = "demo"
                spec.version = "0.1.0"
                spec.summary = "test gem"
                spec.authors = ["Test"]
                spec.required_ruby_version = ">= 3.1"
                spec.homepage = "https://github.com/acme/demo"
              end
            GEMSPEC

            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: File.join(gem_root, "template"),
              ensure_clean_git!: nil,
              ask: true,
            )

            described_class.run

            merged = File.read(File.join(project_root, "README.md"))
            # H1 emoji preserved
            expect(merged.lines.first).to match(/^#\s+🎉\s+Existing Title/)
            # Preserved H2 branch content
            expect(merged).to include("Existing synopsis intro.")
            expect(merged).to include("### Details")
            expect(merged).to include("Keep this nested detail.")
            expect(merged).to include("#### More")
            expect(merged).to include("And this deeper detail.")
            # Other targeted sections still merged
            expect(merged).to include("Existing configuration.")
            expect(merged).to include("Existing usage.")
          end
        end
      end

      it "does not treat # inside fenced code blocks as headings during README merge" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            template_readme = <<~MD
              # 🚀 Template Title

              ## Synopsis
              Template synopsis.

              ## Configuration
              Template configuration.

              ## Basic Usage
              Template usage.
            MD
            File.write(File.join(gem_root, "README.md"), template_readme)

            existing_readme = <<~MD
              # 🎉 Existing Title

              ## Synopsis
              Existing synopsis.

              ```console
              # DANGER: options to reduce prompts will overwrite files without asking.
              bundle exec rake kettle:dev:install allowed=true force=true
              ```

              ## Configuration
              Existing configuration.

              ## Basic Usage
              Existing usage.
            MD
            File.write(File.join(project_root, "README.md"), existing_readme)

            File.write(File.join(project_root, "demo.gemspec"), <<~GEMSPEC)
              Gem::Specification.new do |spec|
                spec.name = "demo"
                spec.version = "0.1.0"
                spec.summary = "test gem"
                spec.authors = ["Test"]
                spec.required_ruby_version = ">= 3.1"
                spec.homepage = "https://github.com/acme/demo"
              end
            GEMSPEC

            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: File.join(gem_root, "template"),
              ensure_clean_git!: nil,
              ask: true,
            )

            described_class.run

            merged = File.read(File.join(project_root, "README.md"))
            # H1 full-line preserved from existing README
            expect(merged.lines.first).to match(/^#\s+🎉\s+Existing Title/)
            # Ensure the code block remains intact and not split
            expect(merged).to include("```console")
            expect(merged).to include("# DANGER: options to reduce prompts will overwrite files without asking.")
            expect(merged).to include("bundle exec rake kettle:dev:install allowed=true force=true")
            # And targeted sections still merged with existing content
            expect(merged).to include("Existing synopsis.")
            expect(merged).to include("Existing configuration.")
            expect(merged).to include("Existing usage.")
          end
        end
      end

      it "replaces {KJ|KETTLE_DEV_GEM} token after normal replacements" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            template_root = File.join(gem_root, "template")
            FileUtils.mkdir_p(template_root)
            # Template gemspec example contains both normal tokens and the special token
            File.write(File.join(template_root, "gem.gemspec.example"), <<~GEMSPEC)
              Gem::Specification.new do |spec|
                spec.name = "{KJ|GEM_NAME}"
                # This should become the actual destination gem name via token replacement
                spec.summary = "{KJ|GEM_NAME} summary"
                # This token should resolve to the literal string "kettle-dev"
                spec.add_development_dependency("{KJ|KETTLE_DEV_GEM}", "~> 1.0.0")
              end
            GEMSPEC

            # Destination project gemspec defines gem_name and org so replacements occur
            File.write(File.join(project_root, "my-gem.gemspec"), <<~GEMSPEC)
              Gem::Specification.new do |spec|
                spec.name = "my-gem"
                spec.version = "0.1.0"
                spec.summary = "test"
                spec.authors = ["Test"]
                spec.required_ruby_version = ">= 3.1"
                spec.homepage = "https://github.com/acme/my-gem"
              end
            GEMSPEC

            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: template_root,
              ensure_clean_git!: nil,
              ask: true,
            )

            described_class.run

            dest = File.join(project_root, "my-gem.gemspec")
            expect(File).to exist(dest)
            txt = File.read(dest)
            # Token replacement happened: {KJ|GEM_NAME} became my-gem (name carried over from destination)
            expect(txt).to include('spec.name = "my-gem"')
            # No unresolved tokens remain
            expect(txt).not_to include("{KJ|")
          end
        end
      end

      it "copies Appraisal.root.gemfile with AST merge" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            template_root = File.join(gem_root, "template")
            FileUtils.mkdir_p(template_root)
            File.write(File.join(template_root, "Appraisal.root.gemfile"), <<~RUBY)
              source "https://gem.coop"
              gem "foo"
            RUBY
            File.write(File.join(template_root, "Appraisal.root.gemfile.example"), <<~RUBY)
              source "https://gem.coop"
              gem "foo"
            RUBY

            File.write(File.join(project_root, "Appraisal.root.gemfile"), <<~RUBY)
              source "https://example.com"
              gem "bar"
            RUBY
            File.write(File.join(project_root, "demo.gemspec"), <<~GEMSPEC)
              Gem::Specification.new do |spec|
                spec.name = "demo"
                spec.version = "0.1.0"
                spec.summary = "test gem"
                spec.authors = ["Test"]
                spec.required_ruby_version = ">= 3.1"
                spec.homepage = "https://github.com/acme/demo"
              end
            GEMSPEC

            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: File.join(gem_root, "template"),
              ensure_clean_git!: nil,
              ask: true,
            )
            described_class.run
            merged = File.read(File.join(project_root, "Appraisal.root.gemfile"))
            expect(merged).to include('source "https://gem.coop"')
            expect(merged).to include('gem "foo"')
            expect(merged).to include('gem "bar"')
          end
        end
      end

      it "merges Appraisals entries without losing custom appraise blocks" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            template_root = File.join(gem_root, "template")
            FileUtils.mkdir_p(template_root)
            File.write(File.join(template_root, "Appraisals"), <<~APP)
              appraise "ruby-3.1" do
                gemfile "gemfiles/ruby_3.1.gemfile"
              end
            APP
            File.write(File.join(template_root, "Appraisals.example"), <<~APP)
              appraise "ruby-3.1" do
                gemfile "gemfiles/ruby_3.1.gemfile"
              end
            APP

            File.write(File.join(project_root, "Appraisals"), <<~APP)
              appraise "ruby-3.0" do
                gemfile "gemfiles/ruby_3.0.gemfile"
              end
            APP
            File.write(File.join(project_root, "demo.gemspec"), <<~G)
              Gem::Specification.new do |spec|
                spec.name = "demo"
                spec.version = "0.1.0"
                spec.summary = "test gem"
                spec.authors = ["Test"]
                spec.required_ruby_version = ">= 3.1"
                spec.homepage = "https://github.com/acme/demo"
              end
            G
            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: File.join(gem_root, "template"),
              ensure_clean_git!: nil,
              ask: true,
            )
            described_class.run
            merged = File.read(File.join(project_root, "Appraisals"))
            expect(merged).to include('appraise "ruby-3.1"')
            expect(merged).to include('appraise "ruby-3.0"')
          end
        end
      end
    end

    describe "strategy overrides" do
      let(:helpers) { Kettle::Jem::TemplateHelpers }

      before do
        stub_env("allowed" => "true")
        stub_env("FUNDING_ORG" => "false")
      end

      it "accepts template content without merge for accept_template and preserves destination for keep_destination" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            template_root = File.join(gem_root, "template")
            FileUtils.mkdir_p(template_root)
            File.write(File.join(template_root, ".kettle-jem.yml.example"), <<~YAML)
              defaults:
                freeze_token: "kettle-jem"
              tokens:
                author:
                  name: "{KJ|AUTHOR:NAME}"
            YAML
            File.write(File.join(template_root, "README.md.example"), <<~MD)
              # {KJ|GEM_NAME}

              Template README body
            MD

            File.write(File.join(project_root, "demo.gemspec"), <<~GEMSPEC)
              Gem::Specification.new do |spec|
                spec.name = "demo"
                spec.version = "0.1.0"
                spec.summary = "test"
                spec.authors = ["Jane Doe"]
                spec.email = ["jane@example.com"]
                spec.required_ruby_version = ">= 3.1"
                spec.homepage = "https://github.com/acme/demo"
              end
            GEMSPEC

            # Stub helpers used by the task
            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: template_root,
              ensure_clean_git!: nil,
              ask: true,
            )

            # Override global funding disable for this example to allow customization
            stub_env("FUNDING_ORG" => "")

            # Exercise
            expect { described_class.run }.not_to raise_error

            # Assert
            dest_ci = File.join(project_root, ".kettle-jem.yml")
            expect(File).to exist(dest_ci)
            expect(File.read(dest_ci)).to include('name: "Jane Doe"')

            dest_readme = File.join(project_root, "README.md")
            expect(File).not_to exist(dest_readme)
          end
        end
      end

      it "does not create a missing file when strategy is keep_destination" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            template_root = File.join(gem_root, "template")
            FileUtils.mkdir_p(template_root)
            File.write(File.join(template_root, ".kettle-jem.yml.example"), <<~YAML)
              defaults:
                freeze_token: "kettle-jem"
              tokens:
                author:
                  name: "{KJ|AUTHOR:NAME}"
            YAML
            File.write(File.join(project_root, ".kettle-jem.yml"), <<~YAML)
              # Header comment
              defaults:
                freeze_token: "destination-token"

              # Token section comment
              tokens:
                author:
                  name: "Custom Author"

              # Patterns section comment
              patterns:
                - path: "certs/**"
                  strategy: raw_copy

              # Files section comment
              files: {}
            YAML
            File.write(File.join(project_root, "demo.gemspec"), <<~GEMSPEC)
              Gem::Specification.new do |spec|
                spec.name = "demo"
                spec.version = "0.1.0"
                spec.summary = "test"
                spec.authors = ["Jane Marie Doe"]
                spec.email = ["jane@example.com"]
                spec.required_ruby_version = ">= 3.1"
                spec.homepage = "https://github.com/acme/demo"
              end
            GEMSPEC

            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: template_root,
              ensure_clean_git!: nil,
              ask: true,
            )

            expect { described_class.run }.not_to raise_error

            content = File.read(File.join(project_root, ".kettle-jem.yml"))
            expect(content).to include('freeze_token: "destination-token"')
            expect(content).to include('name: "Custom Author"')
          end
        end
      end
    end
  end

  # Consolidated from template_task_carryover_spec.rb and template_task_env_spec.rb
  describe "carryover/env behaviors" do
    let(:helpers) { Kettle::Jem::TemplateHelpers }

    describe "carryover of gemspec fields" do
      before { stub_env("allowed" => "true") }

      it "carries over key fields from original gemspec when overwriting with example (after replacements)" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            template_root = File.join(gem_root, "template")
            FileUtils.mkdir_p(template_root)
            File.write(File.join(template_root, "gem.gemspec.example"), <<~GEMSPEC)
              Gem::Specification.new do |spec|
                spec.name = "kettle-dev"
                spec.version = "1.0.0"
                spec.authors = ["Template Author"]
                spec.email = ["template@example.com"]
                spec.summary = "🍲 Template summary"
                spec.description = "🍲 Template description"
                spec.license = "MIT"
                spec.required_ruby_version = ">= 2.3.0"
                spec.require_paths = ["lib"]
                spec.bindir = "exe"
                spec.executables = ["templ"]
                Kettle::Dev
              end
            GEMSPEC

            File.write(File.join(project_root, "my-gem.gemspec"), <<~GEMSPEC)
              Gem::Specification.new do |spec|
                spec.name = "my-gem"
                spec.version = "0.1.0"
                spec.authors = ["Alice", "Bob"]
                spec.email = ["alice@example.com"]
                spec.summary = "Original summary"
                spec.description = "Original description more text"
                spec.license = "Apache-2.0"
                spec.required_ruby_version = ">= 3.2"
                spec.require_paths = ["lib", "ext"]
                spec.bindir = "bin"
                spec.executables = ["mygem", "mg"]
                spec.homepage = "https://github.com/acme/my-gem"
              end
            GEMSPEC

            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: template_root,
              ensure_clean_git!: nil,
              ask: true,
            )

            described_class.run

            dest = File.join(project_root, "my-gem.gemspec")
            txt = File.read(dest)
            expect(txt).to match(/spec\.name\s*=\s*\"my-gem\"/)
            # After Prism merge, destination fields are carried over (destination preference)
            expect(txt).to include("Alice")
            expect(txt).to include("Bob")
            expect(txt).to include("alice@example.com")
            expect(txt).to include("Original summary")
            expect(txt).to include("Original description more text")
          end
        end
      end
    end
  end

  describe "CHANGELOG default spacing regression" do
    let(:helpers) { Kettle::Jem::TemplateHelpers }

    before do
      stub_env("allowed" => "true")
      stub_env("FUNDING_ORG" => "false")
    end

    it "ensures a blank line exists between Unreleased chunk and first released version when using DEFAULT_CHANGELOG.md" do
      Dir.mktmpdir do |gem_root|
        Dir.mktmpdir do |project_root|
          template_root = File.join(gem_root, "template")
          FileUtils.mkdir_p(template_root)
          # Use the DEFAULT_CHANGELOG.md fixture as the template CHANGELOG
          fixture_path = File.join(__dir__, "..", "..", "..", "fixtures", "DEFAULT_CHANGELOG.md")
          default_changelog = if File.file?(fixture_path)
            content = File.read(fixture_path)
            content.strip.empty? ? nil : content
          end
          default_changelog ||= <<~MD
            # Changelog

            ## [Unreleased]
            ### Added
            ### Changed
            ### Deprecated
            ### Removed
            ### Fixed
            ### Security

            ## [0.1.0] - 2025-09-13
            - Initial release
          MD
          # Template CHANGELOG provides only header and Unreleased skeleton
          template_changelog = <<~MD
            # Changelog

            ## [Unreleased]
            ### Added
            ### Changed
            ### Deprecated
            ### Removed
            ### Fixed
            ### Security
          MD
          File.write(File.join(template_root, "CHANGELOG.md.example"), template_changelog)

          # Destination project already has a default CHANGELOG (from bundle gem)
          File.write(File.join(project_root, "CHANGELOG.md"), default_changelog)

          # Minimal gemspec so metadata scanning works and replacements happen
          File.write(File.join(project_root, "my-gem.gemspec"), <<~GEMSPEC)
            Gem::Specification.new do |spec|
              spec.name = "my-gem"
              spec.version = "0.1.0"
              spec.summary = "test gem"
              spec.authors = ["Test"]
              spec.required_ruby_version = ">= 3.1"
              spec.homepage = "https://github.com/acme/my-gem"
            end
          GEMSPEC

          allow(helpers).to receive_messages(project_root: project_root, template_root: template_root, ensure_clean_git!: nil, ask: true)

          described_class.run

          result = File.read(File.join(project_root, "CHANGELOG.md"))
          # There must be exactly one blank line between the Unreleased section and the next version chunk
          # Specifically, ensure a blank line before the first numbered version header following Unreleased
          expect(result).to match(/## \[Unreleased\](?:.|\n)*?### Security\n\n## \[/)
        end
      end
    end
  end

  describe "::run prefers .junie/guidelines.md.example" do
    let(:helpers) { Kettle::Jem::TemplateHelpers }

    before do
      stub_env("allowed" => "true")
      stub_env("FUNDING_ORG" => "false")
    end

    it "copies .junie/guidelines.md from the .example source when both exist" do
      Dir.mktmpdir do |gem_root|
        Dir.mktmpdir do |project_root|
          template_root = File.join(gem_root, "template")
          # Arrange template files under template_root
          template_junie = File.join(template_root, ".junie")
          FileUtils.mkdir_p(template_junie)
          File.write(File.join(template_junie, "guidelines.md"), "REAL-GUIDELINES\n")
          File.write(File.join(template_junie, "guidelines.md.example"), "EXAMPLE-GUIDELINES\n")

          # Minimal gemspec so metadata scan works
          File.write(File.join(project_root, "demo.gemspec"), <<~GEMSPEC)
            Gem::Specification.new do |spec|
              spec.name = "demo"
              spec.version = "0.1.0"
              spec.summary = "test"
              spec.authors = ["Test"]
              spec.required_ruby_version = ">= 3.1"
              spec.homepage = "https://github.com/acme/demo"
            end
          GEMSPEC

          allow(helpers).to receive_messages(
            project_root: project_root,
            template_root: template_root,
            ensure_clean_git!: nil,
            ask: true,
          )

          expect { described_class.run }.not_to raise_error

          dest = File.join(project_root, ".junie", "guidelines.md")
          expect(File).to exist(dest)
          content = File.read(dest)
          expect(content).to include("EXAMPLE-GUIDELINES")
          expect(content).not_to include("REAL-GUIDELINES")
        end
      end
    end
  end

  describe "merging behaviors" do
    let(:helpers) { Kettle::Jem::TemplateHelpers }

    before do
      stub_env("allowed" => "true")
      stub_env("FUNDING_ORG" => "false")
    end

    it "merges modular coverage gemfile content with existing custom entries" do
      Dir.mktmpdir do |gem_root|
        Dir.mktmpdir do |project_root|
          template_dir = File.join(gem_root, "template", "gemfiles", "modular")
          FileUtils.mkdir_p(template_dir)
          File.write(File.join(template_dir, "coverage.gemfile"), <<~GEMFILE)
            source "https://gem.coop"
            gem "simplecov", "~> 0.22"
          GEMFILE
          dest_dir = File.join(project_root, "gemfiles", "modular")
          FileUtils.mkdir_p(dest_dir)
          File.write(File.join(dest_dir, "coverage.gemfile"), <<~GEMFILE)
            # keep this comment
            gem "custom-coverage", "~> 1.0"
          GEMFILE

          File.write(File.join(project_root, "demo.gemspec"), <<~GEMSPEC)
            Gem::Specification.new do |spec|
              spec.name = "demo"
              spec.version = "0.1.0"
              spec.summary = "test gem"
              spec.authors = ["Test"]
              spec.required_ruby_version = ">= 3.1"
              spec.homepage = "https://github.com/acme/demo"
            end
          GEMSPEC

          allow(helpers).to receive_messages(
            project_root: project_root,
            template_root: File.join(gem_root, "template"),
            ensure_clean_git!: nil,
            ask: true,
          )
          described_class.run
          merged = File.read(File.join(dest_dir, "coverage.gemfile"))
          expect(merged).to include("# keep this comment")
          expect(merged).to include('gem "custom-coverage", "~> 1.0"')
          expect(merged).to include('gem "simplecov", "~> 0.22"')
        end
      end
    end

    it "merges existing style.gemfile content while updating rubocop tokens" do
      Dir.mktmpdir do |gem_root|
        Dir.mktmpdir do |project_root|
          template_dir = File.join(gem_root, "template", "gemfiles", "modular")
          FileUtils.mkdir_p(template_dir)
          File.write(File.join(template_dir, "style.gemfile.example"), <<~GEMFILE)
            gem "rubocop-lts", "{KJ|RUBOCOP_LTS_CONSTRAINT}"
            gem "{KJ|RUBOCOP_RUBY_GEM}"
          GEMFILE
          dest_dir = File.join(project_root, "gemfiles", "modular")
          FileUtils.mkdir_p(dest_dir)
          File.write(File.join(dest_dir, "style.gemfile"), <<~GEMFILE)
            # existing customization
            gem "my-company-style"
          GEMFILE

          File.write(File.join(project_root, "demo.gemspec"), <<~G)
            Gem::Specification.new do |spec|
              spec.name = "demo"
              spec.version = "0.1.0"
              spec.summary = "test gem"
              spec.authors = ["Test"]
              spec.required_ruby_version = ">= 3.2"
              spec.homepage = "https://github.com/acme/demo"
            end
          G
          allow(helpers).to receive_messages(
            project_root: project_root,
            template_root: File.join(gem_root, "template"),
            ensure_clean_git!: nil,
            ask: true,
          )
          described_class.run
          merged = File.read(File.join(dest_dir, "style.gemfile"))
          expect(merged).to include("# existing customization")
          expect(merged).to include('gem "my-company-style"')
          expect(merged).to include('gem "rubocop-lts", "~> 24.0"')
          expect(merged).to include('gem "rubocop-ruby3_2"')
        end
      end
    end

    describe "merge_by_file_type in step 7" do
      it "merges a Ruby file (Rakefile) with the destination via prism-merge" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            template_root = File.join(gem_root, "template")
            FileUtils.mkdir_p(template_root)

            # Template Rakefile
            File.write(File.join(template_root, "Rakefile.example"), <<~RUBY)
              # frozen_string_literal: true

              require "bundler/gem_tasks"
              require "rspec/core/rake_task"

              RSpec::Core::RakeTask.new(:spec)
            RUBY

            # Existing destination Rakefile with custom task
            File.write(File.join(project_root, "Rakefile"), <<~RUBY)
              # frozen_string_literal: true

              require "bundler/gem_tasks"

              task :custom do
                puts "custom"
              end
            RUBY

            File.write(File.join(project_root, "demo.gemspec"), <<~GEMSPEC)
              Gem::Specification.new do |spec|
                spec.name = "demo"
                spec.version = "0.1.0"
                spec.summary = "test gem"
                spec.authors = ["Test"]
                spec.required_ruby_version = ">= 3.1"
                spec.homepage = "https://github.com/acme/demo"
              end
            GEMSPEC

            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: File.join(gem_root, "template"),
              ensure_clean_git!: nil,
              ask: true,
            )
            described_class.run

            result = File.read(File.join(project_root, "Rakefile"))
            # Should retain destination custom task
            expect(result).to include("custom")
            # Should include template additions
            expect(result).to include("rspec")
          end
        end
      end

      it "merges a YAML file (.rubocop.yml) with the destination via psych-merge" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            template_root = File.join(gem_root, "template")
            FileUtils.mkdir_p(template_root)

            File.write(File.join(template_root, ".rubocop.yml.example"), <<~YAML)
              AllCops:
                TargetRubyVersion: 3.1
                NewCops: enable
            YAML

            # Existing destination with custom cop
            File.write(File.join(project_root, ".rubocop.yml"), <<~YAML)
              AllCops:
                TargetRubyVersion: 3.2
              Metrics/MethodLength:
                Max: 20
            YAML

            File.write(File.join(project_root, "demo.gemspec"), <<~GEMSPEC)
              Gem::Specification.new do |spec|
                spec.name = "demo"
                spec.version = "0.1.0"
                spec.summary = "test gem"
                spec.authors = ["Test"]
                spec.required_ruby_version = ">= 3.1"
                spec.homepage = "https://github.com/acme/demo"
              end
            GEMSPEC

            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: File.join(gem_root, "template"),
              ensure_clean_git!: nil,
              ask: true,
            )
            described_class.run

            result = File.read(File.join(project_root, ".rubocop.yml"))
            # Should retain destination customization
            expect(result).to include("Metrics/MethodLength")
          end
        end
      end

      it "does not preserve redundant duplicate YAML entries from the destination" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            template_root = File.join(gem_root, "template")
            FileUtils.mkdir_p(template_root)

            File.write(File.join(template_root, ".rubocop.yml.example"), <<~YAML)
              Layout/IndentationConsistency:
                Exclude: ['*.md']
            YAML

            File.write(File.join(project_root, ".rubocop.yml"), <<~YAML)
              Layout/IndentationConsistency:
                Exclude: ['*.md']
                Exclude: ['*.md']
            YAML

            File.write(File.join(project_root, "demo.gemspec"), <<~GEMSPEC)
              Gem::Specification.new do |spec|
                spec.name = "demo"
                spec.version = "0.1.0"
                spec.summary = "test gem"
                spec.authors = ["Test"]
                spec.required_ruby_version = ">= 3.1"
                spec.homepage = "https://github.com/acme/demo"
              end
            GEMSPEC

            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: File.join(gem_root, "template"),
              ensure_clean_git!: nil,
              ask: true,
            )
            described_class.run

            result = File.read(File.join(project_root, ".rubocop.yml"))

            expect(result).to eq(<<~YAML)
              Layout/IndentationConsistency:
                Exclude: ['*.md']
            YAML
            expect(result.scan("Exclude: ['*.md']").size).to eq(1)
          end
        end
      end

      it "merges a text file (.gitignore) with the destination via text-merge" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            template_root = File.join(gem_root, "template")
            FileUtils.mkdir_p(template_root)

            File.write(File.join(template_root, ".gitignore.example"), <<~GITIGNORE)
              *.gem
              /pkg/
              /tmp/*
              !/tmp/.gitignore
            GITIGNORE
            File.write(File.join(project_root, ".gitignore"), "*.gem\nvendor/\nmy_custom_dir/\n")

            File.write(File.join(project_root, "demo.gemspec"), <<~GEMSPEC)
              Gem::Specification.new do |spec|
                spec.name = "demo"
                spec.version = "0.1.0"
                spec.summary = "test gem"
                spec.authors = ["Test"]
                spec.required_ruby_version = ">= 3.1"
                spec.homepage = "https://github.com/acme/demo"
              end
            GEMSPEC

            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: template_root,
              ensure_clean_git!: nil,
              ask: true,
            )
            described_class.run

            result = File.read(File.join(project_root, ".gitignore"))
            expect(result).to include("/tmp/*")
            expect(result).to include("!/tmp/.gitignore")
            expect(result).to include("my_custom_dir/")
          end
        end
      end

      it "does not append a duplicate template paragraph when AGENTS.md contains a malformed near-match paragraph" do
        Dir.mktmpdir do |dir|
          dest = File.join(dir, "AGENTS.md")
          File.write(dest, <<~MARKDOWN)
            # AGENTS.md - kettle-jem Development Guide

            ## 🎯 Project Overview

            `kettle-jem` is a collection of merge presets and utilities for gem templating.

            This project is a **RubyGem** managed with the [kettle-rb](https://github.com/kettle-rb) toolchain.
            **Minimum Supported Ruby**: See the gemspec `required_ruby_version` constraint.
            **Local Development Ruby**: See `.tool-versions` for the version used in local development (typically the latest stable Ruby).
            **CRITICAL**: The canonical project environment lives in `mise.toml`, with local overrides in `.env.local` loaded via `dotenvy`.
            **Recovery rule**: If a `mise exec` command goes silent or appears hung, assume `mise trust` is the first thing to check. Recover by running:
            Gemfiles are split into modular components under `gemfiles/modular/`. Each component handles a specific concern (coverage, style, debug, etc.). The main `Gemfile` loads these modular components via `eval_gemfile`.
            **CRITICAL**: All constructors and public API methods that accept keyword arguments MUST include `**options` as the final parameter for forward compatibility.
          MARKDOWN

          template = <<~MARKDOWN
            # AGENTS.md - Development Guide

            ## 🎯 Project Overview

            This project is a **RubyGem** managed with the [kettle-rb](https://github.com/kettle-rb) toolchain.
            **Minimum Supported Ruby**: See the gemspec `required_ruby_version` constraint.
            **Local Development Ruby**: See `.tool-versions` for the version used in local development (typically the latest stable Ruby).

            ## ⚠️ AI Agent Terminal Limitations

            ### Use `mise` for Project Environment

            **CRITICAL**: The canonical project environment lives in `mise.toml`, with local overrides in `.env.local` loaded via `dotenvy`.

            **Recovery rule**: If a `mise exec` command goes silent or appears hung, assume `mise trust` is the first thing to check. Recover by running:

            ## 📝 Project Conventions

            ### Modular Gemfile Architecture

            Gemfiles are split into modular components under `gemfiles/modular/`. Each component handles a specific concern (coverage, style, debug, etc.). The main `Gemfile` loads these modular components via `eval_gemfile`.

            ### Forward Compatibility with `**options`

            **CRITICAL**: All constructors and public API methods that accept keyword arguments MUST include `**options` as the final parameter for forward compatibility.
          MARKDOWN

          result = described_class.merge_by_file_type(template, dest, "AGENTS.md", Kettle::Jem::TemplateHelpers)
          tail = result.lines.last(6).join

          expect(result.scan("This project is a **RubyGem** managed with the [kettle-rb]").size).to eq(1)
          expect(tail).not_to include("This project is a **RubyGem**")
          expect(tail).not_to include("**CRITICAL**: The canonical project environment lives")
          expect(tail).not_to include("**Recovery rule**:")
          expect(result).to include("### Modular Gemfile Architecture")
        end
      end

      it "keeps AGENTS development workflow updates in-place instead of mismatching and appending them" do
        Dir.mktmpdir do |dir|
          dest = File.join(dir, "AGENTS.md")
          File.write(dest, <<~MARKDOWN)
            # AGENTS.md - Development Guide

            ## 🔧 Development Workflows

            ### Running Tests

            ```bash
            mise exec -C /path/to/project -- bundle exec rspec
            ```

            Single file (disable coverage threshold):
            ```bash
            mise exec -C /path/to/project -- env K_SOUP_COV_MIN_HARD=false bundle exec rspec spec/path/to/spec.rb
            ```

            ### Coverage Reports

            ```bash
            mise exec -C /path/to/project -- bin/rake coverage
            ```

            ## 🚫 Common Pitfalls

            1. Keep commands self-contained.
          MARKDOWN

          template = <<~MARKDOWN
            # AGENTS.md - Development Guide

            ## 🔧 Development Workflows

            ### Running Commands

            Always make commands self-contained. Use `mise exec -C /home/pboling/src/kettle-rb/prism-merge -- ...` so the command gets the project environment in the same invocation.

            ### Running Tests

            Full suite spec runs:

            ```bash
            mise exec -C /path/to/project -- bundle exec rspec
            ```

            For single file, targeted, or partial spec runs the coverage threshold **must** be disabled.
            Use the `K_SOUP_COV_MIN_HARD=false` environment variable to disable hard failure:

            ```bash
            mise exec -C /path/to/project -- env K_SOUP_COV_MIN_HARD=false bundle exec rspec spec/path/to/spec.rb
            ```

            ### Coverage Reports

            ```bash
            mise exec -C /path/to/project -- bin/rake coverage
            ```

            ## 🚫 Common Pitfalls

            1. Keep commands self-contained.
          MARKDOWN

          result = described_class.merge_by_file_type(template, dest, "AGENTS.md", Kettle::Jem::TemplateHelpers)

          workflows = result[/## 🔧 Development Workflows.*?(?=## 🚫 Common Pitfalls)/m]
          tail = result.lines.last(8).join

          expect(workflows).to include("### Running Commands")
          expect(workflows).to include("Full suite spec runs:")
          expect(workflows).to include("For single file, targeted, or partial spec runs")
          expect(workflows).not_to include("Single file (disable coverage threshold):")
          expect(tail).not_to include("### Running Commands")
          expect(tail).not_to include("For single file, targeted, or partial spec runs")
        end
      end
    end

    describe "AGENTS template content" do
      it "avoids repeated trust and test-output guidance in the template source" do
        template_path = File.expand_path("../../../../template/AGENTS.md.example", __dir__)
        template = File.read(template_path)

        expect(template.scan("mise trust -C /path/to/project").size).to eq(1)
        expect(template.scan("head`/`tail").size).to eq(1)
      end
    end
  end

  describe "failure_mode" do
    let(:helpers) { Kettle::Jem::TemplateHelpers }

    before do
      stub_env("allowed" => "true")
      stub_env("FUNDING_ORG" => "false")
    end

    it "defaults to :error" do
      stub_env("FAILURE_MODE" => nil)
      expect(described_class.failure_mode).to eq(:error)
    end

    it "returns :error when ENV is 'error'" do
      stub_env("FAILURE_MODE" => "error")
      expect(described_class.failure_mode).to eq(:error)
    end

    it "returns :rescue when ENV is 'rescue'" do
      stub_env("FAILURE_MODE" => "rescue")
      expect(described_class.failure_mode).to eq(:rescue)
    end

    it "returns :error for unrecognized values" do
      stub_env("FAILURE_MODE" => "bogus")
      expect(described_class.failure_mode).to eq(:error)
    end

    context "when merge fails in error mode (default)" do
      it "raises Kettle::Dev::Error from merge_by_file_type" do
        Dir.mktmpdir do |dir|
          stub_env("FAILURE_MODE" => "error")

          dest = File.join(dir, "broken.rb")
          File.write(dest, "valid ruby\n")

          # Force a merge failure by stubbing apply_strategy to raise
          h = Kettle::Jem::TemplateHelpers
          allow(h).to receive(:ruby_template?).and_return(true)
          allow(h).to receive(:apply_strategy).and_raise(RuntimeError, "merge boom")

          expect {
            described_class.merge_by_file_type("template content", dest, "broken.rb", h)
          }.to raise_error(Kettle::Dev::Error, /Merge failed for broken\.rb.*merge boom/)
        end
      end
    end

    context "when merge fails in rescue mode" do
      it "returns original content from merge_by_file_type" do
        Dir.mktmpdir do |dir|
          stub_env("FAILURE_MODE" => "rescue")

          dest = File.join(dir, "broken.rb")
          File.write(dest, "valid ruby\n")

          h = Kettle::Jem::TemplateHelpers
          allow(h).to receive(:ruby_template?).and_return(true)
          allow(h).to receive(:apply_strategy).and_raise(RuntimeError, "merge boom")

          result = described_class.merge_by_file_type("template content", dest, "broken.rb", h)
          expect(result).to eq("template content")
        end
      end
    end

    context "when FAILURE_MODE=error during full run" do
      it "raises when step 7 merge fails on a file" do
        Dir.mktmpdir do |gem_root|
          Dir.mktmpdir do |project_root|
            stub_env("FAILURE_MODE" => "error")

            template_root = File.join(gem_root, "template")
            FileUtils.mkdir_p(template_root)

            # A YAML file that will trigger psych-merge
            File.write(File.join(template_root, "config.yml.example"), "key: value\n")
            # Destination has invalid YAML to trigger a merge failure
            File.write(File.join(project_root, "config.yml"), ":\n  bad:\n- yaml: [\n")

            File.write(File.join(project_root, "demo.gemspec"), <<~GEMSPEC)
              Gem::Specification.new do |spec|
                spec.name = "demo"
                spec.version = "0.1.0"
                spec.summary = "test gem"
                spec.authors = ["Test"]
                spec.required_ruby_version = ">= 3.1"
                spec.homepage = "https://github.com/acme/demo"
              end
            GEMSPEC

            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: template_root,
              ensure_clean_git!: nil,
              ask: true,
            )

            # The outer rescue in step 7 catches and reports the error,
            # so the run itself prints a WARNING but doesn't abort the entire task.
            # However, the merge_by_file_type will raise, and the step 7
            # rescue will catch it and print the warning.
            expect { described_class.run }.not_to raise_error
          end
        end
      end
    end
  end

  describe "Kettle::Jem::Tasks::TemplateTask::CONFIG_FILE merging", :config_file do
    let(:helpers) { Kettle::Jem::TemplateHelpers }

    before do
      stub_env("allowed" => "true")
      stub_env("FUNDING_ORG" => "false")
    end

    it "writes derived author values into a newly created .kettle-jem.yml" do
      Dir.mktmpdir do |gem_root|
        Dir.mktmpdir do |project_root|
          template_root = File.join(gem_root, "template")
          FileUtils.mkdir_p(template_root)
          File.write(File.join(template_root, ".kettle-jem.yml.example"), <<~YAML)
            defaults:
              freeze_token: "kettle-jem"
            tokens:
              author:
                name: "{KJ|AUTHOR:NAME}"
                given_names: "{KJ|AUTHOR:GIVEN_NAMES}"
                family_names: "{KJ|AUTHOR:FAMILY_NAMES}"
                email: "{KJ|AUTHOR:EMAIL}"
                domain: "{KJ|AUTHOR:DOMAIN}"
          YAML
          File.write(File.join(project_root, "demo.gemspec"), <<~GEMSPEC)
            Gem::Specification.new do |spec|
              spec.name = "demo"
              spec.version = "0.1.0"
              spec.summary = "test"
              spec.authors = ["Jane Marie Doe"]
              spec.email = ["jane@example.com"]
              spec.required_ruby_version = ">= 3.1"
              spec.homepage = "https://github.com/acme/demo"
            end
          GEMSPEC

          allow(helpers).to receive_messages(
            project_root: project_root,
            template_root: template_root,
            ensure_clean_git!: nil,
            ask: true,
          )

          expect { described_class.run }.not_to raise_error

          content = File.read(File.join(project_root, ".kettle-jem.yml"))
          expect(content).to include('name: "Jane Marie Doe"')
          expect(content).to include('given_names: "Jane Marie"')
          expect(content).to include('family_names: "Doe"')
          expect(content).to include('email: "jane@example.com"')
          expect(content).to include('domain: "example.com"')
        end
      end
    end

    it "preserves destination values for existing .kettle-jem.yml keys while adding template-only author keys" do
      Dir.mktmpdir do |gem_root|
        Dir.mktmpdir do |project_root|
          template_root = File.join(gem_root, "template")
          FileUtils.mkdir_p(template_root)
          File.write(File.join(template_root, ".kettle-jem.yml.example"), <<~YAML)
            defaults:
              freeze_token: "kettle-jem"
            tokens:
              author:
                name: "{KJ|AUTHOR:NAME}"
                given_names: "{KJ|AUTHOR:GIVEN_NAMES}"
                family_names: "{KJ|AUTHOR:FAMILY_NAMES}"
                email: "{KJ|AUTHOR:EMAIL}"
                domain: "{KJ|AUTHOR:DOMAIN}"
          YAML
          File.write(File.join(project_root, ".kettle-jem.yml"), <<~YAML)
            # Header comment
            defaults:
              freeze_token: "destination-token"

            # Token section comment
            tokens:
              author:
                name: "Custom Author"

            # Patterns section comment
            patterns:
              - path: "certs/**"
                strategy: raw_copy

            # Files section comment
            files: {}
          YAML
          File.write(File.join(project_root, "demo.gemspec"), <<~GEMSPEC)
            Gem::Specification.new do |spec|
              spec.name = "demo"
              spec.version = "0.1.0"
              spec.summary = "test"
              spec.authors = ["Jane Marie Doe"]
              spec.email = ["jane@example.com"]
              spec.required_ruby_version = ">= 3.1"
              spec.homepage = "https://github.com/acme/demo"
            end
          GEMSPEC

          allow(helpers).to receive_messages(
            project_root: project_root,
            template_root: template_root,
            ensure_clean_git!: nil,
            ask: true,
          )

          expect { described_class.run }.not_to raise_error

          content = File.read(File.join(project_root, ".kettle-jem.yml"))
          expect(content).to include('freeze_token: "destination-token"')
          expect(content).to include('name: "Custom Author"')
          expect(content).to include('given_names: "Jane Marie"')
          expect(content).to include('family_names: "Doe"')
          expect(content).to include('email: "jane@example.com"')
          expect(content).to include('domain: "example.com"')
        end
      end
    end

    it "preserves section comments and does not duplicate patterns when merging an existing .kettle-jem.yml" do
      Dir.mktmpdir do |gem_root|
        Dir.mktmpdir do |project_root|
          template_root = File.join(gem_root, "template")
          FileUtils.mkdir_p(template_root)
          File.write(File.join(template_root, ".kettle-jem.yml.example"), <<~YAML)
            # Header comment
            defaults:
              freeze_token: "kettle-jem"

            # Token section comment
            tokens:
              author:
                name: "{KJ|AUTHOR:NAME}"
                given_names: "{KJ|AUTHOR:GIVEN_NAMES}"
                family_names: "{KJ|AUTHOR:FAMILY_NAMES}"
                email: "{KJ|AUTHOR:EMAIL}"
                domain: "{KJ|AUTHOR:DOMAIN}"

            # Patterns section comment
            patterns:
              - path: "certs/**"
                strategy: raw_copy

            # Files section comment
            files: {}
          YAML
          File.write(File.join(project_root, ".kettle-jem.yml"), <<~YAML)
            # Header comment
            defaults:
              freeze_token: "destination-token"

            # Token section comment
            tokens:
              author:
                name: "Custom Author"

            # Patterns section comment
            patterns:
              - path: "certs/**"
                strategy: raw_copy

            # Files section comment
            files: {}
          YAML
          File.write(File.join(project_root, "demo.gemspec"), <<~GEMSPEC)
            Gem::Specification.new do |spec|
              spec.name = "demo"
              spec.version = "0.1.0"
              spec.summary = "test"
              spec.authors = ["Jane Marie Doe"]
              spec.email = ["jane@example.com"]
              spec.required_ruby_version = ">= 3.1"
              spec.homepage = "https://github.com/acme/demo"
            end
          GEMSPEC

          allow(helpers).to receive_messages(
            project_root: project_root,
            template_root: template_root,
            ensure_clean_git!: nil,
            ask: true,
          )

          expect { described_class.run }.not_to raise_error

          content = File.read(File.join(project_root, ".kettle-jem.yml"))
          expect(content).to include("# Header comment")
          expect(content).to include("# Token section comment")
          expect(content).to include("# Patterns section comment")
          expect(content).to include("# Files section comment")
          expect(content.scan("# Files section comment").size).to eq(1)
          expect(content.scan('path: "certs/**"').size).to eq(1)
          expect(content).to include('freeze_token: "destination-token"')
          expect(content).to include('name: "Custom Author"')
          expect(content).to include('given_names: "Jane Marie"')
          expect(content).to include('family_names: "Doe"')
          expect(content).to include('email: "jane@example.com"')
          expect(content).to include('domain: "example.com"')
        end
      end
    end
  end

  describe "#collect_git_copyright!" do
    let(:helpers) { Kettle::Jem::TemplateHelpers }

    def build_license_md(dir, body)
      path = File.join(dir, "LICENSE.md")
      File.write(path, body)
      path
    end

    let(:ga_double)        { instance_double(Kettle::Dev::GitAdapter) }
    let(:collector_double) { instance_double(Kettle::Jem::CopyrightCollector) }

    before do
      allow(Kettle::Dev::GitAdapter).to receive(:new).and_return(ga_double)
      allow(Kettle::Jem::CopyrightCollector).to receive(:new)
        .with(git_adapter: ga_double, project_root: anything, machine_users: anything)
        .and_return(collector_double)
    end

    context "when the collector returns copyright lines" do
      before do
        allow(collector_double).to receive(:copyright_lines)
          .and_return(["Copyright (c) 2026 Alice", "Copyright (c) 2025 Bob"])
      end

      it "writes a ## Copyright Notice section to LICENSE.md" do
        Dir.mktmpdir do |dir|
          build_license_md(dir, "# License\n\nChoose a license.\n\nCopyright (c) 2026 Fallback Author\n")
          described_class.collect_git_copyright!(helpers: helpers, project_root: dir)
          result = File.read(File.join(dir, "LICENSE.md"))
          expect(result).to include("## Copyright Notice")
          expect(result).to include("Copyright (c) 2026 Alice")
          expect(result).to include("Copyright (c) 2025 Bob")
        end
      end

      it "removes the fallback 'Copyright (c)' line before appending the section" do
        Dir.mktmpdir do |dir|
          build_license_md(dir, "# License\n\nCopyright (c) 2026 Fallback\n")
          described_class.collect_git_copyright!(helpers: helpers, project_root: dir)
          result = File.read(File.join(dir, "LICENSE.md"))
          expect(result).not_to include("Fallback")
          expect(result).to include("Copyright (c) 2026 Alice")
        end
      end

      it "replaces an existing ## Copyright Notice section" do
        Dir.mktmpdir do |dir|
          build_license_md(dir, "# License\n\n## Copyright Notice\n\nCopyright (c) 2020 OldData\n")
          described_class.collect_git_copyright!(helpers: helpers, project_root: dir)
          result = File.read(File.join(dir, "LICENSE.md"))
          expect(result).not_to include("OldData")
          expect(result).to include("Copyright (c) 2026 Alice")
        end
      end
    end

    context "when the collector returns no lines" do
      before { allow(collector_double).to receive(:copyright_lines).and_return([]) }

      it "leaves LICENSE.md unchanged" do
        Dir.mktmpdir do |dir|
          original = "# License\n\nCopyright (c) 2026 Fallback\n"
          build_license_md(dir, original)
          described_class.collect_git_copyright!(helpers: helpers, project_root: dir)
          expect(File.read(File.join(dir, "LICENSE.md"))).to eq(original)
        end
      end
    end

    context "when LICENSE.md does not exist" do
      it "does not raise and does not create the file" do
        Dir.mktmpdir do |dir|
          expect {
            described_class.collect_git_copyright!(helpers: helpers, project_root: dir)
          }.not_to raise_error
          expect(File.exist?(File.join(dir, "LICENSE.md"))).to be false
        end
      end
    end

    context "when GitAdapter.new raises an unexpected error" do
      before do
        allow(Kettle::Dev::GitAdapter).to receive(:new).and_raise(RuntimeError, "no git repo")
      end

      it "does not propagate the error" do
        Dir.mktmpdir do |dir|
          original = "# License\n\nCopyright (c) 2026 Fallback\n"
          build_license_md(dir, original)
          expect { described_class.collect_git_copyright!(helpers: helpers, project_root: dir) }
            .not_to raise_error
          expect(File.read(File.join(dir, "LICENSE.md"))).to eq(original)
        end
      end
    end
  end

  describe "#sync_existing_kettle_config! preserves destination licenses" do
    let(:helpers) { Kettle::Jem::TemplateHelpers }

    it "does not add template-only licenses back when destination already has a licenses key (REPRO)" do
      Dir.mktmpdir do |template_root|
        Dir.mktmpdir do |project_root|
          # Template uses flow sequence (the fixed format) so the merger does NOT
          # recurse into the sequence and add template items to the destination.
          template_config = <<~YAML
            # Managed by kettle-jem
            licenses: [MIT]
          YAML
          File.write(File.join(template_root, ".kettle-jem.yml.example"), template_config)

          # User's project config has removed MIT and uses only AGPL
          dest_config = <<~YAML
            # My project config
            licenses:
              - AGPL-3.0-only
          YAML
          File.write(File.join(project_root, ".kettle-jem.yml"), dest_config)

          # Stub all helpers methods used by sync_existing_kettle_config!
          allow(helpers).to receive(:prefer_example) { |p| File.exist?(p + ".example") ? p + ".example" : p }
          allow(helpers).to receive(:configure_tokens!).and_return(nil)
          allow(helpers).to receive(:read_template) { |p| File.read(p) }
          allow(helpers).to receive(:seed_kettle_config_content) { |c, _| c }
          allow(helpers).to receive(:seed_gemspec_licenses_in_config_content) { |c| c }
          allow(helpers).to receive(:clear_tokens!).and_return(nil)
          allow(helpers).to receive(:clear_kettle_config!).and_return(nil)
          allow(helpers).to receive(:project_root).and_return(project_root)
          allow(helpers).to receive(:record_template_result).and_return(nil)
          allow(helpers).to receive(:output_path) { |p| p }
          allow(helpers).to receive(:ask).and_return(true)
          allow(helpers).to receive(:force_mode?).and_return(false)

          described_class.sync_existing_kettle_config!(
            helpers: helpers,
            project_root: project_root,
            template_root: template_root,
            token_options: {org: "test-org", gem_name: "test-gem", namespace: "Test", namespace_shield: "TEST", gem_shield: "test-gem"},
          )

          result = File.read(File.join(project_root, ".kettle-jem.yml"))
          parsed = YAML.safe_load(result)
          # AGPL must be kept; MIT must NOT be added back
          expect(parsed["licenses"]).to include("AGPL-3.0-only")
          expect(parsed["licenses"]).not_to include("MIT"), \
            "licenses array must NOT have MIT re-added by the SmartMerger; got: #{parsed["licenses"].inspect}"
        end
      end
    end

    it "does not add template-only licenses back when destination already has a licenses key (block sequence template)" do
      Dir.mktmpdir do |template_root|
        Dir.mktmpdir do |project_root|
          # Template uses block sequence — the real template format that triggered the bug
          template_config = <<~YAML
            # Managed by kettle-jem
            licenses:
              - MIT
              - Apache-2.0
              - PolyForm-Small-Business-1.0.0
              - LicenseRef-Big-Time-Public-License
          YAML
          File.write(File.join(template_root, ".kettle-jem.yml.example"), template_config)

          # User's project config has replaced the template licenses with a single custom one
          dest_config = <<~YAML
            # My project config
            licenses:
              - AGPL-3.0-only
          YAML
          File.write(File.join(project_root, ".kettle-jem.yml"), dest_config)

          allow(helpers).to receive(:prefer_example) { |p| File.exist?(p + ".example") ? p + ".example" : p }
          allow(helpers).to receive(:configure_tokens!).and_return(nil)
          allow(helpers).to receive(:read_template) { |p| File.read(p) }
          allow(helpers).to receive(:seed_kettle_config_content) { |c, _| c }
          allow(helpers).to receive(:seed_gemspec_licenses_in_config_content) { |c| c }
          allow(helpers).to receive(:clear_tokens!).and_return(nil)
          allow(helpers).to receive(:clear_kettle_config!).and_return(nil)
          allow(helpers).to receive(:project_root).and_return(project_root)
          allow(helpers).to receive(:record_template_result).and_return(nil)
          allow(helpers).to receive(:output_path) { |p| p }
          allow(helpers).to receive(:ask).and_return(true)
          allow(helpers).to receive(:force_mode?).and_return(false)

          described_class.sync_existing_kettle_config!(
            helpers: helpers,
            project_root: project_root,
            template_root: template_root,
            token_options: {org: "test-org", gem_name: "test-gem", namespace: "Test", namespace_shield: "TEST", gem_shield: "test-gem"},
          )

          result = File.read(File.join(project_root, ".kettle-jem.yml"))
          parsed = YAML.safe_load(result)
          # User's AGPL-3.0-only must be kept; template licenses must NOT be added
          expect(parsed["licenses"]).to eq(["AGPL-3.0-only"]), \
            "licenses must NOT be overwritten with template defaults; got: #{parsed["licenses"].inspect}"
        end
      end
    end

    it "seeds licenses from gemspec when destination config has no licenses key" do
      Dir.mktmpdir do |template_root|
        Dir.mktmpdir do |project_root|
          template_config = <<~YAML
            # Managed by kettle-jem
            licenses:
              - MIT
              - Apache-2.0
          YAML
          File.write(File.join(template_root, ".kettle-jem.yml.example"), template_config)

          # Destination has no licenses: key at all
          dest_config = <<~YAML
            # My project config
            name: my-gem
          YAML
          File.write(File.join(project_root, ".kettle-jem.yml"), dest_config)

          allow(helpers).to receive(:prefer_example) { |p| File.exist?(p + ".example") ? p + ".example" : p }
          allow(helpers).to receive(:configure_tokens!).and_return(nil)
          allow(helpers).to receive(:read_template) { |p| File.read(p) }
          allow(helpers).to receive(:seed_kettle_config_content) { |c, _| c }
          # seed_gemspec_licenses_in_config_content replaces licenses: in template content
          # with the gemspec value ["ISC"]. Not stubbed here — exercised directly below.
          allow(helpers).to receive(:seed_gemspec_licenses_in_config_content) do |c|
            c.sub(/^licenses:.*\n(?:  - .*\n)*/m, "licenses:\n  - ISC\n")
          end
          allow(helpers).to receive(:clear_tokens!).and_return(nil)
          allow(helpers).to receive(:clear_kettle_config!).and_return(nil)
          allow(helpers).to receive(:project_root).and_return(project_root)
          allow(helpers).to receive(:record_template_result).and_return(nil)
          allow(helpers).to receive(:output_path) { |p| p }
          allow(helpers).to receive(:ask).and_return(true)
          allow(helpers).to receive(:force_mode?).and_return(false)

          described_class.sync_existing_kettle_config!(
            helpers: helpers,
            project_root: project_root,
            template_root: template_root,
            token_options: {org: "test-org", gem_name: "test-gem", namespace: "Test", namespace_shield: "TEST", gem_shield: "test-gem"},
          )

          result = File.read(File.join(project_root, ".kettle-jem.yml"))
          parsed = YAML.safe_load(result)
          # The gemspec-seeded ISC license must appear (not the template default MIT/Apache)
          expect(parsed["licenses"]).to eq(["ISC"]), \
            "licenses must be seeded from gemspec when absent from dest; got: #{parsed["licenses"].inspect}"
        end
      end
    end
  end

  describe "TemplateHelpers#seed_gemspec_licenses_in_config_content" do
    let(:helpers) { Kettle::Jem::TemplateHelpers }

    it "replaces the licenses: block in template content with gemspec value" do
      template_content = <<~YAML
        name: project
        licenses:
          - MIT
          - Apache-2.0
        version: "1.0"
      YAML
      allow(helpers).to receive(:safe_gemspec_metadata).and_return({licenses: ["ISC"]})
      result = helpers.seed_gemspec_licenses_in_config_content(template_content)
      parsed = YAML.safe_load(result)
      expect(parsed["licenses"]).to eq(["ISC"])
      expect(parsed["name"]).to eq("project")
      expect(parsed["version"]).to eq("1.0")
    end

    it "uses MIT fallback when gemspec has no licenses" do
      template_content = <<~YAML
        licenses:
          - Apache-2.0
      YAML
      allow(helpers).to receive(:safe_gemspec_metadata).and_return({})
      result = helpers.seed_gemspec_licenses_in_config_content(template_content)
      parsed = YAML.safe_load(result)
      expect(parsed["licenses"]).to eq(["MIT"])
    end

    it "returns content unchanged when an error occurs" do
      template_content = <<~YAML
        licenses:
          - Apache-2.0
      YAML
      allow(helpers).to receive(:safe_gemspec_metadata).and_raise(StandardError, "inner error")
      result = helpers.seed_gemspec_licenses_in_config_content(template_content)
      expect(result).to eq(template_content)
    end
  end

  describe "#remove_obsolete_license_files!" do
    let(:helpers) { Kettle::Jem::TemplateHelpers }

    it "deletes license files whose SPDX id is absent from resolved_licenses" do
      Dir.mktmpdir do |template_root|
        Dir.mktmpdir do |project_root|
          # Simulate a template directory with three known license file templates
          File.write(File.join(template_root, "MIT.md.example"), "MIT license")
          File.write(File.join(template_root, "AGPL-3.0-only.md.example"), "AGPL license")
          File.write(File.join(template_root, "Apache-2.0.md.example"), "Apache license")
          # Non-license markdown that must never be touched
          File.write(File.join(template_root, "README.md.example"), "readme template")

          # Project currently has all three SPDX license files
          File.write(File.join(project_root, "MIT.md"), "MIT license text")
          File.write(File.join(project_root, "AGPL-3.0-only.md"), "AGPL license text")
          File.write(File.join(project_root, "Apache-2.0.md"), "Apache license text")

          # Config now only lists MIT and AGPL — Apache is obsolete
          allow(helpers).to receive(:resolved_licenses).and_return(["MIT", "AGPL-3.0-only"])
          allow(helpers).to receive(:spdx_basename) { |id| id }

          described_class.remove_obsolete_license_files!(
            helpers: helpers,
            project_root: project_root,
            template_root: template_root,
          )

          expect(File.exist?(File.join(project_root, "MIT.md"))).to be true
          expect(File.exist?(File.join(project_root, "AGPL-3.0-only.md"))).to be true
          expect(File.exist?(File.join(project_root, "Apache-2.0.md"))).to be false
        end
      end
    end

    it "does not touch non-license markdown files even when they have a template counterpart" do
      Dir.mktmpdir do |template_root|
        Dir.mktmpdir do |project_root|
          File.write(File.join(template_root, "MIT.md.example"), "MIT license")
          File.write(File.join(template_root, "README.md.example"), "readme")
          File.write(File.join(template_root, "CHANGELOG.md.example"), "changelog")

          File.write(File.join(project_root, "README.md"), "my readme")
          File.write(File.join(project_root, "CHANGELOG.md"), "my changelog")
          File.write(File.join(project_root, "MIT.md"), "MIT license text")

          # Only MIT is active — README and CHANGELOG should never be touched
          allow(helpers).to receive(:resolved_licenses).and_return(["MIT"])
          allow(helpers).to receive(:spdx_basename) { |id| id }

          described_class.remove_obsolete_license_files!(
            helpers: helpers,
            project_root: project_root,
            template_root: template_root,
          )

          expect(File.exist?(File.join(project_root, "README.md"))).to be true
          expect(File.exist?(File.join(project_root, "CHANGELOG.md"))).to be true
          expect(File.exist?(File.join(project_root, "MIT.md"))).to be true
        end
      end
    end

    it "does not raise when a managed obsolete license file is absent from the project" do
      Dir.mktmpdir do |template_root|
        Dir.mktmpdir do |project_root|
          File.write(File.join(template_root, "Apache-2.0.md.example"), "Apache license")

          # Apache-2.0.md does NOT exist in project_root — should be a no-op
          allow(helpers).to receive(:resolved_licenses).and_return(["MIT"])
          allow(helpers).to receive(:spdx_basename) { |id| id }

          expect do
            described_class.remove_obsolete_license_files!(
              helpers: helpers,
              project_root: project_root,
              template_root: template_root,
            )
          end.not_to raise_error
        end
      end
    end
  end

  describe "config-to-gemspec license sync" do
    let(:helpers) { Kettle::Jem::TemplateHelpers }

    before { stub_env("allowed" => "true") }

    it "removes spec.license (singular) when spec.licenses (plural) is being set" do
      Dir.mktmpdir do |gem_root|
        Dir.mktmpdir do |project_root|
          template_root = File.join(gem_root, "template")
          FileUtils.mkdir_p(template_root)

          File.write(File.join(template_root, "gem.gemspec.example"), <<~GEMSPEC)
            Gem::Specification.new do |spec|
              spec.name = "demo-gem"
              spec.version = "1.0.0"
              spec.authors = ["Template Author"]
              spec.email = ["t@example.com"]
              spec.summary = "Template summary"
              spec.description = "Template description"
              spec.licenses = ["MIT"]
              spec.required_ruby_version = ">= 2.3.0"
              spec.require_paths = ["lib"]
              spec.bindir = "exe"
              spec.executables = []
            end
          GEMSPEC

          # Existing gemspec uses singular spec.license (as scaffolded by `bundle gem`)
          File.write(File.join(project_root, "demo-gem.gemspec"), <<~GEMSPEC)
            Gem::Specification.new do |spec|
              spec.name = "demo-gem"
              spec.version = "0.1.0"
              spec.authors = ["Alice"]
              spec.email = ["alice@example.com"]
              spec.summary = "My gem"
              spec.description = "My gem does things"
              spec.license = "MIT"
              spec.required_ruby_version = ">= 3.0"
              spec.require_paths = ["lib"]
              spec.bindir = "exe"
              spec.executables = []
            end
          GEMSPEC

          # Config declares multiple licenses — spec.licenses should be written and spec.license removed
          allow(helpers).to receive(:resolved_licenses).and_return(["AGPL-3.0-only", "PolyForm-Small-Business-1.0.0", "LicenseRef-Big-Time-Public-License"])
          allow(helpers).to receive_messages(
            project_root: project_root,
            template_root: template_root,
            ensure_clean_git!: nil,
            ask: true,
          )

          described_class.run

          dest = File.read(File.join(project_root, "demo-gem.gemspec"))
          expect(dest).to include("AGPL-3.0-only")
          expect(dest).to include("PolyForm-Small-Business-1.0.0")
          expect(dest).to include("LicenseRef-Big-Time-Public-License")
          expect(dest).to include("spec.licenses")
          expect(dest).not_to match(/spec\.license\s*=\s*"/)
        end
      end
    end

    it "writes the .kettle-jem.yml license list into spec.licenses instead of preserving the gemspec value" do
      Dir.mktmpdir do |gem_root|
        Dir.mktmpdir do |project_root|
          template_root = File.join(gem_root, "template")
          FileUtils.mkdir_p(template_root)

          File.write(File.join(template_root, "gem.gemspec.example"), <<~GEMSPEC)
            Gem::Specification.new do |spec|
              spec.name = "demo-gem"
              spec.version = "1.0.0"
              spec.authors = ["Template Author"]
              spec.email = ["t@example.com"]
              spec.summary = "Template summary"
              spec.description = "Template description"
              spec.licenses = ["MIT"]
              spec.required_ruby_version = ">= 2.3.0"
              spec.require_paths = ["lib"]
              spec.bindir = "exe"
              spec.executables = []
            end
          GEMSPEC

          # Existing gemspec has Apache-2.0 only
          File.write(File.join(project_root, "demo-gem.gemspec"), <<~GEMSPEC)
            Gem::Specification.new do |spec|
              spec.name = "demo-gem"
              spec.version = "0.1.0"
              spec.authors = ["Alice"]
              spec.email = ["alice@example.com"]
              spec.summary = "My gem"
              spec.description = "My gem does things"
              spec.licenses = ["Apache-2.0"]
              spec.required_ruby_version = ">= 3.0"
              spec.require_paths = ["lib"]
              spec.bindir = "exe"
              spec.executables = []
            end
          GEMSPEC

          # Config declares MIT + AGPL — these should win over the gemspec's Apache-2.0
          allow(helpers).to receive(:resolved_licenses).and_return(["MIT", "AGPL-3.0-only"])
          allow(helpers).to receive_messages(
            project_root: project_root,
            template_root: template_root,
            ensure_clean_git!: nil,
            ask: true,
          )

          described_class.run

          dest = File.read(File.join(project_root, "demo-gem.gemspec"))
          expect(dest).to include("MIT")
          expect(dest).to include("AGPL-3.0-only")
          expect(dest).not_to include("Apache-2.0")
        end
      end
    end
  end
end
