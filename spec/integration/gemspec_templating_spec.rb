# frozen_string_literal: true

RSpec.describe "Gemspec Templating Integration" do
  let(:fixture_path) { File.expand_path("../fixtures/example-kettle-soup-cover.gemspec", __dir__) }
  let(:fixture_content) { File.read(fixture_path) }
  let(:template_gemspec_path) { File.expand_path("../../kettle-dev.gemspec.example", __dir__) }
  let(:template_content) { File.read(template_gemspec_path) }

  describe "freeze block placement" do
    it "handles multiple magic comments correctly" do
      content = <<~RUBY
        #!/usr/bin/env ruby
        # frozen_string_literal: true
        # encoding: utf-8

        Gem::Specification.new do |spec|
          spec.name = "example"
        end
      RUBY

      lines = content.lines
      expect(lines[0]).to match(/^#!/)
      expect(lines[1]).to match(/frozen_string_literal/)
      expect(lines[2]).to match(/encoding/)
      expect(lines[3].strip).to eq("")
      expect(lines[4]).to eq("Gem::Specification.new do |spec|\n")
    end
  end

  describe "spec.summary and spec.description preservation" do
    let(:template_with_emoji) do
      <<~RUBY
        # frozen_string_literal: true

        Gem::Specification.new do |spec|
          spec.name = "template-gem"
          spec.version = "1.0.0"
          spec.summary = "🥘 "
          spec.description = "🥘 "
        end
      RUBY
    end

    let(:destination_with_content) do
      <<~RUBY
        # frozen_string_literal: true

        Gem::Specification.new do |spec|
          spec.name = "my-gem"
          spec.version = "1.0.0"
          spec.summary = "🍲 kettle-rb OOTB SimpleCov config"
          spec.description = "🍲 A Covered Kettle of Test Coverage"
        end
      RUBY
    end

    it "preserves destination summary and description when they have content" do
      replacements = {
        name: "my-gem",
        summary: "🥘 ",
        description: "🥘 ",
      }

      result = Kettle::Jem::PrismGemspec.replace_gemspec_fields(
        destination_with_content,
        replacements,
      )

      # Should NOT overwrite with template defaults
      expect(result).not_to include('spec.summary = "🥘 "')
      expect(result).to include("🍲 kettle-rb OOTB SimpleCov config")
      expect(result).to include("🍲 A Covered Kettle of Test Coverage")
    end

    it "does not replace non-empty summary/description with template placeholders" do
      # This is the critical test - template has "🥘 " (placeholder)
      # destination has real content - destination should win

      result = Kettle::Jem::PrismGemspec.replace_gemspec_fields(
        fixture_content,
        {
          summary: "🥘 ",
          description: "🥘 ",
        },
      )

      # Original values from fixture should be preserved
      expect(result).to include("🍲 kettle-rb OOTB SimpleCov config")
      expect(result).to match(/A Covered Kettle of Test Coverage SOUP/)
    end
  end

  describe "preventing file corruption" do
    it "does not repeat gemspec attributes multiple times" do
      result = Kettle::Jem::PrismGemspec.replace_gemspec_fields(
        fixture_content,
        {
          name: "test-gem",
          authors: ["Test Author"],
          summary: "🥘 Test summary",
        },
      )

      # Count occurrences of spec.name
      name_count = result.scan(/spec\.name\s*=/).length
      expect(name_count).to eq(1), "spec.name should appear exactly once, found #{name_count} times"

      # Count occurrences of spec.authors
      authors_count = result.scan(/spec\.authors\s*=/).length
      expect(authors_count).to eq(1), "spec.authors should appear exactly once, found #{authors_count} times"
    end

    it "maintains valid Ruby syntax" do
      result = Kettle::Jem::PrismGemspec.replace_gemspec_fields(
        fixture_content,
        {
          name: "test-gem",
          version: "1.0.0",
        },
      )

      # Parse with Prism to ensure valid syntax
      parse_result = Prism.parse(result)
      expect(parse_result.success?).to be(true),
        "Generated gemspec should be valid Ruby. Errors: #{parse_result.errors.map(&:message).join(", ")}"
    end

    it "correctly identifies the end of Gem::Specification.new block" do
      result = Kettle::Jem::PrismGemspec.replace_gemspec_fields(
        fixture_content,
        {
          name: "test-gem",
        },
      )

      # The file should end with 'end' and a newline, not have content after it
      lines = result.lines
      last_non_empty_line = lines.reverse.find { |l| !l.strip.empty? }
      expect(last_non_empty_line&.strip).to eq("end")
    end
  end

  describe "handling gem_version variable" do
    it "does not corrupt the gem_version conditional assignment" do
      result = Kettle::Jem::PrismGemspec.replace_gemspec_fields(
        fixture_content,
        {
          name: "test-gem",
        },
      )

      # The gem_version variable should remain intact
      expect(result).to include("gem_version =")
      expect(result).to include('if RUBY_VERSION >= "3.1"')

      # Should not duplicate or corrupt the version logic
      gem_version_count = result.scan(/gem_version\s*=/).length
      expect(gem_version_count).to eq(1)
    end
  end

  describe "emoji extraction from README" do
    it "uses emoji from README H1 if available" do
      readme = <<~MD
        # 🍲 Kettle Soup Cover

        A test project.
      MD

      emoji = Kettle::Jem::PrismGemspec.extract_readme_h1_emoji(readme)
      expect(emoji).to eq("🍲")
    end

    it "returns nil when README has no emoji" do
      readme = <<~MD
        # Project Without Emoji

        Description.
      MD

      emoji = Kettle::Jem::PrismGemspec.extract_readme_h1_emoji(readme)
      expect(emoji).to be_nil
    end
  end

  describe "full integration with real fixture" do
    it "successfully templates the fixture without corruption" do
      # Simulate what template_task.rb does
      replacements = {
        name: fixture_content[/spec\.name\s*=\s*"([^"]+)"/, 1],
        authors: ["Peter Boling"],
        email: ["floss@galtzo.com"],
        summary: "🥘 ", # Template default - should NOT overwrite
        description: "🥘 ", # Template default - should NOT overwrite
      }

      result = Kettle::Jem::PrismGemspec.replace_gemspec_fields(
        fixture_content,
        replacements,
      )

      # Verify no corruption
      parse_result = Prism.parse(result)
      expect(parse_result.success?).to be(true)

      # Verify summary/description preserved
      expect(result).to include("🍲 kettle-rb OOTB SimpleCov config")

      # Verify no duplication
      expect(result.scan(/spec\.name\s*=/).length).to eq(1)
      expect(result.scan(/spec\.summary\s*=/).length).to eq(1)
      expect(result.scan(/spec\.description\s*=/).length).to eq(1)
    end
  end

  describe "gemspec operator-write merging" do
    let(:template_fixture_path) { File.expand_path("../fixtures/example-kettle-jem.template.gemspec", __dir__) }
    let(:destination_fixture_path) { File.expand_path("../fixtures/example-kettle-jem.gemspec", __dir__) }
    let(:template_fixture_content) { File.read(template_fixture_path) }
    let(:destination_fixture_content) { File.read(destination_fixture_path) }

    def merge_gemspec(src:, dest:)
      Kettle::Jem::SourceMerger.apply(
        strategy: :merge,
        src: src,
        dest: dest,
        path: "kettle-jem.gemspec",
        file_type: :gemspec,
      )
    end

    it "does not duplicate spec.rdoc_options operator writes" do
      merged = merge_gemspec(src: template_fixture_content, dest: destination_fixture_content)

      expect(Prism.parse(merged).success?).to be(true)
      expect(merged.scan(/^\s*spec\.rdoc_options \+= \[/).length).to eq(1), <<~MSG
        Expected merged gemspec to contain exactly one spec.rdoc_options += block.

        #{merged}
      MSG
    end

    it "is idempotent across repeated gemspec merges" do
      once = merge_gemspec(src: template_fixture_content, dest: destination_fixture_content)
      twice = merge_gemspec(src: template_fixture_content, dest: once)

      expect(Prism.parse(twice).success?).to be(true)
      expect(twice.scan(/^\s*spec\.rdoc_options \+= \[/).length).to eq(1), <<~MSG
        Expected repeated gemspec merges to keep a single spec.rdoc_options += block.

        #{twice}
      MSG
    end

    it "preserves destination-only spec.files entries while still accepting template additions" do
      merged = merge_gemspec(src: template_fixture_content, dest: destination_fixture_content)

      expect(Prism.parse(merged).success?).to be(true)
      expect(merged).to include('".devcontainer/**/*"')
      expect(merged).to include('"gemfiles/modular/*.gemfile"')
      expect(merged).to include('"lib/**/*.rb"')
      expect(merged).to include('"sig/**/*.rbs"')
    end

    it "preserves kettle-jem-style version, files, and runtime dependency customizations" do
      template = <<~RUBY
        # coding: utf-8
        # frozen_string_literal: true

        gem_version =
          if RUBY_VERSION >= "3.1" # rubocop:disable Gemspec/RubyVersionGlobalsUsage
            Module.new.tap { |mod| Kernel.load("#{__dir__}/lib/kettle/dev/version.rb", mod) }::Kettle::Dev::Version::VERSION
          else
            lib = File.expand_path("lib", __dir__)
            $LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
            require "kettle/dev/version"
            Kettle::Dev::Version::VERSION
          end

        Gem::Specification.new do |spec|
          spec.name = "demo"
          spec.version = gem_version
          spec.required_ruby_version = ">= 3.2.0"

          # Specify which files are part of the released package.
          spec.files = Dir[
            "lib/**/*.rb",
            "lib/**/*.rake",
            "sig/**/*.rbs",
          ]

          spec.add_dependency("version_gem", "~> 1.1", ">= 1.1.9")
        end
      RUBY

      destination = <<~RUBY
        # coding: utf-8
        # frozen_string_literal: true

        Gem::Specification.new do |spec|
          spec.name = "kettle-jem"
          spec.version = Module.new.tap { |mod| Kernel.load("#{__dir__}/lib/kettle/jem/version.rb", mod) }::Kettle::Jem::Version::VERSION
          spec.required_ruby_version = ">= 3.2.0"

          enumerate_package_files = lambda do |root|
            Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).select do |path|
              File.file?(path) && ![".", ".."].include?(File.basename(path))
            end
          end

          # Specify which files are part of the released package.
          spec.files = [
            *Dir["lib/**/*.rb"],
            *Dir["lib/**/*.rake"],
            *Dir["lib/**/*.yml"],
            *enumerate_package_files.call("template"),
            *enumerate_package_files.call("partials"),
            *Dir["sig/**/*.rbs"],
          ]

          spec.add_dependency("ast-merge", "~> 5.0", ">= 5.0.0")
          spec.add_dependency("token-resolver", "~> 1.0", ">= 1.0.2")
          spec.add_dependency("tree_haver", "~> 6.0", ">= 6.0.0")
          spec.add_dependency("service_actor", "~> 3.9")
          spec.add_dependency("service_actor-promptable", "~> 1.0")
          spec.add_dependency("kettle-dev", "~> 2.0")
          spec.add_dependency("kettle-drift", "~> 0.1")
          spec.add_dependency("version_gem", "~> 1.1", ">= 1.1.9")
        end
      RUBY

      merged = merge_gemspec(src: template, dest: destination)

      expect(Prism.parse(merged).success?).to be(true), merged
      expect(merged).to include('enumerate_package_files = lambda do |root|')
      expect(merged).to include('*enumerate_package_files.call("template")')
      expect(merged).to include('*enumerate_package_files.call("partials")')
      expect(merged).to include('spec.add_dependency("token-resolver", "~> 1.0", ">= 1.0.2")')
      expect(merged).to include('spec.add_dependency("service_actor", "~> 3.9")')
      expect(merged).to include('spec.add_dependency("kettle-drift", "~> 0.1")')
      expect(merged).to include('spec.add_dependency("kettle-dev", "~> 2.0")')
      expect(merged).to match(/spec\.version = Module\.new\.tap \{ \|mod\| Kernel\.load\(".*\/lib\/kettle\/jem\/version\.rb", mod\) \}::Kettle::Jem::Version::VERSION/)
      expect(merged).not_to include("gem_version =")
      expect(merged.scan(/^\s*spec\.files\s*=/).length).to eq(1)
    end

    it "replaces executable destination spec.files with the template Dir assignment" do
      template = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "demo"
          spec.version = "1.0.0"

          # Specify which files are part of the released package.
          spec.files = Dir[
            "lib/**/*.rb",
            "sig/**/*.rbs",
          ]
        end
      RUBY

      destination = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "demo"
          spec.version = "1.0.0"

          # Specify which files should be added to the gem when it is released.
          # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
          gemspec = File.basename(__FILE__)
          spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
            ls.readlines("\\x0", chomp: true).reject do |f|
              (f == gemspec) ||
                f.start_with?(*%w[bin/ Gemfile .gitignore .rspec spec/ .github/ .rubocop.yml])
            end
          end
        end
      RUBY

      merged = merge_gemspec(src: template, dest: destination)

      expect(Prism.parse(merged).success?).to be(true)
      expect(merged).to include("# Specify which files are part of the released package.")
      expect(merged).to include("spec.files = Dir[")
      expect(merged).to include('"lib/**/*.rb"')
      expect(merged).to include('"sig/**/*.rbs"')
      expect(merged).not_to include("IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL)")
    end

    it "preserves a custom nonliteral destination spec.files assignment" do
      template = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "demo"
          spec.version = "1.0.0"

          # Specify which files are part of the released package.
          spec.files = Dir[
            "lib/**/*.rb",
            "sig/**/*.rbs",
          ]
        end
      RUBY

      destination = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "demo"
          spec.version = "1.0.0"

          enumerate_package_files = lambda do |root|
            Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).select do |path|
              File.file?(path) && ![".", ".."].include?(File.basename(path))
            end
          end

          # Specify which files are part of the released package.
          spec.files = [
            *Dir["lib/**/*.rb"],
            *Dir["lib/**/*.rake"],
            *Dir["lib/**/*.yml"],
            *enumerate_package_files.call("template"),
            *enumerate_package_files.call("partials"),
            *Dir["sig/**/*.rbs"],
          ]
        end
      RUBY

      merged = merge_gemspec(src: template, dest: destination)

      expect(Prism.parse(merged).success?).to be(true)
      expect(merged).to include("enumerate_package_files = lambda do |root|")
      expect(merged).to include('*enumerate_package_files.call("template")')
      expect(merged).to include('*enumerate_package_files.call("partials")')
      expect(merged).to include('*Dir["lib/**/*.yml"]')
      expect(merged.scan(/^\s*spec\.files\s*=/).length).to eq(1)
      expect(merged).not_to include("spec.files = Dir[\n    \"lib/**/*.rb\",\n    \"sig/**/*.rbs\",")
    end

    it "keeps template-owned blank-line boundaries around inserted gemspec sections" do
      template = <<~RUBY
        # coding: utf-8
        # frozen_string_literal: true

        # kettle-jem:freeze
        # note
        # kettle-jem:unfreeze

        gem_version = "1.0.0"

        Gem::Specification.new do |spec|
          spec.name = "demo"
          spec.version = gem_version
          spec.required_ruby_version = ">= 2.3.0"

          # signing docs
          unless ENV.include?("SKIP_GEM_SIGNING")
            nil
          end

          spec.metadata["changelog_uri"] = "a"
          spec.metadata["bug_tracker_uri"] = "b"
          spec.metadata["documentation_uri"] = "c"
        end
      RUBY

      destination = <<~RUBY
        # frozen_string_literal: true

        require_relative "lib/demo/version"

        Gem::Specification.new do |spec|
          spec.name = "demo"
          spec.version = "1.0.0"
          spec.required_ruby_version = ">= 3.2.0"
          spec.metadata["changelog_uri"] = "A"

          spec.metadata["documentation_uri"] = "C"
        end
      RUBY

      merged = merge_gemspec(src: template, dest: destination)

      expect(Prism.parse(merged).success?).to be(true), merged
      expect(merged).to include("# frozen_string_literal: true\n\n# kettle-jem:freeze")
      expect(merged).not_to include("# frozen_string_literal: true\n\n\n# kettle-jem:freeze")
      expect(merged).to include("spec.required_ruby_version = \">= 2.3.0\"\n\n  # signing docs")
      expect(merged).to include("spec.metadata[\"changelog_uri\"] = \"a\"\n  spec.metadata[\"bug_tracker_uri\"] = \"b\"")
    end

    it "keeps runtime dependencies above the development dependency note block without duplicate dev entries and preserves aligned trailing comments" do
      template = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "demo"
          spec.version = "1.0.0"
          spec.add_dependency("version_gem", "~> 1.1", ">= 1.1.9")              # ruby >= 2.2.0

          # NOTE: It is preferable to list development dependencies in the gemspec due to increased
          #       visibility and discoverability.

          # Dev, Test, & Release Tasks
          spec.add_development_dependency("kettle-dev", "~> 2.0")                  # ruby >= 2.3.0

          # Security
          spec.add_development_dependency("bundler-audit", "~> 0.9.3")             # ruby >= 2.0.0
        end
      RUBY

      destination = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "demo"
          spec.version = "1.0.0"
          spec.add_dependency("version_gem", "~> 1.1", ">= 1.1.9")              # ruby >= 2.2.0
          # Dev tooling (runtime dep — kettle-jem extends kettle-dev's functionality)
          spec.add_dependency("kettle-dev", "~> 2.0")                            # ruby >= 2.3.0

          # NOTE: It is preferable to list development dependencies in the gemspec due to increased
          #       visibility and discoverability.

          # Security
          spec.add_development_dependency("bundler-audit", "~> 0.9.3")             # ruby >= 2.0.0
        end
      RUBY

      merged = merge_gemspec(src: template, dest: destination)

      expect(Prism.parse(merged).success?).to be(true)
      expect(merged).to include('spec.add_dependency("kettle-dev", "~> 2.0")                            # ruby >= 2.3.0')
      expect(merged).not_to include('spec.add_development_dependency("kettle-dev", "~> 2.0")')
      expect(merged).to include('spec.add_dependency("version_gem", "~> 1.1", ">= 1.1.9")              # ruby >= 2.2.0')
      expect(merged).to include("#       visibility and discoverability.\n\n  # Security")
      expect(merged).not_to include("#       visibility and discoverability.\n\n\n  # Security")

      runtime_index = merged.index('spec.add_dependency("kettle-dev", "~> 2.0")')
      note_index = merged.index("# NOTE: It is preferable to list development dependencies in the gemspec due to increased")
      bundler_audit_index = merged.index('spec.add_development_dependency("bundler-audit", "~> 0.9.3")')

      expect(runtime_index).to be < note_index
      expect(note_index).to be < bundler_audit_index
    end

    it "does not accumulate duplicate blank section separators across a nomono-shaped gemspec merge" do
      template = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "demo"
          spec.version = "1.0.0"
          spec.required_ruby_version = ">= 3.2.0"
          spec.metadata["rubygems_mfa_required"] = "true"

          # Specify which files are part of the released package.
          spec.files = Dir[
            "lib/**/*.rb",
          ]
          spec.require_paths = ["lib"]

          # Utilities
          spec.add_dependency("version_gem", "~> 1.1")

          # NOTE: It is preferable to list development dependencies in the gemspec due to increased
          #       visibility and discoverability.

          # Dev, Test, & Release Tasks
          spec.add_development_dependency("kettle-dev", "~> 2.0")

          # Security
          spec.add_development_dependency("bundler-audit", "~> 0.9.3")

          # Tasks
          spec.add_development_dependency("rake", "~> 13.0")
        end
      RUBY

      destination = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "demo"
          spec.version = "1.0.0"
          spec.required_ruby_version = ">= 3.2.0"
          spec.metadata["allowed_push_host"] = "https://rubygems.org"
          spec.metadata["rubygems_mfa_required"] = "true"

          # Specify which files should be added to the gem when it is released.
          gemspec = File.basename(__FILE__)
          spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
            ls.readlines("\\x0", chomp: true)
          end
          spec.require_paths = ["lib"]

          # Utilities
          spec.add_dependency("version_gem", "~> 1.1")

          # NOTE: It is preferable to list development dependencies in the gemspec due to increased
          #       visibility and discoverability.

          # Dev, Test, & Release Tasks
          spec.add_development_dependency("kettle-dev", "~> 2.0")

          # Security
          spec.add_development_dependency("bundler-audit", "~> 0.9.3")

          # Tasks
          spec.add_development_dependency("rake", "~> 13.0")
        end
      RUBY

      once = merge_gemspec(src: template, dest: destination)
      twice = merge_gemspec(src: template, dest: once)

      expect(Prism.parse(once).success?).to be(true), once
      expect(once).to include("spec.metadata[\"rubygems_mfa_required\"] = \"true\"\n\n  # Specify which files")
      expect(once).not_to include("spec.metadata[\"rubygems_mfa_required\"] = \"true\"\n\n\n  # Specify which files")
      expect(once).to include("spec.require_paths = [\"lib\"]\n\n  # Utilities")
      expect(once).not_to include("spec.require_paths = [\"lib\"]\n\n\n  # Utilities")
      expect(once).to include("spec.add_development_dependency(\"kettle-dev\", \"~> 2.0\")\n\n  # Security")
      expect(once).not_to include("spec.add_development_dependency(\"kettle-dev\", \"~> 2.0\")\n\n\n  # Security")
      expect(once).to include("spec.add_development_dependency(\"bundler-audit\", \"~> 0.9.3\")\n\n  # Tasks")
      expect(once).not_to include("spec.add_development_dependency(\"bundler-audit\", \"~> 0.9.3\")\n\n\n  # Tasks")

      expect(Prism.parse(twice).success?).to be(true), twice
      expect(twice).to eq(once)
    end
  end

  describe "block variable name mismatch" do
    def merge_gemspec(src:, dest:)
      Kettle::Jem::SourceMerger.apply(
        strategy: :merge,
        src: src,
        dest: dest,
        path: "example.gemspec",
        file_type: :gemspec,
      )
    end

    it "correctly merges template |spec| with destination |gem|" do
      template = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "example"
          spec.version = "1.0.0"
          spec.summary = "Template summary"
          spec.add_dependency("foo", "~> 1.0")
        end
      RUBY

      destination = <<~RUBY
        Gem::Specification.new do |gem|
          gem.name = "example"
          gem.version = "2.0.0"
          gem.summary = "Dest summary"
          gem.authors = ["Someone"]
        end
      RUBY

      merged = merge_gemspec(src: template, dest: destination)

      expect(Prism.parse(merged).success?).to be(true), "Merged gemspec should be valid Ruby:\n#{merged}"

      # With template-wins preference, template's variable name is used
      # and all lines are normalized to the same variable
      expect(merged).not_to match(/\bgem\./), "Merged output should not contain 'gem.' when template uses 'spec':\n#{merged}"
      expect(merged).to include("spec.name")
      expect(merged).to include("spec.version")
      expect(merged).to include("spec.summary")
      # Destination-only attributes preserved (renamed to template var)
      expect(merged).to include("spec.authors")
      # Template-only dependencies added
      expect(merged).to include('spec.add_dependency("foo", "~> 1.0")')
    end

    it "correctly merges template |spec| with destination |s|" do
      template = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "example"
          spec.version = "1.0.0"
        end
      RUBY

      destination = <<~RUBY
        Gem::Specification.new do |s|
          s.name = "example"
          s.version = "2.0.0"
          s.homepage = "https://example.com"
        end
      RUBY

      merged = merge_gemspec(src: template, dest: destination)

      expect(Prism.parse(merged).success?).to be(true), "Merged gemspec should be valid Ruby:\n#{merged}"
      # Template wins → template's variable name is used
      expect(merged).not_to match(/\bs\./), "Merged output should not contain 's.' when template uses 'spec':\n#{merged}"
      expect(merged).to include("spec.name")
      expect(merged).to include("spec.version")
      expect(merged).to include("spec.homepage")
    end
  end
end
