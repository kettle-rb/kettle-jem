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
  end
end
