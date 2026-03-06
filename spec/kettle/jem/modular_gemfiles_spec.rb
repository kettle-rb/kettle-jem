# frozen_string_literal: true

RSpec.describe Kettle::Jem::ModularGemfiles do
  after do
    Kettle::Jem::TemplateHelpers.clear_tokens!
  end

  it "exposes sync! and performs copy calls via helpers" do
    helpers = Kettle::Jem::TemplateHelpers
    Dir.mktmpdir do |proj|
      Dir.mktmpdir do |gemroot|
        # Create a minimal source tree for modular files
        src_dir = File.join(gemroot, "template", described_class::MODULAR_GEMFILE_DIR)
        FileUtils.mkdir_p(src_dir)
        %w[coverage debug documentation injected optional runtime_heads templating x_std_libs].each do |base|
          File.write(File.join(src_dir, "#{base}.gemfile"), "# #{base}\n")
        end
        File.write(File.join(src_dir, "style.gemfile"), "gem 'rubocop-lts', '{KJ|RUBOCOP_LTS_CONSTRAINT}'\n# {KJ|RUBOCOP_RUBY_GEM}\n")
        %w[erb mutex_m stringio x_std_libs].each do |dir|
          FileUtils.mkdir_p(File.join(src_dir, dir))
          File.write(File.join(src_dir, dir, "placeholder"), "ok\n")
        end

        # Stub helpers.project_root and template_root to these temp dirs
        allow(helpers).to receive_messages(
          project_root: proj,
          template_root: File.join(gemroot, "template"),
          ask: true,
        )

        expect {
          described_class.sync!(helpers: helpers, project_root: proj, min_ruby: Gem::Version.new("3.2"))
        }.not_to raise_error

        # Verify a couple of outputs exist
        expect(File).to exist(File.join(proj, described_class::MODULAR_GEMFILE_DIR, "coverage.gemfile"))
        expect(File).to exist(File.join(proj, described_class::MODULAR_GEMFILE_DIR, "style.gemfile"))
        expect(File.read(File.join(proj, described_class::MODULAR_GEMFILE_DIR, "style.gemfile"))).to include("rubocop-lts")
        expect(File).to exist(File.join(proj, described_class::MODULAR_GEMFILE_DIR, "erb", "placeholder"))
      end
    end
  end

  it "preserves if statements and comments when merging style.gemfile" do
    helpers = Kettle::Jem::TemplateHelpers
    Dir.mktmpdir do |proj|
      Dir.mktmpdir do |gemroot|
        # Create source and destination directories
        src_dir = File.join(gemroot, "template", described_class::MODULAR_GEMFILE_DIR)
        dest_dir = File.join(proj, described_class::MODULAR_GEMFILE_DIR)
        FileUtils.mkdir_p(src_dir)
        FileUtils.mkdir_p(dest_dir)

        # Create template source with if statement and tokens
        src_content = <<~RUBY
          # frozen_string_literal: true

          gem "reek", "~> 6.5"
          gem "rubocop-packaging", "~> 0.6", ">= 0.6.0"
          gem "standard", ">= 1.50"
          gem "rubocop-on-rbs", "~> 1.8"                    # ruby >= 3.1.0

          # Std Lib extractions
          gem "benchmark", "~> 0.4", ">= 0.4.1" # Removed from Std Lib in Ruby 3.5

          if ENV.fetch("RUBOCOP_LTS_LOCAL", "false").casecmp("true").zero?
            home = ENV["HOME"] || Dir.home
            gem "rubocop-lts", path: "\#{home}/src/rubocop-lts/rubocop-lts"
            gem "rubocop-lts-rspec", path: "\#{home}/src/rubocop-lts/rubocop-lts-rspec"
            gem "{KJ|RUBOCOP_RUBY_GEM}", path: "\#{home}/src/rubocop-lts/{KJ|RUBOCOP_RUBY_GEM}"
            gem "standard-rubocop-lts", path: "\#{home}/src/rubocop-lts/standard-rubocop-lts"
          else
            gem "rubocop-lts", "{KJ|RUBOCOP_LTS_CONSTRAINT}"
            gem "{KJ|RUBOCOP_RUBY_GEM}"
            gem "rubocop-rspec", "~> 3.6"
          end
        RUBY
        File.write(File.join(src_dir, "style.gemfile"), src_content)

        # Create pre-existing destination with different gems
        dest_content = <<~RUBY
          # frozen_string_literal: true

          gem "reek", "~> 6.4"
          gem "rubocop", "~> 1.73", ">= 1.73.2"
          gem "standard", "~> 1.47"
        RUBY
        File.write(File.join(dest_dir, "style.gemfile"), dest_content)

        # Create empty subdirectories
        %w[erb mutex_m stringio x_std_libs].each do |dir|
          FileUtils.mkdir_p(File.join(src_dir, dir))
        end

        # Stub helpers methods
        allow(helpers).to receive_messages(
          project_root: proj,
          template_root: File.join(gemroot, "template"),
          ask: true,
        )

        # Configure tokens so read_template resolves {KJ|...} tokens
        helpers.configure_tokens!(
          org: "test-org",
          gem_name: "test-gem",
          namespace: "TestGem",
          namespace_shield: "Test__Gem",
          gem_shield: "test__gem",
          min_ruby: Gem::Version.new("2.3"),
        )

        # Run sync
        described_class.sync!(
          helpers: helpers,
          project_root: proj,
          min_ruby: Gem::Version.new("2.3"),
        )

        # Read the result
        result = File.read(File.join(dest_dir, "style.gemfile"))

        # Verify the if statement is preserved
        expect(result).to include('if ENV.fetch("RUBOCOP_LTS_LOCAL"')
        expect(result).to include("else")
        expect(result).to include("end")

        # Verify comments are preserved
        expect(result).to include("# ruby >= 3.1.0")
        expect(result).to include("# Std Lib extractions")
        expect(result).to include("# Removed from Std Lib in Ruby 3.5")

        # Verify tokens were replaced for Ruby 2.3
        expect(result).to include('gem "rubocop-lts", "~> 10.0"')
        expect(result).to include('gem "rubocop-ruby2_3"')
        expect(result).not_to include("{KJ|RUBOCOP_LTS_CONSTRAINT}")
        expect(result).not_to include("{KJ|RUBOCOP_RUBY_GEM}")

        # Verify new gems from template were added
        expect(result).to include("rubocop-packaging")
        expect(result).to include("rubocop-on-rbs")
        expect(result).to include("benchmark")

        # Verify existing gems from destination were preserved
        expect(result).to include("reek")
        expect(result).to include("standard")
      end
    end
  end

  describe "self-dependency removal" do
    let(:helpers) { Kettle::Jem::TemplateHelpers }

    it "strips gem lines matching gem_name from modular gemfiles" do
      Dir.mktmpdir do |proj|
        Dir.mktmpdir do |gemroot|
          src_dir = File.join(gemroot, "template", described_class::MODULAR_GEMFILE_DIR)
          dest_dir = File.join(proj, described_class::MODULAR_GEMFILE_DIR)
          FileUtils.mkdir_p(src_dir)
          FileUtils.mkdir_p(dest_dir)

          # Template has tree_haver as a gem dependency — problematic when
          # the destination IS tree_haver itself
          File.write(File.join(src_dir, "templating_local.gemfile"), <<~RUBY)
            gem "tree_haver", path: "../tree_haver"
            gem "ast-merge", path: "../ast-merge"
            gem "prism-merge", path: "../ast-merge/vendor/prism-merge"
          RUBY

          allow(helpers).to receive_messages(
            project_root: proj,
            template_root: File.join(gemroot, "template"),
            ask: true,
          )

          described_class.sync!(
            helpers: helpers,
            project_root: proj,
            gem_name: "tree_haver",
          )

          result = File.read(File.join(dest_dir, "templating_local.gemfile"))
          expect(result).not_to include("tree_haver")
          expect(result).to include('gem "ast-merge"')
          expect(result).to include('gem "prism-merge"')
        end
      end
    end

    it "does not strip anything when gem_name is nil" do
      Dir.mktmpdir do |proj|
        Dir.mktmpdir do |gemroot|
          src_dir = File.join(gemroot, "template", described_class::MODULAR_GEMFILE_DIR)
          dest_dir = File.join(proj, described_class::MODULAR_GEMFILE_DIR)
          FileUtils.mkdir_p(src_dir)
          FileUtils.mkdir_p(dest_dir)

          File.write(File.join(src_dir, "templating_local.gemfile"), <<~RUBY)
            gem "tree_haver", path: "../tree_haver"
            gem "ast-merge", path: "../ast-merge"
          RUBY

          allow(helpers).to receive_messages(
            project_root: proj,
            template_root: File.join(gemroot, "template"),
            ask: true,
          )

          described_class.sync!(
            helpers: helpers,
            project_root: proj,
            gem_name: nil,
          )

          result = File.read(File.join(dest_dir, "templating_local.gemfile"))
          expect(result).to include("tree_haver")
          expect(result).to include("ast-merge")
        end
      end
    end
  end

  describe "min ruby bucket pruning" do
    let(:helpers) { Kettle::Jem::TemplateHelpers }

    it "skips buckets below min_ruby and warns when destination file exists" do
      Dir.mktmpdir do |proj|
        Dir.mktmpdir do |gemroot|
          src_dir = File.join(gemroot, "template", described_class::MODULAR_GEMFILE_DIR, "erb")
          dest_dir = File.join(proj, described_class::MODULAR_GEMFILE_DIR, "erb")
          FileUtils.mkdir_p(File.join(src_dir, "r3.1"))
          FileUtils.mkdir_p(File.join(src_dir, "r3"))
          FileUtils.mkdir_p(dest_dir)

          # r3.1 should be pruned for min_ruby 3.2
          File.write(File.join(src_dir, "r3.1", "v4.0.gemfile"), "gem 'erb'\n")
          # r3 should be kept (catch-all for >=3.2)
          File.write(File.join(src_dir, "r3", "v3.0.gemfile"), "gem 'erb'\n")

          # Existing destination file for the pruned bucket should trigger warning
          pruned_dest = File.join(dest_dir, "r3.1", "v4.0.gemfile")
          FileUtils.mkdir_p(File.dirname(pruned_dest))
          File.write(pruned_dest, "old\n")

          allow(helpers).to receive_messages(
            project_root: proj,
            template_root: File.join(gemroot, "template"),
            ask: true,
          )
          helpers.clear_warnings

          described_class.sync!(
            helpers: helpers,
            project_root: proj,
            min_ruby: Gem::Version.new("3.2"),
          )

          expect(File).to exist(File.join(dest_dir, "r3", "v3.0.gemfile"))
          expect(helpers.warnings.join("\n")).to include("r3.1")
        end
      end
    end
  end

  describe "strategy handling" do
    let(:helpers) { Kettle::Jem::TemplateHelpers }

    it "does not create a modular gemfile when strategy is keep_destination" do
      Dir.mktmpdir do |proj|
        Dir.mktmpdir do |gemroot|
          src_dir = File.join(gemroot, "template", described_class::MODULAR_GEMFILE_DIR)
          FileUtils.mkdir_p(src_dir)
          File.write(File.join(src_dir, "optional.gemfile"), "gem \"foo\"\n")

          File.write(File.join(proj, ".kettle-jem.yml"), <<~YAML)
            defaults:
              preference: template
              add_template_only_nodes: true
              freeze_token: kettle-jem
            tokens: {}
            patterns: []
            files:
              gemfiles:
                modular:
                  optional.gemfile:
                    strategy: keep_destination
          YAML

          allow(helpers).to receive_messages(
            project_root: proj,
            template_root: File.join(gemroot, "template"),
            ask: true,
          )
          helpers.clear_kettle_config!

          described_class.sync!(helpers: helpers, project_root: proj)

          expect(File).not_to exist(File.join(proj, described_class::MODULAR_GEMFILE_DIR, "optional.gemfile"))
        end
      end
    end
  end
end
