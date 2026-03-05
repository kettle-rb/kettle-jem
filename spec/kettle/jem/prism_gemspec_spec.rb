# frozen_string_literal: true

require "kettle/jem/prism_gemspec"

RSpec.describe Kettle::Jem::PrismGemspec do
  describe ".replace_gemspec_fields" do
    it "replaces scalar fields inside gemspec block and preserves comments" do
      src = <<~RUBY
        # frozen_string_literal: true

        Gem::Specification.new do |spec|
          # original comment
          spec.name = "kettle-dev"
          spec.version = "0.1.0"
          spec.authors = ["Old Author"]

          # keep me
          spec.add_dependency "rake"
        end
      RUBY

      out = described_class.replace_gemspec_fields(src, {name: "my-gem", authors: ["A", "B"]})
      expect(out).to include('spec.name = "my-gem"')
      expect(out).to include('spec.authors = ["A", "B"]')
      # ensure comment preserved
      expect(out).to include("# original comment")
    end

    it "removes self-dependency when _remove_self_dependency provided" do
      src = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "kettle-dev"
          spec.add_dependency "kettle-dev", "~> 1.0"
          spec.add_development_dependency 'other'
        end
      RUBY

      out = described_class.replace_gemspec_fields(src, {_remove_self_dependency: "kettle-dev"})
      expect(out).not_to include('add_dependency "kettle-dev"')
      expect(out).to include("add_development_dependency")
    end

    it "handles a different block param name" do
      src = <<~RUBY
        Gem::Specification.new do |s|
          s.name = "old"
        end
      RUBY
      out = described_class.replace_gemspec_fields(src, {name: "new"})
      expect(out).to include('s.name = "new"')
    end

    it "inserts field after version when version not present" do
      src = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "a"
        end
      RUBY
      out = described_class.replace_gemspec_fields(src, {authors: ["X"]})
      expect(out).to include('spec.authors = ["X"]')
    end

    it "preserves commented out dependency lines and does not remove them" do
      src = <<~RUBY
        Gem::Specification.new do |spec|
          # spec.add_dependency "kettle-dev", "~> 1"
          spec.add_dependency "other"
        end
      RUBY
      out = described_class.replace_gemspec_fields(src, {_remove_self_dependency: "kettle-dev"})
      expect(out).to include('# spec.add_dependency "kettle-dev"')
      expect(out).to include('spec.add_dependency "other"')
    end

    it "does not replace non-literal RHS assignments" do
      src = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = generate_name
        end
      RUBY
      out = described_class.replace_gemspec_fields(src, {name: "x"})
      expect(out).to include("spec.name = generate_name")
      expect(out).not_to include('spec.name = "x"')
    end
  end

  describe ".ensure_development_dependencies" do
    # BUG REPRO: When the destination gemspec has promoted a gem from
    # add_development_dependency to add_dependency (runtime), the template's
    # add_development_dependency line should NOT overwrite it. The destination's
    # promotion to runtime must be respected.

    it "does not downgrade add_dependency to add_development_dependency" do
      destination = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "kettle-jem"
          spec.version = "1.0.0"

          spec.add_dependency("kettle-dev", "~> 2.0")

          spec.add_development_dependency("rake", "~> 13.0")
        end
      RUBY

      desired = {
        "kettle-dev" => '  spec.add_development_dependency("kettle-dev", "~> 2.0")',
        "rake" => '  spec.add_development_dependency("rake", "~> 13.0")',
      }

      result = described_class.ensure_development_dependencies(destination, desired)

      # kettle-dev should remain as add_dependency (runtime), not downgraded
      expect(result).to include('add_dependency("kettle-dev"')
      expect(result).not_to match(/add_development_dependency.*kettle-dev/)

      # rake should stay as add_development_dependency (already matches)
      expect(result).to include('add_development_dependency("rake"')
    end

    it "does not downgrade add_runtime_dependency to add_development_dependency" do
      destination = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "example"
          spec.version = "1.0.0"

          spec.add_runtime_dependency("kettle-dev", "~> 2.0")

          spec.add_development_dependency("rake", "~> 13.0")
        end
      RUBY

      desired = {
        "kettle-dev" => '  spec.add_development_dependency("kettle-dev", "~> 2.0")',
      }

      result = described_class.ensure_development_dependencies(destination, desired)

      # kettle-dev should remain as add_runtime_dependency
      expect(result).to include('add_runtime_dependency("kettle-dev"')
      expect(result).not_to match(/add_development_dependency.*kettle-dev/)
    end

    it "still updates version constraints for development dependencies" do
      destination = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "example"
          spec.version = "1.0.0"

          spec.add_development_dependency("rake", ">= 12")
        end
      RUBY

      desired = {
        "rake" => '  spec.add_development_dependency("rake", "~> 13.0")',
      }

      result = described_class.ensure_development_dependencies(destination, desired)

      # rake should be updated to match the desired version
      expect(result).to include("~> 13.0")
      expect(result).not_to include(">= 12")
    end

    it "adds missing development dependencies that are not present at all" do
      destination = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "example"
          spec.version = "1.0.0"
        end
      RUBY

      desired = {
        "rake" => '  spec.add_development_dependency("rake", "~> 13.0")',
      }

      result = described_class.ensure_development_dependencies(destination, desired)

      expect(result).to include('add_development_dependency("rake", "~> 13.0")')
    end

    it "does not leave orphaned trailing comments when replacing dependency lines" do
      destination = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "example"
          spec.version = "1.0.0"

          spec.add_development_dependency("rake", ">= 12")                    # ruby >= 2.2.0
          spec.add_development_dependency("rspec", "~> 3.0")                  # ruby >= 2.3.0
        end
      RUBY

      desired = {
        "rake" => '  spec.add_development_dependency("rake", "~> 13.0")                                # ruby >= 2.2.0',
        "rspec" => '  spec.add_development_dependency("rspec", "~> 3.12")                               # ruby >= 2.5.0',
      }

      result = described_class.ensure_development_dependencies(destination, desired)

      # The old trailing comments should not appear as orphaned lines
      lines = result.lines.map(&:strip)
      orphaned = lines.select { |l| l == "# ruby >= 2.2.0" || l == "# ruby >= 2.3.0" }
      expect(orphaned).to be_empty, "Found orphaned trailing comments: #{orphaned.inspect}"
      # The replacement lines should include their new trailing comments
      expect(result).to include("~> 13.0")
      expect(result).to include("~> 3.12")
    end
  end
end
