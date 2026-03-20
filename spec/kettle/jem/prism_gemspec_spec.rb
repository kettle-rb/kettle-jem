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

  describe ".rewrite_version_loader" do
    let(:template) do
      <<~RUBY
        # coding: utf-8
        # frozen_string_literal: true

        # kettle-jem:freeze
        # kettle-jem:unfreeze

        gem_version =
          if RUBY_VERSION >= "3.1" # rubocop:disable Gemspec/RubyVersionGlobalsUsage
            Module.new.tap { |mod| Kernel.load("\#{__dir__}/lib/kettle/dev/version.rb", mod) }::Kettle::Dev::Version::VERSION
          else
            lib = File.expand_path("lib", __dir__)
            $LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
            require "kettle/dev/version"
            Kettle::Dev::Version::VERSION
          end

        Gem::Specification.new do |spec|
          spec.name = "demo"
          spec.version = gem_version
        end
      RUBY
    end

    it "inlines the version loader when min_ruby is >= 3.1" do
      out = described_class.rewrite_version_loader(
        template,
        min_ruby: Gem::Version.new("3.2"),
        entrypoint_require: "kettle/jem",
        namespace: "Kettle::Jem",
      )

      expect(out).not_to include("gem_version =")
      expect(out).to include('spec.version = Module.new.tap { |mod| Kernel.load("#{__dir__}/lib/kettle/jem/version.rb", mod) }::Kettle::Jem::Version::VERSION')
      expect(out).not_to include('spec.version = gem_version')
    end

    it "keeps the legacy gem_version block when min_ruby is below 3.1" do
      out = described_class.rewrite_version_loader(
        template,
        min_ruby: Gem::Version.new("3.0"),
        entrypoint_require: "kettle/dev",
        namespace: "Kettle::Dev",
      )

      expect(out).to include("gem_version =")
      expect(out).to include('if RUBY_VERSION >= "3.1"')
      expect(out).to include('require "kettle/dev/version"')
      expect(out).to include('spec.version = gem_version')
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

    it "inserts new development dependencies below the development dependency note block when present" do
      destination = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "example"
          spec.version = "1.0.0"
          spec.add_dependency("version_gem", "~> 1.1", ">= 1.1.9")              # ruby >= 2.2.0

          # NOTE: It is preferable to list development dependencies in the gemspec due to increased
          #       visibility and discoverability.

          # Security
          spec.add_development_dependency("bundler-audit", "~> 0.9.3")             # ruby >= 2.0.0
        end
      RUBY

      desired = {
        "rake" => '  spec.add_development_dependency("rake", "~> 13.0")                                # ruby >= 2.2.0',
      }

      result = described_class.ensure_development_dependencies(destination, desired)

      note_index = result.index('# NOTE: It is preferable to list development dependencies in the gemspec due to increased')
      rake_index = result.index('spec.add_development_dependency("rake", "~> 13.0")                                # ruby >= 2.2.0')

      expect(note_index).not_to be_nil
      expect(rake_index).not_to be_nil
      expect(note_index).to be < rake_index
    end

    it "removes a conflicting development dependency when the same gem already exists as a runtime dependency" do
      destination = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "example"
          spec.version = "1.0.0"
          # Dev tooling (runtime dep — example extends kettle-dev's functionality)
          spec.add_dependency("kettle-dev", "~> 2.0")                            # ruby >= 2.3.0

          # NOTE: It is preferable to list development dependencies in the gemspec due to increased
          #       visibility and discoverability.

          # Dev, Test, & Release Tasks
          spec.add_development_dependency("kettle-dev", "~> 1.0")                  # ruby >= 2.3.0
        end
      RUBY

      desired = {
        "kettle-dev" => '  spec.add_development_dependency("kettle-dev", "~> 2.0")                  # ruby >= 2.3.0',
      }

      result = described_class.ensure_development_dependencies(destination, desired)

      expect(result).to include('spec.add_dependency("kettle-dev", "~> 2.0")                            # ruby >= 2.3.0')
      expect(result.scan(/^\s*spec\.add_(?:development_)?dependency\("kettle-dev"/).length).to eq(1)
      expect(result).not_to include('spec.add_development_dependency("kettle-dev"')
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
