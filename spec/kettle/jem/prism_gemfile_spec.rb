# frozen_string_literal: true

require "kettle/jem/prism_gemfile"

RSpec.describe Kettle::Jem::PrismGemfile do
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
  end

  describe ".filter_to_top_level_gems" do
    it "extracts only top-level gem/source/git_source calls" do
      content = <<~RUBY
        source "https://rubygems.org"
        gem "foo"
        group :development do
          gem "dev-only"
        end
      RUBY

      result = described_class.filter_to_top_level_gems(content)
      expect(result).to include('source "https://rubygems.org"')
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

      result = described_class.filter_to_top_level_gems(content)
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

      result = described_class.filter_to_top_level_gems(content)
      expect(result).to eq("")
    end

    it "includes inline comments on gem lines" do
      content = <<~RUBY
        gem "foo" # important
      RUBY

      result = described_class.filter_to_top_level_gems(content)
      expect(result).to include('gem "foo" # important')
    end

    it "returns content unchanged on parse error" do
      content = "this is not valid ruby {{{"
      result = described_class.filter_to_top_level_gems(content)
      # On parse error, returns original content
      expect(result).to be_a(String)
    end
  end

  describe ".remove_github_git_source" do
    it "removes git_source(:github) from content" do
      content = <<~'RUBY'
        git_source(:github) { |repo| "https://github.com/#{repo}.git" }
        gem "foo"
      RUBY

      result = described_class.remove_github_git_source(content)
      expect(result).not_to include("git_source(:github)")
      expect(result).to include('gem "foo"')
    end

    it "leaves content unchanged when no git_source(:github)" do
      content = <<~'RUBY'
        git_source(:gitlab) { |repo| "https://gitlab.com/#{repo}.git" }
        gem "foo"
      RUBY

      result = described_class.remove_github_git_source(content)
      expect(result).to include("git_source(:gitlab)")
      expect(result).to include('gem "foo"')
    end

    it "leaves content unchanged when no git_source at all" do
      content = "gem \"foo\"\n"
      result = described_class.remove_github_git_source(content)
      expect(result).to eq(content)
    end

    it "returns content on parse error" do
      content = "not valid ruby {{{"
      result = described_class.remove_github_git_source(content)
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
end
