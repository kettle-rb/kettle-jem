# frozen_string_literal: true

# rubocop:disable ThreadSafety/DirChdir

RSpec.describe Kettle::Jem::SetupCLI do
  def write(file, content)
    File.write(file, content)
  end

  def read(file)
    File.read(file)
  end

  describe "skip-commit propagation" do
    after { ENV.delete("KETTLE_JEM_SKIP_COMMIT") }

    it "sets KETTLE_JEM_SKIP_COMMIT when --skip-commit is passed" do
      described_class.new(["--skip-commit"])

      expect(ENV["KETTLE_JEM_SKIP_COMMIT"]).to eq("true")
    end

    it "treats KETTLE_JEM_SKIP_COMMIT as authoritative process state" do
      ENV["KETTLE_JEM_SKIP_COMMIT"] = "true"
      cli = described_class.new([])

      expect(cli.send(:skip_commit?)).to be(true)
    end
  end

  it "updates existing add_development_dependency lines that omit parentheses, without creating duplicates" do
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        # minimal git repo to satisfy prechecks!
        %x(git init -q)
        # clean working tree
        %x(git add -A && git commit --allow-empty -m initial -q)

        # Create a Gemfile to satisfy prechecks
        write("Gemfile", "source 'https://gem.coop'\n")

        # Create a target gemspec with non-parenthesized dev deps (from the user's example)
        gemspec = <<~RUBY
          Gem::Specification.new do |spec|
            spec.name = 'example'
            spec.version = '0.0.1'

            spec.add_development_dependency 'addressable', '>= 2'
            spec.add_development_dependency 'rake', '>= 12'
            spec.add_development_dependency 'rexml', '>= 3'
            spec.add_development_dependency 'rspec', '>= 3'
            spec.add_development_dependency 'rspec-block_is_expected'
            spec.add_development_dependency 'rspec-pending-for'
            spec.add_development_dependency 'rspec-stubbed_env'
            spec.add_development_dependency 'rubocop-lts', ['>= 2.0.3', '~>2.0']
            spec.add_development_dependency 'silent_stream'
          end
        RUBY
        write("example.gemspec", gemspec)

        # Stub installed_path to point to the example shipped with repo
        example_path = File.expand_path("../../../template/gem.gemspec.example", __dir__)

        cli = described_class.allocate
        cli.instance_variable_set(:@argv, [])
        cli.instance_variable_set(:@passthrough, [])
        cli.send(:parse!) # init options

        # stub prechecks! to set gemspec/Gemfile without enforcing cleanliness again
        cli.instance_variable_set(:@gemspec_path, File.join(dir, "example.gemspec"))

        allow(cli).to receive(:installed_path).and_wrap_original do |orig, rel|
          # Only intercept the example gemspec lookup
          if rel == "gem.gemspec.example"
            example_path
          else
            orig.call(rel)
          end
        end

        # We also need to bypass git clean check inside prechecks!
        allow(cli).to receive(:prechecks!).and_return(nil)

        # Run just the dependency sync
        cli.send(:ensure_dev_deps!)

        result = read("example.gemspec")

        # Ensure we did not introduce duplicates for gems like rake and stone_checksums
        rake_lines = result.lines.grep(/add_development_dependency\s*\(?\s*["']rake["']/)
        stone_checksums_lines = result.lines.grep(/add_development_dependency\s*\(?\s*["']stone_checksums["']/)
        expect(rake_lines.size).to eq(1)
        expect(stone_checksums_lines.size).to eq(1)

        # Ensure the lines were updated to match the constraints from the example file (i.e., include ~> 13.0 etc.)
        expect(result).to match(/add_development_dependency\(\s*"rake"\s*,\s*"~> 13\.0"\s*\)/)
        expect(result).to match(/add_development_dependency\(\s*"stone_checksums"\s*,\s*"~> 1\.0"\s*,\s*">= 1\.0\.\d+"\s*\)/)
      end
    end
  end

  describe "include passthrough" do
    it "run_kettle_install! includes include=... in the rake command" do
      cli = described_class.allocate
      cli.instance_variable_set(:@passthrough, ["include=foo/bar/**"])
      cli.instance_variable_set(:@verbose, true)
      expect(cli).to receive(:sh!).with(a_string_including("bin/rake kettle:jem:install include\\=foo/bar/\\*\\*"), suppress_command_log: false)
      cli.send(:run_kettle_install!)
    end
  end

  describe "setup preflight" do
    it "suppresses startup and completion chatter when quiet is enabled", :check_output do
      cli = described_class.new([])

      allow(cli).to receive(:debug_bundler_env)
      allow(cli).to receive(:debug_git_status)
      allow(cli).to receive_messages(
        bundled_execution_context?: true,
        ensure_project_files!: nil,
        load_bundled_runtime!: nil,
        ensure_rakefile!: nil,
        run_kettle_install!: nil,
        commit_bootstrap_changes!: nil,
      )

      expect { cli.run! }.not_to output.to_stdout
    ensure
      ENV.delete("KETTLE_JEM_QUIET")
    end

    it "returns early when bootstrap writes the template config file" do
      cli = described_class.allocate
      cli.instance_variable_set(:@argv, [])
      cli.instance_variable_set(:@original_argv, [])
      cli.instance_variable_set(:@passthrough, [])
      cli.send(:parse!)

      allow(cli).to receive(:debug_bundler_env)
      allow(cli).to receive(:debug_git_status)
      allow(cli).to receive(:say)
      allow(cli).to receive_messages(
        bundled_execution_context?: false,
        prechecks!: nil,
        template_config_present?: false,
        ensure_template_config_bootstrap!: :bootstrap_only,
      )
      expect(cli).not_to receive(:ensure_gemfile_from_example!)
      expect(cli).not_to receive(:handoff_to_bundled_phase!)
      expect(cli).not_to receive(:ensure_dev_deps!)
      expect(cli).not_to receive(:ensure_modular_gemfiles!)

      expect { cli.run! }.not_to raise_error
    end

    it "runs only the minimal bootstrap steps before handing off to bundler when the config already exists" do
      cli = described_class.allocate
      cli.instance_variable_set(:@argv, [])
      cli.instance_variable_set(:@original_argv, [])
      cli.instance_variable_set(:@passthrough, [])
      cli.send(:parse!)

      allow(cli).to receive(:debug_bundler_env)
      allow(cli).to receive(:debug_git_status)
      allow(cli).to receive(:say)
      allow(cli).to receive_messages(bundled_execution_context?: false, prechecks!: nil, template_config_present?: true)

      expect(cli).not_to receive(:ensure_template_config_bootstrap!)
      expect(cli).not_to receive(:ensure_modular_gemfiles!)
      expect(cli).not_to receive(:ensure_rakefile!)
      expect(cli).not_to receive(:run_kettle_install!)
      expect(cli).not_to receive(:commit_bootstrap_changes!)
      expect(cli).not_to receive(:ensure_gemfile_from_example!)
      expect(cli).not_to receive(:ensure_dev_deps!)
      expect(cli).to receive(:run_preflight_templating!).ordered.and_return(nil)
      expect(cli).to receive(:ensure_bin_setup!).ordered.and_return(nil)
      expect(cli).to receive(:run_bin_setup!).ordered.and_return(nil)
      expect(cli).to receive(:run_bundle_binstubs!).ordered.and_return(nil)
      expect(cli).to receive(:handoff_to_bundled_phase!).ordered.and_return(nil)

      expect { cli.run! }.not_to raise_error
    end

    it "runs the heavy setup steps only after bundler is active" do
      cli = described_class.allocate
      cli.instance_variable_set(:@argv, [])
      cli.instance_variable_set(:@original_argv, [])
      cli.instance_variable_set(:@passthrough, [])
      cli.send(:parse!)

      allow(cli).to receive(:debug_bundler_env)
      allow(cli).to receive(:debug_git_status)
      allow(cli).to receive(:say)
      allow(cli).to receive(:bundled_execution_context?).and_return(true)

      expect(cli).not_to receive(:prechecks!)
      expect(cli).not_to receive(:ensure_template_config_bootstrap!)
      expect(cli).not_to receive(:ensure_dev_deps!)
      expect(cli).not_to receive(:ensure_gemfile_from_example!)
      expect(cli).not_to receive(:ensure_modular_gemfiles!)
      expect(cli).to receive(:ensure_project_files!).ordered.and_return(nil)
      expect(cli).to receive(:load_bundled_runtime!).ordered.and_return(nil)
      expect(cli).to receive(:ensure_rakefile!).ordered.and_return(nil)
      expect(cli).to receive(:run_kettle_install!).ordered.and_return(nil)
      expect(cli).to receive(:commit_bootstrap_changes!).ordered.and_return(nil)

      expect { cli.run! }.not_to raise_error
    end
  end

  describe "template config bootstrap seeding" do
    it "fills env-backed token values into blank .kettle-jem.yml slots" do
      cli = described_class.allocate
      example_path = File.expand_path("../../../template/.kettle-jem.yml.example", __dir__)

      stub_env(
        "KJ_GH_USER" => "pboling",
        "KJ_AUTHOR_NAME" => "Peter H. Boling",
        "KJ_AUTHOR_GIVEN_NAMES" => "Peter H.",
        "KJ_AUTHOR_FAMILY_NAMES" => "Boling",
        "KJ_AUTHOR_EMAIL" => "floss@galtzo.com",
        "KJ_AUTHOR_DOMAIN" => "galtzo.com",
        "KJ_AUTHOR_ORCID" => "0009-0008-8519-441X",
        "KJ_FUNDING_KOFI" => "pboling",
        "KJ_SOCIAL_MASTODON" => "galtzo",
      )

      seeded = cli.send(:seed_bootstrap_template_config, File.read(example_path))
      parsed = YAML.safe_load(seeded, permitted_classes: [], aliases: false)

      expect(parsed.dig("tokens", "forge", "gh_user")).to eq("pboling")
      expect(parsed.dig("tokens", "author", "name")).to eq("Peter H. Boling")
      expect(parsed.dig("tokens", "author", "given_names")).to eq("Peter H.")
      expect(parsed.dig("tokens", "author", "family_names")).to eq("Boling")
      expect(parsed.dig("tokens", "author", "email")).to eq("floss@galtzo.com")
      expect(parsed.dig("tokens", "author", "domain")).to eq("galtzo.com")
      expect(parsed.dig("tokens", "author", "orcid")).to eq("0009-0008-8519-441X")
      expect(parsed.dig("tokens", "funding", "kofi")).to eq("pboling")
      expect(parsed.dig("tokens", "social", "mastodon")).to eq("galtzo")
    end

    it "resolves top-level bootstrap config placeholders from ENV" do
      cli = described_class.allocate
      content = <<~YAML
        project_emoji: "{KJ|PROJECT_EMOJI}"
        min_divergence_threshold: {KJ|MIN_DIVERGENCE_THRESHOLD}
      YAML

      stub_env(
        "KJ_PROJECT_EMOJI" => "⭐️",
        "KJ_MIN_DIVERGENCE_THRESHOLD" => "0",
      )

      seeded = cli.send(:seed_bootstrap_template_config, content)

      expect(seeded).to include('project_emoji: "⭐️"')
      expect(seeded).to include("min_divergence_threshold: 0")
      expect(seeded).not_to include("{KJ|PROJECT_EMOJI}")
      expect(seeded).not_to include("{KJ|MIN_DIVERGENCE_THRESHOLD}")
    end

    it "falls back to loadable gemspec metadata when author env vars are absent" do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          File.write("demo.gemspec", <<~RUBY)
            Gem::Specification.new do |spec|
              spec.name = "demo"
              spec.authors = ["Example Person"]
              spec.email = ["example@example.com"]
            end
          RUBY

          cli = described_class.allocate
          cli.instance_variable_set(:@gemspec_path, File.join(dir, "demo.gemspec"))
          stub_env(
            "KJ_AUTHOR_NAME" => nil,
            "KJ_AUTHOR_GIVEN_NAMES" => nil,
            "KJ_AUTHOR_FAMILY_NAMES" => nil,
            "KJ_AUTHOR_EMAIL" => nil,
            "KJ_AUTHOR_DOMAIN" => nil,
          )

          values = cli.send(:bootstrap_template_config_values)

          expect(values.dig("author", "name")).to eq("Example Person")
          expect(values.dig("author", "given_names")).to eq("Example")
          expect(values.dig("author", "family_names")).to eq("Person")
          expect(values.dig("author", "email")).to eq("example@example.com")
          expect(values.dig("author", "domain")).to eq("example.com")
        end
      end
    end
  end

  describe "#ensure_modular_gemfiles!" do
    it "raises when metadata extraction fails so token configuration cannot proceed" do
      cli = described_class.allocate
      helpers = class_double(Kettle::Jem::TemplateHelpers)
      allow(helpers).to receive_messages(
        project_root: "/tmp/project",
        template_root: "/tmp/checkout/template",
        opencollective_disabled?: false,
      )
      allow(helpers).to receive(:gemspec_metadata).and_raise(StandardError)
      allow(helpers).to receive(:configure_tokens!).and_raise(Kettle::Jem::Error, "Gem name could not be derived")
      stub_const("Kettle::Jem::TemplateHelpers", helpers)

      # Token configuration failure is now fatal — ensure_modular_gemfiles! must not swallow it
      expect(Kettle::Jem::ModularGemfiles).not_to receive(:sync!)
      expect {
        cli.send(:ensure_modular_gemfiles!)
      }.to raise_error(Kettle::Jem::Error, /Gem name could not be derived/)
    end
  end

  describe "#ensure_dev_deps! additional branches" do
    around do |ex|
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) { ex.run }
      end
    end

    def setup_cli_for_deps(example_path)
      cli = described_class.allocate
      cli.instance_variable_set(:@argv, [])
      cli.instance_variable_set(:@passthrough, [])
      cli.send(:parse!)
      allow(cli).to receive(:installed_path).and_wrap_original do |orig, rel|
        if rel == "gem.gemspec.example"
          example_path
        else
          orig.call(rel)
        end
      end
      cli
    end

    it "appends wanted lines when target gemspec lacks closing end (no rindex match)" do
      # Create an empty gemspec to force the append code path
      File.write("target.gemspec", "")
      example_path = File.expand_path("../../../template/gem.gemspec.example", __dir__)
      cli = setup_cli_for_deps(example_path)
      cli.instance_variable_set(:@gemspec_path, File.join(Dir.pwd, "target.gemspec"))

      # Act
      cli.send(:ensure_dev_deps!)

      content = File.read("target.gemspec")
      # Expect at least one development dependency line to be present (from example)
      expect(content).to match(/add_development_dependency\(\s*"rake"/)
    end

    it "prints up-to-date message when no changes are needed", :check_output do
      # Make the target match the example exactly (after placeholder substitution)
      example_path = File.expand_path("../../../template/gem.gemspec.example", __dir__)
      text = File.read(example_path).gsub("{KJ|KETTLE_DEV_GEM}", "kettle-dev")
      File.write("target.gemspec", text)

      cli = setup_cli_for_deps(example_path)
      cli.instance_variable_set(:@gemspec_path, File.join(Dir.pwd, "target.gemspec"))
      cli.instance_variable_set(:@verbose, true)

      expect { cli.send(:ensure_dev_deps!) }.to output(/Development dependencies already up to date\./).to_stdout
      expect(File.read("target.gemspec")).to eq(text)
    end

    it "syncs multiline development dependencies from the example gemspec while ignoring commented-out ones" do
      File.write("target.gemspec", <<~RUBY)
        Gem::Specification.new do |spec|
          spec.name = "demo"
          spec.version = "0.0.1"
        end
      RUBY

      example_path = File.join(Dir.pwd, "multiline-example.gemspec")
      File.write(example_path, <<~RUBY)
        Gem::Specification.new do |spec|
          spec.name = "template-demo"
          spec.version = "0.0.1"

          # spec.add_development_dependency("ignored", "~> 9.9")
          spec.add_development_dependency(
            "rake",
            "~> 13.0"
          ) # ruby >= 2.2.0
        end
      RUBY

      cli = setup_cli_for_deps(example_path)
      cli.instance_variable_set(:@gemspec_path, File.join(Dir.pwd, "target.gemspec"))

      cli.send(:ensure_dev_deps!)

      content = File.read("target.gemspec")
      expect(content).to include("  spec.add_development_dependency(\n    \"rake\",\n    \"~> 13.0\"\n  ) # ruby >= 2.2.0")
      expect(content).not_to include("ignored")
    end

    it "still seeds development dependencies when Prism context lookup is unavailable during bootstrap" do
      File.write("Gemfile", "source 'https://gem.coop'\n")
      File.write("target.gemspec", <<~RUBY)
        Gem::Specification.new do |spec|
          spec.name = "demo"
          spec.version = "0.0.1"
        end
      RUBY

      example_path = File.expand_path("../../../template/gem.gemspec.example", __dir__)
      cli = setup_cli_for_deps(example_path)
      cli.instance_variable_set(:@gemspec_path, File.join(Dir.pwd, "target.gemspec"))

      allow(Kettle::Jem::PrismGemspec).to receive(:gemspec_context).and_raise(LoadError, "cannot load such file -- prism")

      cli.send(:ensure_dev_deps!)

      content = File.read("target.gemspec")
      expect(content).to match(/add_development_dependency\(\s*"rake"/)
      expect(content).to match(/add_development_dependency\(\s*"kettle-test"/)
    end
  end

  describe "#commit_bootstrap_changes! fallbacks" do
    around do |ex|
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) { ex.run }
      end
    end

    it "uses Open3 fallback when GitAdapter raises (rescue branch)", :check_output do
      %x(git init -q)
      # Simulate clean working tree via Open3 output empty
      allow(Kettle::Dev::GitAdapter).to receive(:new).and_raise(StandardError)
      allow(Open3).to receive(:capture2).with("git", "status", "--porcelain").and_return(["", instance_double(Process::Status)])
      cli = described_class.allocate
      cli.instance_variable_set(:@verbose, true)
      expect { cli.send(:commit_bootstrap_changes!) }.to output(/No changes to commit/).to_stdout
    end

    it "uses Open3 path when GitAdapter constant is removed (else branch)", :check_output do
      %x(git init -q)
      hide_const("Kettle::Dev::GitAdapter")
      allow(Open3).to receive(:capture2).with("git", "status", "--porcelain").and_return(["", instance_double(Process::Status)])
      cli = described_class.allocate
      cli.instance_variable_set(:@verbose, true)
      expect { cli.send(:commit_bootstrap_changes!) }.to output(/No changes to commit/).to_stdout
    end
  end

  describe "#derive_funding_org_from_git_if_missing!" do
    before do
      # Never modify ENV directly in specs; ensure OPENCOLLECTIVE_HANDLE is unset for each example
      # Also ensure FUNDING_ORG is unset to avoid cross-example leakage when a previous
      # example derives it from the git remote.
      stub_env("OPENCOLLECTIVE_HANDLE" => nil, "FUNDING_ORG" => nil)
    end

    around do |ex|
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) { ex.run }
      end
    end

    def build_cli
      described_class.allocate
    end

    it "returns early when .opencollective.yml has org" do
      File.write(".opencollective.yml", "org: cool-co\n")
      cli = build_cli
      # Provide a git adapter that would otherwise set the env if called
      fake_ga = instance_double(Kettle::Dev::GitAdapter)
      allow(Kettle::Dev::GitAdapter).to receive(:new).and_return(fake_ga)
      allow(fake_ga).to receive_messages(clean?: true, remote_url: "git@github.com:acme/thing.git")

      cli.send(:derive_funding_org_from_git_if_missing!)

      expect(ENV["FUNDING_ORG"]).to be_nil
    end

    it "logs debug when reading .opencollective.yml fails", :check_output do
      stub_env("KETTLE_DEV_DEBUG" => "true")
      oc = File.join(Dir.pwd, ".opencollective.yml")
      # Create file and then force File.read to raise for this specific path
      File.write(oc, "org: nope\n")
      cli = build_cli
      allow(File).to receive(:read).and_wrap_original do |orig, path|
        if path == oc
          raise IOError, "boom"
        else
          orig.call(path)
        end
      end
      expect { cli.send(:derive_funding_org_from_git_if_missing!) }
        .to output(/Reading \.opencollective\.yml failed: IOError: boom/).to_stderr
    end

    it "uses remotes_with_urls when remote_url is unavailable and sets FUNDING_ORG from origin", :check_output do
      stub_env("KETTLE_DEV_DEBUG" => "true")
      fake_ga = Object.new
      def fake_ga.respond_to?(m)
        m == :remotes_with_urls
      end
      allow(fake_ga).to receive(:remotes_with_urls).and_return({"origin" => "https://github.com/example/repo.git"})
      allow(Kettle::Dev::GitAdapter).to receive(:new).and_return(fake_ga)

      cli = build_cli
      expect { cli.send(:derive_funding_org_from_git_if_missing!) }
        .to output(/Derived FUNDING_ORG from git origin: example/).to_stderr
    end

    it "logs debug when remotes_with_urls raises and otherwise continues silently", :check_output do
      stub_env("KETTLE_DEV_DEBUG" => "true")
      fake_ga = Object.new
      def fake_ga.respond_to?(m)
        m == :remotes_with_urls
      end
      allow(fake_ga).to receive(:remotes_with_urls).and_raise(StandardError, "bad remote")
      allow(Kettle::Dev::GitAdapter).to receive(:new).and_return(fake_ga)

      cli = build_cli
      expect { cli.send(:derive_funding_org_from_git_if_missing!) }
        .to output(/remotes_with_urls failed: StandardError: bad remote/).to_stderr
      expect(ENV["FUNDING_ORG"]).to be_nil
    end

    it "swallows unexpected adapter errors and logs debug (outer rescue)", :check_output do
      stub_env("KETTLE_DEV_DEBUG" => "true")
      allow(Kettle::Dev::GitAdapter).to receive(:new).and_raise(RuntimeError, "kaput")
      cli = build_cli
      expect { cli.send(:derive_funding_org_from_git_if_missing!) }
        .to output(/Could not derive funding org from git: RuntimeError: kaput/).to_stderr
    end
  end

  describe "#initialize and parse!" do
    it "collects passthrough options and remaining args; shows help and exits with 0", :check_output do
      argv = ["--allowed=foo", "--hook_templates=bar", "--only=baz", "-h"]
      expect do
        expect { described_class.new(argv) }.to raise_error(MockSystemExit, /exit status 0/)
      end.to output(/Usage: kettle-jem.*--verbose/m).to_stdout
    ensure
      ENV.delete("KETTLE_JEM_QUIET")
    end

    it "rescues parse errors, prints usage, and exits 2", :check_output do
      argv = ["--unknown"]
      cli = described_class.allocate
      cli.instance_variable_set(:@argv, argv)
      # call private parse! directly to isolate behavior
      expect do
        expect { cli.send(:parse!) }.to raise_error(MockSystemExit, /exit status 2/)
      end.to output(/Usage: kettle-jem/).to_stdout.and output(/OptionParser/).to_stderr
    end

    it "appends remaining argv into @passthrough when no special flags" do
      cli = described_class.new(["foo=1", "bar"])
      expect(cli.instance_variable_get(:@passthrough)).to include("foo=1", "bar")
    end

    it "quiet is the default behavior (no flag needed)" do
      cli = described_class.new([])

      expect(cli.send(:quiet?)).to be(true)
    end
  end

  it "force is the default behavior (ENV['force'] not needed)" do
    cli = described_class.new([])
    expect(cli.send(:force?)).to be(true)
  end

  it "--failure-mode sets ENV['FAILURE_MODE'] and passes through to rake" do
    stub_const("ENV", {})
    cli = described_class.new(["--failure-mode=rescue"])
    expect(ENV["FAILURE_MODE"]).to eq("rescue")
    expect(cli.instance_variable_get(:@passthrough)).to include("FAILURE_MODE=rescue")
  end

  describe "#prechecks!" do
    around do |ex|
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) { ex.run }
      end
    end

    it "aborts when git tree is dirty, even with force" do
      %x(git init -q)
      %x(git add -A && git commit --allow-empty -m initial -q)
      File.write("dirty.txt", "uncommitted\n")

      cli = described_class.allocate
      cli.instance_variable_set(:@argv, [])
      cli.instance_variable_set(:@passthrough, [])
      cli.send(:parse!)
      stub_env("force" => "true")

      # Stub GitAdapter to report dirty tree
      allow(Kettle::Dev::GitAdapter).to receive(:new).and_return(instance_double(Kettle::Dev::GitAdapter, clean?: false))

      expect {
        cli.send(:prechecks!)
      }.to raise_error(MockSystemExit, /not clean/)
    end
  end

  describe "#debug" do
    it "prints when DEBUG=true", :check_output do
      stub_env("KETTLE_DEV_DEBUG" => "true")
      cli = described_class.allocate
      expect { cli.send(:debug, "hi") }.to output(/DEBUG: hi/).to_stderr
    end

    it "does not print when DEBUG=false", :check_output do
      stub_env("KETTLE_DEV_DEBUG" => "false")
      cli = described_class.allocate
      expect { cli.send(:debug, "hi") }.not_to output.to_stderr
    end
  end

  describe "#say and #abort!" do
    it "say prints with prefix", :check_output do
      cli = described_class.allocate
      expect { cli.send(:say, "msg") }.to output(/\[kettle-jem\] msg/).to_stdout
    end

    it "say suppresses verbose-only messages when quiet", :check_output do
      cli = described_class.allocate
      cli.instance_variable_set(:@quiet, true)

      expect { cli.send(:say, "msg", verbose_only: true) }.not_to output.to_stdout
    end

    it "abort! uses ExitAdapter and raises MockSystemExit with message" do
      cli = described_class.allocate
      expect { cli.send(:abort!, "boom") }.to raise_error(MockSystemExit, /ERROR: boom/)
    end
  end

  describe "#sh!" do
    it "prints command and stderr, and aborts on non-zero", :check_output do
      cli = described_class.allocate
      allow(Open3).to receive(:capture3).and_return(["", "err", instance_double(Process::Status, success?: false)])
      expect do
        expect { cli.send(:sh!, "echo hi") }.to raise_error(MockSystemExit, /Command failed/)
      end.to output(/exec: echo hi/).to_stdout.and output("err").to_stderr
    end

    it "passes env to capture3 and succeeds", :check_output do
      cli = described_class.allocate
      status = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture3).with({"A" => "1"}, "cmd").and_return(["", "", status])
      expect { cli.send(:sh!, "cmd", env: {"A" => "1"}) }.to output(/exec: cmd/).to_stdout
    end

    it "suppresses successful command logging and output when requested", :check_output do
      cli = described_class.allocate
      status = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture3).with({}, "bundle binstubs --all").and_return(["out", "err", status])

      expect { cli.send(:sh!, "bundle binstubs --all", suppress_output: true, suppress_command_log: true) }
        .to output("").to_stdout.and output("").to_stderr
    end

    it "suppresses successful command logging while still streaming subprocess output", :check_output do
      cli = described_class.allocate
      status = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture3).with({}, "bin/setup --quiet").and_return(["out", "err", status])

      expect { cli.send(:sh!, "bin/setup --quiet", suppress_command_log: true) }
        .to output("out").to_stdout.and output("err").to_stderr
    end

    it "replays suppressed command logging and output when a suppressed command fails", :check_output do
      cli = described_class.allocate
      status = instance_double(Process::Status, success?: false)
      allow(Open3).to receive(:capture3).with({}, "bundle binstubs --all").and_return(["out", "err", status])

      expect do
        expect { cli.send(:sh!, "bundle binstubs --all", suppress_output: true, suppress_command_log: true) }
          .to raise_error(MockSystemExit, /Command failed/)
      end.to output(/exec: bundle binstubs --all\nout/).to_stdout.and output("err").to_stderr
    end
  end

  describe "#ensure_gemfile_from_example!" do
    around do |ex|
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) { ex.run }
      end
    end

    it "merges Gemfile.example entries without duplicating directives" do
      # minimal git repo and files
      %x(git init -q)
      %x(git add -A && git commit --allow-empty -m initial -q)
      File.write("a.gemspec", "Gem::Specification.new do |s| end\n")

      # Start with a Gemfile that already has source, gemspec, and one eval_gemfile
      initial = <<~G
        source "https://gem.coop"
        gemspec
        eval_gemfile "gemfiles/modular/style.gemfile"
      G
      File.write("Gemfile", initial)

      cli = described_class.allocate
      cli.instance_variable_set(:@argv, [])
      cli.instance_variable_set(:@passthrough, [])
      cli.send(:parse!)

      # Stub installed_path to return the repo's Gemfile.example
      example_path = File.expand_path("../../../template/Gemfile.example", __dir__)
      allow(cli).to receive(:installed_path).and_wrap_original do |orig, rel|
        if rel == "Gemfile.example"
          example_path
        else
          orig.call(rel)
        end
      end

      # Act
      cli.send(:ensure_gemfile_from_example!)

      result = File.read("Gemfile")

      # It should not duplicate the existing source/gemspec/eval line
      expect(result.scan(/^source /).size).to eq(1)
      expect(result.scan(/^gemspec/).size).to eq(1)
      expect(result.scan(/^eval_gemfile \"gemfiles\/modular\/style.gemfile\"/).size).to eq(1)

      # It should add the git_source lines (gitlab) from example
      expect(result).to match(/^git_source\(:codeberg\) \{ \|repo_name\| \"https:\/\/codeberg\.org\/\#\{repo_name\}\" \}/)
      expect(result).to match(/^git_source\(:gitlab\) \{ \|repo_name\| \"https:\/\/gitlab\.com\/\#\{repo_name\}\" \}/)

      # It should add the missing eval_gemfile entries listed in the example
      expect(result).to include('eval_gemfile "gemfiles/modular/debug.gemfile"')
      expect(result).to include('eval_gemfile "gemfiles/modular/coverage.gemfile"')
      expect(result).to include('eval_gemfile "gemfiles/modular/documentation.gemfile"')
      expect(result).to include('eval_gemfile "gemfiles/modular/optional.gemfile"')
      expect(result).to include('eval_gemfile "gemfiles/modular/x_std_libs.gemfile"')

      # Idempotent on second run
      cli.send(:ensure_gemfile_from_example!)
      result2 = File.read("Gemfile")
      expect(result2).to eq(result)
    end

    it "limits bootstrap eval_gemfile additions to the requested paths" do
      File.write("a.gemspec", "Gem::Specification.new do |s| end\n")
      File.write("Gemfile", "")

      cli = described_class.allocate
      cli.instance_variable_set(:@argv, [])
      cli.instance_variable_set(:@passthrough, [])
      cli.send(:parse!)

      example_path = File.expand_path("../../../template/Gemfile.example", __dir__)
      allow(cli).to receive(:installed_path).and_wrap_original do |orig, rel|
        if rel == "Gemfile.example"
          example_path
        else
          orig.call(rel)
        end
      end

      cli.send(:ensure_gemfile_from_example!, eval_paths: ["gemfiles/modular/templating.gemfile"])

      result = File.read("Gemfile")

      expect(result).to include('source "https://gem.coop"')
      expect(result).to include("gemspec")
      expect(result).to include("git_source(:codeberg)")
      expect(result).to include("git_source(:gitlab)")
      expect(result).to include('eval_gemfile "gemfiles/modular/templating.gemfile"')
      expect(result).not_to include('eval_gemfile "gemfiles/modular/debug.gemfile"')
      expect(result).not_to include('eval_gemfile "gemfiles/modular/coverage.gemfile"')
      expect(result).not_to include('eval_gemfile "gemfiles/modular/style.gemfile"')
    end
  end

  describe "#prechecks! (funding and env derivation)" do
    around do |ex|
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) { ex.run }
      end
    end

    before do
      # Ensure no leftover env interferes with derivation logic
      # Never modify ENV directly in specs; use stub_env from rspec-stubbed_env
      stub_env("OPENCOLLECTIVE_HANDLE" => nil)
    end

    it "seeds FUNDING_ORG from git origin when not provided elsewhere", :check_output do
      %x(git init -q)
      %x(git add -A && git commit --allow-empty -m initial -q)
      File.write("Gemfile", "")
      File.write("a.gemspec", "Gem::Specification.new do |s| end\n")
      # Ensure no env or oc file
      # stubbed_env context starts with nils, just ensure file not present
      FileUtils.rm_f(".opencollective.yml")

      fake_ga = instance_double(Kettle::Dev::GitAdapter)
      allow(Kettle::Dev::GitAdapter).to receive(:new).and_return(fake_ga)
      allow(fake_ga).to receive(:clean?).and_return(true)
      allow(fake_ga).to receive(:remote_url).with("origin").and_return("git@github.com:acme/thing.git")

      cli = described_class.allocate
      # Ensure derivation path is taken; use stub_env to clear FUNDING_ORG without asserting on ENV later
      stub_env("FUNDING_ORG" => nil, "KETTLE_DEV_DEBUG" => "true")
      expect { cli.send(:prechecks!) }
        .to output(/Derived FUNDING_ORG from git origin: acme/).to_stderr
    end

    it "aborts if not in git repo" do
      cli = described_class.allocate
      expect { cli.send(:prechecks!) }.to raise_error(MockSystemExit, /Not inside a git repository/)
    end

    it "aborts on dirty tree via git status fallback" do
      %x(git init -q)
      File.write("Gemfile", "")
      File.write("a.gemspec", "Gem::Specification.new do |s| end\n")
      out = " M file\n"
      allow(Kettle::Dev::GitAdapter).to receive(:new).and_raise(StandardError)
      allow(Open3).to receive(:capture3).with("git status --porcelain").and_return([out, "", instance_double(Process::Status)])
      cli = described_class.allocate
      expect { cli.send(:prechecks!) }.to raise_error(MockSystemExit, /Git working tree is not clean/)
    end

    it "sets @gemspec_path and passes when clean and files present" do
      %x(git init -q)
      %x(git add -A && git commit --allow-empty -m initial -q)
      File.write("Gemfile", "")
      File.write("a.gemspec", "Gem::Specification.new do |s| end\n")
      allow(Kettle::Dev::GitAdapter).to receive(:new).and_return(double(clean?: true))
      cli = described_class.allocate
      cli.send(:prechecks!)
      expect(cli.instance_variable_get(:@gemspec_path)).to end_with("a.gemspec")
    end

    it "aborts if no gemspec or Gemfile" do
      %x(git init -q)
      %x(git add -A && git commit --allow-empty -m initial -q)
      allow(Kettle::Dev::GitAdapter).to receive(:new).and_return(double(clean?: true))
      cli = described_class.allocate
      expect { cli.send(:prechecks!) }.to raise_error(MockSystemExit, /No gemspec/)
      File.write("a.gemspec", "Gem::Specification.new do |s| end\n")
      expect { cli.send(:prechecks!) }.to raise_error(MockSystemExit, /No Gemfile/)
    end
  end

  describe "bundled re-entry project state" do
    around do |ex|
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) { ex.run }
      end
    end

    it "initializes @gemspec_path via ensure_project_files! in bundled mode" do
      File.write("Gemfile", "source 'https://gem.coop'\n")
      File.write("demo.gemspec", <<~RUBY)
        Gem::Specification.new do |spec|
          spec.name = "demo"
          spec.version = "0.0.1"
        end
      RUBY

      cli = described_class.new([])
      allow(cli).to receive(:debug_bundler_env)
      allow(cli).to receive(:debug_git_status)
      allow(cli).to receive(:say)
      allow(cli).to receive_messages(
        bundled_execution_context?: true,
        load_bundled_runtime!: nil,
        ensure_rakefile!: nil,
        run_kettle_install!: nil,
        commit_bootstrap_changes!: nil,
      )

      expect(cli).to receive(:ensure_project_files!).and_call_original

      expect { cli.run! }.not_to raise_error
      expect(cli.instance_variable_get(:@gemspec_path)).to eq("demo.gemspec")
    end

    it "bundled phase runs without ensure_dev_deps! (handled by pre-flight)" do
      File.write("Gemfile", "source 'https://gem.coop'\n")
      File.write("demo.gemspec", <<~RUBY)
        Gem::Specification.new do |spec|
          spec.name = "demo"
          spec.version = "0.0.1"
        end
      RUBY

      cli = described_class.new([])
      allow(cli).to receive(:debug_bundler_env)
      allow(cli).to receive(:debug_git_status)
      allow(cli).to receive(:say)
      allow(cli).to receive_messages(
        load_bundled_runtime!: nil,
        ensure_rakefile!: nil,
        run_kettle_install!: nil,
        commit_bootstrap_changes!: nil,
      )

      expect(cli).not_to receive(:ensure_dev_deps!)
      expect { cli.send(:run_bundled_phase!) }.not_to raise_error
    end
  end

  describe "#preflight_merge_modular_gemfiles!" do
    around do |ex|
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) { ex.run }
      end
    end

    def stub_preflight_modular_source_dir(cli, source_dir:)
      allow(cli).to receive(:installed_path).and_wrap_original do |orig, rel|
        (rel == File.join("gemfiles", "modular")) ? source_dir : orig.call(rel)
      end
    end

    it "copies bootstrap modular gemfiles when missing", :check_output do
      source_dir = File.join(Dir.pwd, "template", "gemfiles", "modular")
      FileUtils.mkdir_p(source_dir)
      File.write(File.join(source_dir, "templating.gemfile.example"), "gem 'templating-new'\n")
      File.write(File.join(source_dir, "templating_local.gemfile.example"), "gem 'templating-local-new'\n")

      cli = described_class.allocate
      cli.instance_variable_set(:@verbose, true)
      stub_preflight_modular_source_dir(cli, source_dir: source_dir)

      expect { cli.send(:preflight_merge_modular_gemfiles!, Kettle::Jem::TemplateHelpers, nil) }
        .to output(/Pre-flight: wrote gemfiles\/modular\/templating\.gemfile\..*Pre-flight: wrote gemfiles\/modular\/templating_local\.gemfile\./m).to_stdout
      expect(File.read(File.join("gemfiles", "modular", "templating.gemfile"))).to eq("gem 'templating-new'\n")
      expect(File.read(File.join("gemfiles", "modular", "templating_local.gemfile"))).to eq("gem 'templating-local-new'\n")
    end

    it "rewrites modular gemfiles from template when force is the default", :check_output do
      FileUtils.mkdir_p(File.join("gemfiles", "modular"))
      File.write(File.join("gemfiles", "modular", "templating.gemfile"), "gem 'templating-old'\n")
      File.write(File.join("gemfiles", "modular", "templating_local.gemfile"), "gem 'templating-local-old'\n")

      source_dir = File.join(Dir.pwd, "template", "gemfiles", "modular")
      FileUtils.mkdir_p(source_dir)
      File.write(File.join(source_dir, "templating.gemfile.example"), "gem 'templating-new'\n")
      File.write(File.join(source_dir, "templating_local.gemfile.example"), "gem 'templating-local-new'\n")

      cli = described_class.new(["--verbose"])
      stub_preflight_modular_source_dir(cli, source_dir: source_dir)

      expect { cli.send(:preflight_merge_modular_gemfiles!, Kettle::Jem::TemplateHelpers, nil) }
        .to output(/Pre-flight: wrote gemfiles\/modular\/templating\.gemfile\..*Pre-flight: wrote gemfiles\/modular\/templating_local\.gemfile\./m).to_stdout
      expect(File.read(File.join("gemfiles", "modular", "templating.gemfile"))).to eq("gem 'templating-new'\n")
      expect(File.read(File.join("gemfiles", "modular", "templating_local.gemfile"))).to eq("gem 'templating-local-new'\n")
    end

    it "refreshes templating_local.gemfile from template on force while stripping only the destination gem", :check_output do
      File.write("ast-merge.gemspec", <<~RUBY)
        Gem::Specification.new do |spec|
          spec.name = "ast-merge"
        end
      RUBY

      FileUtils.mkdir_p(File.join("gemfiles", "modular"))
      File.write(File.join("gemfiles", "modular", "templating_local.gemfile"), <<~RUBY)
        require File.expand_path("../../../nomono/lib/nomono/bundler", __dir__)

        local_gems = %w[
          tree_haver
          bash-merge
          legacy-merge
        ]

        # export VENDORED_GEMS=tree_haver,bash-merge,legacy-merge
        platform :mri do
          eval_nomono_gems(gems: local_gems)
        end
      RUBY

      source_dir = File.join(Dir.pwd, "template", "gemfiles", "modular")
      FileUtils.mkdir_p(source_dir)
      File.write(File.join(source_dir, "templating.gemfile.example"), "gem 'templating-new'\n")
      File.write(File.join(source_dir, "templating_local.gemfile.example"), <<~RUBY)
        require "nomono/bundler"

        local_gems = %w[
          tree_haver
          ast-merge
          bash-merge
          kettle-jem
          prism-merge
        ]

        # export VENDORED_GEMS=tree_haver,ast-merge,bash-merge,kettle-jem,prism-merge
        platform :mri do
          eval_nomono_gems(gems: local_gems)
        end
      RUBY

      cli = described_class.new(["--verbose"])
      cli.instance_variable_set(:@gemspec_path, File.join(Dir.pwd, "ast-merge.gemspec"))
      stub_preflight_modular_source_dir(cli, source_dir: source_dir)

      expect { cli.send(:preflight_merge_modular_gemfiles!, Kettle::Jem::TemplateHelpers, "ast-merge") }
        .to output(/Pre-flight: wrote gemfiles\/modular\/templating_local\.gemfile\./).to_stdout

      result = File.read(File.join("gemfiles", "modular", "templating_local.gemfile"))
      expect(result).to include('require "nomono/bundler"')
      expect(result).to include("tree_haver")
      expect(result).to include("bash-merge")
      expect(result).to include("kettle-jem")
      expect(result).to include("prism-merge")
      expect(result).not_to include("legacy-merge")
      expect(result).not_to include("ast-merge")
    end

    it "strips the host gem's name from templating_local.gemfile on fresh copy", :check_output do
      File.write("rbs-merge.gemspec", <<~RUBY)
        Gem::Specification.new do |spec|
          spec.name = "rbs-merge"
        end
      RUBY

      source_dir = File.join(Dir.pwd, "template", "gemfiles", "modular")
      FileUtils.mkdir_p(source_dir)
      File.write(File.join(source_dir, "templating.gemfile.example"), "gem 'templating-new'\n")
      File.write(File.join(source_dir, "templating_local.gemfile.example"), <<~RUBY)
        require "nomono/bundler"

        local_gems = %w[
          tree_haver
          ast-merge
          rbs-merge
          kettle-jem
        ]

        # export VENDORED_GEMS=tree_haver,ast-merge,rbs-merge,kettle-jem
        platform :mri do
          eval_nomono_gems(gems: local_gems)
        end
      RUBY

      cli = described_class.allocate
      cli.instance_variable_set(:@verbose, true)
      cli.instance_variable_set(:@gemspec_path, File.join(Dir.pwd, "rbs-merge.gemspec"))
      stub_preflight_modular_source_dir(cli, source_dir: source_dir)

      expect { cli.send(:preflight_merge_modular_gemfiles!, Kettle::Jem::TemplateHelpers, "rbs-merge") }
        .to output(/Pre-flight: wrote gemfiles\/modular\/templating_local\.gemfile/).to_stdout

      result = File.read(File.join("gemfiles", "modular", "templating_local.gemfile"))
      expect(result).to include("tree_haver")
      expect(result).to include("ast-merge")
      expect(result).to include("kettle-jem")
      expect(result).not_to match(/^\s+rbs-merge\s*$/)
      expect(result).not_to include("rbs-merge")
    end

    it "strips the host gem's name from an existing templating_local.gemfile during merge", :check_output do
      File.write("rbs-merge.gemspec", <<~RUBY)
        Gem::Specification.new do |spec|
          spec.name = "rbs-merge"
        end
      RUBY

      FileUtils.mkdir_p(File.join("gemfiles", "modular"))
      File.write(File.join("gemfiles", "modular", "templating_local.gemfile"), <<~RUBY)
        require "nomono/bundler"

        local_gems = %w[
          tree_haver
          ast-merge
          rbs-merge
          kettle-jem
        ]

        # export VENDORED_GEMS=tree_haver,ast-merge,rbs-merge,kettle-jem
        platform :mri do
          eval_nomono_gems(gems: local_gems)
        end
      RUBY

      source_dir = File.join(Dir.pwd, "template", "gemfiles", "modular")
      FileUtils.mkdir_p(source_dir)
      File.write(File.join(source_dir, "templating.gemfile.example"), "gem 'templating-new'\n")
      File.write(File.join(source_dir, "templating_local.gemfile.example"), "gem 'templating-local-new'\n")

      cli = described_class.allocate
      cli.instance_variable_set(:@verbose, true)
      cli.instance_variable_set(:@force, false)
      cli.instance_variable_set(:@gemspec_path, File.join(Dir.pwd, "rbs-merge.gemspec"))
      stub_preflight_modular_source_dir(cli, source_dir: source_dir)
      allow(Kettle::Jem::SourceMerger).to receive(:apply).and_return(File.read(File.join("gemfiles", "modular", "templating_local.gemfile")))

      expect { cli.send(:preflight_merge_modular_gemfiles!, Kettle::Jem::TemplateHelpers, "rbs-merge") }
        .to output(/Pre-flight: wrote gemfiles\/modular\/templating\.gemfile\..*Pre-flight: merged gemfiles\/modular\/templating_local\.gemfile/m).to_stdout

      result = File.read(File.join("gemfiles", "modular", "templating_local.gemfile"))
      expect(result).to include("tree_haver")
      expect(result).to include("ast-merge")
      expect(result).to include("kettle-jem")
      expect(result).not_to match(/^\s+rbs-merge\s*$/)
      expect(result).not_to include("rbs-merge")
    end
  end

  describe "#ensure_bootstrap_eval_gemfile!" do
    around do |ex|
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) { ex.run }
      end
    end

    let(:cli) do
      c = described_class.allocate
      c.instance_variable_set(:@verbose, true)
      c
    end
    let(:eval_line) { 'eval_gemfile "gemfiles/modular/templating.gemfile"' }

    it "adds the eval_gemfile line to an existing Gemfile that lacks it", :check_output do
      File.write("Gemfile", "# frozen_string_literal: true\nsource \"https://rubygems.org\"\n")
      expect { cli.send(:ensure_bootstrap_eval_gemfile!) }
        .to output(/Added templating\.gemfile eval/).to_stdout
      content = File.read("Gemfile")
      expect(content).to include(eval_line)
    end

    it "creates Gemfile with the eval_gemfile line when Gemfile is absent", :check_output do
      expect { cli.send(:ensure_bootstrap_eval_gemfile!) }
        .to output(/Added templating\.gemfile eval/).to_stdout
      expect(File.read("Gemfile")).to include(eval_line)
    end

    it "does not duplicate the eval_gemfile line when already present", :check_output do
      File.write("Gemfile", "source \"https://rubygems.org\"\n#{eval_line}\n")
      expect { cli.send(:ensure_bootstrap_eval_gemfile!) }
        .to output(/already includes/).to_stdout
      expect(File.read("Gemfile").scan(eval_line).size).to eq(1)
    end

    it "does not use PrismGemfile during the operation" do
      File.write("Gemfile", "source \"https://rubygems.org\"\n")
      allow(cli).to receive(:say)
      expect(Kettle::Jem::PrismGemfile).not_to receive(:merge_gem_calls)
      cli.send(:ensure_bootstrap_eval_gemfile!)
    end
  end

  describe "#strip_self_from_templating_local" do
    let(:cli) { described_class.allocate }

    let(:content_with_rbs_merge) do
      <<~RUBY
        require "nomono/bundler"

        local_gems = %w[
          tree_haver
          ast-merge
          rbs-merge
          kettle-jem
        ]

        # export VENDORED_GEMS=tree_haver,ast-merge,rbs-merge,kettle-jem
        platform :mri do
          eval_nomono_gems(gems: local_gems)
        end
      RUBY
    end

    it "removes the host gem from the %w[] array and VENDORED_GEMS comment" do
      allow(cli).to receive(:gemspec_string_value).with("name").and_return("rbs-merge")
      result = cli.send(:strip_self_from_templating_local, content_with_rbs_merge)
      expect(result).not_to match(/^\s+rbs-merge\s*$/)
      expect(result).not_to include("rbs-merge")
      expect(result).to include("tree_haver")
      expect(result).to include("ast-merge")
      expect(result).to include("kettle-jem")
      expect(result).to include("# export VENDORED_GEMS=tree_haver,ast-merge,kettle-jem")
    end

    it "returns content unchanged when gem name is nil" do
      allow(cli).to receive(:gemspec_string_value).with("name").and_return(nil)
      result = cli.send(:strip_self_from_templating_local, content_with_rbs_merge)
      expect(result).to eq(content_with_rbs_merge)
    end

    it "handles a gem name not present in the content gracefully" do
      allow(cli).to receive(:gemspec_string_value).with("name").and_return("no-such-gem")
      result = cli.send(:strip_self_from_templating_local, content_with_rbs_merge)
      expect(result).to eq(content_with_rbs_merge)
    end
  end

  describe "#ensure_bin_setup! and #ensure_rakefile!" do
    around do |ex|
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) { ex.run }
      end
    end

    before do
      Kettle::Jem::TemplateHelpers.clear_tokens!
      Kettle::Jem::TemplateHelpers.class_variable_set(:@@kettle_config, nil) if Kettle::Jem::TemplateHelpers.class_variable_defined?(:@@kettle_config)
      Kettle::Jem::TemplateHelpers.class_variable_set(:@@manifestation, nil) if Kettle::Jem::TemplateHelpers.class_variable_defined?(:@@manifestation)
    end

    after { Kettle::Jem::TemplateHelpers.clear_tokens! }

    # Write a minimal gemspec so configure_tokens! can derive gem_name/org/namespace.
    def write_minimal_gemspec!
      File.write("test-gem.gemspec", <<~GEMSPEC)
        Gem::Specification.new do |spec|
          spec.name = "test-gem"
          spec.version = "0.1.0"
          spec.authors = ["Test"]
          spec.summary = "test"
          spec.homepage = "https://github.com/test-org/test-gem"
        end
      GEMSPEC
    end

    it "copies bin/setup when missing", :check_output do
      cli = described_class.allocate
      cli.instance_variable_set(:@verbose, true)
      # create a temp source file to simulate installed gem asset
      src = File.expand_path("src_bin_setup", Dir.pwd)
      File.write(src, "#!/usr/bin/env ruby\n")
      FileUtils.chmod("+x", src)
      allow(cli).to receive(:installed_path).and_return(src)
      expect { cli.send(:ensure_bin_setup!) }.to output(/Copied bin\/setup/).to_stdout
      expect(File.exist?("bin/setup")).to be true
      expect(File.stat("bin/setup").mode & 0o111).to be > 0
    end

    it "says present when bin/setup exists", :check_output do
      FileUtils.mkdir_p("bin")
      File.write("bin/setup", "#!/usr/bin/env ruby\nputs :existing\n")
      cli = described_class.allocate
      cli.instance_variable_set(:@verbose, true)
      cli.instance_variable_set(:@force, false)
      expect { cli.send(:ensure_bin_setup!) }.to output(/bin\/setup present\./).to_stdout
      expect(File.read("bin/setup")).to include("puts :existing")
    end

    it "overwrites an existing bin/setup when force is the default", :check_output do
      FileUtils.mkdir_p("bin")
      File.write("bin/setup", "#!/usr/bin/env ruby\nputs :old\n")
      src = File.expand_path("src_bin_setup", Dir.pwd)
      File.write(src, "#!/usr/bin/env ruby\nputs :new\n")
      FileUtils.chmod("+x", src)
      cli = described_class.new(["--verbose"])
      allow(cli).to receive(:installed_path).and_return(src)

      expect { cli.send(:ensure_bin_setup!) }.to output(/Overwrote bin\/setup/).to_stdout
      expect(File.read("bin/setup")).not_to include("puts :old")
      expect(File.stat("bin/setup").mode & 0o111).to be > 0
    end

    it "writes Rakefile from example and announces merge or creation", :check_output do
      write_minimal_gemspec!
      # Point project_root at the tmpdir so configure_template_tokens!
      # finds the minimal gemspec above instead of the real kettle-jem.gemspec
      # (which can fail to load depending on Gem loader state / spec ordering).
      Kettle::Jem::TemplateHelpers.class_variable_set(:@@project_root_override, Dir.pwd)
      cli = described_class.allocate
      cli.instance_variable_set(:@verbose, true)
      # create a temp source Rakefile.example to simulate installed gem asset
      src = File.expand_path("src_Rakefile.example", Dir.pwd)
      File.write(src, "# frozen_string_literal: true\nrequire \"bundler/gem_tasks\"\n")
      allow(cli).to receive(:installed_path).and_return(src)
      expect { cli.send(:ensure_rakefile!) }.to output(/Creating Rakefile/).to_stdout
      File.write("Rakefile", "# frozen_string_literal: true\ntask :custom do\n  puts \"custom\"\nend\n")
      expect { cli.send(:ensure_rakefile!) }.to output(/Merged Rakefile/).to_stdout
      merged = File.read("Rakefile")
      expect(merged).to include("custom")
      expect(merged).to include("bundler/gem_tasks")
    end

    it "raises Kettle::Dev::Error when Rakefile merge fails in error mode (default)" do
      write_minimal_gemspec!
      cli = described_class.allocate
      src = File.expand_path("src_Rakefile.example", Dir.pwd)
      File.write(src, "# frozen_string_literal: true\nrequire \"bundler/gem_tasks\"\n")
      allow(cli).to receive(:installed_path).and_return(src)
      # WHY THIS STUB IS HERE:
      # ensure_rakefile! calls configure_template_tokens! internally, which
      # resolves project_root via Rake.application.original_dir. In an RSpec
      # process Rake is loaded, so original_dir returns the kettle-jem repo
      # root (not the test's tmpdir). This means gemspec_metadata loads the
      # real kettle-jem.gemspec. When Gem::Specification.load evaluates that
      # gemspec after a prior test has already loaded it in the same process,
      # Gem loader state can cause the load to silently fail, returning nil
      # gem_name → "Gem name could not be derived" error.
      #
      # This test exercises merge-failure handling (error vs rescue mode),
      # NOT token derivation. Stubbing configure_template_tokens! isolates
      # the concern under test and eliminates the order-dependent failure.
      allow(cli).to receive(:configure_template_tokens!)
      File.write("Rakefile", "existing content\n")
      stub_env("FAILURE_MODE" => "error")
      allow(Kettle::Jem::SourceMerger).to receive(:apply).and_raise(RuntimeError, "merge boom")

      expect {
        cli.send(:ensure_rakefile!)
      }.to raise_error(Kettle::Dev::Error, /Merge failed for Rakefile.*merge boom/)
    end

    it "falls back to template content when Rakefile merge fails in rescue mode", :check_output do
      write_minimal_gemspec!
      cli = described_class.allocate
      src = File.expand_path("src_Rakefile.example", Dir.pwd)
      File.write(src, "# template content\n")
      allow(cli).to receive(:installed_path).and_return(src)
      # See the "error mode" test above for full explanation of this stub.
      allow(cli).to receive(:configure_template_tokens!)
      File.write("Rakefile", "existing content\n")
      stub_env("FAILURE_MODE" => "rescue")
      allow(Kettle::Jem::SourceMerger).to receive(:apply).and_raise(RuntimeError, "merge boom")

      expect {
        cli.send(:ensure_rakefile!)
      }.to output(/merge failed, using template/).to_stdout
      expect(File.read("Rakefile")).to eq("# template content\n")
    end
  end

  describe "#commit_bootstrap_changes! and downstream cmds" do
    around do |ex|
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) { ex.run }
      end
    end

    it "no-ops when clean", :check_output do
      %x(git init -q)
      %x(git add -A && git commit --allow-empty -m initial -q)
      allow(Kettle::Dev::GitAdapter).to receive(:new).and_return(double(clean?: true))
      cli = described_class.allocate
      cli.instance_variable_set(:@verbose, true)
      expect { cli.send(:commit_bootstrap_changes!) }.to output(/No changes to commit/).to_stdout
    end

    it "adds and commits when dirty and prints messages", :check_output do
      %x(git init -q)
      File.write("file", "x")
      allow(Kettle::Dev::GitAdapter).to receive(:new).and_return(double(clean?: false))
      cli = described_class.allocate
      cli.instance_variable_set(:@verbose, true)
      allow(cli).to receive(:sh!).and_call_original
      # Stub sh! internals to not actually execute
      allow(Open3).to receive(:capture3).and_return(["", "", instance_double(Process::Status, success?: true)])
      expect { cli.send(:commit_bootstrap_changes!) }.to output(/Committed template bootstrap changes/).to_stdout
    end

    it "run_bin_setup! and run_bundle_binstubs! invoke sh! with proper command" do
      cli = described_class.allocate
      cli.instance_variable_set(:@verbose, true)
      expect(cli).to receive(:sh!).with(/bin\/setup/, suppress_command_log: false)
      cli.send(:run_bin_setup!)
      expect(cli).to receive(:sh!).with("bundle binstubs --all", suppress_output: false, suppress_command_log: false)
      cli.send(:run_bundle_binstubs!)
    end

    it "run_bin_setup! passes --quiet through to bin/setup when requested" do
      cli = described_class.allocate
      cli.instance_variable_set(:@quiet, true)

      expect(cli).to receive(:sh!).with("bin/setup --quiet", suppress_command_log: true)
      cli.send(:run_bin_setup!)
    end

    it "run_bundle_binstubs! suppresses direct bundler output when quiet is requested" do
      cli = described_class.allocate
      cli.instance_variable_set(:@quiet, true)

      expect(cli).to receive(:sh!).with("bundle binstubs --all", suppress_output: true, suppress_command_log: true)
      cli.send(:run_bundle_binstubs!)
    end

    it "handoff_to_bundled_phase! re-enters through bundle exec kettle-jem with the original argv" do
      cli = described_class.allocate
      cli.instance_variable_set(:@verbose, true)
      cli.instance_variable_set(:@original_argv, ["--allowed=true", "--force"])

      expect(cli).to receive(:sh!).with(a_string_including("bundle exec kettle-jem --allowed\\=true --force"), suppress_command_log: false)
      cli.send(:handoff_to_bundled_phase!)
    end

    it "handoff_to_bundled_phase! preserves --quiet in the bundled re-entry" do
      cli = described_class.allocate
      cli.instance_variable_set(:@quiet, true)
      cli.instance_variable_set(:@original_argv, ["--allowed=true", "--quiet"])

      expect(cli).to receive(:sh!).with(a_string_including("bundle exec kettle-jem --allowed\\=true --quiet"), suppress_command_log: true)
      cli.send(:handoff_to_bundled_phase!)
    end

    it "run_kettle_install! builds rake cmd with passthrough" do
      cli = described_class.allocate
      cli.instance_variable_set(:@verbose, true)
      cli.instance_variable_set(:@passthrough, ["only=hooks"])
      expect(cli).to receive(:sh!).with(a_string_including("bundle exec rake kettle:jem:install only\\=hooks"), suppress_command_log: false)
      cli.send(:run_kettle_install!)
    end

    it "run_kettle_install! preserves --quiet for the final rake invocation" do
      cli = described_class.allocate
      cli.instance_variable_set(:@quiet, true)
      cli.instance_variable_set(:@passthrough, ["--quiet", "only=hooks"])

      expect(cli).to receive(:sh!).with(a_string_including("bundle exec rake kettle:jem:install --quiet only\\=hooks"), suppress_command_log: true)
      cli.send(:run_kettle_install!)
    end
  end

  describe "template source resolution" do
    let(:cli) { described_class.allocate }

    describe "#installed_path" do
      it "prefers template .example files over same-path files at the gem root" do
        path = cli.send(:installed_path, ".devcontainer/apt-install/install.sh")

        expect(path).to end_with("template/.devcontainer/apt-install/install.sh.example")
      end

      it "does not fall back to non-template files from the gem root" do
        expect(cli.send(:installed_path, "Gemfile.lock")).to be_nil
      end
    end

    describe "#ensure_bin_setup!" do
      around do |ex|
        Dir.mktmpdir do |dir|
          Dir.chdir(dir) { ex.run }
        end
      end

      it "copies bin/setup from template/bin/setup.example" do
        allow(cli).to receive(:say)

        cli.send(:ensure_bin_setup!)

        expect(File.read("bin/setup")).to eq(
          File.read(File.expand_path("../../../template/bin/setup.example", __dir__)),
        )
      end

      it "overwrites an existing stale bin/setup when force is enabled" do
        allow(cli).to receive(:say)
        cli.instance_variable_set(:@force, true)
        FileUtils.mkdir_p("bin")
        File.write("bin/setup", <<~BASH)
          #!/usr/bin/env bash
          set -euo pipefail

          bundle install
        BASH

        cli.send(:ensure_bin_setup!)

        expect(File.read("bin/setup")).to eq(
          File.read(File.expand_path("../../../template/bin/setup.example", __dir__)),
        )
      end
    end
  end

  describe "#installed_path" do
    it "resolves within installed gem when loaded spec present" do
      cli = described_class.allocate
      spec = instance_double(Gem::Specification, full_gem_path: File.expand_path("../../../../", __dir__))
      allow(Gem).to receive(:loaded_specs).and_return({"kettle-jem" => spec})
      path = cli.send(:installed_path, "Rakefile.example")
      expect(path).to end_with("Rakefile.example")
      expect(File.exist?(path)).to be true
    end

    it "falls back to repo checkout path when gem not loaded" do
      cli = described_class.allocate
      allow(Gem).to receive(:loaded_specs).and_return({})
      path = cli.send(:installed_path, "Rakefile.example")
      expect(path).to end_with("Rakefile.example")
      expect(File.exist?(path)).to be true
    end

    it "returns nil when file not present in either location" do
      cli = described_class.allocate
      allow(Gem).to receive(:loaded_specs).and_return({})
      expect(cli.send(:installed_path, "nope.txt")).to be_nil
    end
  end

  describe "#run! end-to-end sequencing" do
    it "runs bootstrap steps in order before the bundled handoff" do
      cli = described_class.allocate
      cli.instance_variable_set(:@argv, [])
      cli.instance_variable_set(:@original_argv, [])
      allow(cli).to receive(:parse!)
      allow(cli).to receive(:bundled_execution_context?).and_return(false)
      %i[prechecks! template_config_present? run_preflight_templating! ensure_bin_setup! run_bin_setup! run_bundle_binstubs! handoff_to_bundled_phase!].each do |m|
        allow(cli).to receive(:template_config_present?).and_return(true) if m == :template_config_present?
        expect(cli).to receive(m).ordered
      end
      expect { cli.run! }.not_to raise_error
    end

    it "runs the bundled phase steps in order once bundler is active" do
      cli = described_class.allocate
      cli.instance_variable_set(:@argv, [])
      cli.instance_variable_set(:@original_argv, [])
      allow(cli).to receive(:parse!)

      call_order = []
      allow(cli).to receive(:bundled_execution_context?).and_return(true)
      %i[ensure_project_files! load_bundled_runtime! ensure_rakefile! run_kettle_install! commit_bootstrap_changes!].each do |m|
        allow(cli).to receive(m) { call_order << m }
      end

      cli.run!

      project_idx = call_order.index(:ensure_project_files!)
      load_idx = call_order.index(:load_bundled_runtime!)
      install_idx = call_order.index(:run_kettle_install!)
      commit_idx = call_order.index(:commit_bootstrap_changes!)
      expect(project_idx).to eq(0)
      expect(load_idx).to eq(1)
      expect(install_idx).to be < commit_idx,
        "Expected run_kettle_install! (idx=#{install_idx}) to run before commit_bootstrap_changes! (idx=#{commit_idx})"
    end
  end

  describe "#ensure_rakefile!" do
    around do |ex|
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) { ex.run }
      end
    end

    before do
      Kettle::Jem::TemplateHelpers.clear_tokens!
      Kettle::Jem::TemplateHelpers.clear_kettle_config!
    end

    after do
      Kettle::Jem::TemplateHelpers.clear_tokens!
      Kettle::Jem::TemplateHelpers.clear_kettle_config!
    end

    it "writes a token-resolved Rakefile header using kettle-jem version and template run date" do
      cli = described_class.allocate
      src = File.expand_path("src_Rakefile.example", Dir.pwd)
      File.write(src, <<~RUBY)
        # {KJ|GEM_NAME} Rakefile v{KJ|KETTLE_JEM_VERSION} - {KJ|TEMPLATE_RUN_DATE}
        # Copyright (c) {KJ|TEMPLATE_RUN_YEAR} {KJ|AUTHOR:NAME} ({KJ|AUTHOR:DOMAIN})
        require "bundler/gem_tasks"
      RUBY
      allow(cli).to receive(:installed_path).and_return(src)
      allow(Kettle::Jem::TemplateHelpers).to receive_messages(
        project_root: Dir.pwd,
        gemspec_metadata: {
          gem_name: "demo-gem",
          min_ruby: Gem::Version.create("3.2"),
          forge_org: "acme",
          namespace: "DemoGem",
          namespace_shield: "Demo__Gem",
          gem_shield: "demo__gem",
          authors: ["Test User"],
          email: ["test@example.com"],
        },
        template_run_timestamp: Time.new(2026, 3, 14, 12, 0, 0, "+00:00"),
        kettle_jem_version: "9.9.9",
        # Prevent the template's own .kettle-jem.yml.example (which contains real author
        # data) from being loaded as the config fallback when the temp dir has no config.
        kettle_config: {},
      )

      cli.send(:ensure_rakefile!)

      content = File.read("Rakefile")
      expect(content).to include("# demo-gem Rakefile v9.9.9 - 2026-03-14")
      expect(content).to include("# Copyright (c) 2026 Test User (example.com)")
    end
  end
end
# rubocop:enable ThreadSafety/DirChdir
