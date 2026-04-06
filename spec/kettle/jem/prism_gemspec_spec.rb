# frozen_string_literal: true

RSpec.describe Kettle::Jem::PrismGemspec do
  def gemspec_field_node_for(content, field = "files")
    context = described_class.send(:gemspec_context, content)
    described_class.send(:find_field_node, context[:stmt_nodes], context[:blk_param], field)
  end

  def gemspec_field_node_and_source_for(content, field = "files")
    field_node = gemspec_field_node_for(content, field)
    [field_node, described_class.send(:exact_field_assignment_source, field_node, content)]
  end

  def wrap_gemspec_assignment(source)
    [
      "Gem::Specification.new do |spec|\n",
      source.to_s.lines.map { |line| "  #{line}" }.join,
      "end\n",
    ].join
  end

  describe ".merge" do
    it "runs the gemspec recipe through the shared recipe runner" do
      template = "Gem::Specification.new do |spec|\n  spec.name = \"demo\"\nend\n"
      dest = "Gem::Specification.new do |spec|\n  spec.name = \"legacy\"\nend\n"
      recipe = instance_double(Ast::Merge::Recipe::Config)
      runner = instance_double(Ast::Merge::Recipe::Runner)
      result = Struct.new(:content).new("Gem::Specification.new do |spec|\n  spec.name = \"demo\"\nend\n")

      allow(Kettle::Jem).to receive(:recipe).with(:gemspec).and_return(recipe)
      allow(Ast::Merge::Recipe::Runner).to receive(:new).with(recipe).and_return(runner)
      allow(runner).to receive(:run_content).with(
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

      allow(Kettle::Jem).to receive(:recipe).with(:gemspec).and_return(recipe)
      allow(Ast::Merge::Recipe::Runner).to receive(:new).with(recipe).and_return(runner)
      allow(runner).to receive(:run_content).with(
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

    it "re-raises gemspec merge errors from the recipe runner instead of silently falling back" do
      template = "Gem::Specification.new do |spec|\n  spec.name = \"demo\"\nend\n"
      dest = "Gem::Specification.new do |spec|\n  spec.name = \"legacy\"\nend\n"
      recipe = instance_double(Ast::Merge::Recipe::Config)
      runner = instance_double(Ast::Merge::Recipe::Runner)

      allow(Kettle::Jem).to receive(:recipe).with(:gemspec).and_return(recipe)
      allow(Ast::Merge::Recipe::Runner).to receive(:new).with(recipe).and_return(runner)
      expect(runner).to receive(:run_content).with(
        template_content: template,
        destination_content: dest,
        relative_path: "project.gemspec",
      ).and_raise(Kettle::Jem::Error, "Malformed merged gemspec content while harmonizing \"files\".")

      expect {
        described_class.merge(template, dest)
      }.to raise_error(Kettle::Jem::Error, /Malformed merged gemspec content while harmonizing "files"/)
    end

    it "raises when the recipe runner returns malformed merged gemspec content" do
      template = "Gem::Specification.new do |spec|\n  spec.name = \"demo\"\nend\n"
      dest = "Gem::Specification.new do |spec|\n  spec.name = \"legacy\"\nend\n"
      recipe = instance_double(Ast::Merge::Recipe::Config)
      runner = instance_double(Ast::Merge::Recipe::Runner)
      result = Struct.new(:content).new("Gem::Specification.new do |spec|\n  spec.name = \"demo\"\nendend\n")

      allow(Kettle::Jem).to receive(:recipe).with(:gemspec).and_return(recipe)
      allow(Ast::Merge::Recipe::Runner).to receive(:new).with(recipe).and_return(runner)
      allow(runner).to receive(:run_content).with(
        template_content: template,
        destination_content: dest,
        relative_path: "project.gemspec",
      ).and_return(result)

      expect {
        described_class.merge(template, dest)
      }.to raise_error(Kettle::Jem::Error, /Malformed merged gemspec content after recipe execution/)
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

  describe ".debug_error" do
    it "delegates rescued error reporting to kettle-dev without changing the optional context" do
      error = RuntimeError.new("boom")

      expect(Kettle::Dev).to receive(:debug_error).with(error, :merge)

      described_class.debug_error(error, :merge)
    end
  end

  describe ".build_runtime_context" do
    it "symbolizes hash-like context keys, overwrites stale runtime metadata, and drops blank optional fields" do
      expect(
        described_class.build_runtime_context(
          {"existing" => 1, :keep => true, "min_ruby" => "stale"},
          min_ruby: Gem::Version.new("3.2"),
          entrypoint_require: "kettle/jem",
          namespace: "Kettle::Jem",
        ),
      ).to eq(
        existing: 1,
        keep: true,
        min_ruby: Gem::Version.new("3.2"),
        entrypoint_require: "kettle/jem",
        namespace: "Kettle::Jem",
      )

      expect(
        described_class.build_runtime_context(
          Object.new,
          min_ruby: nil,
          entrypoint_require: " \n",
          namespace: "",
        ),
      ).to eq({})
    end
  end

  describe ".extract_leading_emoji" do
    it "returns only the first leading emoji grapheme cluster and otherwise yields nil" do
      expect(described_class.extract_leading_emoji("👨‍👩‍👧‍👦 Family gem")).to eq("👨‍👩‍👧‍👦")
      expect(described_class.extract_leading_emoji("plain text")).to be_nil
      expect(described_class.extract_leading_emoji("")).to be_nil
      expect(described_class.extract_leading_emoji(nil)).to be_nil
    end
  end

  describe ".extract_readme_h1_emoji" do
    it "extracts leading emoji from the first markdown H1 and ignores non-H1 or empty content" do
      readme = <<~MD
        # 🫖 Kettle Jem

        ## 🔥 Later heading
      MD

      expect(described_class.extract_readme_h1_emoji(readme)).to eq("🫖")
      expect(described_class.extract_readme_h1_emoji("## 🫖 Not a top heading\n")).to be_nil
      expect(described_class.extract_readme_h1_emoji("")).to be_nil
    end
  end

  describe ".extract_gemspec_emoji" do
    it "extracts emoji from gemspec summary before falling back to description and nil cases" do
      summary_first = <<~RUBY
        # frozen_string_literal: true

        Gem::Specification.new do |spec|
          spec.summary = "🍲 Summary"
          spec.description = "🫖 Description"
        end
      RUBY

      description_fallback = <<~RUBY
        Gem::Specification.new do |spec|
          spec.summary = "Plain summary"
          spec.description = "🫖 Description"
        end
      RUBY

      expect(described_class.extract_gemspec_emoji(summary_first)).to eq("🍲")
      expect(described_class.extract_gemspec_emoji(description_fallback)).to eq("🫖")
      expect(described_class.extract_gemspec_emoji("Gem::Specification.new do |spec|\n  spec.summary =\nend\n")).to be_nil
      expect(described_class.extract_gemspec_emoji(nil)).to be_nil
    end
  end

  describe ".sync_readme_h1_emoji" do
    it "rewrites the README H1 from gemspec emoji and otherwise preserves unsyncable content" do
      gemspec_with_emoji = <<~RUBY
        Gem::Specification.new do |spec|
          spec.summary = "🍲 Summary"
        end
      RUBY

      gemspec_without_emoji = <<~RUBY
        Gem::Specification.new do |spec|
          spec.summary = "Plain summary"
        end
      RUBY

      expect(
        described_class.sync_readme_h1_emoji(
          readme_content: "# 🥘 My Project\n\nDescription\n",
          gemspec_content: gemspec_with_emoji,
        ),
      ).to eq("# 🍲 My Project\n\nDescription\n")

      expect(
        described_class.sync_readme_h1_emoji(
          readme_content: "# My Project",
          gemspec_content: gemspec_with_emoji,
        ),
      ).to eq("# 🍲 My Project\n")

      expect(
        described_class.sync_readme_h1_emoji(
          readme_content: "No H1 here",
          gemspec_content: gemspec_with_emoji,
        ),
      ).to eq("No H1 here")

      expect(
        described_class.sync_readme_h1_emoji(
          readme_content: "# My Project\n",
          gemspec_content: gemspec_without_emoji,
        ),
      ).to eq("# My Project\n")

      expect(
        described_class.sync_readme_h1_emoji(
          readme_content: nil,
          gemspec_content: gemspec_with_emoji,
        ),
      ).to be_nil
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

    it "inserts spec.version after the first statement when the gemspec body has no spec.name anchor" do
      template_without_name_or_version = <<~RUBY
        gem_version = "ignored"

        Gem::Specification.new do |spec|
          spec.summary = "demo"
        end
      RUBY

      out = described_class.rewrite_version_loader(
        template_without_name_or_version,
        min_ruby: Gem::Version.new("3.2"),
        entrypoint_require: "kettle/jem",
        namespace: "Kettle::Jem",
      )

      expect(out).to include('spec.summary = "demo"')
      expect(out).to include('spec.version = Module.new.tap { |mod| Kernel.load("#{__dir__}/lib/kettle/jem/version.rb", mod) }::Kettle::Jem::Version::VERSION')
      expect(out.index('spec.summary = "demo"')).to be < out.index('spec.version = Module.new.tap { |mod| Kernel.load("#{__dir__}/lib/kettle/jem/version.rb", mod) }::Kettle::Jem::Version::VERSION')
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

  describe ".harmonize_merged_content" do
    it "short-circuits empty content and otherwise runs files-union before dependency normalization" do
      expect(described_class.harmonize_merged_content("", template_content: "template", destination_content: "dest")).to eq("")

      allow(described_class).to receive(:union_literal_dir_assignment).with(
        "merged",
        field: "files",
        template_content: "template",
        destination_content: "dest",
      ).and_return("unioned")
      allow(described_class).to receive(:cleanup_destination_nonliteral_dir_assignment).with(
        "unioned",
        field: "files",
        template_content: "template",
        destination_content: "dest",
      ).and_return("cleaned")
      allow(described_class).to receive(:normalize_dependency_sections).with(
        "cleaned",
        template_content: "template",
        destination_content: "dest",
        prefer_template: false,
      ).and_return("normalized")

      expect(
        described_class.harmonize_merged_content(
          "merged",
          template_content: "template",
          destination_content: "dest",
        ),
      ).to eq("normalized")
    end

    it "re-raises malformed-content gemspec errors instead of returning the unharmonized merge" do
      expect(described_class).to receive(:union_literal_dir_assignment).with(
        "merged",
        field: "files",
        template_content: "template",
        destination_content: "dest",
      ).and_raise(Kettle::Jem::Error, "Malformed merged gemspec content while harmonizing \"files\".")

      expect {
        described_class.harmonize_merged_content(
          "merged",
          template_content: "template",
          destination_content: "dest",
        )
      }.to raise_error(Kettle::Jem::Error, /Malformed merged gemspec content while harmonizing "files"/)
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

    it "keeps dependency records and lookup keyed by the same normalized scan contract" do
      content = <<~RUBY
        spec.add_dependency("demo", "~> 1.0") # runtime
        spec.add_development_dependency("rspec",    ">= 3")
      RUBY

      records = described_class.dependency_records(content.lines)
      lookup = described_class.dependency_line_lookup(content)

      expect(records).to eq(
        [
          {
            line_index: 0,
            method: "add_dependency",
            gem: "demo",
            line: "spec.add_dependency(\"demo\", \"~> 1.0\") # runtime\n",
            signature: '"demo", "~> 1.0"',
          },
          {
            line_index: 1,
            method: "add_development_dependency",
            gem: "rspec",
            line: "spec.add_development_dependency(\"rspec\",    \">= 3\")\n",
            signature: '"rspec", ">= 3"',
          },
        ],
      )
      expect(lookup).to eq(
        [
          [["add_dependency", '"demo", "~> 1.0"'], "spec.add_dependency(\"demo\", \"~> 1.0\") # runtime\n"],
          [["add_development_dependency", '"rspec", ">= 3"'], "spec.add_development_dependency(\"rspec\",    \">= 3\")\n"],
        ].to_h,
      )
    end

    it "filters development dependency records from the shared scan snapshot" do
      content = <<~RUBY
        # spec.add_development_dependency("ignored", "~> 9.9")
        spec.add_dependency("demo", "~> 1.0")
        spec.add_development_dependency("rspec",    ">= 3") # comment
      RUBY

      records = described_class.development_dependency_records(content)

      expect(records).to eq(
        [
          {
            line_index: 2,
            method: "add_development_dependency",
            gem: "rspec",
            line: "spec.add_development_dependency(\"rspec\",    \">= 3\") # comment\n",
            signature: '"rspec", ">= 3"',
          },
        ],
      )
    end

    it "indexes first development records by gem while tracking runtime gems from the shared scan snapshot" do
      content = <<~RUBY
        spec.add_dependency("demo", "~> 1.0")
        spec.add_development_dependency("rake", ">= 12")
        spec.add_development_dependency("rake", "~> 13.0")
      RUBY

      index = described_class.dependency_record_index(content)

      expect(index[:runtime_gems].to_a).to eq(["demo"])
      expect(index[:development_by_gem]).to eq(
        "rake" => {
          line_index: 1,
          method: "add_development_dependency",
          gem: "rake",
          line: "spec.add_development_dependency(\"rake\", \">= 12\")\n",
          signature: '"rake", ">= 12"',
        },
      )
    end

    it "classifies one dependency record into runtime gems or first development records without changing the shared index shape" do
      index = {development_by_gem: {}, runtime_gems: Set.new}
      first_dev = {
        line_index: 1,
        method: "add_development_dependency",
        gem: "rake",
        line: 'spec.add_development_dependency("rake", ">= 12")\n',
        signature: '"rake", ">= 12"',
      }

      described_class.index_dependency_record(index, {method: "add_dependency", gem: "demo"})
      described_class.index_dependency_record(index, first_dev)
      described_class.index_dependency_record(index, first_dev.merge(line_index: 2, signature: '"rake", "~> 13.0"'))
      described_class.index_dependency_record(index, {method: "metadata", gem: "ignored"})

      expect(index).to eq(
        development_by_gem: {"rake" => first_dev},
        runtime_gems: Set["demo"],
      )
    end

    it "routes dependency index building through the extracted single-record classifier" do
      records = [
        {method: "add_dependency", gem: "demo"},
        {method: "add_development_dependency", gem: "rake"},
        {method: "add_development_dependency", gem: "rspec"},
      ]
      seen_memo = nil

      expect(described_class).to receive(:index_dependency_record).with(kind_of(Hash), records[0]).ordered do |memo, record|
        expect(record).to be(records[0])
        expect(memo).to eq(development_by_gem: {}, runtime_gems: Set.new)
        memo[:runtime_gems] << record[:gem]
        seen_memo = memo
      end
      expect(described_class).to receive(:index_dependency_record).with(kind_of(Hash), records[1]).ordered do |memo, record|
        expect(record).to be(records[1])
        expect(memo).to be(seen_memo)
        expect(memo).to eq(development_by_gem: {}, runtime_gems: Set["demo"])
        memo[:development_by_gem][record[:gem]] = record
      end
      expect(described_class).to receive(:index_dependency_record).with(kind_of(Hash), records[2]).ordered do |memo, record|
        expect(record).to be(records[2])
        expect(memo).to be(seen_memo)
        expect(memo).to eq(
          development_by_gem: {"rake" => records[1]},
          runtime_gems: Set["demo"],
        )
        memo[:development_by_gem][record[:gem]] = record
      end

      result = described_class.build_dependency_index(records)

      expect(result).to eq(
        development_by_gem: {
          "rake" => records[1],
          "rspec" => records[2],
        },
        runtime_gems: Set["demo"],
      )
    end

    it "prefers one lookup source while filling unmatched dependency signatures from the fallback source" do
      template_content = <<~RUBY
        spec.add_dependency("demo", "~> 1.0") # template
        spec.add_development_dependency("rake", "~> 13.0")
      RUBY
      destination_content = <<~RUBY
        spec.add_dependency "demo", "~> 1.0" # destination
      RUBY

      lookup = described_class.preferred_dependency_line_lookup(
        template_content: template_content,
        destination_content: destination_content,
      )

      expect(lookup).to eq(
        [
          [["add_dependency", '"demo", "~> 1.0"'], "spec.add_dependency \"demo\", \"~> 1.0\" # destination\n"],
          [["add_development_dependency", '"rake", "~> 13.0"'], "spec.add_development_dependency(\"rake\", \"~> 13.0\")\n"],
        ].to_h,
      )
    end

    it "selects preferred and fallback dependency lookup sources based on prefer_template" do
      template_content = "template\n"
      destination_content = "destination\n"
      template_lookup = {template: true}
      destination_lookup = {destination: true}

      allow(described_class).to receive(:dependency_line_lookup).with(destination_content).ordered.and_return(destination_lookup)
      allow(described_class).to receive(:dependency_line_lookup).with(template_content).ordered.and_return(template_lookup)

      default_sources = described_class.preferred_dependency_lookup_sources(
        template_content: template_content,
        destination_content: destination_content,
      )

      expect(default_sources).to eq([destination_lookup, template_lookup])

      allow(described_class).to receive(:dependency_line_lookup).with(template_content).ordered.and_return(template_lookup)
      allow(described_class).to receive(:dependency_line_lookup).with(destination_content).ordered.and_return(destination_lookup)

      template_preferred_sources = described_class.preferred_dependency_lookup_sources(
        template_content: template_content,
        destination_content: destination_content,
        prefer_template: true,
      )

      expect(template_preferred_sources).to eq([template_lookup, destination_lookup])
    end

    it "routes preferred dependency lookup through the extracted source selector before filling fallback signatures" do
      template_content = "template\n"
      destination_content = "destination\n"
      preferred_lookup = {preferred: "line\n"}
      fallback_lookup = {fallback: "fallback\n"}

      allow(described_class).to receive(:preferred_dependency_lookup_sources).with(
        template_content: template_content,
        destination_content: destination_content,
        prefer_template: true,
      ).and_return([preferred_lookup, fallback_lookup])

      lookup = described_class.preferred_dependency_line_lookup(
        template_content: template_content,
        destination_content: destination_content,
        prefer_template: true,
      )

      expect(lookup).to eq(
        preferred: "line\n",
        fallback: "fallback\n",
      )
    end

    it "fills unmatched preferred dependency signatures from the fallback lookup without overwriting preferred lines" do
      preferred_lookup = {
        ["add_dependency", '"demo", "~> 1.0"'] => "spec.add_dependency \"demo\", \"~> 1.0\" # destination\n",
      }
      fallback_lookup = {
        ["add_dependency", '"demo", "~> 1.0"'] => "spec.add_dependency(\"demo\", \"~> 1.0\") # template\n",
        ["add_development_dependency", '"rake", "~> 13.0"'] => "spec.add_development_dependency(\"rake\", \"~> 13.0\")\n",
      }

      lookup = described_class.fill_preferred_dependency_lookup(preferred_lookup.dup, fallback_lookup)

      expect(lookup).to eq(
        ["add_dependency", '"demo", "~> 1.0"'] => "spec.add_dependency \"demo\", \"~> 1.0\" # destination\n",
        ["add_development_dependency", '"rake", "~> 13.0"'] => "spec.add_development_dependency(\"rake\", \"~> 13.0\")\n",
      )
    end

    it "routes preferred dependency lookup through the extracted fallback-fill helper after selecting sources" do
      template_content = "template\n"
      destination_content = "destination\n"
      preferred_lookup = {preferred: "line\n"}
      fallback_lookup = {fallback: "fallback\n"}
      merged_lookup = {preferred: "line\n", fallback: "fallback\n"}

      allow(described_class).to receive(:preferred_dependency_lookup_sources).with(
        template_content: template_content,
        destination_content: destination_content,
        prefer_template: false,
      ).and_return([preferred_lookup, fallback_lookup])
      allow(described_class).to receive(:fill_preferred_dependency_lookup).with(preferred_lookup, fallback_lookup).and_return(merged_lookup)

      lookup = described_class.preferred_dependency_line_lookup(
        template_content: template_content,
        destination_content: destination_content,
      )

      expect(lookup).to eq(merged_lookup)
    end

    it "rewrites only the targeted dependency line when a preferred source line is available" do
      updated_lines = [
        "spec.name = \"demo\"\n",
        "spec.add_dependency \"demo\", \"~> 1.0\" # destination\n",
      ]
      record = {
        line_index: 1,
        method: "add_dependency",
        signature: '"demo", "~> 1.0"',
      }
      preferred_lines = {
        ["add_dependency", '"demo", "~> 1.0"'] => "spec.add_dependency(\"demo\", \"~> 1.0\") # template\n",
      }

      described_class.apply_preferred_dependency_line(updated_lines, record, preferred_lines)

      expect(updated_lines).to eq(
        [
          "spec.name = \"demo\"\n",
          "spec.add_dependency(\"demo\", \"~> 1.0\") # template\n",
        ],
      )
    end

    it "routes shared preferred-line application through the extracted single-record helper while duplicating caller lines" do
      lines = ["original\n"]
      records = [{line_index: 0}, {line_index: 1}]
      preferred_lines = {preferred: true}
      seen_lines = []

      expect(described_class).to receive(:apply_preferred_dependency_line).with(kind_of(Array), records[0], preferred_lines).ordered do |updated_lines, record, forwarded_preferred_lines|
        expect(record).to be(records[0])
        expect(forwarded_preferred_lines).to be(preferred_lines)
        expect(updated_lines).not_to be(lines)
        expect(updated_lines).to eq(lines)
        updated_lines[0] = "first mutation\n"
        seen_lines << updated_lines
      end
      expect(described_class).to receive(:apply_preferred_dependency_line).with(kind_of(Array), records[1], preferred_lines).ordered do |updated_lines, record, forwarded_preferred_lines|
        expect(record).to be(records[1])
        expect(forwarded_preferred_lines).to be(preferred_lines)
        expect(updated_lines).to be(seen_lines.first)
        expect(updated_lines).to eq(["first mutation\n"])
        updated_lines[0] = "second mutation\n"
      end

      result = described_class.apply_preferred_dependency_lines(lines, records, preferred_lines)

      expect(result).to eq(["second mutation\n"])
      expect(lines).to eq(["original\n"])
    end

    it "returns a duplicate runtime-shadowed development dependency block range for one matching record" do
      lines = ["spec.add_development_dependency(\"rake\", \"~> 13.0\")\n"]
      record = {
        line_index: 0,
        method: "add_development_dependency",
        gem: "rake",
      }

      allow(described_class).to receive(:dependency_block_range).with(lines, 0).and_return(0..0)

      range = described_class.duplicate_runtime_shadowed_development_dependency_range(
        lines,
        record,
        runtime_gems: Set["rake"],
      )

      expect(range).to eq(0..0)
      expect(
        described_class.duplicate_runtime_shadowed_development_dependency_range(
          lines,
          record.merge(gem: "rspec"),
          runtime_gems: Set["rake"],
        ),
      ).to be_nil
    end

    it "routes runtime-shadowed dev range collection through the extracted single-record helper" do
      lines = ["spec.add_development_dependency(\"rake\", \"~> 13.0\")\n"]
      records = [{gem: "rake"}, {gem: "rspec"}, {gem: "rubocop"}]
      runtime_gems = Set["rake"]

      allow(described_class).to receive(:build_dependency_index).with(records).and_return(
        development_by_gem: {},
        runtime_gems: runtime_gems,
      )
      allow(described_class).to receive(:duplicate_runtime_shadowed_development_dependency_range).with(
        lines,
        records[0],
        runtime_gems: runtime_gems,
      ).ordered.and_return(0..0)
      allow(described_class).to receive(:duplicate_runtime_shadowed_development_dependency_range).with(
        lines,
        records[1],
        runtime_gems: runtime_gems,
      ).ordered.and_return(nil)
      allow(described_class).to receive(:duplicate_runtime_shadowed_development_dependency_range).with(
        lines,
        records[2],
        runtime_gems: runtime_gems,
      ).ordered.and_return(4..5)

      ranges = described_class.duplicate_runtime_shadowed_development_dependency_ranges(lines, records)

      expect(ranges).to eq([0..0, 4..5])
    end

    it "routes runtime-shadowed development dependency cleanup through range discovery and shared range removal" do
      lines = ["before\n", "duplicate\n", "after\n"]
      records = [{gem: "rake"}]
      ranges = [1..1]
      sentinel = ["before\n", "after\n"]

      allow(described_class).to receive(:duplicate_runtime_shadowed_development_dependency_ranges).with(lines, records).and_return(
        ranges,
      )
      allow(Kettle::Jem::PrismGemspec).to receive(:remove_line_ranges_with_plans).with(
        content: lines.join,
        lines: lines,
        ranges: ranges,
        metadata: {
          source: :kettle_jem_prism_gemspec_dependency_section,
          reason: :runtime_shadowed_development_dependency,
        },
      ).and_return(sentinel)

      result = described_class.remove_runtime_shadowed_development_dependency_blocks(lines, records)

      expect(result).to eq(sentinel)
    end

    it "builds dependency block ranges from the shared start and end helpers" do
      lines = ["# NOTE\n", "# Runtime\n", 'spec.add_dependency("alpha", "~> 1.0")\n', "\n"]

      allow(described_class).to receive(:attached_comment_start_index).with(
        lines,
        2,
        stop_above_index: 0,
      ).and_return(1)
      allow(described_class).to receive(:trailing_blank_line_end_index).with(lines, 2).and_return(3)

      range = described_class.dependency_block_range(lines, 2, stop_above_index: 0)

      expect(range).to eq(1..3)
    end

    it "removes line ranges through shared structural-edit plans while keeping caller lines intact" do
      lines = ["alpha\n", "beta\n", "gamma\n", "delta\n", "epsilon\n"]

      updated_lines = Kettle::Jem::PrismGemspec.remove_line_ranges_with_plans(
        content: lines.join,
        lines: lines,
        ranges: [1..2, 4..4],
        metadata: {source: :spec},
      )

      expect(updated_lines).to eq(["alpha\n", "delta\n"])
      expect(lines).to eq(["alpha\n", "beta\n", "gamma\n", "delta\n", "epsilon\n"])
    end

    it "collects only contiguous attached comments above a dependency while honoring the stop-above guard" do
      lines = [
        "# NOTE\n",
        "# Runtime\n",
        "# Additional context\n",
        'spec.add_dependency("alpha", "~> 1.0")\n',
      ]

      expect(described_class.attached_comment_start_index(lines, 3)).to eq(0)
      expect(described_class.attached_comment_start_index(lines, 3, stop_above_index: 0)).to eq(1)
      expect(described_class.attached_comment_start_index(lines, 3, stop_above_index: 1)).to eq(2)
    end

    it "extends a dependency block through one trailing blank separator line and otherwise leaves the end index unchanged" do
      lines = [
        "# Runtime\n",
        'spec.add_dependency("alpha", "~> 1.0")\n',
        "\n",
        "# Security\n",
      ]

      expect(described_class.trailing_blank_line_end_index(lines, 1)).to eq(2)
      expect(described_class.trailing_blank_line_end_index(lines, 0)).to eq(0)
      expect(described_class.trailing_blank_line_end_index(lines, 3)).to eq(3)
    end

    it "treats only blank-terminated dependency blocks as already separated" do
      separated_block = ["# Runtime\n", 'spec.add_dependency("alpha", "~> 1.0")\n', "\n"]
      tight_block = ["# Runtime\n", 'spec.add_dependency("alpha", "~> 1.0")\n']

      expect(described_class.block_ends_with_separator?(separated_block)).to be(true)
      expect(described_class.block_ends_with_separator?(tight_block)).to be(false)
      expect(described_class.block_ends_with_separator?([])).to be(true)
    end

    it "requires a leading separator only when the preceding line is nonblank" do
      expect(described_class.needs_separator_before_blocks?("spec.name = \"demo\"\n")).to be(true)
      expect(described_class.needs_separator_before_blocks?("\n")).to be(false)
      expect(described_class.needs_separator_before_blocks?(nil)).to be_nil
    end

    it "adds a trailing separator only when following content is nonblank and insertion is still tight" do
      tight_insertion = ["# Runtime\n", 'spec.add_dependency("alpha", "~> 1.0")\n']
      separated_insertion = tight_insertion + ["\n"]

      expect(described_class.needs_separator_after_blocks?("# NOTE\n", tight_insertion)).to be(true)
      expect(described_class.needs_separator_after_blocks?("\n", tight_insertion)).to be(false)
      expect(described_class.needs_separator_after_blocks?("# NOTE\n", separated_insertion)).to be(false)
      expect(described_class.needs_separator_after_blocks?(nil, tight_insertion)).to be_nil
    end

    it "builds one dependency scan payload while normalizing lookup line endings" do
      payload = described_class.dependency_scan_record('spec.add_dependency("demo", "~> 1.0")', 3)

      expect(payload).to eq(
        lookup_key: ["add_dependency", '"demo", "~> 1.0"'],
        normalized_line: "spec.add_dependency(\"demo\", \"~> 1.0\")\n",
        record: {
          line_index: 3,
          method: "add_dependency",
          gem: "demo",
          line: 'spec.add_dependency("demo", "~> 1.0")',
          signature: '"demo", "~> 1.0"',
        },
      )

      expect(described_class.dependency_scan_record("spec.name = \"demo\"\n", 0)).to be_nil
    end

    it "routes dependency scanning through the extracted single-line helper while preserving lookup precedence" do
      source = [["first\n", 0], ["second", 1], ["ignored\n", 2], ["third\n", 3]]
      first_payload = {
        lookup_key: ["add_dependency", '"demo", "~> 1.0"'],
        normalized_line: "first normalized\n",
        record: {line_index: 0, method: "add_dependency", gem: "demo", line: "first\n", signature: '"demo", "~> 1.0"'},
      }
      second_payload = {
        lookup_key: ["add_dependency", '"demo", "~> 1.0"'],
        normalized_line: "second normalized\n",
        record: {line_index: 1, method: "add_dependency", gem: "demo", line: "second", signature: '"demo", "~> 1.0"'},
      }
      third_payload = {
        lookup_key: ["add_development_dependency", '"rake", "~> 13.0"'],
        normalized_line: "third normalized\n",
        record: {line_index: 3, method: "add_development_dependency", gem: "rake", line: "third\n", signature: '"rake", "~> 13.0"'},
      }

      allow(described_class).to receive(:dependency_line_source).with("content").and_return(source)
      allow(described_class).to receive(:dependency_scan_record).with("first\n", 0).ordered.and_return(first_payload)
      allow(described_class).to receive(:dependency_scan_record).with("second", 1).ordered.and_return(second_payload)
      allow(described_class).to receive(:dependency_scan_record).with("ignored\n", 2).ordered.and_return(nil)
      allow(described_class).to receive(:dependency_scan_record).with("third\n", 3).ordered.and_return(third_payload)

      scan = described_class.dependency_scan("content")

      expect(scan).to eq(
        lookup: {
          ["add_dependency", '"demo", "~> 1.0"'] => "first normalized\n",
          ["add_development_dependency", '"rake", "~> 13.0"'] => "third normalized\n",
        },
        records: [
          first_payload[:record],
          second_payload[:record],
          third_payload[:record],
        ],
      )
    end

    it "yields indexed dependency scan source lines from arrays, strings, and nil content without changing line text" do
      expect(described_class.dependency_line_source(["first\n", "second"]).to_a).to eq(
        [["first\n", 0], ["second", 1]],
      )
      expect(described_class.dependency_line_source("alpha\nbeta").to_a).to eq(
        [["alpha\n", 0], ["beta", 1]],
      )
      expect(described_class.dependency_line_source(nil).to_a).to eq([])
    end

    it "builds dependency lookup keys from method and normalized signature without changing unrelated payload fields" do
      expect(
        described_class.dependency_lookup_key(
          method: "add_dependency",
          signature: '"demo", "~> 1.0"',
          gem: "demo",
          line_index: 3,
        ),
      ).to eq(["add_dependency", '"demo", "~> 1.0"'])
    end

    it "normalizes dependency signatures by trimming outer whitespace and collapsing internal runs" do
      expect(described_class.normalize_dependency_signature(%(  "demo",   "~> 1.0"  ))).to eq('"demo", "~> 1.0"')
      expect(described_class.normalize_dependency_signature("\n\t\"demo\",\n  \">= 1.0\"\t")).to eq('"demo", ">= 1.0"')
      expect(described_class.normalize_dependency_signature(nil)).to eq("")
    end

    it "treats only add_dependency and add_runtime_dependency as runtime methods" do
      expect(described_class.runtime_dependency_method?(:add_dependency)).to be(true)
      expect(described_class.runtime_dependency_method?("add_runtime_dependency")).to be(true)
      expect(described_class.runtime_dependency_method?(:add_development_dependency)).to be(false)
      expect(described_class.runtime_dependency_method?(nil)).to be(false)
    end

    it "recognizes only runtime dependency records that appear below the note boundary" do
      expect(
        described_class.runtime_record_after_note?(
          {method: "add_dependency", line_index: 6},
          4,
        ),
      ).to be(true)
      expect(
        described_class.runtime_record_after_note?(
          {method: "add_runtime_dependency", line_index: 5},
          4,
        ),
      ).to be(true)
      expect(
        described_class.runtime_record_after_note?(
          {method: "add_dependency", line_index: 4},
          4,
        ),
      ).to be(false)
      expect(
        described_class.runtime_record_after_note?(
          {method: "add_development_dependency", line_index: 7},
          4,
        ),
      ).to be(false)
    end

    it "routes runtime-after-note filtering through the extracted single-record predicate" do
      lines = ["spec.name = \"demo\"\n"]
      note_index = 4
      records = [
        {method: "add_dependency", line_index: 6},
        {method: "add_runtime_dependency", line_index: 5},
        {method: "add_development_dependency", line_index: 7},
      ]

      allow(described_class).to receive(:runtime_record_after_note?).with(records[0], note_index).ordered.and_return(true)
      allow(described_class).to receive(:runtime_record_after_note?).with(records[1], note_index).ordered.and_return(true)
      allow(described_class).to receive(:runtime_record_after_note?).with(records[2], note_index).ordered.and_return(false)

      result = described_class.runtime_records_after_note(lines, note_index, records: records)

      expect(result).to eq(records.take(2))
    end

    it "finds runtime records below the note through the default dependency-record accessor" do
      lines = <<~RUBY.lines
        spec.name = "demo"

        # NOTE: It is preferable to list development dependencies in the gemspec due to increased
        #       visibility and discoverability.

        spec.add_dependency("alpha", "~> 1.0")
        spec.add_development_dependency("rake", "~> 13.0")
      RUBY

      note_end_index = described_class.note_block_end_index(lines, described_class.note_block_start_index(lines))

      records = described_class.runtime_records_after_note(lines, note_end_index)

      expect(records).to eq(
        [
          {
            line_index: 5,
            method: "add_dependency",
            gem: "alpha",
            line: "spec.add_dependency(\"alpha\", \"~> 1.0\")\n",
            signature: '"alpha", "~> 1.0"',
          },
        ],
      )
    end

    # Regression: bare `#` continuation lines inside the NOTE block were not
    # recognized as part of the block, so note_block_end_index stopped too early.
    # This caused the lines between note_end and the runtime dep (the tail of the NOTE
    # block comment) to be treated as attached comments of that dep and moved with it,
    # duplicating them on every subsequent template run.
    it "includes bare comment-continuation lines (empty #) within the note block boundary" do
      lines = <<~TEXT.lines
        # NOTE: It is preferable to list development dependencies in the gemspec due to increased
        #       visibility and discoverability.
        #       Thus, dev dependencies in gemspec must have
        #
        #       required_ruby_version ">= 3.2.0" (or lower)
        #
        #       Development dependencies that require strictly newer Ruby versions should be in a "gemfile".
      TEXT

      note_start = described_class.note_block_start_index(lines)
      note_end = described_class.note_block_end_index(lines, note_start)

      # Every line is part of the note block (indices 0..6)
      expect(note_end).to eq(6)
    end

    it "does not pull note-block continuation lines into an extracted runtime dependency block" do
      # The NOTE block tail (bare # + required_ruby_version + ...) is separated from
      # the runtime dep only by contiguous comments (no blank line in between).
      # Without the fix, attached_comment_start_index would walk all the way back
      # through those comment lines and include them in the moved block, placing the
      # note-block tail *before* NOTE. On subsequent template-merge passes the template
      # re-inserts those lines back into the NOTE body, producing one more duplicate
      # on every run.
      lines = <<~TEXT.lines
        spec.add_dependency("version_gem", "~> 1.1")

        # NOTE: It is preferable to list development dependencies in the gemspec due to increased
        #       visibility and discoverability.
        #       Thus, dev dependencies in gemspec must have
        #
        #       required_ruby_version ">= 3.2.0" (or lower)
        #
        #       Development dependencies that require strictly newer Ruby versions should be in a "gemfile".
        # Dev tooling
        spec.add_dependency("kettle-dev", "~> 2.0")

        spec.add_development_dependency("rake", "~> 13.0")
      TEXT

      result = described_class.relocate_runtime_dependency_blocks_before_note(lines)

      # The note-block tail (required_ruby_version etc.) must remain INSIDE the NOTE
      # block – i.e. it must appear *after* the "# NOTE:" line in the output.
      note_pos = result.index("# NOTE:")
      req_ruby_pos = result.index("required_ruby_version")
      expect(req_ruby_pos).to be > note_pos

      # kettle-dev must land before the NOTE block after relocation
      expect(result.index('spec.add_dependency("kettle-dev"')).to be < note_pos
    end

    it "builds a relocation snapshot from the note boundary and runtime records that trail it" do
      lines = ["spec.name = \"demo\"\n"]
      note_index = 2
      note_end_index = 4
      runtime_after_note = [{line_index: 6, method: "add_dependency", gem: "alpha"}]

      allow(described_class).to receive(:note_block_start_index).with(lines).and_return(note_index)
      allow(described_class).to receive(:note_block_end_index).with(lines, note_index).and_return(note_end_index)
      allow(described_class).to receive(:runtime_records_after_note).with(lines, note_end_index).and_return(runtime_after_note)

      snapshot = described_class.runtime_dependency_relocation_snapshot(lines)

      expect(snapshot).to eq(
        note_end_index: note_end_index,
        note_trailing_blank: nil,
        runtime_after_note: runtime_after_note,
      )
    end

    it "extracts one runtime dependency block below the note boundary into a moved block plus remaining lines" do
      lines = <<~RUBY.lines
        spec.name = "demo"

        # NOTE: It is preferable to list development dependencies in the gemspec due to increased
        #       visibility and discoverability.

        # Runtime
        spec.add_dependency("alpha", "~> 1.0")

        spec.add_development_dependency("rake", "~> 13.0")
      RUBY
      note_end_index = described_class.note_block_end_index(lines, described_class.note_block_start_index(lines))

      moved_block, remaining_lines = described_class.extract_runtime_dependency_block_after_note(
        lines,
        {line_index: 6, method: "add_dependency", gem: "alpha"},
        note_end_index,
      )

      expect(moved_block).to eq(
        [
          "# Runtime\n",
          "spec.add_dependency(\"alpha\", \"~> 1.0\")\n",
          "\n",
        ],
      )
      expect(remaining_lines).to eq(
        [
          "spec.name = \"demo\"\n",
          "\n",
          "# NOTE: It is preferable to list development dependencies in the gemspec due to increased\n",
          "#       visibility and discoverability.\n",
          "\n",
          "spec.add_development_dependency(\"rake\", \"~> 13.0\")\n",
        ],
      )
    end

    it "routes runtime-block extraction through the extracted single-record helper while preserving moved-block order" do
      lines = ["original\n"]
      note_end_index = 4
      records = [
        {line_index: 6, method: "add_dependency", gem: "alpha"},
        {line_index: 9, method: "add_dependency", gem: "beta"},
      ]
      beta_block = ["beta\n"]
      alpha_block = ["alpha\n"]
      after_beta = ["after beta\n"]
      after_alpha = ["after alpha\n"]

      allow(described_class).to receive(:extract_runtime_dependency_block_after_note).with(
        lines,
        records[1],
        note_end_index,
      ).ordered.and_return([beta_block, after_beta])
      allow(described_class).to receive(:extract_runtime_dependency_block_after_note).with(
        after_beta,
        records[0],
        note_end_index,
      ).ordered.and_return([alpha_block, after_alpha])

      moved_blocks, remaining_lines = described_class.extract_runtime_dependency_blocks_after_note(lines, records, note_end_index)

      expect(moved_blocks).to eq([alpha_block, beta_block])
      expect(remaining_lines).to eq(after_alpha)
    end

    it "returns the original lines joined when there is no note block to insert above" do
      lines = ["spec.name = \"demo\"\n", 'spec.add_dependency("alpha", "~> 1.0")\n']

      allow(described_class).to receive(:note_block_start_index).with(lines).and_return(nil)
      expect(described_class).not_to receive(:build_dependency_block_insertion)

      result = described_class.insert_blocks_before_note(lines, [["ignored\n"]])

      expect(result).to eq(lines.join)
    end

    it "routes note-adjacent runtime block reinsertion through the shared insertion builder" do
      lines = [
        "spec.name = \"demo\"\n",
        "\n",
        "# NOTE: It is preferable to list development dependencies in the gemspec due to increased\n",
      ]
      blocks = [["# Runtime\n", "spec.add_dependency(\"alpha\", \"~> 1.0\")\n", "\n"]]
      insertion = ["# Runtime\n", "spec.add_dependency(\"alpha\", \"~> 1.0\")\n", "\n"]

      allow(described_class).to receive(:note_block_start_index).with(lines).and_return(2)
      allow(described_class).to receive(:build_dependency_block_insertion).with(
        blocks,
        before_line: lines[1],
        after_line: lines[2],
      ).and_return(insertion)

      result = described_class.insert_blocks_before_note(lines, blocks)

      expect(result).to eq(
        "spec.name = \"demo\"\n" \
          "\n" \
          "# Runtime\n" \
          "spec.add_dependency(\"alpha\", \"~> 1.0\")\n" \
          "\n" \
          "# NOTE: It is preferable to list development dependencies in the gemspec due to increased\n",
      )
    end

    it "adds exactly one leading separator before moved blocks when prior content is nonblank" do
      blocks = [["# Runtime\n", "spec.add_dependency(\"alpha\", \"~> 1.0\")\n"]]

      insertion = described_class.build_dependency_block_insertion(
        blocks,
        before_line: "spec.name = \"demo\"\n",
        after_line: "# NOTE\n",
      )

      expect(insertion).to eq(
        [
          "\n",
          "# Runtime\n",
          "spec.add_dependency(\"alpha\", \"~> 1.0\")\n",
          "\n",
        ],
      )
    end

    it "does not duplicate an added trailing separator when the following line is already blank" do
      blocks = [["# Runtime\n", "spec.add_dependency(\"alpha\", \"~> 1.0\")\n"]]

      insertion = described_class.build_dependency_block_insertion(
        blocks,
        before_line: "\n",
        after_line: "\n",
      )

      expect(insertion).to eq(
        [
          "# Runtime\n",
          "spec.add_dependency(\"alpha\", \"~> 1.0\")\n",
        ],
      )
    end

    it "runs preferred-line application, runtime-shadowed dev cleanup, and runtime relocation through the shared normalization pipeline" do
      content = "  spec.add_dependency(\"demo\", \"~> 1.0\")\n"
      template_content = "template\n"
      destination_content = "destination\n"
      lines = content.lines
      preferred_lines = {"signature" => "preferred\n"}
      records = [{line_index: 0, method: "add_dependency", gem: "demo", signature: "signature"}]
      formatted_lines = ["formatted\n"]
      deduped_lines = ["deduped\n"]
      sentinel = "normalized\n"

      allow(described_class).to receive(:preferred_dependency_line_lookup).with(
        template_content: template_content,
        destination_content: destination_content,
        prefer_template: false,
      ).and_return(preferred_lines)
      allow(described_class).to receive(:dependency_records).with(lines).and_return(records)
      allow(described_class).to receive(:apply_preferred_dependency_lines).with(lines, records, preferred_lines).and_return(
        formatted_lines,
      )
      allow(described_class).to receive(:remove_runtime_shadowed_development_dependency_blocks).with(
        formatted_lines,
        records,
      ).and_return(deduped_lines)
      allow(described_class).to receive(:relocate_runtime_dependency_blocks_before_note).with(deduped_lines).and_return(
        sentinel,
      )

      out = normalize_dependency_sections(
        content,
        template_content: template_content,
        destination_content: destination_content,
      )

      expect(out).to eq(sentinel)
    end

    it "routes runtime relocation through the extracted snapshot helper before moving and reinserting blocks" do
      lines = ["spec.name = \"demo\"\n"]
      relocation_snapshot = {
        note_end_index: 4,
        runtime_after_note: [{line_index: 6, method: "add_dependency", gem: "alpha"}],
      }
      moved_blocks = [["# Runtime\n", 'spec.add_dependency("alpha", "~> 1.0")\n']]
      remaining_lines = ["remaining\n"]
      sentinel = "relocated\n"

      allow(described_class).to receive(:runtime_dependency_relocation_snapshot).with(lines).and_return(relocation_snapshot)
      allow(described_class).to receive(:extract_runtime_dependency_blocks_after_note).with(
        lines,
        relocation_snapshot[:runtime_after_note],
        relocation_snapshot[:note_end_index],
      ).and_return([moved_blocks, remaining_lines])
      allow(described_class).to receive(:insert_blocks_before_note).with(remaining_lines, moved_blocks).and_return(sentinel)

      out = described_class.relocate_runtime_dependency_blocks_before_note(lines)

      expect(out).to eq(sentinel)
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

    it "removes every duplicate development dependency block for a gem promoted to runtime" do
      content = <<~RUBY
        spec.add_dependency("kettle-dev", "~> 2.0")

        # Dev Tasks
        spec.add_development_dependency("kettle-dev", "~> 2.0")

        # Legacy duplicate
        spec.add_development_dependency("kettle-dev", "~> 1.9")

        spec.add_development_dependency("rake", "~> 13.0")
      RUBY

      out = normalize_dependency_sections(
        content,
        template_content: content,
        destination_content: content,
      )

      expect(out).to include('spec.add_dependency("kettle-dev", "~> 2.0")')
      expect(out.scan('add_development_dependency("kettle-dev"').size).to eq(0)
      expect(out).to include('spec.add_development_dependency("rake", "~> 13.0")')
      expect(out).not_to include("# Dev Tasks")
      expect(out).not_to include("# Legacy duplicate")
    end

    it "keeps the note separator when removing a duplicate development block directly below the note" do
      content = <<~RUBY
        spec.add_dependency("kettle-dev", "~> 2.0")

        # NOTE: It is preferable to list development dependencies in the gemspec due to increased
        #       visibility and discoverability.

        # Dev, Test, & Release Tasks
        spec.add_development_dependency("kettle-dev", "~> 2.0")

        # Security
        spec.add_development_dependency("bundler-audit", "~> 0.9.3")
      RUBY

      out = normalize_dependency_sections(
        content,
        template_content: content,
        destination_content: content,
      )

      expect(out).to include("#       visibility and discoverability.\n\n# Security")
      expect(out).not_to include("#       visibility and discoverability.\n# Dev, Test, & Release Tasks")
      expect(out).not_to include("#       visibility and discoverability.\n\n\n# Security")
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
      expect(out.index("# Runtime")).to be < out.index("# NOTE: It is preferable to list development dependencies in the gemspec due to increased")
      expect(out.index("# NOTE: It is preferable to list development dependencies in the gemspec due to increased")).to be < out.index("# Security")
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

      expect(out.index("# Runtime A")).to be < out.index('spec.add_dependency("alpha", "~> 1.0")')
      expect(out.index('spec.add_dependency("alpha", "~> 1.0")')).to be < out.index("# Runtime B")
      expect(out.index("# Runtime B")).to be < out.index('spec.add_runtime_dependency("beta", "~> 2.0")')
      expect(out.index('spec.add_runtime_dependency("beta", "~> 2.0")')).to be < out.index("# NOTE: It is preferable to list development dependencies in the gemspec due to increased")
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

    it "preserves a single blank line after a blank-terminated note block when a remaining development section still follows it" do
      content = <<~RUBY
        spec.name = "demo"
        spec.add_dependency("version_gem", "~> 1.1")

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

      expect(out).to include("#       visibility and discoverability.\n\n# Security")
      expect(out).not_to include("#       visibility and discoverability.\n\n\n# Security")
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

      expect(out.index("# Runtime")).to be < out.index("# NOTE: It is preferable to list development dependencies in the gemspec due to increased")
      expect(out.index("# NOTE: It is preferable to list development dependencies in the gemspec due to increased")).to be < out.index("# Detached")
      expect(out.index("# Detached")).to be < out.index("# Security")
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
      expect(out.index("# Runtime")).to be < out.index("# NOTE: It is preferable to list development dependencies in the gemspec due to increased")
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

  describe ".development_dependency_entries_fallback" do
    it "projects fallback dependency records into ordered entry hashes while stripping only trailing line endings" do
      records = [
        {
          gem: "rake",
          line: "spec.add_development_dependency(\"rake\", \"~> 13.0\")\n",
          signature: '"rake", "~> 13.0"',
          ignored: :extra,
        },
        {
          gem: "rspec",
          line: "  spec.add_development_dependency(\"rspec\", \">= 3\")   \n",
          signature: '"rspec", ">= 3"',
        },
      ]

      allow(described_class::DependencySectionPolicy).to receive(:development_dependency_records).with("content").and_return(records)

      expect(described_class.send(:development_dependency_entries_fallback, "content")).to eq(
        [
          {
            gem: "rake",
            line: 'spec.add_development_dependency("rake", "~> 13.0")',
            signature: '"rake", "~> 13.0"',
          },
          {
            gem: "rspec",
            line: '  spec.add_development_dependency("rspec", ">= 3")',
            signature: '"rspec", ">= 3"',
          },
        ],
      )
    end
  end

  describe ".development_dependency_signatures" do
    it "maps extracted development dependency entries to compact sorted signatures" do
      entries = [
        {gem: "rake", signature: '"rake", "~> 13.0"'},
        {gem: "ignored", signature: nil},
        {gem: "bundler-audit", signature: '"bundler-audit", "~> 0.9.3"'},
        {gem: "rspec", signature: '"rspec", ">= 3"'},
      ]

      allow(described_class).to receive(:development_dependency_entries).with("content").and_return(entries)

      expect(described_class.development_dependency_signatures("content")).to eq(
        [
          '"bundler-audit", "~> 0.9.3"',
          '"rake", "~> 13.0"',
          '"rspec", ">= 3"',
        ],
      )
    end
  end

  describe ".union_literal_dir_assignment" do
    it "raises a descriptive error when any gemspec context is unavailable" do
      allow(described_class).to receive(:gemspec_context).with("merged").and_return(nil)
      allow(described_class).to receive(:gemspec_context).with("template").and_return({stmt_nodes: [:template], blk_param: "spec"})
      allow(described_class).to receive(:gemspec_context).with("destination").and_return({stmt_nodes: [:destination], blk_param: "spec"})

      expect {
        described_class.send(
          :union_literal_dir_assignment,
          "merged",
          field: "files",
          template_content: "template",
          destination_content: "destination",
        )
      }.to raise_error(Kettle::Jem::Error, /Malformed merged gemspec content while harmonizing "files"/)
    end

    it "merges the requested field through a shared splice-plan application when all contexts resolve" do
      merged_context = {stmt_nodes: [:merged], blk_param: "spec"}
      template_context = {stmt_nodes: [:template], blk_param: "spec"}
      destination_context = {stmt_nodes: [:destination], blk_param: "spec"}
      location = double("Prism::Location", start_line: 3, end_line: 6)
      merged_node = instance_double(Prism::CallNode, slice: "merged files", location: location)
      template_node = instance_double(Prism::CallNode, slice: "template files")
      destination_node = instance_double(Prism::CallNode, slice: "destination files")

      allow(described_class).to receive(:gemspec_context).with("merged").and_return(merged_context)
      allow(described_class).to receive(:gemspec_context).with("template").and_return(template_context)
      allow(described_class).to receive(:gemspec_context).with("destination").and_return(destination_context)
      allow(described_class).to receive(:find_field_node).with(merged_context[:stmt_nodes], merged_context[:blk_param], "files").and_return(merged_node)
      allow(described_class).to receive(:find_field_node).with(template_context[:stmt_nodes], template_context[:blk_param], "files").and_return(template_node)
      allow(described_class).to receive(:find_field_node).with(destination_context[:stmt_nodes], destination_context[:blk_param], "files").and_return(destination_node)
      allow(described_class).to receive(:merge_dir_assignment_source).with(
        merged_node: merged_node,
        merged_content: "merged",
        template_node: template_node,
        template_content: "template",
        destination_node: destination_node,
        destination_content: "destination",
      ).and_return("replacement")
      allow(described_class).to receive(:build_splice_plan).with(
        content: "merged",
        replacement: "replacement",
        start_line: 3,
        end_line: 6,
        metadata: {
          source: :kettle_jem_prism_gemspec,
          edit: :union_literal_dir_assignment,
          field: "files",
        },
      ).and_return(:plan)
      allow(described_class).to receive(:merged_content_from_plans).with(
        content: "merged",
        plans: [:plan],
        metadata: {
          source: :kettle_jem_prism_gemspec,
          edit: :union_literal_dir_assignment,
          field: "files",
        },
      ).and_return("updated")

      expect(
        described_class.send(
          :union_literal_dir_assignment,
          "merged",
          field: "files",
          template_content: "template",
          destination_content: "destination",
        ),
      ).to eq("updated")
    end

    it "raises when the merged gemspec content is malformed instead of attempting textual recovery" do
      content = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "demo"
          spec.version = "1.0.0"

          gemspec = File.basename(__FILE__)
        spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
            ls.readlines("\\x0", chomp: true).reject do |f|
              (f == gemspec)
                f.start_with?("lib/")
            end
          endend
      RUBY

      template_content = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "demo"
          spec.version = "1.0.0"
          spec.files = Dir[
            "lib/**/*.rb",
            "sig/**/*.rbs",
          ]
        end
      RUBY

      destination_content = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "demo"
          spec.version = "1.0.0"

          gemspec = File.basename(__FILE__)
          spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
            ls.readlines("\\x0", chomp: true).reject do |f|
              (f == gemspec) ||
                f.start_with?("lib/")
            end
          end
        end
      RUBY

      expect {
        described_class.send(
          :union_literal_dir_assignment,
          content,
          field: "files",
          template_content: template_content,
          destination_content: destination_content,
        )
      }.to raise_error(Kettle::Jem::Error, /Malformed merged gemspec content while harmonizing "files"/)
    end
  end

  describe ".gemspec_context" do
    it "returns nil when Prism parsing fails before any gemspec extraction happens" do
      failure = instance_double(Prism::ParseResult, success?: false)

      allow(Kettle::Jem::PrismUtils).to receive(:parse_with_comments).with("broken").and_return(failure)

      expect(described_class.send(:gemspec_context, "broken")).to be_nil
    end

    it "returns nil when the parsed content does not contain a Gem::Specification.new block" do
      content = <<~RUBY
        module Demo
          VALUE = 1
        end
      RUBY

      expect(described_class.send(:gemspec_context, content)).to be_nil
    end

    it "extracts the gemspec call, explicit block param, and body statements" do
      content = <<~RUBY
        Gem::Specification.new do |g|
          g.name = "demo"
          g.summary = "summary"
        end
      RUBY

      context = described_class.send(:gemspec_context, content)

      expect(context[:gemspec_call]).to be_a(Prism::CallNode)
      expect(context[:blk_param]).to eq("g")
      expect(context[:stmt_nodes].map(&:name)).to eq([:name=, :summary=])
    end

    it "falls back to spec when the gemspec block omits an explicit block parameter" do
      content = <<~RUBY
        Gem::Specification.new do
          configure!
        end
      RUBY

      context = described_class.send(:gemspec_context, content)

      expect(context[:blk_param]).to eq("spec")
      expect(context[:stmt_nodes].map(&:name)).to eq([:configure!])
    end

    it "returns a usable context for gemspec blocks with an explicit param but no body statements" do
      content = <<~RUBY
        Gem::Specification.new do |spec|
        end
      RUBY

      context = described_class.send(:gemspec_context, content)

      expect(context).to include(
        blk_param: "spec",
        gemspec_call: be_a(Prism::CallNode),
        stmt_nodes: [],
      )
    end

    it "returns a usable context for empty gemspec blocks without an explicit block parameter" do
      content = <<~RUBY
        Gem::Specification.new do
        end
      RUBY

      context = described_class.send(:gemspec_context, content)

      expect(context).to include(
        blk_param: "spec",
        gemspec_call: be_a(Prism::CallNode),
        stmt_nodes: [],
      )
    end

    it "returns an empty statement list for comment-only gemspec blocks" do
      content = <<~RUBY
        Gem::Specification.new do |spec|
          # Important context comment
          # kettle-jem:freeze
          # Frozen content
          # kettle-jem:unfreeze
        end
      RUBY

      context = described_class.send(:gemspec_context, content)

      expect(context).to include(
        blk_param: "spec",
        gemspec_call: be_a(Prism::CallNode),
      )
      expect(context[:blk_param]).to eq("spec")
      expect(context[:stmt_nodes]).to eq([])
    end

    it "falls back to spec for comment-only gemspec blocks without an explicit block parameter" do
      content = <<~RUBY
        Gem::Specification.new do
          # Important context comment
          # kettle-jem:freeze
          # Frozen content
          # kettle-jem:unfreeze
        end
      RUBY

      context = described_class.send(:gemspec_context, content)

      expect(context).to include(
        blk_param: "spec",
        gemspec_call: be_a(Prism::CallNode),
        stmt_nodes: [],
      )
    end
  end

  describe ".merge_dir_assignment_source" do
    it "keeps merged framing while combining unique groups in destination, merged, then template order" do
      merged_content = <<~RUBY
        Gem::Specification.new do |spec|
          spec.files = Dir[
            "lib/**/*.rb",
            "sig/**/*.rbs",
          ]
        end
      RUBY

      template_content = <<~RUBY
        Gem::Specification.new do |spec|
          spec.files = Dir[
            "lib/**/*.rb",
            "README.md",
          ]
        end
      RUBY

      destination_content = <<~RUBY
        Gem::Specification.new do |spec|
          spec.files = Dir[
            "sig/**/*.rbs",
            "test/**/*.rb",
          ]
        end
      RUBY

      expect(
        described_class.send(
          :merge_dir_assignment_source,
          merged_node: gemspec_field_node_for(merged_content),
          merged_content: merged_content,
          template_node: gemspec_field_node_for(template_content),
          template_content: template_content,
          destination_node: gemspec_field_node_for(destination_content),
          destination_content: destination_content,
        ),
      ).to eq(
        "  spec.files = Dir[\n    " \
          "\"sig/**/*.rbs\",\n    " \
          "\"test/**/*.rb\",\n    " \
          "\"lib/**/*.rb\",\n    " \
          "\"README.md\",\n  " \
          "]\n",
      )
    end

    it "returns nil when any source assignment is executable rather than a literal Dir list" do
      merged_source = <<~RUBY
        spec.files = Dir[
          "lib/**/*.rb",
        ]
      RUBY

      template_source = <<~RUBY
        spec.files = Dir[
          "lib/**/*.rb",
          "sig/**/*.rbs",
        ]
      RUBY

      destination_source = <<~RUBY
        spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
          ls.readlines("\\x0", chomp: true).reject do |f|
            f.start_with?("lib/")
          end
        end
      RUBY
      merged_content = wrap_gemspec_assignment(merged_source)
      template_content = wrap_gemspec_assignment(template_source)
      destination_content = wrap_gemspec_assignment(destination_source)

      expect(
        described_class.send(
          :merge_dir_assignment_source,
          merged_node: gemspec_field_node_for(merged_content),
          merged_content: merged_content,
          template_node: gemspec_field_node_for(template_content),
          template_content: template_content,
          destination_node: gemspec_field_node_for(destination_content),
          destination_content: destination_content,
        ),
      ).to be_nil
    end
  end

  describe ".replace_destination_nonliteral_assignment_source" do
    it "replaces a nonliteral destination assignment with the template literal Dir assignment and attached comment while dropping Bundler boilerplate" do
      merged_content = <<~RUBY
        Gem::Specification.new do |spec|
          # Specify which files are part of the released package.
          # Specify which files should be added to the gem when it is released.
          # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
          gemspec = File.basename(__FILE__)
          spec.files = Dir[
            generated_files,
            "lib/**/*.rb",
          ]
        end
      RUBY

      template_content = <<~RUBY
        Gem::Specification.new do |spec|
          # Specify which files are part of the released package.
          spec.files = Dir[
            "lib/**/*.rb",
            "sig/**/*.rbs",
          ]
        end
      RUBY

      destination_content = <<~RUBY
        Gem::Specification.new do |spec|
          spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
            ls.readlines("\\x0", chomp: true)
          end
        end
      RUBY

      expect(
        described_class.send(
          :replace_destination_nonliteral_assignment_source,
          merged_node: gemspec_field_node_for(merged_content),
          merged_content: merged_content,
          template_node: gemspec_field_node_for(template_content),
          template_content: template_content,
          destination_node: gemspec_field_node_for(destination_content),
          destination_content: destination_content,
        ),
      ).to eq(
        replacement: "  # Specify which files are part of the released package.\n  " \
          "spec.files = Dir[\n    " \
          "\"lib/**/*.rb\",\n    " \
          "\"sig/**/*.rbs\",\n  " \
          "]\n",
        start_line: 3,
        end_line: 9,
      )
    end
  end

  describe ".literal_dir_assignment_parts" do
    it "returns nil when the assignment is not a multiline literal Dir list" do
      content = <<~RUBY
        Gem::Specification.new do |spec|
          spec.files = Dir[
            generated_files,
            "lib/**/*.rb",
          ]
        end
      RUBY

      expect(described_class.send(:literal_dir_assignment_parts, gemspec_field_node_for(content), content: content)).to be_nil
    end

    it "keeps the outer framing and grouped literal-entry lines" do
      content = <<~RUBY
        Gem::Specification.new do |spec|
          spec.files = Dir[
            # keep lib
            "lib/**/*.rb",
            "sig/**/*.rbs", # keep inline
          ] # keep closing
        end
      RUBY

      expect(described_class.send(:literal_dir_assignment_parts, gemspec_field_node_for(content), content: content)).to eq(
        opening: "  spec.files = Dir[\n",
        closing: "  ] # keep closing\n",
        groups: [
          {
            key: '"lib/**/*.rb"',
            lines: [
              "    # keep lib\n",
              "    \"lib/**/*.rb\",\n",
            ],
          },
          {
            key: '"sig/**/*.rbs"',
            lines: [
              "    \"sig/**/*.rbs\", # keep inline\n",
            ],
          },
        ],
      )
    end
  end

  describe ".literal_collection_groups" do
    it "groups each literal entry with any leading blank or comment lines" do
      content = <<~RUBY
        Gem::Specification.new do |spec|
          spec.files = Dir[

            # keep me with lib
            "lib/**/*.rb",
            # keep me with sig
            "sig/**/*.rbs",
          ]
        end
      RUBY
      field_node, source = gemspec_field_node_and_source_for(content)
      rhs_node = described_class.send(:literal_dir_assignment_rhs_node, field_node)

      expect(described_class.send(:literal_collection_groups, field_node: field_node, rhs_node: rhs_node, lines: source.lines)).to eq([
        {
          key: '"lib/**/*.rb"',
          lines: [
            "\n",
            "    # keep me with lib\n",
            "    \"lib/**/*.rb\",\n",
          ],
        },
        {
          key: '"sig/**/*.rbs"',
          lines: [
            "    # keep me with sig\n",
            "    \"sig/**/*.rbs\",\n",
          ],
        },
      ])
    end

    it "drops trailing blank or comment lines that are not followed by a literal entry" do
      content = <<~RUBY
        Gem::Specification.new do |spec|
          spec.files = Dir[
            # keep me with lib
            "lib/**/*.rb",

            # trailing comment
          ]
        end
      RUBY
      field_node, source = gemspec_field_node_and_source_for(content)
      rhs_node = described_class.send(:literal_dir_assignment_rhs_node, field_node)

      expect(described_class.send(:literal_collection_groups, field_node: field_node, rhs_node: rhs_node, lines: source.lines)).to eq([
        {
          key: '"lib/**/*.rb"',
          lines: [
            "    # keep me with lib\n",
            "    \"lib/**/*.rb\",\n",
          ],
        },
      ])
    end
  end

  describe ".dependency_node_records" do
    it "returns an empty list when there are no statement nodes to inspect" do
      expect(described_class.send(:dependency_node_records, nil, "spec")).to eq([])
    end

    it "keeps only dependency calls with a nonblank gem literal and projects shared node metadata" do
      dependency_location = instance_double(Prism::Location, start_line: 5, end_line: 6)
      blank_location = instance_double(Prism::Location, start_line: 7, end_line: 7)
      dependency_arguments = instance_double(Prism::ArgumentsNode, arguments: [:rake_arg])
      blank_arguments = instance_double(Prism::ArgumentsNode, arguments: [:blank_arg])
      dependency_node = instance_double(
        Prism::CallNode,
        arguments: dependency_arguments,
        name: :add_development_dependency,
        location: dependency_location,
      )
      blank_node = instance_double(
        Prism::CallNode,
        arguments: blank_arguments,
        name: :add_dependency,
        location: blank_location,
      )
      ignored_node = Object.new

      allow(described_class).to receive(:gemspec_dependency_call?).with(dependency_node, "spec").ordered.and_return(true)
      allow(Kettle::Jem::PrismUtils).to receive(:extract_literal_value).with(:rake_arg).ordered.and_return("rake")
      allow(described_class).to receive(:gemspec_dependency_call?).with(blank_node, "spec").ordered.and_return(true)
      allow(Kettle::Jem::PrismUtils).to receive(:extract_literal_value).with(:blank_arg).ordered.and_return(nil)
      allow(described_class).to receive(:gemspec_dependency_call?).with(ignored_node, "spec").ordered.and_return(false)

      expect(
        described_class.send(:dependency_node_records, [dependency_node, blank_node, ignored_node], "spec"),
      ).to eq([
        {
          node: dependency_node,
          method: "add_development_dependency",
          gem: "rake",
          start_line: 5,
          end_line: 6,
        },
      ])
    end
  end

  describe ".dependency_node_index" do
    it "tracks runtime gems while keeping the first development record per gem on the Prism-backed path" do
      content = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "example"
          spec.version = "1.0.0"
          spec.add_dependency("demo", "~> 1.0")
          spec.add_development_dependency("rake", ">= 12")
          spec.add_development_dependency("rake", "~> 13.0")
        end
      RUBY

      context = described_class.send(:gemspec_context, content)
      index = described_class.send(:dependency_node_index, context[:stmt_nodes], context[:blk_param])

      expect(index[:runtime_gems].to_a).to eq(["demo"])
      expect(index[:development_by_gem].fetch("rake")).to include(
        method: "add_development_dependency",
        gem: "rake",
        start_line: 5,
        end_line: 5,
      )
    end
  end

  describe ".dependency_indent" do
    it "extracts only the leading indentation from the first line of the node slice" do
      node = instance_double(Prism::CallNode, slice: "    spec.add_dependency(\"demo\")\n      continued")

      expect(described_class.send(:dependency_indent, node)).to eq("    ")
    end

    it "returns an empty indentation string when the first line is not indented" do
      node = instance_double(Prism::CallNode, slice: "spec.add_dependency(\"demo\")\n")

      expect(described_class.send(:dependency_indent, node)).to eq("")
    end
  end

  describe ".formatted_dependency_line" do
    it "trims the desired line, prefixes the provided indent, and appends one newline" do
      expect(
        described_class.send(:formatted_dependency_line, "  spec.add_dependency(\"demo\", \"~> 1.0\")  ", indent: "    "),
      ).to eq("    spec.add_dependency(\"demo\", \"~> 1.0\")\n")
    end

    it "coerces nil into an indented blank line" do
      expect(described_class.send(:formatted_dependency_line, nil, indent: "  ")).to eq("  \n")
    end
  end

  describe ".dependency_signature" do
    it "joins normalized arguments in order and returns an empty signature when no arguments are present" do
      args = [:gem_arg, :constraint_arg, :platform_arg]
      arguments_node = instance_double(Prism::ArgumentsNode, arguments: args)
      node = instance_double(Prism::CallNode, arguments: arguments_node)

      allow(Kettle::Jem::PrismUtils).to receive(:normalize_argument).with(:gem_arg).ordered.and_return('"demo"')
      allow(Kettle::Jem::PrismUtils).to receive(:normalize_argument).with(:constraint_arg).ordered.and_return('"~> 1.0"')
      allow(Kettle::Jem::PrismUtils).to receive(:normalize_argument).with(:platform_arg).ordered.and_return("platforms: %i[mri]")

      expect(described_class.send(:dependency_signature, node)).to eq('"demo", "~> 1.0", platforms: %i[mri]')
      expect(described_class.send(:dependency_signature, instance_double(Prism::CallNode, arguments: nil))).to eq("")
    end
  end

  describe ".development_dependency_sync_actions" do
    it "forwards ordered desired entries through the single-gem sync classifier" do
      desired = {
        "kettle-dev" => '  spec.add_development_dependency("kettle-dev", "~> 2.0")',
        "rake" => '  spec.add_development_dependency("rake", "~> 13.0")',
        "rspec" => '  spec.add_development_dependency("rspec", "~> 3.12")',
      }
      dependency_index = {runtime_gems: Set.new, development_by_gem: {}}
      runtime_action = {action: :skip_runtime, gem_name: "kettle-dev"}
      replacement_action = {action: :replace_existing_dev, gem_name: "rake"}
      insertion_action = {action: :insert_missing, gem_name: "rspec"}

      allow(described_class).to receive(:development_dependency_sync_action).with(
        "kettle-dev",
        desired.fetch("kettle-dev"),
        dependency_index,
      ).ordered.and_return(runtime_action)
      allow(described_class).to receive(:development_dependency_sync_action).with(
        "rake",
        desired.fetch("rake"),
        dependency_index,
      ).ordered.and_return(replacement_action)
      allow(described_class).to receive(:development_dependency_sync_action).with(
        "rspec",
        desired.fetch("rspec"),
        dependency_index,
      ).ordered.and_return(insertion_action)

      result = described_class.send(:development_dependency_sync_actions, desired, dependency_index)

      expect(result).to eq([runtime_action, replacement_action, insertion_action])
    end
  end

  describe ".development_dependency_sync_action" do
    it "classifies runtime, existing-dev, and missing-dev gems without changing payload shape" do
      dev_record = {
        method: "add_development_dependency",
        gem: "rake",
        start_line: 5,
        end_line: 5,
      }
      dependency_index = {
        runtime_gems: Set["kettle-dev"],
        development_by_gem: {"rake" => dev_record},
      }

      expect(
        described_class.send(
          :development_dependency_sync_action,
          "kettle-dev",
          '  spec.add_development_dependency("kettle-dev", "~> 2.0")',
          dependency_index,
        ),
      ).to eq(
        action: :skip_runtime,
        gem_name: "kettle-dev",
        desired_line: '  spec.add_development_dependency("kettle-dev", "~> 2.0")',
      )

      expect(
        described_class.send(
          :development_dependency_sync_action,
          "rake",
          '  spec.add_development_dependency("rake", "~> 13.0")',
          dependency_index,
        ),
      ).to eq(
        action: :replace_existing_dev,
        gem_name: "rake",
        desired_line: '  spec.add_development_dependency("rake", "~> 13.0")',
        record: dev_record,
      )

      expect(
        described_class.send(
          :development_dependency_sync_action,
          "rspec",
          '  spec.add_development_dependency("rspec", "~> 3.12")',
          dependency_index,
        ),
      ).to eq(
        action: :insert_missing,
        gem_name: "rspec",
        desired_line: '  spec.add_development_dependency("rspec", "~> 3.12")',
        record: nil,
      )
    end
  end

  describe ".development_dependency_missing_lines" do
    it "filters ordered single-action missing-line results through the shared batch helper" do
      sync_actions = [
        {action: :skip_runtime, gem_name: "kettle-dev"},
        {action: :insert_missing, gem_name: "rspec"},
        {action: :replace_existing_dev, gem_name: "rake"},
        {action: :insert_missing, gem_name: "rubocop"},
      ]
      rspec_line = "    spec.add_development_dependency(\"rspec\", \"~> 3.12\")\n"
      rubocop_line = "    spec.add_development_dependency(\"rubocop\", \"~> 1.72\")\n"

      allow(described_class).to receive(:development_dependency_missing_line).with(
        sync_actions[0],
        indent: "    ",
      ).ordered.and_return(nil)
      allow(described_class).to receive(:development_dependency_missing_line).with(
        sync_actions[1],
        indent: "    ",
      ).ordered.and_return(rspec_line)
      allow(described_class).to receive(:development_dependency_missing_line).with(
        sync_actions[2],
        indent: "    ",
      ).ordered.and_return(nil)
      allow(described_class).to receive(:development_dependency_missing_line).with(
        sync_actions[3],
        indent: "    ",
      ).ordered.and_return(rubocop_line)

      result = described_class.send(:development_dependency_missing_lines, sync_actions, indent: "    ")

      expect(result).to eq([rspec_line, rubocop_line])
    end
  end

  describe ".development_dependency_missing_line" do
    it "formats only insert-missing actions into normalized dependency lines" do
      expect(
        described_class.send(
          :development_dependency_missing_line,
          {
            action: :insert_missing,
            desired_line: 'spec.add_development_dependency("rspec", "~> 3.12")',
          },
          indent: "    ",
        ),
      ).to eq("    spec.add_development_dependency(\"rspec\", \"~> 3.12\")\n")

      expect(
        described_class.send(
          :development_dependency_missing_line,
          {
            action: :skip_runtime,
            desired_line: 'spec.add_development_dependency("kettle-dev", "~> 2.0")',
          },
        ),
      ).to be_nil

      expect(
        described_class.send(
          :development_dependency_missing_line,
          {
            action: :replace_existing_dev,
            desired_line: 'spec.add_development_dependency("rake", "~> 13.0")',
          },
        ),
      ).to be_nil
    end
  end

  describe ".development_dependency_sync_snapshot_payload" do
    it "builds the shared snapshot hash from ordered sync actions and missing lines" do
      sync_actions = [
        {action: :replace_existing_dev, gem_name: "rake"},
        {
          action: :insert_missing,
          gem_name: "rspec",
          desired_line: 'spec.add_development_dependency("rspec", "~> 3.12")',
        },
      ]
      missing_lines = ["    spec.add_development_dependency(\"rspec\", \"~> 3.12\")\n"]

      allow(described_class).to receive(:development_dependency_missing_lines).with(
        sync_actions,
        indent: "    ",
      ).and_return(missing_lines)

      result = described_class.send(
        :development_dependency_sync_snapshot_payload,
        sync_actions,
        indent: "    ",
      )

      expect(result).to eq(
        sync_actions: sync_actions,
        missing_lines: missing_lines,
      )
    end
  end

  describe ".development_dependency_sync_snapshot" do
    it "returns ordered mixed-action sync decisions and missing lines" do
      content = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "example"
          spec.version = "1.0.0"
          spec.add_dependency("kettle-dev", "~> 2.0")
          spec.add_development_dependency("rake", ">= 12")
        end
      RUBY

      desired = {
        "kettle-dev" => '  spec.add_development_dependency("kettle-dev", "~> 2.0")',
        "rake" => '  spec.add_development_dependency("rake", "~> 13.0")',
        "rspec" => '  spec.add_development_dependency("rspec", "~> 3.12")',
      }

      context = described_class.send(:gemspec_context, content)
      index = described_class.send(:dependency_node_index, context[:stmt_nodes], context[:blk_param])

      snapshot = described_class.send(:development_dependency_sync_snapshot, desired, index)

      expect(snapshot[:sync_actions].map { |action| [action[:action], action[:gem_name]] }).to eq([
        [:skip_runtime, "kettle-dev"],
        [:replace_existing_dev, "rake"],
        [:insert_missing, "rspec"],
      ])
      expect(snapshot[:missing_lines]).to eq([
        "  spec.add_development_dependency(\"rspec\", \"~> 3.12\")\n",
      ])
      expect(snapshot[:sync_actions][1][:record]).to include(
        method: "add_development_dependency",
        gem: "rake",
        start_line: 5,
        end_line: 5,
      )
    end
  end

  describe ".development_dependency_replacement_actions" do
    it "returns only ordered usable replacement actions across AST and fallback records" do
      ast_action = {
        action: :replace_existing_dev,
        gem_name: "rake",
        record: {start_line: 3, end_line: 3, node: Object.new},
      }
      fallback_action = {
        action: :replace_existing_dev,
        gem_name: "rspec",
        record: {line_index: 4, line: '  spec.add_development_dependency("rspec", ">= 3")\n'},
      }
      sync_actions = [
        {action: :skip_runtime, gem_name: "kettle-dev"},
        ast_action,
        {action: :insert_missing, gem_name: "rubocop"},
        {action: :replace_existing_dev, gem_name: "broken", record: nil},
        fallback_action,
      ]

      expect(described_class).to receive(:development_dependency_replacement_record).exactly(sync_actions.length).times.and_call_original

      expect(
        described_class.send(:development_dependency_replacement_actions, sync_actions),
      ).to eq([ast_action, fallback_action])
    end
  end

  describe ".missing_development_dependency_insertion_text" do
    it "joins ordered missing lines and coerces nil to an empty insertion string" do
      missing_lines = [
        '  spec.add_development_dependency("bundler-audit", "~> 0.9.3")\n',
        '  spec.add_development_dependency("rspec", "~> 3.12")\n',
      ]

      expect(described_class.send(:missing_development_dependency_insertion_text, missing_lines)).to eq(missing_lines.join)
      expect(described_class.send(:missing_development_dependency_insertion_text, nil)).to eq("")
    end
  end

  describe ".development_dependency_insertion_payload" do
    it "returns the shared note-block insertion index and ordered insertion text for mixed missing lines" do
      content = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "example"
          spec.version = "1.0.0"

          # NOTE: It is preferable to list development dependencies in the gemspec due to increased
          #       visibility and discoverability.
          # Security
          spec.add_development_dependency("bundler-audit", "~> 0.9.3")
        end
      RUBY

      missing_lines = [
        [
          "  spec.add_development_dependency(",
          '    "rubocop",',
          '    "~> 1.72"',
          "  )",
        ].join("\n") + "\n",
        '  spec.add_development_dependency("rspec", "~> 3.12")\n',
      ]

      payload = described_class.send(:development_dependency_insertion_payload, content.lines, missing_lines)

      expect(payload).to eq(
        line_index: content.lines.index("  # Security\n"),
        insertion_text: missing_lines.join,
      )
    end

    it "anchors insertion payload at the content end when no note block or final end line is present" do
      lines = ['spec.add_dependency("demo", "~> 1.0")\n']
      missing_lines = ['spec.add_development_dependency("rspec", "~> 3.12")\n']

      payload = described_class.send(:development_dependency_insertion_payload, lines, missing_lines)

      expect(payload).to eq(
        line_index: 1,
        insertion_text: missing_lines.join,
      )
    end
  end

  describe ".development_dependency_replacement_payload" do
    it "returns shared replacement payload text for both AST-style and fallback-style replace actions" do
      content = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "example"
            spec.add_development_dependency("rake", ">= 12")
        end
      RUBY

      ast_action = {
        action: :replace_existing_dev,
        gem_name: "rake",
        desired_line: 'spec.add_development_dependency("rake", "~> 13.0")',
        record: {
          start_line: 3,
          end_line: 3,
          node: Object.new,
        },
      }

      fallback_action = {
        action: :replace_existing_dev,
        gem_name: "rspec",
        desired_line: 'spec.add_development_dependency("rspec", "~> 3.12")',
        record: {
          line_index: 0,
          line: "    spec.add_development_dependency(\"rspec\", \">= 3\")\n",
        },
      }

      ast_payload = described_class.send(:development_dependency_replacement_payload, ast_action, content: content)
      fallback_payload = described_class.send(:development_dependency_replacement_payload, fallback_action)

      expect(ast_payload).to eq(
        gem_name: "rake",
        record: ast_action[:record],
        replacement_text: "    spec.add_development_dependency(\"rake\", \"~> 13.0\")\n",
      )
      expect(fallback_payload).to eq(
        gem_name: "rspec",
        record: fallback_action[:record],
        replacement_text: "    spec.add_development_dependency(\"rspec\", \"~> 3.12\")\n",
      )
    end

    it "returns nil for non-replacement sync actions" do
      action = {
        action: :insert_missing,
        gem_name: "rspec",
        desired_line: 'spec.add_development_dependency("rspec", "~> 3.12")',
      }

      expect(described_class.send(:development_dependency_replacement_payload, action)).to be_nil
    end
  end

  describe ".development_dependency_replacement_indent" do
    it "prefers content/start_line, then node indentation, then fallback line indentation" do
      content = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "example"
            spec.add_development_dependency("rake", ">= 12")
        end
      RUBY

      expect(
        described_class.send(
          :development_dependency_replacement_indent,
          {start_line: 3, node: Object.new, line: "      ignored\n"},
          content: content,
        ),
      ).to eq("    ")

      node = Object.new
      allow(described_class).to receive(:dependency_indent).with(node).and_return("  ")
      expect(
        described_class.send(
          :development_dependency_replacement_indent,
          {node: node, line: "      ignored\n"},
        ),
      ).to eq("  ")

      expect(
        described_class.send(
          :development_dependency_replacement_indent,
          {line: "      spec.add_development_dependency(\"rspec\", \">= 3\")\n"},
        ),
      ).to eq("      ")
    end
  end

  describe ".development_dependency_replacement_text" do
    it "derives indentation through the shared helper before formatting the replacement line" do
      record = {start_line: 3, node: Object.new}

      allow(described_class).to receive(:development_dependency_replacement_indent).with(record, content: "content").and_return("    ")
      allow(described_class).to receive(:formatted_dependency_line).with(
        'spec.add_development_dependency("rake", "~> 13.0")',
        indent: "    ",
      ).and_return("    spec.add_development_dependency(\"rake\", \"~> 13.0\")\n")

      expect(
        described_class.send(
          :development_dependency_replacement_text,
          'spec.add_development_dependency("rake", "~> 13.0")',
          record,
          content: "content",
        ),
      ).to eq("    spec.add_development_dependency(\"rake\", \"~> 13.0\")\n")
    end
  end

  describe ".plan_overlapping_line" do
    it "returns the first plan whose line range includes the requested line number and nil when none match" do
      first_overlap = instance_double(Ast::Merge::StructuralEdit::SplicePlan, line_range: 3..5)
      later_overlap = instance_double(Ast::Merge::StructuralEdit::SplicePlan, line_range: 5..7)
      non_overlap = instance_double(Ast::Merge::StructuralEdit::SplicePlan, line_range: 9..10)

      expect(described_class.send(:plan_overlapping_line, [first_overlap, later_overlap, non_overlap], 5)).to equal(first_overlap)
      expect(described_class.send(:plan_overlapping_line, [non_overlap], 5)).to be_nil
      expect(described_class.send(:plan_overlapping_line, nil, 5)).to be_nil
    end
  end

  describe ".add_anchor_splice_plan" do
    it "builds a plan from the anchor line and appends it when no existing plan overlaps the insertion line" do
      plans = [:existing]
      metadata = {source: :spec}
      built_plan = instance_double(Ast::Merge::StructuralEdit::SplicePlan)

      allow(described_class).to receive(:anchor_splice_replacement).with(
        "before\n",
        "inserted\n",
        position: :before,
      ).and_return("replacement")
      allow(described_class).to receive(:build_splice_plan).with(
        content: "before\nafter\n",
        replacement: "replacement",
        start_line: 1,
        end_line: 1,
        metadata: metadata,
      ).and_return(built_plan)
      allow(described_class).to receive(:plan_overlapping_line).with(plans, 1).and_return(nil)

      expect(
        described_class.send(
          :add_anchor_splice_plan,
          plans: plans,
          content: "before\nafter\n",
          lines: ["before\n", "after\n"],
          anchor_line: 1,
          insertion_text: "inserted\n",
          metadata: metadata,
        ),
      ).to eq([:existing, built_plan])
    end

    it "delegates overlap handling to merge_anchor_splice_plan with merged metadata" do
      overlap = instance_double(Ast::Merge::StructuralEdit::SplicePlan, metadata: {existing: true})
      trailing = instance_double(Ast::Merge::StructuralEdit::SplicePlan)

      allow(described_class).to receive(:plan_overlapping_line).with([overlap, trailing], 1).and_return(overlap)
      allow(described_class).to receive(:merge_anchor_splice_plan).with(
        plans: [overlap, trailing],
        content: "before\nafter\n",
        overlap_plan: overlap,
        insertion_text: "inserted\n",
        position: :before,
        metadata: {existing: true, source: :spec},
      ).and_return(:merged_plan_set)

      expect(
        described_class.send(
          :add_anchor_splice_plan,
          plans: [overlap, trailing],
          content: "before\nafter\n",
          lines: ["before\n", "after\n"],
          anchor_line: 1,
          insertion_text: "inserted\n",
          metadata: {source: :spec},
        ),
      ).to eq(:merged_plan_set)
    end
  end

  describe ".development_dependency_replacement_record" do
    it "returns only usable replacement records unchanged across AST and fallback shapes" do
      ast_record = {start_line: 3, end_line: 3, node: Object.new}
      fallback_record = {line_index: 4, line: '  spec.add_development_dependency("rspec", ">= 3")\n'}

      expect(
        described_class.send(
          :development_dependency_replacement_record,
          {action: :replace_existing_dev, record: ast_record},
        ),
      ).to equal(ast_record)

      expect(
        described_class.send(
          :development_dependency_replacement_record,
          {action: :replace_existing_dev, record: fallback_record},
        ),
      ).to equal(fallback_record)

      expect(
        described_class.send(
          :development_dependency_replacement_record,
          {action: :insert_missing, record: ast_record},
        ),
      ).to be_nil

      expect(
        described_class.send(
          :development_dependency_replacement_record,
          {action: :replace_existing_dev, record: nil},
        ),
      ).to be_nil
    end
  end

  describe ".ast_development_dependency_replacement_plan" do
    it "builds the single replacement splice plan for an AST replace action" do
      content = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "example"
          spec.add_development_dependency("rake", ">= 12")
        end
      RUBY

      action = {
        action: :replace_existing_dev,
        gem_name: "rake",
        desired_line: 'spec.add_development_dependency("rake", "~> 13.0")',
        record: {
          start_line: 3,
          end_line: 3,
          node: Object.new,
        },
      }

      plan = described_class.send(:ast_development_dependency_replacement_plan, action, content: content)

      expect(plan).to be_a(Ast::Merge::StructuralEdit::SplicePlan)
      expect(plan.replace_start_line).to eq(3)
      expect(plan.replace_end_line).to eq(3)
      expect(plan.replacement).to eq("  spec.add_development_dependency(\"rake\", \"~> 13.0\")\n")
      expect(plan.metadata).to include(
        source: :kettle_jem_prism_gemspec,
        edit: :ensure_development_dependency_replace,
        gem_name: "rake",
      )
    end

    it "uses the payload-carried record and gem metadata from the shared replacement payload" do
      content = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "example"
          spec.version = "1.0.0"
        end
      RUBY

      action = {
        action: :replace_existing_dev,
        gem_name: "ignored-action-gem",
        desired_line: 'spec.add_development_dependency("rake", "~> 13.0")',
        record: {start_line: 1, end_line: 1, node: Object.new},
      }
      payload = {
        gem_name: "payload-gem",
        record: {start_line: 3, end_line: 3},
        replacement_text: "  payload replacement\n",
      }

      allow(described_class).to receive(:development_dependency_replacement_payload).with(
        action,
        content: content,
      ).and_return(payload)

      plan = described_class.send(:ast_development_dependency_replacement_plan, action, content: content)

      expect(plan).to be_a(Ast::Merge::StructuralEdit::SplicePlan)
      expect(plan.replace_start_line).to eq(3)
      expect(plan.replace_end_line).to eq(3)
      expect(plan.replacement).to eq("  payload replacement\n")
      expect(plan.metadata).to include(
        source: :kettle_jem_prism_gemspec,
        edit: :ensure_development_dependency_replace,
        gem_name: "payload-gem",
      )
    end
  end

  describe ".ast_development_dependency_replacement_plans" do
    it "forwards ordered usable replacement actions into single-action AST plans and drops nil results" do
      sync_actions = [{gem_name: "ignored"}]
      content = "Gem::Specification.new do |spec|\nend\n"
      action_one = {gem_name: "rake"}
      action_two = {gem_name: "rspec"}
      action_three = {gem_name: "rubocop"}
      plan_one = Object.new
      plan_three = Object.new

      allow(described_class).to receive(:development_dependency_replacement_actions).with(sync_actions).and_return(
        [action_one, action_two, action_three],
      )
      allow(described_class).to receive(:ast_development_dependency_replacement_plan).with(
        action_one,
        content: content,
      ).ordered.and_return(plan_one)
      allow(described_class).to receive(:ast_development_dependency_replacement_plan).with(
        action_two,
        content: content,
      ).ordered.and_return(nil)
      allow(described_class).to receive(:ast_development_dependency_replacement_plan).with(
        action_three,
        content: content,
      ).ordered.and_return(plan_three)

      result = described_class.send(:ast_development_dependency_replacement_plans, sync_actions, content: content)

      expect(result).to eq([plan_one, plan_three])
    end
  end

  describe ".apply_fallback_development_dependency_replacements" do
    it "duplicates the caller lines and forwards ordered usable replacement actions into the single-action fallback helper" do
      lines = ["original\n"]
      sync_actions = [{gem_name: "ignored"}]
      action_one = {gem_name: "rake"}
      action_two = {gem_name: "rspec"}
      seen_lines = []

      allow(described_class).to receive(:development_dependency_replacement_actions).with(sync_actions).and_return(
        [action_one, action_two],
      )
      expect(described_class).to receive(:apply_fallback_development_dependency_replacement).with(
        kind_of(Array),
        action_one,
      ).ordered do |updated_lines, action|
        expect(action).to be(action_one)
        expect(updated_lines).not_to be(lines)
        expect(updated_lines).to eq(lines)
        updated_lines[0] = "first mutation\n"
        seen_lines << updated_lines
      end
      expect(described_class).to receive(:apply_fallback_development_dependency_replacement).with(
        kind_of(Array),
        action_two,
      ).ordered do |updated_lines, action|
        expect(action).to be(action_two)
        expect(updated_lines).to be(seen_lines.first)
        expect(updated_lines).to eq(["first mutation\n"])
        updated_lines[0] = "second mutation\n"
      end

      result = described_class.send(:apply_fallback_development_dependency_replacements, lines, sync_actions)

      expect(result).to eq(["second mutation\n"])
      expect(lines).to eq(["original\n"])
    end
  end

  describe ".apply_fallback_development_dependency_replacement" do
    it "rewrites only the targeted fallback dependency line while preserving indentation" do
      lines = [
        "spec.add_dependency(\"demo\", \"~> 1.0\")\n",
        "    spec.add_development_dependency(\"rake\", \">= 12\")\n",
        "spec.add_development_dependency(\"rspec\", \">= 3\")\n",
      ]

      replace_action = {
        action: :replace_existing_dev,
        gem_name: "rake",
        desired_line: 'spec.add_development_dependency("rake", "~> 13.0")',
        record: {
          line_index: 1,
          line: lines[1],
        },
      }

      insert_action = {
        action: :insert_missing,
        gem_name: "bundler-audit",
        desired_line: 'spec.add_development_dependency("bundler-audit", "~> 0.9.3")',
      }

      updated_lines = lines.dup
      described_class.send(:apply_fallback_development_dependency_replacement, updated_lines, insert_action)
      described_class.send(:apply_fallback_development_dependency_replacement, updated_lines, replace_action)

      expect(updated_lines).to eq(
        [
          "spec.add_dependency(\"demo\", \"~> 1.0\")\n",
          "    spec.add_development_dependency(\"rake\", \"~> 13.0\")\n",
          "spec.add_development_dependency(\"rspec\", \">= 3\")\n",
        ],
      )
    end

    it "rewrites the payload-carried line index from the shared replacement payload" do
      updated_lines = [
        "zero\n",
        "one\n",
        "two\n",
      ]
      action = {
        action: :replace_existing_dev,
        gem_name: "ignored-action-gem",
        desired_line: 'spec.add_development_dependency("rake", "~> 13.0")',
        record: {line_index: 1, line: "one\n"},
      }
      payload = {
        gem_name: "payload-gem",
        record: {line_index: 2, line: "two\n"},
        replacement_text: "payload replacement\n",
      }

      allow(described_class).to receive(:development_dependency_replacement_payload).with(action).and_return(payload)

      described_class.send(:apply_fallback_development_dependency_replacement, updated_lines, action)

      expect(updated_lines).to eq([
        "zero\n",
        "one\n",
        "payload replacement\n",
      ])
    end

    it "is a no-op when the shared replacement payload is unavailable" do
      updated_lines = ["zero\n", "one\n"]
      action = {
        action: :insert_missing,
        gem_name: "rspec",
        desired_line: 'spec.add_development_dependency("rspec", "~> 3.12")',
      }

      allow(described_class).to receive(:development_dependency_replacement_payload).with(action).and_return(nil)

      expect {
        described_class.send(:apply_fallback_development_dependency_replacement, updated_lines, action)
      }.not_to change { updated_lines }
    end
  end

  describe ".add_missing_development_dependency_plans" do
    it "returns the original plans when no insertion exists and otherwise forwards into the single insertion-plan helper" do
      plans = [Object.new]
      content = "Gem::Specification.new do |spec|\nend\n"
      lines = content.lines
      missing_lines = ['  spec.add_development_dependency("rspec", "~> 3.12")\n']
      insertion = {line_index: 1, insertion_text: missing_lines.join}
      forwarded = [:forwarded]

      allow(described_class).to receive(:development_dependency_insertion_payload).with(lines, missing_lines).ordered.and_return(nil)

      no_op = described_class.send(
        :add_missing_development_dependency_plans,
        plans,
        content: content,
        lines: lines,
        missing_lines: missing_lines,
      )

      expect(no_op).to eq(plans)

      allow(described_class).to receive(:development_dependency_insertion_payload).with(lines, missing_lines).ordered.and_return(
        insertion,
      )
      allow(described_class).to receive(:add_missing_development_dependency_plan).with(
        plans,
        content: content,
        lines: lines,
        insertion: insertion,
        missing_count: missing_lines.size,
      ).ordered.and_return(forwarded)

      result = described_class.send(
        :add_missing_development_dependency_plans,
        plans,
        content: content,
        lines: lines,
        missing_lines: missing_lines,
      )

      expect(result).to eq(forwarded)
    end
  end

  describe ".add_missing_development_dependency_plan" do
    it "builds the single insertion splice plan for ordered missing AST dependency lines" do
      content = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "example"
          spec.version = "1.0.0"

          # NOTE: It is preferable to list development dependencies in the gemspec due to increased
          #       visibility and discoverability.
          # Security
        end
      RUBY

      missing_lines = [
        '  spec.add_development_dependency("bundler-audit", "~> 0.9.3")\n',
        '  spec.add_development_dependency("rspec", "~> 3.12")\n',
      ]
      lines = content.lines
      insertion = described_class.send(:development_dependency_insertion_payload, lines, missing_lines)

      plans = described_class.send(
        :add_missing_development_dependency_plan,
        [],
        content: content,
        lines: lines,
        insertion: insertion,
        missing_count: missing_lines.size,
      )

      expect(plans.size).to eq(1)

      plan = plans.first
      expect(plan).to be_a(Ast::Merge::StructuralEdit::SplicePlan)
      expect(plan.replace_start_line).to eq(7)
      expect(plan.replace_end_line).to eq(7)
      expect(plan.replacement).to eq(missing_lines.join + "  # Security\n")
      expect(plan.metadata).to include(
        source: :kettle_jem_prism_gemspec,
        edit: :ensure_development_dependency_insert,
        inserted_missing_dependencies: 2,
      )
    end
  end

  describe ".apply_fallback_missing_development_dependency_insertions" do
    it "duplicates the caller lines and forwards the shared missing-line payload into the single-action fallback helper" do
      lines = ["original\n"]
      missing_lines = ['  spec.add_development_dependency("rspec", "~> 3.12")\n']

      expect(described_class).to receive(:apply_fallback_missing_development_dependency_insertion).with(
        kind_of(Array),
        missing_lines,
      ) do |updated_lines, forwarded_missing_lines|
        expect(forwarded_missing_lines).to eq(missing_lines)
        expect(updated_lines).not_to be(lines)
        expect(updated_lines).to eq(lines)
        updated_lines[0] = "mutated\n"
      end

      result = described_class.send(:apply_fallback_missing_development_dependency_insertions, lines, missing_lines)

      expect(result).to eq(["mutated\n"])
      expect(lines).to eq(["original\n"])
    end
  end

  describe ".apply_fallback_missing_development_dependency_insertion" do
    it "inserts ordered missing dependency lines before the note-adjacent section without disturbing neighbors" do
      lines = <<~RUBY.lines
        Gem::Specification.new do |spec|
          spec.name = "example"

          # NOTE: It is preferable to list development dependencies in the gemspec due to increased
          #       visibility and discoverability.
          # Security
          spec.add_development_dependency("bundler-audit", "~> 0.9.3")
        end
      RUBY

      missing_lines = [
        "  spec.add_development_dependency(\"rake\", \"~> 13.0\")\n",
        "  spec.add_development_dependency(\"rspec\", \"~> 3.12\")\n",
      ]

      updated_lines = lines.dup
      described_class.send(:apply_fallback_missing_development_dependency_insertion, updated_lines, missing_lines)

      expect(updated_lines.join).to include(
        "  # NOTE: It is preferable to list development dependencies in the gemspec due to increased\n  " \
          "#       visibility and discoverability.\n  " \
          "spec.add_development_dependency(\"rake\", \"~> 13.0\")\n  " \
          "spec.add_development_dependency(\"rspec\", \"~> 3.12\")\n  " \
          "# Security\n",
      )
      expect(updated_lines.first).to eq("Gem::Specification.new do |spec|\n")
      expect(updated_lines.last).to eq("end\n")
    end
  end

  describe ".bootstrap_development_dependency_seed_content" do
    it "seeds ordered dependency lines into empty bootstrap content without a leading blank line" do
      desired = {
        "rake" => '  spec.add_development_dependency("rake", "~> 13.0")',
        "rspec" => '  spec.add_development_dependency("rspec", "~> 3.12")',
      }

      seeded = described_class.send(:bootstrap_development_dependency_seed_content, "", desired)

      expect(seeded).to eq(
        "spec.add_development_dependency(\"rake\", \"~> 13.0\")\n" \
          "spec.add_development_dependency(\"rspec\", \"~> 3.12\")\n",
      )
    end
  end

  describe ".safe_gemspec_context" do
    it "returns the parsed gemspec context for a valid Gem::Specification body" do
      content = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "example"
          spec.version = "1.0.0"
        end
      RUBY

      context = described_class.send(:safe_gemspec_context, content)

      expect(context).to include(
        blk_param: "spec",
        gemspec_call: be_a(Prism::CallNode),
      )
      expect(context[:stmt_nodes].map(&:name)).to eq(%i[name= version=])
    end

    it "returns a usable context for comment-only Gem::Specification bodies" do
      content = <<~RUBY
        Gem::Specification.new do
          # kettle-jem:freeze
          # preserved custom content
          # kettle-jem:unfreeze
        end
      RUBY

      context = described_class.send(:safe_gemspec_context, content)

      expect(context).to include(
        blk_param: "spec",
        gemspec_call: be_a(Prism::CallNode),
        stmt_nodes: [],
      )
    end

    it "returns nil when gemspec context lookup raises a LoadError" do
      allow(described_class).to receive(:gemspec_context).and_raise(LoadError, "cannot load such file -- prism")

      expect(described_class.send(:safe_gemspec_context, "Gem::Specification.new do |spec|\nend\n")).to be_nil
    end

    it "returns nil when gemspec context lookup raises a StandardError" do
      allow(described_class).to receive(:gemspec_context).and_raise(StandardError, "boom")

      expect(described_class.send(:safe_gemspec_context, "Gem::Specification.new do |spec|\nend\n")).to be_nil
    end
  end

  describe ".ast_replacement_development_dependency_plans" do
    it "threads snapshot sync actions into the shared AST replacement-plan path" do
      sync_snapshot = {
        sync_actions: [{action: :replace_existing_dev, gem_name: "rake"}],
      }
      content = "Gem::Specification.new do |spec|\nend\n"
      sentinel = [:forwarded]

      allow(described_class).to receive(:ast_development_dependency_replacement_plans).with(
        sync_snapshot[:sync_actions],
        content: content,
      ).and_return(sentinel)

      result = described_class.send(
        :ast_replacement_development_dependency_plans,
        sync_snapshot,
        content: content,
      )

      expect(result).to eq(sentinel)
    end
  end

  describe ".ast_missing_development_dependency_plans" do
    it "threads snapshot missing lines into the shared AST insertion-plan path" do
      content = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "example"

          # NOTE: It is preferable to list development dependencies in the gemspec due to increased
          #       visibility and discoverability.
          # Security
        end
      RUBY

      plans = [Object.new]
      sync_snapshot = {
        missing_lines: ['  spec.add_development_dependency("rspec", "~> 3.12")\n'],
      }
      lines = content.lines
      sentinel = [:forwarded]

      allow(described_class).to receive(:add_missing_development_dependency_plans).with(
        plans,
        content: content,
        lines: lines,
        missing_lines: sync_snapshot[:missing_lines],
      ).and_return(sentinel)

      result = described_class.send(
        :ast_missing_development_dependency_plans,
        plans,
        sync_snapshot,
        content: content,
        lines: lines,
      )

      expect(result).to eq(sentinel)
    end
  end

  describe ".apply_fallback_replacement_development_dependency_sync" do
    it "threads snapshot sync actions into the shared fallback replacement path" do
      lines = ["Gem::Specification.new do |spec|\n"]
      sync_snapshot = {
        sync_actions: [{action: :replace_existing_dev, gem_name: "rake"}],
      }
      sentinel = ["forwarded"]

      allow(described_class).to receive(:apply_fallback_development_dependency_replacements).with(
        lines,
        sync_snapshot[:sync_actions],
      ).and_return(sentinel)

      result = described_class.send(
        :apply_fallback_replacement_development_dependency_sync,
        lines,
        sync_snapshot,
      )

      expect(result).to eq(sentinel)
    end
  end

  describe ".fallback_development_dependency_sync_snapshot" do
    it "threads fallback lines into the shared dependency snapshot path" do
      lines = ["Gem::Specification.new do |spec|\n"]
      desired = {"rake" => '  spec.add_development_dependency("rake", "~> 13.0")'}
      index = {development_by_gem: {}, runtime_gems: Set.new}
      sentinel = {sync_actions: [], missing_lines: []}

      allow(described_class::DependencySectionPolicy).to receive(:dependency_record_index).with(lines).and_return(index)
      allow(described_class).to receive(:development_dependency_sync_snapshot).with(desired, index).and_return(sentinel)

      result = described_class.send(:fallback_development_dependency_sync_snapshot, desired, lines)

      expect(result).to eq(sentinel)
    end
  end

  describe ".ast_development_dependency_sync_snapshot" do
    it "threads AST context into the shared dependency snapshot path" do
      desired = {"rake" => '  spec.add_development_dependency("rake", "~> 13.0")'}
      context = {
        stmt_nodes: [Object.new],
        blk_param: "spec",
      }
      index = {development_by_gem: {}, runtime_gems: Set.new}
      sentinel = {sync_actions: [], missing_lines: []}

      allow(described_class).to receive(:dependency_node_index).with(context[:stmt_nodes], context[:blk_param]).and_return(index)
      allow(described_class).to receive(:development_dependency_sync_snapshot).with(desired, index).and_return(sentinel)

      result = described_class.send(:ast_development_dependency_sync_snapshot, desired, context)

      expect(result).to eq(sentinel)
    end
  end

  describe ".development_dependency_sync_snapshot_for" do
    it "dispatches the shared dependency snapshot builder to fallback or AST based on context availability" do
      desired = {"rake" => '  spec.add_development_dependency("rake", "~> 13.0")'}
      lines = ["Gem::Specification.new do |spec|\n"]
      context = {stmt_nodes: [Object.new], blk_param: "spec"}
      fallback_snapshot = {sync_actions: [:fallback], missing_lines: []}
      ast_snapshot = {sync_actions: [:ast], missing_lines: []}

      allow(described_class).to receive(:fallback_development_dependency_sync_snapshot).with(desired, lines).ordered.and_return(
        fallback_snapshot,
      )
      allow(described_class).to receive(:ast_development_dependency_sync_snapshot).with(desired, context).ordered.and_return(
        ast_snapshot,
      )

      fallback_result = described_class.send(:development_dependency_sync_snapshot_for, desired, lines: lines)
      ast_result = described_class.send(:development_dependency_sync_snapshot_for, desired, lines: lines, context: context)

      expect(fallback_result).to eq(fallback_snapshot)
      expect(ast_result).to eq(ast_snapshot)
    end
  end

  describe ".apply_fallback_missing_development_dependency_sync" do
    it "threads snapshot missing lines into the shared fallback insertion path" do
      updated_lines = ["Gem::Specification.new do |spec|\n"]
      sync_snapshot = {
        missing_lines: ['  spec.add_development_dependency("rspec", "~> 3.12")\n'],
      }
      sentinel = ["forwarded"]

      allow(described_class).to receive(:apply_fallback_missing_development_dependency_insertions).with(
        updated_lines,
        sync_snapshot[:missing_lines],
      ).and_return(sentinel)

      result = described_class.send(
        :apply_fallback_missing_development_dependency_sync,
        updated_lines,
        sync_snapshot,
      )

      expect(result).to eq(sentinel)
    end
  end

  describe ".materialize_development_dependency_sync" do
    it "joins the shared fallback line mutation result when no AST context is available" do
      content = "original\n"
      lines = content.lines
      sync_snapshot = {sync_actions: [], missing_lines: []}
      updated_lines = ["updated\n"]

      allow(described_class).to receive(:apply_fallback_development_dependency_sync).with(lines, sync_snapshot).and_return(
        updated_lines,
      )

      result = described_class.send(
        :materialize_development_dependency_sync,
        content,
        lines: lines,
        sync_snapshot: sync_snapshot,
      )

      expect(result).to eq(updated_lines.join)
    end

    it "runs the shared AST plan build plus materialization path when context is available" do
      content = "original\n"
      lines = content.lines
      context = {stmt_nodes: [Object.new], blk_param: "spec"}
      sync_snapshot = {sync_actions: [], missing_lines: []}
      plans = [:plans]
      sentinel = "updated\n"

      allow(described_class).to receive(:ast_development_dependency_sync_plans).with(
        sync_snapshot,
        content: content,
        lines: lines,
      ).and_return(plans)
      allow(described_class).to receive(:materialize_development_dependency_sync_plans).with(content, plans).and_return(
        sentinel,
      )

      result = described_class.send(
        :materialize_development_dependency_sync,
        content,
        lines: lines,
        sync_snapshot: sync_snapshot,
        context: context,
      )

      expect(result).to eq(sentinel)
    end
  end

  describe ".ast_development_dependency_sync_plans" do
    it "builds the shared replace-plus-insert structural edit batch for the mixed-action AST path" do
      destination = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "example"
          spec.version = "1.0.0"
          spec.add_dependency("kettle-dev", "~> 2.0")

          # NOTE: It is preferable to list development dependencies in the gemspec due to increased
          #       visibility and discoverability.
          spec.add_development_dependency("rake", ">= 12")
        end
      RUBY

      desired = {
        "kettle-dev" => '  spec.add_development_dependency("kettle-dev", "~> 2.0")',
        "rake" => '  spec.add_development_dependency("rake", "~> 13.0")',
        "rspec" => '  spec.add_development_dependency("rspec", "~> 3.12")',
      }

      context = described_class.send(:safe_gemspec_context, destination)
      index = described_class.send(:dependency_node_index, context[:stmt_nodes], context[:blk_param])
      snapshot = described_class.send(:development_dependency_sync_snapshot, desired, index)

      plans = described_class.send(
        :ast_development_dependency_sync_plans,
        snapshot,
        content: destination,
        lines: destination.lines,
      )

      result = described_class.send(
        :merged_content_from_plans,
        content: destination,
        plans: plans,
        metadata: {source: :kettle_jem_prism_gemspec, edit: :ensure_development_dependencies},
      )

      expect(plans.size).to eq(1)
      expect(plans.first.metadata).to include(
        edit: :ensure_development_dependency_replace,
        gem_name: "rake",
        inserted_missing_dependencies: 1,
      )
      expect(result).to include('spec.add_dependency("kettle-dev", "~> 2.0")')
      expect(result).not_to include('spec.add_development_dependency("kettle-dev", "~> 2.0")')
      expect(result).to include(
        "  # NOTE: It is preferable to list development dependencies in the gemspec due to increased\n  " \
          "#       visibility and discoverability.\n  " \
          "spec.add_development_dependency(\"rspec\", \"~> 3.12\")\n  " \
          "spec.add_development_dependency(\"rake\", \"~> 13.0\")",
      )
      expect(result).not_to include('spec.add_development_dependency("rake", ">= 12")')
    end
  end

  describe ".materialize_development_dependency_sync_plans" do
    it "materializes the shared AST plan batch into updated content for the mixed-action overlap path" do
      destination = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "example"
          spec.version = "1.0.0"
          spec.add_dependency("kettle-dev", "~> 2.0")

          # NOTE: It is preferable to list development dependencies in the gemspec due to increased
          #       visibility and discoverability.
          spec.add_development_dependency("rake", ">= 12")
        end
      RUBY

      desired = {
        "kettle-dev" => '  spec.add_development_dependency("kettle-dev", "~> 2.0")',
        "rake" => '  spec.add_development_dependency("rake", "~> 13.0")',
        "rspec" => '  spec.add_development_dependency("rspec", "~> 3.12")',
      }

      context = described_class.send(:safe_gemspec_context, destination)
      index = described_class.send(:dependency_node_index, context[:stmt_nodes], context[:blk_param])
      snapshot = described_class.send(:development_dependency_sync_snapshot, desired, index)
      plans = described_class.send(
        :ast_development_dependency_sync_plans,
        snapshot,
        content: destination,
        lines: destination.lines,
      )

      result = described_class.send(:materialize_development_dependency_sync_plans, destination, plans)

      expect(result).to include('spec.add_dependency("kettle-dev", "~> 2.0")')
      expect(result).not_to include('spec.add_development_dependency("kettle-dev", "~> 2.0")')
      expect(result).to include(
        "  # NOTE: It is preferable to list development dependencies in the gemspec due to increased\n  " \
          "#       visibility and discoverability.\n  " \
          "spec.add_development_dependency(\"rspec\", \"~> 3.12\")\n  " \
          "spec.add_development_dependency(\"rake\", \"~> 13.0\")",
      )
      expect(result).not_to include('spec.add_development_dependency("rake", ">= 12")')
    end
  end

  describe ".finalize_development_dependency_sync" do
    it "joins ordered desired dependency lines and forwards the shared normalization contract" do
      content = "original\n"
      desired = {
        "rake" => '  spec.add_development_dependency("rake", "~> 13.0")',
        "rspec" => '  spec.add_development_dependency("rspec", "~> 3.12")',
      }
      updated = "updated\n"
      sentinel = "normalized\n"

      allow(described_class).to receive(:normalize_dependency_sections).with(
        updated,
        template_content: desired.values.join("\n"),
        destination_content: content,
        prefer_template: true,
      ).and_return(sentinel)

      result = described_class.send(
        :finalize_development_dependency_sync,
        content: content,
        desired: desired,
        updated: updated,
      )

      expect(result).to eq(sentinel)
    end
  end

  describe ".ensure_development_dependencies_fallback" do
    it "threads the shared sync snapshot, materialization, and finalizer helpers on the fallback path" do
      content = "original\n"
      desired = {
        "rake" => '  spec.add_development_dependency("rake", "~> 13.0")',
      }
      lines = content.lines
      sync_snapshot = {sync_actions: [], missing_lines: []}
      updated = "updated\n"
      sentinel = "normalized\n"

      allow(described_class).to receive(:development_dependency_sync_snapshot_for).with(
        desired,
        lines: lines,
      ).and_return(
        sync_snapshot,
      )
      allow(described_class).to receive(:materialize_development_dependency_sync).with(
        content,
        lines: lines,
        sync_snapshot: sync_snapshot,
      ).and_return(
        updated,
      )
      allow(described_class).to receive(:finalize_development_dependency_sync).with(
        content: content,
        desired: desired,
        updated: updated,
      ).and_return(sentinel)

      result = described_class.send(:ensure_development_dependencies_fallback, content, desired)

      expect(result).to eq(sentinel)
    end
  end

  describe ".ensure_development_dependencies_ast" do
    it "threads the shared sync snapshot, materialization, and finalizer helpers on the AST path" do
      content = "original\n"
      desired = {
        "rake" => '  spec.add_development_dependency("rake", "~> 13.0")',
      }
      lines = content.lines
      context = {stmt_nodes: [Object.new], blk_param: "spec"}
      sync_snapshot = {sync_actions: [], missing_lines: []}
      updated = "updated\n"
      sentinel = "normalized\n"

      allow(described_class).to receive(:development_dependency_sync_snapshot_for).with(
        desired,
        lines: lines,
        context: context,
      ).and_return(sync_snapshot)
      allow(described_class).to receive(:materialize_development_dependency_sync).with(
        content,
        lines: lines,
        sync_snapshot: sync_snapshot,
        context: context,
      ).and_return(updated)
      allow(described_class).to receive(:finalize_development_dependency_sync).with(
        content: content,
        desired: desired,
        updated: updated,
      ).and_return(sentinel)

      result = described_class.send(
        :ensure_development_dependencies_ast,
        content,
        desired,
        context: context,
        lines: lines,
      )

      expect(result).to eq(sentinel)
    end

    it "runs the AST-backed replace plus insert flow through the extracted helper on the mixed-action path" do
      destination = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "example"
          spec.version = "1.0.0"
          spec.add_dependency("kettle-dev", "~> 2.0")

          # NOTE: It is preferable to list development dependencies in the gemspec due to increased
          #       visibility and discoverability.
          spec.add_development_dependency("rake", ">= 12")
        end
      RUBY

      desired = {
        "kettle-dev" => '  spec.add_development_dependency("kettle-dev", "~> 2.0")',
        "rake" => '  spec.add_development_dependency("rake", "~> 13.0")',
        "rspec" => '  spec.add_development_dependency("rspec", "~> 3.12")',
      }

      context = described_class.send(:safe_gemspec_context, destination)

      result = described_class.send(
        :ensure_development_dependencies_ast,
        destination,
        desired,
        context: context,
        lines: destination.lines,
      )

      expect(result).to include('spec.add_dependency("kettle-dev", "~> 2.0")')
      expect(result).not_to include('spec.add_development_dependency("kettle-dev", "~> 2.0")')
      expect(result).to include(
        "  # NOTE: It is preferable to list development dependencies in the gemspec due to increased\n  " \
          "#       visibility and discoverability.\n  " \
          "spec.add_development_dependency(\"rspec\", \"~> 3.12\")\n  " \
          "spec.add_development_dependency(\"rake\", \"~> 13.0\")",
      )
      expect(result).not_to include('spec.add_development_dependency("rake", ">= 12")')
    end
  end

  describe ".apply_fallback_development_dependency_sync" do
    it "runs the fallback replace plus insert line mutation through the extracted helper on the mixed-action path" do
      destination = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "example"
          spec.version = "1.0.0"
          spec.add_dependency("kettle-dev", "~> 2.0")

          # NOTE: It is preferable to list development dependencies in the gemspec due to increased
          #       visibility and discoverability.
          spec.add_development_dependency("rake", ">= 12")
        end
      RUBY

      desired = {
        "kettle-dev" => '  spec.add_development_dependency("kettle-dev", "~> 2.0")',
        "rake" => '  spec.add_development_dependency("rake", "~> 13.0")',
        "rspec" => '  spec.add_development_dependency("rspec", "~> 3.12")',
      }

      index = described_class::DependencySectionPolicy.dependency_record_index(destination.lines)
      snapshot = described_class.send(:development_dependency_sync_snapshot, desired, index)

      result_lines = described_class.send(:apply_fallback_development_dependency_sync, destination.lines, snapshot)
      result = result_lines.join

      expect(result).to include('spec.add_dependency("kettle-dev", "~> 2.0")')
      expect(result).not_to include('spec.add_development_dependency("kettle-dev", "~> 2.0")')
      expect(result).to include(
        "  # NOTE: It is preferable to list development dependencies in the gemspec due to increased\n  " \
          "#       visibility and discoverability.\n  " \
          "spec.add_development_dependency(\"rspec\", \"~> 3.12\")\n  " \
          "spec.add_development_dependency(\"rake\", \"~> 13.0\")",
      )
      expect(result).not_to include('spec.add_development_dependency("rake", ">= 12")')
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

    it "is a no-op on the AST path when every desired dependency is already present as runtime" do
      destination = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "example"
          spec.version = "1.0.0"

          spec.add_dependency("kettle-dev", "~> 2.0")
        end
      RUBY

      desired = {
        "kettle-dev" => '  spec.add_development_dependency("kettle-dev", "~> 2.0")',
      }

      result = described_class.ensure_development_dependencies(destination, desired)

      expect(result).to eq(destination)
    end

    it "is a no-op on the fallback path when every desired dependency is already present as runtime" do
      allow(described_class).to receive(:gemspec_context).and_return(nil)

      destination = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "example"
          spec.version = "1.0.0"

          spec.add_dependency("kettle-dev", "~> 2.0")
        end
      RUBY

      desired = {
        "kettle-dev" => '  spec.add_development_dependency("kettle-dev", "~> 2.0")',
      }

      result = described_class.ensure_development_dependencies(destination, desired)

      expect(result).to eq(destination)
    end

    it "is a no-op on the AST path when every desired development dependency already matches exactly" do
      destination = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "example"
          spec.version = "1.0.0"

          spec.add_development_dependency("rake", "~> 13.0")
        end
      RUBY

      desired = {
        "rake" => '  spec.add_development_dependency("rake", "~> 13.0")',
      }

      result = described_class.ensure_development_dependencies(destination, desired)

      expect(result).to eq(destination)
    end

    it "is a no-op on the fallback path when every desired development dependency already matches exactly" do
      allow(described_class).to receive(:gemspec_context).and_return(nil)

      destination = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "example"
          spec.version = "1.0.0"

          spec.add_development_dependency("rake", "~> 13.0")
        end
      RUBY

      desired = {
        "rake" => '  spec.add_development_dependency("rake", "~> 13.0")',
      }

      result = described_class.ensure_development_dependencies(destination, desired)

      expect(result).to eq(destination)
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

    it "keeps non-overlapping AST-path insertions after replaced dependencies and before the final end" do
      destination = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "example"
          spec.version = "1.0.0"

          spec.add_development_dependency("rake", ">= 12")
        end
      RUBY

      desired = {
        "rake" => '  spec.add_development_dependency("rake", "~> 13.0")',
        "rspec" => '  spec.add_development_dependency("rspec", "~> 3.12")',
      }

      result = described_class.ensure_development_dependencies(destination, desired)

      expect(result).to include(
        "  spec.add_development_dependency(\"rake\", \"~> 13.0\")\n  spec.add_development_dependency(\"rspec\", \"~> 3.12\")\nend",
      )
      expect(result).not_to include('spec.add_development_dependency("rake", ">= 12")')
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

    it "preserves multiline AST-path insertions directly below the note block and before later section comments" do
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
        "rubocop" => [
          "  spec.add_development_dependency(",
          '    "rubocop",',
          '    "~> 1.72"',
          "  )",
        ].join("\n"),
        "rspec" => '  spec.add_development_dependency("rspec", "~> 3.12")',
      }

      result = described_class.ensure_development_dependencies(destination, desired)

      expect(result).to include(
        "  # NOTE: It is preferable to list development dependencies in the gemspec due to increased\n  " \
          "#       visibility and discoverability.\n  " \
          "spec.add_development_dependency(\n    " \
          "\"rubocop\",\n    " \
          "\"~> 1.72\"\n  " \
          ")\n  " \
          "spec.add_development_dependency(\"rspec\", \"~> 3.12\")\n  " \
          "# Security",
      )
      expect(result.index("spec.add_development_dependency(")).to be < result.index('spec.add_development_dependency("rspec", "~> 3.12")')
      expect(result.index('spec.add_development_dependency("rspec", "~> 3.12")')).to be < result.index("# Security")
    end

    it "preserves multiline fallback insertions directly below the note block and before later section comments" do
      allow(described_class).to receive(:gemspec_context).and_return(nil)

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
        "rubocop" => [
          "  spec.add_development_dependency(",
          '    "rubocop",',
          '    "~> 1.72"',
          "  )",
        ].join("\n"),
        "rspec" => '  spec.add_development_dependency("rspec", "~> 3.12")',
      }

      result = described_class.ensure_development_dependencies(destination, desired)

      expect(result).to include(
        "  # NOTE: It is preferable to list development dependencies in the gemspec due to increased\n  " \
          "#       visibility and discoverability.\n  " \
          "spec.add_development_dependency(\n    " \
          "\"rubocop\",\n    " \
          "\"~> 1.72\"\n  " \
          ")\n  " \
          "spec.add_development_dependency(\"rspec\", \"~> 3.12\")\n  " \
          "# Security",
      )
      expect(result.index("spec.add_development_dependency(")).to be < result.index('spec.add_development_dependency("rspec", "~> 3.12")')
      expect(result.index('spec.add_development_dependency("rspec", "~> 3.12")')).to be < result.index("# Security")
    end

    it "keeps AST-path runtime skip, replacement, and insertion decisions aligned on the mixed-action path" do
      destination = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "example"
          spec.version = "1.0.0"
          spec.add_dependency("kettle-dev", "~> 2.0")

          # NOTE: It is preferable to list development dependencies in the gemspec due to increased
          #       visibility and discoverability.
          spec.add_development_dependency("rake", ">= 12")
        end
      RUBY

      desired = {
        "kettle-dev" => '  spec.add_development_dependency("kettle-dev", "~> 2.0")',
        "rake" => '  spec.add_development_dependency("rake", "~> 13.0")',
        "rspec" => '  spec.add_development_dependency("rspec", "~> 3.12")',
      }

      result = described_class.ensure_development_dependencies(destination, desired)

      expect(result).to include('spec.add_dependency("kettle-dev", "~> 2.0")')
      expect(result).not_to include('spec.add_development_dependency("kettle-dev", "~> 2.0")')
      expect(result).to include(
        "  # NOTE: It is preferable to list development dependencies in the gemspec due to increased\n  " \
          "#       visibility and discoverability.\n  " \
          "spec.add_development_dependency(\"rspec\", \"~> 3.12\")\n  " \
          "spec.add_development_dependency(\"rake\", \"~> 13.0\")",
      )
      expect(result).not_to include('spec.add_development_dependency("rake", ">= 12")')
      expect(result.index('spec.add_development_dependency("rspec", "~> 3.12")')).to be < result.index('spec.add_development_dependency("rake", "~> 13.0")')
    end

    it "keeps fallback runtime skip, replacement, and insertion decisions aligned on the mixed-action path" do
      allow(described_class).to receive(:gemspec_context).and_return(nil)

      destination = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "example"
          spec.version = "1.0.0"
          spec.add_dependency("kettle-dev", "~> 2.0")

          # NOTE: It is preferable to list development dependencies in the gemspec due to increased
          #       visibility and discoverability.
          spec.add_development_dependency("rake", ">= 12")
        end
      RUBY

      desired = {
        "kettle-dev" => '  spec.add_development_dependency("kettle-dev", "~> 2.0")',
        "rake" => '  spec.add_development_dependency("rake", "~> 13.0")',
        "rspec" => '  spec.add_development_dependency("rspec", "~> 3.12")',
      }

      result = described_class.ensure_development_dependencies(destination, desired)

      expect(result).to include('spec.add_dependency("kettle-dev", "~> 2.0")')
      expect(result).not_to include('spec.add_development_dependency("kettle-dev", "~> 2.0")')
      expect(result).to include(
        "  # NOTE: It is preferable to list development dependencies in the gemspec due to increased\n  " \
          "#       visibility and discoverability.\n  " \
          "spec.add_development_dependency(\"rspec\", \"~> 3.12\")\n  " \
          "spec.add_development_dependency(\"rake\", \"~> 13.0\")",
      )
      expect(result).not_to include('spec.add_development_dependency("rake", ">= 12")')
      expect(result.index('spec.add_development_dependency("rspec", "~> 3.12")')).to be < result.index('spec.add_development_dependency("rake", "~> 13.0")')
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

    it "prepends missing dependencies when the insertion anchor overlaps a replaced note-block dependency" do
      destination = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "example"
          spec.version = "1.0.0"

          # NOTE: It is preferable to list development dependencies in the gemspec due to increased
          #       visibility and discoverability.

          spec.add_development_dependency("bundler-audit", "~> 0.9.2")
        end
      RUBY

      desired = {
        "rake" => '  spec.add_development_dependency("rake", "~> 13.0")',
        "bundler-audit" => '  spec.add_development_dependency("bundler-audit", "~> 0.9.3")',
      }

      result = described_class.ensure_development_dependencies(destination, desired)

      expect(result).to include(
        "  # NOTE: It is preferable to list development dependencies in the gemspec due to increased\n  " \
          "#       visibility and discoverability.\n\n  " \
          "spec.add_development_dependency(\"rake\", \"~> 13.0\")\n  " \
          "spec.add_development_dependency(\"bundler-audit\", \"~> 0.9.3\")",
      )
      expect(result).not_to include('spec.add_development_dependency("bundler-audit", "~> 0.9.2")')
      expect(result.index('spec.add_development_dependency("rake", "~> 13.0")')).to be < result.index('spec.add_development_dependency("bundler-audit", "~> 0.9.3")')
    end

    it "keeps multiline AST-path replacements parseable when a missing sibling is inserted ahead of them below the note block" do
      destination = <<~RUBY
        Gem::Specification.new do |spec|
          spec.name = "example"
          spec.version = "1.0.0"

          # NOTE: It is preferable to list development dependencies in the gemspec due to increased
          #       visibility and discoverability.

          spec.add_development_dependency(
            "bundler-audit",
            "~> 0.9.2"
          )
        end
      RUBY

      desired = {
        "rake" => '  spec.add_development_dependency("rake", "~> 13.0")',
        "bundler-audit" => [
          "  spec.add_development_dependency(",
          '    "bundler-audit",',
          '    "~> 0.9.3"',
          "  )",
        ].join("\n"),
      }

      result = described_class.ensure_development_dependencies(destination, desired)

      expect(Prism.parse(result).success?).to be(true)
      expect(result).to include(
        "  # NOTE: It is preferable to list development dependencies in the gemspec due to increased\n  " \
          "#       visibility and discoverability.\n\n  " \
          "spec.add_development_dependency(\"rake\", \"~> 13.0\")\n  " \
          "spec.add_development_dependency(\n    " \
          "\"bundler-audit\",\n    " \
          "\"~> 0.9.3\"\n  " \
          ")",
      )
      expect(result).not_to include('"~> 0.9.2"')
      expect(result.index('spec.add_development_dependency("rake", "~> 13.0")')).to be < result.index("spec.add_development_dependency(\n    \"bundler-audit\",")
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
