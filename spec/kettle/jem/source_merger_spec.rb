# frozen_string_literal: true

RSpec.describe Kettle::Jem::SourceMerger do
  describe ".apply" do
    let(:path) { "Gemfile" }

    it "returns template content without merging when strategy is :accept_template" do
      src = "gem \"foo\"\n"
      result = described_class.apply(strategy: :accept_template, src: src, dest: "gem \"bar\"\n", path: path)
      expect(result).to include("gem \"foo\"")
      expect(result).not_to include("gem \"bar\"")
    end

    it "returns the raw destination unchanged when strategy is :keep_destination" do
      src = "gem \"foo\"\n"
      dest = "gem \"bar\""

      expect(described_class).not_to receive(:detect_file_type)
      expect(Prism::Merge::SmartMerger).not_to receive(:new)

      result = described_class.apply(strategy: :keep_destination, src: src, dest: dest, path: path)
      expect(result).to eq(dest)
    end

    it "rejects legacy :skip strategy" do
      expect {
        described_class.apply(strategy: :skip, src: "", dest: "", path: path)
      }.to raise_error(Kettle::Jem::Error, /Unknown templating strategy/)
    end

    it "rejects legacy :replace strategy" do
      expect {
        described_class.apply(strategy: :replace, src: "", dest: "", path: path)
      }.to raise_error(Kettle::Jem::Error, /Unknown templating strategy/)
    end

    it "rejects legacy :append strategy" do
      expect {
        described_class.apply(strategy: :append, src: "", dest: "", path: path)
      }.to raise_error(Kettle::Jem::Error, /Unknown templating strategy/)
    end

    it "preserves kettle-jem:freeze blocks from the destination", :prism_merge_only do
      src = <<~RUBY
        source "https://example.com"
        gem "foo"
      RUBY
      dest = <<~RUBY
        source "https://gem.coop"
        # kettle-jem:freeze
        gem "bar", "~> 1.0"
      RUBY
      merged = described_class.apply(strategy: :merge, src: src, dest: dest, path: path)
      # With Prism::Merge and template preference, template's source wins
      # But freeze blocks from destination are preserved
      expect(merged).to include("source \"https://example.com\"")
      expect(merged).to include("gem \"foo\"")
      expect(merged).to include("# kettle-jem:freeze")
      expect(merged).to include("gem \"bar\", \"~> 1.0\"")
    end

    it "adds missing gem declarations without duplicates during merge", :prism_merge_only do
      src = <<~RUBY
        source "https://example.com"
        gem "foo"
        gem "bar"
      RUBY
      dest = <<~RUBY
        source "https://example.com"
        gem "foo"
      RUBY
      merged = described_class.apply(strategy: :merge, src: src, dest: dest, path: path)
      foo_count = merged.scan(/gem\s+["']foo["']/).length
      expect(foo_count).to eq(1)
      expect(merged).to include("gem \"bar\"")
    end

    it "routes Gemfile merges through PrismGemfile's public merge boundary" do
      src = "gem \"foo\"\n"
      dest = "gem \"bar\"\n"

      expect(Kettle::Jem::PrismGemfile).to receive(:merge).with(
        src,
        dest,
        merger_options: satisfy { |options| options.is_a?(Hash) && !options.key?(:signature_generator) },
        filter_template: false,
        path: path,
        force: false,
      ).and_return("gem \"foo\"\n")

      merged = described_class.apply(strategy: :merge, src: src, dest: dest, path: path)
      expect(merged).to eq("gem \"foo\"\n")
    end

    it "passes caller merge options through the Gemfile facade" do
      src = "gem \"foo\"\n"
      dest = "gem \"bar\"\n"

      expect(Kettle::Jem::PrismGemfile).to receive(:merge).with(
        src,
        dest,
        merger_options: hash_including(
          preference: :destination,
          add_template_only_nodes: false,
          freeze_token: "custom-freeze",
          max_recursion_depth: 7,
        ),
        filter_template: false,
        path: path,
        force: true,
      ).and_return(dest)

      merged = described_class.apply(
        strategy: :merge,
        src: src,
        dest: dest,
        path: path,
        preference: :destination,
        add_template_only_nodes: false,
        freeze_token: "custom-freeze",
        max_recursion_depth: 7,
        force: true,
      )

      expect(merged).to eq(dest)
    end

    it "replaces matching nodes during merge" do
      src = <<~RUBY
        gem "foo", "~> 2.0"
      RUBY
      dest = <<~RUBY
        gem "foo", "~> 1.0"
      RUBY
      merged = described_class.apply(strategy: :merge, src: src, dest: dest, path: path)
      # With Prism::Merge and template preference, template version should win
      expect(merged).to include("gem \"foo\", \"~> 2.0\"")
      # Should not have the old version (check more flexibly for whitespace)
      expect(merged).not_to match(/1\.0/)
    end

    it "reconciles gemspec fields while retaining frozen metadata", :prism_merge_only do
      src = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "updated-name"
          spec.add_dependency "foo"
        end
      RUBY
      dest = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "original-name"
          # kettle-jem:freeze
          spec.metadata["custom"] = "1"
          # kettle-jem:unfreeze
          spec.add_dependency "existing"
        end
      RUBY
      merged = described_class.apply(strategy: :merge, src: src, dest: dest, path: "sample.gemspec")
      expect(merged).to include("spec.name = \"updated-name\"")
      expect(merged).to include("spec.metadata[\"custom\"] = \"1\"")
    end

    it "adds missing Rake tasks without duplicating existing ones during merge", :prism_merge_only do
      src = <<~RUBY
        task :ci do
          sh "bundle exec rspec"
        end
      RUBY
      dest = <<~RUBY
        task :default do
          sh "bundle exec rake spec"
        end
      RUBY
      merged = described_class.apply(strategy: :merge, src: src, dest: dest, path: "Rakefile")
      default_count = merged.scan(/task\s+:default/).length
      expect(default_count).to eq(1)
      expect(merged).to include("task :ci")
      expect(merged).to include("task :default")
    end

    it "relocates the bootstrap default task next to its desc when an identical task already exists later in the Rakefile", :prism_merge_only do
      src = <<~RUBY
        # frozen_string_literal: true

        require "bundler/gem_tasks" if !Dir[File.join(__dir__, "*.gemspec")].empty?

        # Define a base default task early so other files can enhance it.
        desc "Default tasks aggregator"
        task :default do
          puts "Default task complete."
        end

        # External gems that define tasks - add here!
        require "kettle/dev"
      RUBY
      dest = <<~RUBY
        # frozen_string_literal: true

        require "bundler/gem_tasks" if !Dir[File.join(__dir__, "*.gemspec")].empty?

        # Define a base default task early so other files can enhance it.
        desc "Default tasks aggregator"
        # External gems that define tasks - add here!
        require "kettle/dev"

        task :default do
          puts "Default task complete."
        end
      RUBY

      merged = described_class.apply(strategy: :merge, src: src, dest: dest, path: "Rakefile")

      expect(merged.scan(/^task\s+:default\b/).size).to eq(1)
      expect(merged).to include(<<~RUBY)
        # Define a base default task early so other files can enhance it.
        desc "Default tasks aggregator"
        task :default do
          puts "Default task complete."
        end

        # External gems that define tasks - add here!
      RUBY
      expect(merged.index('desc "Default tasks aggregator"')).to be < merged.index('task :default do')
      expect(merged.index('task :default do')).to be < merged.index('# External gems that define tasks - add here!')
    end

    it "inserts the bootstrap default task when the desc is present but the template task is missing entirely", :prism_merge_only do
      src = <<~RUBY
        # frozen_string_literal: true

        require "bundler/gem_tasks" if !Dir[File.join(__dir__, "*.gemspec")].empty?

        # Define a base default task early so other files can enhance it.
        desc "Default tasks aggregator"
        task :default do
          puts "Default task complete."
        end

        # External gems that define tasks - add here!
        require "kettle/dev"
      RUBY
      dest = <<~RUBY
        # frozen_string_literal: true

        require "bundler/gem_tasks" if !Dir[File.join(__dir__, "*.gemspec")].empty?

        # Define a base default task early so other files can enhance it.
        desc "Default tasks aggregator"
        # External gems that define tasks - add here!
        require "kettle/dev"
      RUBY

      merged = described_class.apply(strategy: :merge, src: src, dest: dest, path: "Rakefile")

      expect(merged.scan(/^task\s+:default\b/).size).to eq(1)
      expect(merged).to include(<<~RUBY)
        # Define a base default task early so other files can enhance it.
        desc "Default tasks aggregator"
        task :default do
          puts "Default task complete."
        end

        # External gems that define tasks - add here!
      RUBY
      expect(merged.index('task :default do')).to be < merged.index('# External gems that define tasks - add here!')
    end

    it "applies caller merge options to generic Ruby merges" do
      src = "value = :template\n"
      dest = "value = :destination\n"
      merger = instance_double(Prism::Merge::SmartMerger, merge: dest.chomp)

      expect(Prism::Merge::SmartMerger).to receive(:new) do |template_content, destination_content, **kwargs|
        expect(template_content).to eq(src)
        expect(destination_content).to eq(dest)
        expect(kwargs[:preference]).to eq(:destination)
        expect(kwargs[:add_template_only_nodes]).to eq(false)
        expect(kwargs[:freeze_token]).to eq("custom-freeze")
        expect(kwargs[:max_recursion_depth]).to eq(3)
        expect(kwargs[:signature_generator]).to be_a(Proc)
        merger
      end

      merged = described_class.apply(
        strategy: :merge,
        src: src,
        dest: dest,
        path: "lib/example.rb",
        preference: :destination,
        add_template_only_nodes: false,
        freeze_token: "custom-freeze",
        max_recursion_depth: 3,
      )

      expect(merged).to eq(dest)
    end

    it "routes Appraisals merges through PrismAppraisals" do
      src = "appraise \"ruby-3-2\" do\nend\n"
      dest = "appraise \"ruby-3-1\" do\nend\n"

      expect(Kettle::Jem::PrismAppraisals).to receive(:merge).with(src, dest).and_return("appraise \"ruby-3-2\" do\nend")

      merged = described_class.apply(strategy: :merge, src: src, dest: dest, path: "Appraisals")
      expect(merged).to eq("appraise \"ruby-3-2\" do\nend\n")
    end

    it "routes gemspec merges through PrismGemspec" do
      src = "Gem::Specification.new do |spec|\n  spec.name = \"demo\"\nend\n"
      dest = "Gem::Specification.new do |spec|\n  spec.name = \"legacy\"\nend\n"

      expect(Kettle::Jem::PrismGemspec).to receive(:merge).with(src, dest).and_return("Gem::Specification.new do |spec|\n  spec.name = \"demo\"\nend")

      merged = described_class.apply(strategy: :merge, src: src, dest: dest, path: "demo.gemspec")
      expect(merged).to eq("Gem::Specification.new do |spec|\n  spec.name = \"demo\"\nend\n")
    end

    it "routes gemspec accept_template through PrismGemspec when generic context is provided" do
      src = "Gem::Specification.new do |spec|\n  spec.name = \"demo\"\nend\n"
      context = {
        min_ruby: Gem::Version.new("3.2"),
        entrypoint_require: "kettle/jem",
        namespace: "Kettle::Jem",
      }

      expect(Kettle::Jem::PrismGemspec).to receive(:merge).with(src, "", context: context).and_return(src.chomp)

      merged = described_class.apply(
        strategy: :accept_template,
        src: src,
        dest: "Gem::Specification.new do |spec|\n  spec.name = \"legacy\"\nend\n",
        path: "demo.gemspec",
        context: context,
      )

      expect(merged).to eq(src)
    end

    context "when preserving comments" do
      it "preserves inline comments on gem declarations", :prism_merge_only do
        src = <<~RUBY
          gem "foo", "~> 2.0"
        RUBY
        dest = <<~RUBY
          gem "foo", "~> 1.0" # production dependency
          gem "bar" # keep this one
        RUBY
        merged = described_class.apply(strategy: :merge, src: src, dest: dest, path: path)
        expect(merged).to include("gem \"foo\", \"~> 2.0\"")
        expect(merged).to include("gem \"bar\"")
        expect(merged).to include("# keep this one")
      end

      it "preserves leading comment blocks before statements", :prism_merge_only do
        src = <<~RUBY
          gem "foo"
        RUBY
        dest = <<~RUBY
          # This is a critical dependency
          # DO NOT REMOVE
          gem "bar"
        RUBY
        merged = described_class.apply(strategy: :merge, src: src, dest: dest, path: path)
        expect(merged).to include("# This is a critical dependency")
        expect(merged).to include("# DO NOT REMOVE")
        expect(merged).to include("gem \"bar\"")
        expect(merged).to include("gem \"foo\"")
      end

      it "preserves comments within blocks" do
        src = <<~RUBY
          Gem::Specification.new do |spec|
            spec.name = "updated-name"
          end
        RUBY
        dest = <<~RUBY
          Gem::Specification.new do |spec|
            spec.name = "original-name"
            # Important: this is used by CI
            spec.metadata["ci_config"] = "true"
          end
        RUBY
        merged = described_class.apply(strategy: :merge, src: src, dest: dest, path: "sample.gemspec")
        expect(merged).to include("spec.name = \"updated-name\"")
      end

      it "preserves comments in freeze blocks", :prism_merge_only do
        src = <<~RUBY
          gem "foo"
        RUBY
        dest = <<~RUBY
          # kettle-jem:freeze
          # Custom configuration
          gem "custom", path: "../custom"
          gem "another" # local override
          # kettle-jem:unfreeze
        RUBY
        merged = described_class.apply(strategy: :merge, src: src, dest: dest, path: path)
        expect(merged).to include("# Custom configuration")
        expect(merged).to include("gem \"custom\", path: \"../custom\"")
        expect(merged).to include("gem \"another\" # local override")
      end

      it "preserves multiline comments", :prism_merge_only do
        src = <<~RUBY
          gem "foo"
        RUBY
        dest = <<~RUBY
          # Beginning of comment block
          # Second line of comment
          # Third line of comment
          gem "bar"
        RUBY
        merged = described_class.apply(strategy: :merge, src: src, dest: dest, path: path)
        expect(merged).to include("# Beginning of comment block")
        expect(merged).to include("# Second line of comment")
        expect(merged).to include("# Third line of comment")
        bar_idx = merged.index("gem \"bar\"")
        comment_idx = merged.index("# Beginning of comment block")
        expect(comment_idx).to be < bar_idx if bar_idx && comment_idx
      end

      it "maintains idempotency with comments", :prism_merge_only do
        src = <<~RUBY
          gem "foo"
        RUBY
        dest = <<~RUBY
          gem "foo"
          # Important comment
          gem "bar"
        RUBY
        merged1 = described_class.apply(strategy: :merge, src: src, dest: dest, path: path)
        merged2 = described_class.apply(strategy: :merge, src: src, dest: merged1, path: path)
        expect(merged2.scan("# Important comment").length).to eq(1)
        bar_count = merged2.scan(/gem\s+["']bar["']/).length
        expect(bar_count).to eq(1)
        foo_count = merged2.scan(/gem\s+["']foo["']/).length
        expect(foo_count).to eq(1)
      end

      it "handles empty lines between comments and statements", :prism_merge_only do
        src = <<~RUBY
          gem "foo"
        RUBY
        dest = <<~RUBY
          # Comment with blank line below
          gem "bar"
        RUBY
        merged = described_class.apply(strategy: :merge, src: src, dest: dest, path: path)
        expect(merged).to include("# Comment with blank line below")
        expect(merged).to include("gem \"bar\"")
      end
    end
  end

  describe ".detect_file_type" do
    it "detects Gemfile" do
      expect(described_class.detect_file_type("Gemfile")).to eq(:gemfile)
    end

    it "detects Gemfile.lock-like paths" do
      expect(described_class.detect_file_type("gemfiles/modular/test.gemfile")).to eq(:gemfile)
    end

    it "detects Appraisals" do
      expect(described_class.detect_file_type("Appraisals")).to eq(:appraisals)
    end

    it "detects gemspec files" do
      expect(described_class.detect_file_type("my-gem.gemspec")).to eq(:gemspec)
    end

    it "detects Rakefile" do
      expect(described_class.detect_file_type("Rakefile")).to eq(:rakefile)
    end

    it "detects .rake files" do
      expect(described_class.detect_file_type("lib/tasks/test.rake")).to eq(:rakefile)
    end

    it "defaults to :ruby for unknown extensions" do
      expect(described_class.detect_file_type("lib/foo.rb")).to eq(:ruby)
    end
  end

  describe ".normalize_strategy" do
    it "returns :merge for nil" do
      expect(described_class.normalize_strategy(nil)).to eq(:merge)
    end

    it "converts string to symbol" do
      expect(described_class.normalize_strategy("merge")).to eq(:merge)
    end

    it "normalizes mixed case and whitespace" do
      expect(described_class.normalize_strategy(" Accept_Template ")).to eq(:accept_template)
    end

    it "returns supported symbol unchanged" do
      expect(described_class.normalize_strategy(:merge)).to eq(:merge)
    end

    it "normalizes accept_template" do
      expect(described_class.normalize_strategy("accept_template")).to eq(:accept_template)
    end

    it "normalizes keep_destination" do
      expect(described_class.normalize_strategy(" keep_destination ")).to eq(:keep_destination)
    end
  end

  describe ".ensure_trailing_newline" do
    it "returns empty string for nil" do
      expect(described_class.ensure_trailing_newline(nil)).to eq("")
    end

    it "adds newline when missing" do
      expect(described_class.ensure_trailing_newline("hello")).to eq("hello\n")
    end

    it "keeps existing newline" do
      expect(described_class.ensure_trailing_newline("hello\n")).to eq("hello\n")
    end
  end

  describe ".apply with unknown strategy" do
    it "raises an error" do
      expect {
        described_class.apply(strategy: :banana, src: "", dest: "", path: "test.rb")
      }.to raise_error(Kettle::Jem::Error, /Unknown templating strategy/)
    end
  end

  describe ".preset_for" do
    it "returns Gemfile preset for :gemfile" do
      expect(described_class.preset_for(:gemfile)).to eq(Kettle::Jem::Presets::Gemfile)
    end

    it "returns Appraisals preset for :appraisals" do
      expect(described_class.preset_for(:appraisals)).to eq(Kettle::Jem::Presets::Appraisals)
    end

    it "returns Gemspec preset for :gemspec" do
      expect(described_class.preset_for(:gemspec)).to eq(Kettle::Jem::Presets::Gemspec)
    end

    it "returns Rakefile preset for :rakefile" do
      expect(described_class.preset_for(:rakefile)).to eq(Kettle::Jem::Presets::Rakefile)
    end

    it "defaults to Gemfile preset for unknown types" do
      expect(described_class.preset_for(:unknown)).to eq(Kettle::Jem::Presets::Gemfile)
    end
  end
end
