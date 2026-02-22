# frozen_string_literal: true

# rubocop:disable RSpec/VerifiedDoubles, RSpec/MultipleExpectations
RSpec.describe Kettle::Jem::TemplateHelpers do
  let(:helpers) { described_class }

  let(:base_args) do
    {
      org: "my-org",
      gem_name: "my-gem",
      namespace: "MyGem",
      namespace_shield: "My__Gem",
      gem_shield: "my__gem",
    }
  end

  before do
    stub_env(
      "FUNDING_ORG" => "false",
      # Forge
      "KJ_GH_USER" => nil,
      "KJ_GL_USER" => nil,
      "KJ_CB_USER" => nil,
      "KJ_SH_USER" => nil,
      # Author
      "KJ_AUTHOR_NAME" => nil,
      "KJ_AUTHOR_GIVEN_NAMES" => nil,
      "KJ_AUTHOR_FAMILY_NAMES" => nil,
      "KJ_AUTHOR_EMAIL" => nil,
      "KJ_AUTHOR_ORCID" => nil,
      "KJ_AUTHOR_DOMAIN" => nil,
      # Funding
      "KJ_FUNDING_PATREON" => nil,
      "KJ_FUNDING_KOFI" => nil,
      "KJ_FUNDING_PAYPAL" => nil,
      "KJ_FUNDING_BUYMEACOFFEE" => nil,
      "KJ_FUNDING_POLAR" => nil,
      "KJ_FUNDING_LIBERAPAY" => nil,
      "KJ_FUNDING_ISSUEHUNT" => nil,
      # Social
      "KJ_SOCIAL_MASTODON" => nil,
      "KJ_SOCIAL_BLUESKY" => nil,
      "KJ_SOCIAL_LINKTREE" => nil,
      "KJ_SOCIAL_DEVTO" => nil,
    )
    allow(helpers).to receive(:gemspec_metadata).and_return(
      min_ruby: Gem::Version.create("3.2"),
    )
  end

  describe ".apply_common_replacements" do
    it "resolves basic {KJ|GEM_NAME} tokens" do
      content = "gem: {KJ|GEM_NAME}"
      result = helpers.apply_common_replacements(content, **base_args)
      expect(result).to eq("gem: my-gem")
    end

    it "resolves {KJ|GH_ORG} token" do
      content = "https://github.com/{KJ|GH_ORG}/{KJ|GEM_NAME}"
      result = helpers.apply_common_replacements(content, **base_args)
      expect(result).to eq("https://github.com/my-org/my-gem")
    end

    it "resolves {KJ|NAMESPACE} token" do
      content = "module {KJ|NAMESPACE}"
      result = helpers.apply_common_replacements(content, **base_args)
      expect(result).to eq("module MyGem")
    end

    it "resolves {KJ|MIN_RUBY} token" do
      content = "ruby >= {KJ|MIN_RUBY}"
      result = helpers.apply_common_replacements(content, **base_args, min_ruby: "3.2")
      expect(result).to eq("ruby >= 3.2")
    end

    it "keeps unresolved tokens when on_missing is :keep" do
      content = "{KJ|UNKNOWN_TOKEN} stays"
      result = helpers.apply_common_replacements(content, **base_args)
      expect(result).to eq("{KJ|UNKNOWN_TOKEN} stays")
    end

    context "with forge user tokens" do
      context "when KJ_GH_USER is set" do
        before do
          stub_env("KJ_GH_USER" => "octocat")
        end

        it "resolves {KJ|GH:USER} token" do
          content = "https://github.com/sponsors/{KJ|GH:USER}"
          result = helpers.apply_common_replacements(content, **base_args)
          expect(result).to eq("https://github.com/sponsors/octocat")
        end

        it "resolves {KJ|GH:USER} alongside other tokens" do
          content = "https://github.com/{KJ|GH_ORG}/{KJ|GEM_NAME} by {KJ|GH:USER}"
          result = helpers.apply_common_replacements(content, **base_args)
          expect(result).to eq("https://github.com/my-org/my-gem by octocat")
        end
      end

      context "when KJ_GL_USER is set" do
        before do
          stub_env("KJ_GL_USER" => "gluser")
        end

        it "resolves {KJ|GL:USER} token" do
          content = "https://gitlab.com/{KJ|GL:USER}"
          result = helpers.apply_common_replacements(content, **base_args)
          expect(result).to eq("https://gitlab.com/gluser")
        end
      end

      context "when KJ_CB_USER is set" do
        before do
          stub_env("KJ_CB_USER" => "berguser")
        end

        it "resolves {KJ|CB:USER} token" do
          content = "https://codeberg.org/{KJ|CB:USER}"
          result = helpers.apply_common_replacements(content, **base_args)
          expect(result).to eq("https://codeberg.org/berguser")
        end
      end

      context "when KJ_SH_USER is set" do
        before do
          stub_env("KJ_SH_USER" => "hutuser")
        end

        it "resolves {KJ|SH:USER} token" do
          content = "https://sr.ht/~{KJ|SH:USER}/"
          result = helpers.apply_common_replacements(content, **base_args)
          expect(result).to eq("https://sr.ht/~hutuser/")
        end
      end

      context "when multiple forge users are set" do
        before do
          stub_env(
            "KJ_GH_USER" => "ghuser",
            "KJ_GL_USER" => "gluser",
            "KJ_CB_USER" => "cbuser",
            "KJ_SH_USER" => "shuser",
          )
        end

        it "resolves all forge user tokens in one pass" do
          content = <<~CONTENT.chomp
            GH: {KJ|GH:USER}
            GL: {KJ|GL:USER}
            CB: {KJ|CB:USER}
            SH: {KJ|SH:USER}
          CONTENT
          result = helpers.apply_common_replacements(content, **base_args)
          expect(result).to eq(<<~EXPECTED.chomp)
            GH: ghuser
            GL: gluser
            CB: cbuser
            SH: shuser
          EXPECTED
        end
      end

      context "when forge user ENV is not set" do
        it "keeps {KJ|GH:USER} token unresolved" do
          content = "sponsor: {KJ|GH:USER}"
          result = helpers.apply_common_replacements(content, **base_args)
          expect(result).to eq("sponsor: {KJ|GH:USER}")
        end

        it "keeps all forge user tokens unresolved" do
          content = "{KJ|GH:USER} {KJ|GL:USER} {KJ|CB:USER} {KJ|SH:USER}"
          result = helpers.apply_common_replacements(content, **base_args)
          expect(result).to eq("{KJ|GH:USER} {KJ|GL:USER} {KJ|CB:USER} {KJ|SH:USER}")
        end
      end

      context "when forge user ENV is blank" do
        before do
          stub_env("KJ_GH_USER" => "   ")
        end

        it "keeps {KJ|GH:USER} token unresolved for blank values" do
          content = "user: {KJ|GH:USER}"
          result = helpers.apply_common_replacements(content, **base_args)
          expect(result).to eq("user: {KJ|GH:USER}")
        end
      end
    end

    context "with author identity tokens" do
      context "when all author ENV vars are set" do
        before do
          stub_env(
            "KJ_AUTHOR_NAME" => "Jane Doe",
            "KJ_AUTHOR_GIVEN_NAMES" => "Jane Marie",
            "KJ_AUTHOR_FAMILY_NAMES" => "Doe",
            "KJ_AUTHOR_EMAIL" => "jane@example.com",
            "KJ_AUTHOR_ORCID" => "0000-0001-2345-6789",
            "KJ_AUTHOR_DOMAIN" => "example.com",
          )
        end

        it "resolves {KJ|AUTHOR:NAME} token" do
          content = 'spec.authors = ["{KJ|AUTHOR:NAME}"]'
          result = helpers.apply_common_replacements(content, **base_args)
          expect(result).to eq('spec.authors = ["Jane Doe"]')
        end

        it "resolves {KJ|AUTHOR:EMAIL} token" do
          content = 'spec.email = ["{KJ|AUTHOR:EMAIL}"]'
          result = helpers.apply_common_replacements(content, **base_args)
          expect(result).to eq('spec.email = ["jane@example.com"]')
        end

        it "resolves {KJ|AUTHOR:DOMAIN} in YARD_HOST" do
          content = "https://{KJ|YARD_HOST}/"
          result = helpers.apply_common_replacements(content, **base_args)
          expect(result).to eq("https://my-gem.example.com/")
        end

        it "resolves {KJ|AUTHOR:ORCID} token" do
          content = "orcid: 'https://orcid.org/{KJ|AUTHOR:ORCID}'"
          result = helpers.apply_common_replacements(content, **base_args)
          expect(result).to eq("orcid: 'https://orcid.org/0000-0001-2345-6789'")
        end

        it "resolves all author tokens in one pass" do
          content = <<~CONTENT.chomp
            given-names: "{KJ|AUTHOR:GIVEN_NAMES}"
            family-names: "{KJ|AUTHOR:FAMILY_NAMES}"
            email: "{KJ|AUTHOR:EMAIL}"
            affiliation: "{KJ|AUTHOR:DOMAIN}"
          CONTENT
          result = helpers.apply_common_replacements(content, **base_args)
          expect(result).to eq(<<~EXPECTED.chomp)
            given-names: "Jane Marie"
            family-names: "Doe"
            email: "jane@example.com"
            affiliation: "example.com"
          EXPECTED
        end
      end

      context "when KJ_AUTHOR_DOMAIN is not set" do
        it "falls back to example.com for YARD_HOST" do
          content = "https://{KJ|YARD_HOST}/"
          result = helpers.apply_common_replacements(content, **base_args)
          expect(result).to eq("https://my-gem.example.com/")
        end
      end
    end

    context "with funding platform tokens" do
      before do
        stub_env(
          "KJ_FUNDING_PATREON" => "mypatreon",
          "KJ_FUNDING_KOFI" => "ABCDEF123",
          "KJ_FUNDING_PAYPAL" => "mypaypal",
          "KJ_FUNDING_BUYMEACOFFEE" => "mycoffee",
          "KJ_FUNDING_POLAR" => "mypolar",
          "KJ_FUNDING_LIBERAPAY" => "myliberapay",
          "KJ_FUNDING_ISSUEHUNT" => "myissuehunt",
        )
      end

      it "resolves {KJ|FUNDING:PATREON} token" do
        content = "https://patreon.com/{KJ|FUNDING:PATREON}"
        result = helpers.apply_common_replacements(content, **base_args)
        expect(result).to eq("https://patreon.com/mypatreon")
      end

      it "resolves {KJ|FUNDING:KOFI} token" do
        content = "https://ko-fi.com/{KJ|FUNDING:KOFI}"
        result = helpers.apply_common_replacements(content, **base_args)
        expect(result).to eq("https://ko-fi.com/ABCDEF123")
      end

      it "resolves {KJ|FUNDING:PAYPAL} token" do
        content = "https://www.paypal.com/paypalme/{KJ|FUNDING:PAYPAL}"
        result = helpers.apply_common_replacements(content, **base_args)
        expect(result).to eq("https://www.paypal.com/paypalme/mypaypal")
      end

      it "resolves {KJ|FUNDING:BUYMEACOFFEE} token" do
        content = "https://www.buymeacoffee.com/{KJ|FUNDING:BUYMEACOFFEE}"
        result = helpers.apply_common_replacements(content, **base_args)
        expect(result).to eq("https://www.buymeacoffee.com/mycoffee")
      end

      it "resolves {KJ|FUNDING:POLAR} token" do
        content = "https://polar.sh/{KJ|FUNDING:POLAR}"
        result = helpers.apply_common_replacements(content, **base_args)
        expect(result).to eq("https://polar.sh/mypolar")
      end

      it "resolves {KJ|FUNDING:LIBERAPAY} token" do
        content = "https://liberapay.com/{KJ|FUNDING:LIBERAPAY}/donate"
        result = helpers.apply_common_replacements(content, **base_args)
        expect(result).to eq("https://liberapay.com/myliberapay/donate")
      end

      it "resolves {KJ|FUNDING:ISSUEHUNT} token" do
        content = "issuehunt: \"{KJ|FUNDING:ISSUEHUNT}\""
        result = helpers.apply_common_replacements(content, **base_args)
        expect(result).to eq('issuehunt: "myissuehunt"')
      end
    end

    context "with social platform tokens" do
      before do
        stub_env(
          "KJ_SOCIAL_MASTODON" => "rubyist",
          "KJ_SOCIAL_BLUESKY" => "rubyist.dev",
          "KJ_SOCIAL_LINKTREE" => "rubyist",
          "KJ_SOCIAL_DEVTO" => "rubyist",
        )
      end

      it "resolves {KJ|SOCIAL:MASTODON} token" do
        content = "https://ruby.social/@{KJ|SOCIAL:MASTODON}"
        result = helpers.apply_common_replacements(content, **base_args)
        expect(result).to eq("https://ruby.social/@rubyist")
      end

      it "resolves {KJ|SOCIAL:BLUESKY} token" do
        content = "https://bsky.app/profile/{KJ|SOCIAL:BLUESKY}"
        result = helpers.apply_common_replacements(content, **base_args)
        expect(result).to eq("https://bsky.app/profile/rubyist.dev")
      end

      it "resolves {KJ|SOCIAL:LINKTREE} token" do
        content = "https://linktr.ee/{KJ|SOCIAL:LINKTREE}"
        result = helpers.apply_common_replacements(content, **base_args)
        expect(result).to eq("https://linktr.ee/rubyist")
      end

      it "resolves {KJ|SOCIAL:DEVTO} token" do
        content = "https://dev.to/{KJ|SOCIAL:DEVTO}"
        result = helpers.apply_common_replacements(content, **base_args)
        expect(result).to eq("https://dev.to/rubyist")
      end
    end
  end
end
# rubocop:enable RSpec/VerifiedDoubles, RSpec/MultipleExpectations
