# frozen_string_literal: true

require "kettle/jem/prism_gemspec"

RSpec.describe Kettle::Jem::PrismGemspec do
  describe ".merge" do
    it "runs the gemspec recipe through the shared recipe runner" do
      template = "Gem::Specification.new do |spec|\n  spec.name = \"demo\"\nend\n"
      dest = "Gem::Specification.new do |spec|\n  spec.name = \"legacy\"\nend\n"
      recipe = instance_double(Ast::Merge::Recipe::Config)
      runner = instance_double(Ast::Merge::Recipe::Runner)
      result = Struct.new(:content).new("Gem::Specification.new do |spec|\n  spec.name = \"demo\"\nend\n")

      expect(Kettle::Jem).to receive(:recipe).with(:gemspec).and_return(recipe)
      expect(Ast::Merge::Recipe::Runner).to receive(:new).with(recipe).and_return(runner)
      expect(runner).to receive(:run_content).with(
        template_content: template,
        destination_content: dest,
        relative_path: "project.gemspec",
      ).and_return(result)

      expect(described_class.merge(template, dest)).to eq(result.content)
    end

    it "passes version-loader metadata through the recipe runtime context" do
      template = "Gem::Specification.new do |spec|\n  spec.name = \"demo\"\nend\n"
      dest = "Gem::Specification.new do |spec|\n  spec.name = \"legacy\"\nend\n"
      recipe = instance_double(Ast::Merge::Recipe::Config)
      runner = instance_double(Ast::Merge::Recipe::Runner)
      result = Struct.new(:content).new("Gem::Specification.new do |spec|\n  spec.name = \"demo\"\nend\n")

      expect(Kettle::Jem).to receive(:recipe).with(:gemspec).and_return(recipe)
      expect(Ast::Merge::Recipe::Runner).to receive(:new).with(recipe).and_return(runner)
      expect(runner).to receive(:run_content).with(
        template_content: template,
        destination_content: dest,
        relative_path: "project.gemspec",
        context: {
          min_ruby: Gem::Version.new("3.2"),
          entrypoint_require: "kettle/jem",
          namespace: "Kettle::Jem",
        },
      ).and_return(result)

      expect(
        described_class.merge(
          template,
          dest,
          min_ruby: Gem::Version.new("3.2"),
          entrypoint_require: "kettle/jem",
          namespace: "Kettle::Jem",
        ),
      ).to eq(result.content)
    end

    it "harmonizes the merged result after smart_merge" do
      template = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "demo"
          spec.files = Dir[
            "lib/**/*.rb"
          ]
        end
      RUBY

      dest = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "demo"
          spec.files = Dir[
            "lib/**/*.rb",
            "sig/**/*.rbs"
          ]
        end
      RUBY

      merged = described_class.merge(template, dest)

      expect(merged).to include('"lib/**/*.rb"')
      expect(merged).to include('"sig/**/*.rbs"')
    end

    it "rewrites the version loader via recipe execution when runtime metadata is provided", :prism_merge_only do
      template = <<~RUBY
        # coding: utf-8
        # frozen_string_literal: true

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

      merged = described_class.merge(
        template,
        "",
        min_ruby: Gem::Version.new("3.2"),
        entrypoint_require: "kettle/jem",
        namespace: "Kettle::Jem",
      )

      expect(merged).not_to include("gem_version =")
      expect(merged).to include('spec.version = Module.new.tap { |mod| Kernel.load("#{__dir__}/lib/kettle/jem/version.rb", mod) }::Kettle::Jem::Version::VERSION')
    end
  end

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

    it "can replace version and insert multiple missing fields in one pass" do
      src = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "a"
          spec.version = "0.1.0"
        end
      RUBY

      out = described_class.replace_gemspec_fields(
        src,
        {
          version: "2.0.0",
          authors: ["X"],
          email: ["x@example.com"],
        },
      )

      expect(out).to include('spec.version = "2.0.0"')
      expect(out).to include('spec.authors = ["X"]')
      expect(out).to include('spec.email = ["x@example.com"]')
      expect(out.index('spec.version = "2.0.0"')).to be < out.index('spec.authors = ["X"]')
      expect(out.index('spec.authors = ["X"]')).to be < out.index('spec.email = ["x@example.com"]')
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

  describe ".remove_spec_dependency" do
    it "removes matching self-dependencies across runtime and development declarations" do
      src = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "kettle-dev"
          spec.add_dependency "kettle-dev", "~> 1.0"
          spec.add_runtime_dependency "kettle-dev", ">= 1.0"
          spec.add_development_dependency "other"
        end
      RUBY

      out = described_class.remove_spec_dependency(src, "kettle-dev")

      expect(out).not_to include('add_dependency "kettle-dev"')
      expect(out).not_to include('add_runtime_dependency "kettle-dev"')
      expect(out).to include('spec.add_development_dependency "other"')
    end

    it "preserves commented dependency lines while removing active self-dependencies" do
      src = <<~RUBY
        Gem::Specification.new do |spec|
          # spec.add_dependency "kettle-dev", "~> 1"
          # Keep this comment with the file
          spec.add_dependency "kettle-dev", "~> 2.0"
          spec.add_dependency "other"
        end
      RUBY

      out = described_class.remove_spec_dependency(src, "kettle-dev")

      expect(out).to include('# spec.add_dependency "kettle-dev", "~> 1"')
      expect(out).to include("# Keep this comment with the file")
      expect(out).to include('spec.add_dependency "other"')
      expect(out).not_to include('spec.add_dependency "kettle-dev", "~> 2.0"')
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
      expect(out).not_to include("spec.version = gem_version")
    end

    it "inserts spec.version when the assignment is missing" do
      template_without_version = <<~RUBY
        gem_version = "ignored"

        Gem::Specification.new do |spec|
          spec.name = "demo"
        end
      RUBY

      out = described_class.rewrite_version_loader(
        template_without_version,
        min_ruby: Gem::Version.new("3.2"),
        entrypoint_require: "kettle/jem",
        namespace: "Kettle::Jem",
      )

      expect(out).to include('spec.name = "demo"')
      expect(out).to include('spec.version = Module.new.tap { |mod| Kernel.load("#{__dir__}/lib/kettle/jem/version.rb", mod) }::Kettle::Jem::Version::VERSION')
      expect(out.index('spec.name = "demo"')).to be < out.index('spec.version = Module.new.tap { |mod| Kernel.load("#{__dir__}/lib/kettle/jem/version.rb", mod) }::Kettle::Jem::Version::VERSION')
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
      expect(out).to include("spec.version = gem_version")
    end
  end

  describe described_class::DependencySectionPolicy do
    def normalize_dependency_sections(content, template_content:, destination_content:, prefer_template: false)
      described_class.normalize(
        content: content,
        template_content: template_content,
        destination_content: destination_content,
        prefer_template: prefer_template,
      )
    end

    it "parses method, gem, and normalized signature from a dependency line in one pass" do
      match = described_class.dependency_line_match('  spec.add_runtime_dependency("demo",    "~> 1.0" ) # comment')

      expect(match).to eq(
        method: "add_runtime_dependency",
        gem: "demo",
        signature: '"demo", "~> 1.0"',
      )
    end

    it "prefers destination dependency formatting by default" do
      content = "  spec.add_dependency(\"demo\", \"~> 1.0\")\n"
      template_content = "  spec.add_dependency(\"demo\", \"~> 1.0\") # template\n"
      destination_content = "  spec.add_dependency \"demo\", \"~> 1.0\" # destination\n"

      out = normalize_dependency_sections(
        content,
        template_content: template_content,
        destination_content: destination_content,
      )

      expect(out).to eq(destination_content)
    end

    it "can prefer template dependency formatting when requested" do
      content = "  spec.add_dependency \"demo\", \"~> 1.0\"\n"
      template_content = "  spec.add_dependency(\"demo\", \"~> 1.0\") # template\n"
      destination_content = "  spec.add_dependency \"demo\", \"~> 1.0\" # destination\n"

      out = normalize_dependency_sections(
        content,
        template_content: template_content,
        destination_content: destination_content,
        prefer_template: true,
      )

      expect(out).to eq(template_content)
    end

    it "does not normalize updated dependency constraints back to stale destination text" do
      content = "  spec.add_dependency(\"demo\", \"~> 2.0\")\n"
      template_content = "  spec.add_dependency(\"demo\", \"~> 1.0\") # template\n"
      destination_content = "  spec.add_dependency \"demo\", \"~> 1.0\" # destination\n"

      out = normalize_dependency_sections(
        content,
        template_content: template_content,
        destination_content: destination_content,
      )

      expect(out).to eq(content)
    end

    it "does not normalize updated dependency constraints back to stale template text when prefer_template is true" do
      content = "  spec.add_dependency(\"demo\", \"~> 2.0\")\n"
      template_content = "  spec.add_dependency(\"demo\", \"~> 1.0\") # template\n"
      destination_content = "  spec.add_dependency \"demo\", \"~> 1.0\" # destination\n"

      out = normalize_dependency_sections(
        content,
        template_content: template_content,
        destination_content: destination_content,
        prefer_template: true,
      )

      expect(out).to eq(content)
    end

    it "removes development dependency blocks when the gem is also a runtime dependency" do
      content = <<~RUBY
          spec.add_dependency("kettle-dev", "~> 2.0")
          # Dev Tasks
          spec.add_development_dependency("kettle-dev", "~> 2.0")

          spec.add_development_dependency("rake", "~> 13.0")
      RUBY

      out = normalize_dependency_sections(
        content,
        template_content: content,
        destination_content: content,
      )

      expect(out).to include('spec.add_dependency("kettle-dev", "~> 2.0")')
      expect(out).to include('spec.add_development_dependency("rake", "~> 13.0")')
      expect(out).not_to include('spec.add_development_dependency("kettle-dev", "~> 2.0")')
      expect(out).not_to include("# Dev Tasks")
    end

    it "moves runtime dependency blocks above the development dependency note block with attached comments" do
      content = <<~RUBY
          spec.name = "demo"

          # NOTE: It is preferable to list development dependencies in the gemspec due to increased
          #       visibility and discoverability.

          # Runtime
          spec.add_dependency("kettle-dev", "~> 2.0")

          # Security
          spec.add_development_dependency("bundler-audit", "~> 0.9.3")
      RUBY

      out = normalize_dependency_sections(
        content,
        template_content: content,
        destination_content: content,
      )

      expect(out).to include("# Runtime\nspec.add_dependency(\"kettle-dev\", \"~> 2.0\")")
      expect(out.index('# Runtime')).to be < out.index('# NOTE: It is preferable to list development dependencies in the gemspec due to increased')
      expect(out.index('# NOTE: It is preferable to list development dependencies in the gemspec due to increased')).to be < out.index('# Security')
    end

    it "keeps multiple runtime blocks below the note in their original order when moving them above it" do
      content = <<~RUBY
          spec.name = "demo"

          # NOTE: It is preferable to list development dependencies in the gemspec due to increased
          #       visibility and discoverability.

          # Runtime A
          spec.add_dependency("alpha", "~> 1.0")

          # Runtime B
          spec.add_runtime_dependency("beta", "~> 2.0")

          # Security
          spec.add_development_dependency("bundler-audit", "~> 0.9.3")
      RUBY

      out = normalize_dependency_sections(
        content,
        template_content: content,
        destination_content: content,
      )

      expect(out.index('# Runtime A')).to be < out.index('spec.add_dependency("alpha", "~> 1.0")')
      expect(out.index('spec.add_dependency("alpha", "~> 1.0")')).to be < out.index('# Runtime B')
      expect(out.index('# Runtime B')).to be < out.index('spec.add_runtime_dependency("beta", "~> 2.0")')
      expect(out.index('spec.add_runtime_dependency("beta", "~> 2.0")')).to be < out.index('# NOTE: It is preferable to list development dependencies in the gemspec due to increased')
    end

    it "inserts a single separator before moved runtime blocks when the note directly follows nonblank content" do
      content = <<~RUBY
          spec.name = "demo"
          # NOTE: It is preferable to list development dependencies in the gemspec due to increased
          #       visibility and discoverability.

          # Runtime
          spec.add_dependency("kettle-dev", "~> 2.0")
      RUBY

      out = normalize_dependency_sections(
        content,
        template_content: content,
        destination_content: content,
      )

      expect(out).to include("spec.name = \"demo\"\n\n# Runtime\nspec.add_dependency(\"kettle-dev\", \"~> 2.0\")")
      expect(out).not_to include("spec.name = \"demo\"\n\n\n# Runtime")
    end

    it "does not introduce an extra blank line after the note when the remaining development section starts immediately" do
      content = <<~RUBY
          spec.name = "demo"

          # NOTE: It is preferable to list development dependencies in the gemspec due to increased
          #       visibility and discoverability.
          # Runtime
          spec.add_dependency("kettle-dev", "~> 2.0")
          # Security
          spec.add_development_dependency("bundler-audit", "~> 0.9.3")
      RUBY

      out = normalize_dependency_sections(
        content,
        template_content: content,
        destination_content: content,
      )

      expect(out).to include("#       visibility and discoverability.\n# Security")
      expect(out).not_to include("#       visibility and discoverability.\n\n# Security")
    end

    it "does not move detached comments separated from a runtime dependency block by a blank line" do
      content = <<~RUBY
          spec.name = "demo"

          # NOTE: It is preferable to list development dependencies in the gemspec due to increased
          #       visibility and discoverability.

          # Detached
          # Commentary

          # Runtime
          spec.add_dependency("kettle-dev", "~> 2.0")

          # Security
          spec.add_development_dependency("bundler-audit", "~> 0.9.3")
      RUBY

      out = normalize_dependency_sections(
        content,
        template_content: content,
        destination_content: content,
      )

      expect(out.index('# Runtime')).to be < out.index('# NOTE: It is preferable to list development dependencies in the gemspec due to increased')
      expect(out.index('# NOTE: It is preferable to list development dependencies in the gemspec due to increased')).to be < out.index('# Detached')
      expect(out.index('# Detached')).to be < out.index('# Security')
    end

    it "moves contiguous attached comments with the runtime dependency block" do
      content = <<~RUBY
          spec.name = "demo"

          # NOTE: It is preferable to list development dependencies in the gemspec due to increased
          #       visibility and discoverability.

          # Runtime
          # Additional context
          spec.add_dependency("kettle-dev", "~> 2.0")

          # Security
          spec.add_development_dependency("bundler-audit", "~> 0.9.3")
      RUBY

      out = normalize_dependency_sections(
        content,
        template_content: content,
        destination_content: content,
      )

      expect(out).to include("# Runtime\n# Additional context\nspec.add_dependency(\"kettle-dev\", \"~> 2.0\")")
      expect(out.index('# Runtime')).to be < out.index('# NOTE: It is preferable to list development dependencies in the gemspec due to increased')
    end

    it "preserves exactly one blank line between moved runtime blocks and the note" do
      content = <<~RUBY
          spec.name = "demo"

          # NOTE: It is preferable to list development dependencies in the gemspec due to increased
          #       visibility and discoverability.

          # Runtime A
          spec.add_dependency("alpha", "~> 1.0")

          # Runtime B
          spec.add_runtime_dependency("beta", "~> 2.0")

          # Security
          spec.add_development_dependency("bundler-audit", "~> 0.9.3")
      RUBY

      out = normalize_dependency_sections(
        content,
        template_content: content,
        destination_content: content,
      )

      expect(out).to include("spec.add_runtime_dependency(\"beta\", \"~> 2.0\")\n\n# NOTE")
      expect(out).not_to include("spec.add_runtime_dependency(\"beta\", \"~> 2.0\")\n\n\n# NOTE")
    end

    it "anchors insertion before the final end when no note block is present" do
      lines = <<~RUBY.lines
        Gem::Specification.new do |spec|
          spec.name = "demo"
        end
      RUBY

      expect(described_class.insertion_line_index(lines)).to eq(2)
    end

    it "anchors insertion at the content end when no note block or final end line is present" do
      lines = ["spec.add_dependency(\"demo\", \"~> 1.0\")\n"]

      expect(described_class.insertion_line_index(lines)).to eq(1)
    end
  end

  describe ".development_dependency_entries" do
    it "extracts ordered development dependency entries from a parseable gemspec and preserves inline comments" do
      content = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "example"
          spec.version = "1.0.0"

          spec.add_development_dependency(
            "rake",
            "~> 13.0"
          ) # ruby >= 2.2.0
          # spec.add_development_dependency("ignored", "~> 9.9")
          spec.add_development_dependency 'rspec', '>= 3'
        end
      RUBY

      result = described_class.development_dependency_entries(content)

      expect(result.map { |entry| entry[:gem] }).to eq(%w[rake rspec])
      expect(result.first[:line]).to include("spec.add_development_dependency(")
      expect(result.first[:line]).to include("# ruby >= 2.2.0")
      expect(result.last[:signature]).to eq('"rspec", ">= 3"')
    end

    it "falls back to line-oriented extraction when Prism context lookup raises" do
      allow(described_class).to receive(:gemspec_context).and_raise(LoadError, "cannot load such file -- prism")

      content = <<~RUBY
        # spec.add_development_dependency("ignored", "~> 9.9")
        spec.add_development_dependency("rake",    "~> 13.0" ) # ruby >= 2.2.0
      RUBY

      result = described_class.development_dependency_entries(content)

      expect(result.size).to eq(1)
      expect(result.first[:gem]).to eq("rake")
      expect(result.first[:line]).to eq('spec.add_development_dependency("rake",    "~> 13.0" ) # ruby >= 2.2.0')
      expect(result.first[:signature]).to eq('"rake", "~> 13.0"')
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

    it "preserves desired insertion order before the final end in the standard path when no note block is present" do
      destination = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "example"
          spec.version = "1.0.0"
        end
      RUBY

      desired = {
        "rake" => '  spec.add_development_dependency("rake", "~> 13.0")',
        "rspec" => '  spec.add_development_dependency("rspec", "~> 3.12")',
      }

      result = described_class.ensure_development_dependencies(destination, desired)

      expect(result).to include("  spec.add_development_dependency(\"rake\", \"~> 13.0\")\n  spec.add_development_dependency(\"rspec\", \"~> 3.12\")\nend")
      expect(result.index('spec.add_development_dependency("rake", "~> 13.0")')).to be < result.index('spec.add_development_dependency("rspec", "~> 3.12")')
    end

    it "preserves desired insertion order in the fallback path below the note block" do
      allow(described_class).to receive(:gemspec_context).and_return(nil)

      destination = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "example"
          spec.version = "1.0.0"
          spec.add_dependency("kettle-dev", "~> 2.0")

          # NOTE: It is preferable to list development dependencies in the gemspec due to increased
          #       visibility and discoverability.
          # Security
          spec.add_development_dependency("bundler-audit", "~> 0.9.3")
        end
      RUBY

      desired = {
        "rake" => '  spec.add_development_dependency("rake", "~> 13.0")',
        "rspec" => '  spec.add_development_dependency("rspec", "~> 3.12")',
        "kettle-dev" => '  spec.add_development_dependency("kettle-dev", "~> 2.0")',
      }

      result = described_class.ensure_development_dependencies(destination, desired)

      expect(result).to include("  # NOTE: It is preferable to list development dependencies in the gemspec due to increased\n  #       visibility and discoverability.\n  spec.add_development_dependency(\"rake\", \"~> 13.0\")\n  spec.add_development_dependency(\"rspec\", \"~> 3.12\")\n  # Security")
      expect(result.index('spec.add_development_dependency("rake", "~> 13.0")')).to be < result.index('spec.add_development_dependency("rspec", "~> 3.12")')
      expect(result).to include('spec.add_dependency("kettle-dev", "~> 2.0")')
      expect(result).not_to include('spec.add_development_dependency("kettle-dev", "~> 2.0")')
    end

    it "preserves desired insertion order in the fallback path without a note block" do
      allow(described_class).to receive(:gemspec_context).and_return(nil)

      destination = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "example"
          spec.version = "1.0.0"
        end
      RUBY

      desired = {
        "rake" => '  spec.add_development_dependency("rake", "~> 13.0")',
        "rspec" => '  spec.add_development_dependency("rspec", "~> 3.12")',
      }

      result = described_class.ensure_development_dependencies(destination, desired)

      expect(result).to include("  spec.add_development_dependency(\"rake\", \"~> 13.0\")\n  spec.add_development_dependency(\"rspec\", \"~> 3.12\")\nend")
      expect(result.index('spec.add_development_dependency("rake", "~> 13.0")')).to be < result.index('spec.add_development_dependency("rspec", "~> 3.12")')
    end

    it "falls back to line-oriented insertion when Prism context lookup raises during bootstrap" do
      allow(described_class).to receive(:gemspec_context).and_raise(LoadError, "cannot load such file -- prism")

      destination = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "example"
          spec.version = "1.0.0"

          # NOTE: It is preferable to list development dependencies in the gemspec due to increased
          #       visibility and discoverability.
          # Security
          spec.add_development_dependency("bundler-audit", "~> 0.9.3")
        end
      RUBY

      desired = {
        "rake" => '  spec.add_development_dependency("rake", "~> 13.0")',
      }

      result = described_class.ensure_development_dependencies(destination, desired)

      expect(result).to include("  # NOTE: It is preferable to list development dependencies in the gemspec due to increased\n  #       visibility and discoverability.\n  spec.add_development_dependency(\"rake\", \"~> 13.0\")\n  # Security")
      expect(result.index('spec.add_development_dependency("rake", "~> 13.0")')).to be < result.index("# Security")
    end

    it "appends missing development dependencies at the content end in the fallback path when no final end line exists" do
      allow(described_class).to receive(:gemspec_context).and_return(nil)

      destination = <<~RUBY
        spec.add_dependency("kettle-dev", "~> 2.0")
      RUBY

      desired = {
        "rake" => '  spec.add_development_dependency("rake", "~> 13.0")',
        "rspec" => '  spec.add_development_dependency("rspec", "~> 3.12")',
      }

      result = described_class.ensure_development_dependencies(destination, desired)

      expect(result).to end_with("spec.add_dependency(\"kettle-dev\", \"~> 2.0\")\n  spec.add_development_dependency(\"rake\", \"~> 13.0\")\n  spec.add_development_dependency(\"rspec\", \"~> 3.12\")\n")
      expect(result.index('spec.add_development_dependency("rake", "~> 13.0")')).to be < result.index('spec.add_development_dependency("rspec", "~> 3.12")')
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

      note_index = result.index("# NOTE: It is preferable to list development dependencies in the gemspec due to increased")
      rake_index = result.index('spec.add_development_dependency("rake", "~> 13.0")                                # ruby >= 2.2.0')
      security_index = result.index("# Security")

      expect(note_index).not_to be_nil
      expect(rake_index).not_to be_nil
      expect(security_index).not_to be_nil
      expect(note_index).to be < rake_index
      expect(rake_index).to be < security_index
      expect(result).to include("  # NOTE: It is preferable to list development dependencies in the gemspec due to increased\n  #       visibility and discoverability.\n\n  spec.add_development_dependency(\"rake\", \"~> 13.0\")                                # ruby >= 2.2.0\n  # Security")
    end

    it "inserts directly below the note block even when a section header comment follows immediately" do
      destination = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "example"
          spec.version = "1.0.0"

          # NOTE: It is preferable to list development dependencies in the gemspec due to increased
          #       visibility and discoverability.
          # Security
          spec.add_development_dependency("bundler-audit", "~> 0.9.3")
        end
      RUBY

      desired = {
        "rake" => '  spec.add_development_dependency("rake", "~> 13.0")',
      }

      result = described_class.ensure_development_dependencies(destination, desired)

      expect(result).to include("  # NOTE: It is preferable to list development dependencies in the gemspec due to increased\n  #       visibility and discoverability.\n  spec.add_development_dependency(\"rake\", \"~> 13.0\")\n  # Security")
      expect(result.index('spec.add_development_dependency("rake", "~> 13.0")')).to be < result.index("# Security")
    end

    it "can insert a missing dependency and replace the first existing dependency below the note block" do
      destination = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "example"
          spec.version = "1.0.0"

          # NOTE: It is preferable to list development dependencies in the gemspec due to increased
          #       visibility and discoverability.

          # Security
          spec.add_development_dependency("bundler-audit", "~> 0.9.2")
        end
      RUBY

      desired = {
        "rake" => '  spec.add_development_dependency("rake", "~> 13.0")',
        "bundler-audit" => '  spec.add_development_dependency("bundler-audit", "~> 0.9.3")',
      }

      result = described_class.ensure_development_dependencies(destination, desired)

      expect(Prism.parse(result).success?).to be(true)
      expect(result).to include('spec.add_development_dependency("rake", "~> 13.0")')
      expect(result).to include('spec.add_development_dependency("bundler-audit", "~> 0.9.3")')
      expect(result).not_to include('spec.add_development_dependency("bundler-audit", "~> 0.9.2")')
      expect(result.index('spec.add_development_dependency("rake", "~> 13.0")')).to be < result.index('spec.add_development_dependency("bundler-audit", "~> 0.9.3")')
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
