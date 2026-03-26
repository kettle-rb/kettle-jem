# frozen_string_literal: true

RSpec.describe Kettle::Jem::PrismGemfile, ".remove_gem_dependency" do
  describe "removing self-referential gem dependencies" do
    it "removes gem call matching the gem name" do
      src = <<~RUBY
        source "https://gem.coop"
        
        gem "rails", "~> 7.0"
        gem "my-gem", "~> 1.0"
        gem "other-gem"
      RUBY

      out = described_class.remove_gem_dependency(src, "my-gem")
      expect(out).to include('gem "rails"')
      expect(out).to include('gem "other-gem"')
      expect(out).not_to include('gem "my-gem"')
    end

    it "preserves other gem calls when removing self-dependency" do
      src = <<~RUBY
        gem "my-app"
        gem "rspec"
        gem "rubocop"
      RUBY

      out = described_class.remove_gem_dependency(src, "my-app")
      expect(out).not_to include('gem "my-app"')
      expect(out).to include('gem "rspec"')
      expect(out).to include('gem "rubocop"')
    end

    it "returns content unchanged when gem_name is empty" do
      src = 'gem "foo"'
      out = described_class.remove_gem_dependency(src, "")
      expect(out).to eq(src)
    end

    it "handles modular gemfile content" do
      src = <<~RUBY
        # Coverage tools
        gem "simplecov", "~> 0.22"
        gem "my-gem", require: false
      RUBY

      out = described_class.remove_gem_dependency(src, "my-gem")
      expect(out).to include("simplecov")
      expect(out).not_to include('gem "my-gem"')
    end

    it "removes gem call inside a platform block" do
      src = <<~RUBY
        platform :mri do
          gem "tree_haver", path: "../tree_haver"
          gem "ast-merge", path: "../ast-merge"
        end
      RUBY

      out = described_class.remove_gem_dependency(src, "tree_haver")
      expect(out).not_to include('gem "tree_haver"')
      expect(out).to include('gem "ast-merge"')
      expect(out).to include("platform :mri do")
    end

    it "removes gem call inside a group block" do
      src = <<~RUBY
        group :development do
          gem "my-gem", "~> 1.0"
          gem "pry"
        end
      RUBY

      out = described_class.remove_gem_dependency(src, "my-gem")
      expect(out).not_to include('gem "my-gem"')
      expect(out).to include('gem "pry"')
    end

    it "removes gem calls inside an if/else conditional" do
      src = <<~RUBY
        if ENV.fetch("DEV", "false").casecmp?("true")
          gem "tree_haver", path: "../tree_haver"
          gem "other-gem", path: "../other"
        else
          gem "tree_haver", "~> 1.0"
          gem "other-gem"
        end
      RUBY

      out = described_class.remove_gem_dependency(src, "tree_haver")
      expect(out).not_to include('gem "tree_haver"')
      expect(out).to include('gem "other-gem"')
    end

    it "removes gem calls at multiple nesting levels" do
      src = <<~RUBY
        gem "tree_haver", "~> 1.0"
        platform :mri do
          gem "tree_haver", path: "../tree_haver"
          gem "ast-merge", path: "../ast-merge"
        end
        if ENV["DEV"]
          gem "tree_haver", path: "../dev/tree_haver"
        end
      RUBY

      out = described_class.remove_gem_dependency(src, "tree_haver")
      expect(out).not_to include('gem "tree_haver"')
      expect(out).to include('gem "ast-merge"')
    end

    it "removes multiline gem declarations without disturbing neighboring entries" do
      src = <<~RUBY
        gem "tree_haver",
          "~> 5.0",
          require: false

        gem "ast-merge", path: "../ast-merge"
      RUBY

      out = described_class.remove_gem_dependency(src, "tree_haver")

      expect(out).not_to include('gem "tree_haver"')
      expect(out).not_to include('"~> 5.0"')
      expect(out).to include('gem "ast-merge", path: "../ast-merge"')
    end

    it "does not strip local_gems arrays or vendored comments when removing gem declarations" do
      src = <<~RUBY
        local_gems = %w[
          ast-merge
          kettle-jem
          prism-merge
        ]

        # export VENDORED_GEMS=ast-merge,kettle-jem,prism-merge
        platform :mri do
          eval_nomono_gems(gems: local_gems)
        end
      RUBY

      out = described_class.remove_gem_dependency(src, "kettle-jem")
      expect(out).to eq(src)
    end
  end

  describe ".merge_local_gem_overrides" do
    it "keeps destination-only local workspace gems, adds template-only gems, and excludes the current gem" do
      merged = <<~RUBY
        local_gems = %w[
          bash-merge
          kettle-jem
          prism-merge
        ]

        # export VENDORED_GEMS=bash-merge,kettle-jem,prism-merge
        platform :mri do
          eval_nomono_gems(gems: local_gems)
        end
      RUBY

      destination = <<~RUBY
        local_gems = %w[
          ast-merge
          tree_haver
          prism-merge
        ]

        # export VENDORED_GEMS=ast-merge,tree_haver,prism-merge
        platform :mri do
          eval_nomono_gems(gems: local_gems)
        end
      RUBY

      out = described_class.merge_local_gem_overrides(merged, destination, excluded_gems: "kettle-jem")

      expect(out).to include("ast-merge")
      expect(out).to include("tree_haver")
      expect(out).to include("bash-merge")
      expect(out).to include("prism-merge")
      expect(out).not_to include("kettle-jem\n")
      expect(out).to include("# export VENDORED_GEMS=ast-merge,tree_haver,prism-merge,bash-merge")
    end

    it "preserves single-line local_gems formatting while merging words from both sides" do
      merged = <<~RUBY
        local_gems = %w[bash-merge kettle-jem prism-merge]

        platform :mri do
          eval_nomono_gems(gems: local_gems)
        end
      RUBY

      destination = <<~RUBY
        local_gems = %w[ast-merge prism-merge]

        platform :mri do
          eval_nomono_gems(gems: local_gems)
        end
      RUBY

      out = described_class.merge_local_gem_overrides(merged, destination, excluded_gems: "kettle-jem")

      expect(out).to include("local_gems = %w[ast-merge prism-merge bash-merge]")
      expect(out).not_to include("local_gems = %w[\n")
    end

    it "preserves a trailing comment attached to the local_gems assignment" do
      merged = <<~RUBY
        local_gems = %w[
          bash-merge
          kettle-jem
          prism-merge
        ] # keep this note

        platform :mri do
          eval_nomono_gems(gems: local_gems)
        end
      RUBY

      destination = <<~RUBY
        local_gems = %w[
          ast-merge
          prism-merge
        ] # keep this note

        platform :mri do
          eval_nomono_gems(gems: local_gems)
        end
      RUBY

      out = described_class.merge_local_gem_overrides(merged, destination, excluded_gems: "kettle-jem")

      expect(out).to include("] # keep this note")
      expect(out).to include("  ast-merge")
      expect(out).to include("  bash-merge")
    end

    it "restores destination local override metadata when the merged content lacks the local_gems preamble" do
      merged = <<~RUBY
        platform :mri do
          eval_nomono_gems(gems: local_gems)
        end
      RUBY

      destination = <<~RUBY
        local_gems = %w[
          ast-merge
          prism-merge
        ]

        # export VENDORED_GEMS=ast-merge,prism-merge
        platform :mri do
          eval_nomono_gems(gems: local_gems)
        end
      RUBY

      out = described_class.merge_local_gem_overrides(merged, destination, excluded_gems: "kettle-jem")

      expect(out).to start_with("local_gems = %w[")
      expect(out).to include("  ast-merge")
      expect(out).to include("  prism-merge")
      expect(out).to include("# export VENDORED_GEMS=ast-merge,prism-merge")
      expect(out.scan("eval_nomono_gems(gems: local_gems)").length).to eq(1)
    end
  end

  describe ".merge_bootstrap_local_gem_overrides" do
    it "keeps destination ordering while adding source-only bootstrap gems and excluding the current gem" do
      source = <<~RUBY
        require "nomono/bundler"

        local_gems = %w[
          ast-merge
          tree_haver
          bash-merge
          kettle-jem
          prism-merge
        ]

        # export VENDORED_GEMS=ast-merge,tree_haver,bash-merge,kettle-jem,prism-merge
        platform :mri do
          eval_nomono_gems(gems: local_gems)
        end
      RUBY

      destination = <<~RUBY
        require "nomono/bundler"

        local_gems = %w[
          tree_haver
          bash-merge
          prism-merge
        ]

        # export VENDORED_GEMS=tree_haver,bash-merge,prism-merge
        platform :mri do
          eval_nomono_gems(gems: local_gems)
        end
      RUBY

      out = described_class.merge_bootstrap_local_gem_overrides(source, destination, excluded_gems: "ast-merge")

      expect(out).to include("tree_haver")
      expect(out).to include("bash-merge")
      expect(out).to include("prism-merge")
      expect(out).to include("kettle-jem")
      expect(out).not_to include("ast-merge\n")
      expect(out).to include("# export VENDORED_GEMS=tree_haver,bash-merge,prism-merge,kettle-jem")
    end

    it "leaves the destination unchanged when the source has no bootstrap override metadata" do
      source = <<~RUBY
        platform :mri do
          eval_nomono_gems(gems: local_gems)
        end
      RUBY

      destination = <<~RUBY
        local_gems = %w[
          tree_haver
        ]

        # export VENDORED_GEMS=tree_haver
        platform :mri do
          eval_nomono_gems(gems: local_gems)
        end
      RUBY

      out = described_class.merge_bootstrap_local_gem_overrides(source, destination, excluded_gems: "ast-merge")
      expect(out).to eq(destination)
    end
  end
end
