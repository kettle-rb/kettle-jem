# frozen_string_literal: true

# rubocop:disable ThreadSafety/DirChdir

RSpec.describe Kettle::Jem::SetupCLI do
  def write(file, content)
    File.write(file, content)
  end

  def read(file)
    File.read(file)
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
      expect(cli).to receive(:sh!).with(a_string_including("bin/rake kettle:jem:install include\\=foo/bar/\\*\\*"))
      cli.send(:run_kettle_install!)
    end
  end

  describe "setup preflight" do
    it "returns early when bootstrap writes the template config file" do
      cli = described_class.allocate
      cli.instance_variable_set(:@argv, [])
      cli.instance_variable_set(:@original_argv, [])
      cli.instance_variable_set(:@passthrough, [])
      cli.send(:parse!)

      allow(cli).to receive(:debug_bundler_env)
      allow(cli).to receive(:debug_git_status)
      allow(cli).to receive(:say)
      allow(cli).to receive(:bundled_execution_context?).and_return(false)
      allow(cli).to receive(:prechecks!).and_return(nil)
      allow(cli).to receive(:template_config_present?).and_return(false)
      allow(cli).to receive(:ensure_template_config_bootstrap!).and_return(:bootstrap_only)
      expect(cli).not_to receive(:ensure_gemfile_from_example!)
      expect(cli).not_to receive(:ensure_bootstrap_modular_gemfiles!)
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
      allow(cli).to receive(:bundled_execution_context?).and_return(false)
      allow(cli).to receive(:prechecks!).and_return(nil)
      allow(cli).to receive(:template_config_present?).and_return(true)

      expect(cli).not_to receive(:ensure_template_config_bootstrap!)
      expect(cli).not_to receive(:ensure_dev_deps!)
      expect(cli).not_to receive(:ensure_modular_gemfiles!)
      expect(cli).not_to receive(:ensure_rakefile!)
      expect(cli).not_to receive(:run_kettle_install!)
      expect(cli).not_to receive(:commit_bootstrap_changes!)
      expect(cli).to receive(:ensure_gemfile_from_example!).with(eval_paths: ["gemfiles/modular/templating.gemfile"]).ordered.and_return(nil)
      expect(cli).to receive(:ensure_bootstrap_modular_gemfiles!).ordered.and_return(nil)
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
      expect(cli).to receive(:ensure_project_files!).ordered.and_return(nil)
      expect(cli).to receive(:load_bundled_runtime!).ordered.and_return(nil)
      expect(cli).to receive(:ensure_dev_deps!).ordered.and_return(nil)
      expect(cli).to receive(:ensure_gemfile_from_example!).with(no_args).ordered.and_return(nil)
      expect(cli).to receive(:ensure_modular_gemfiles!).ordered.and_return(nil)
      expect(cli).to receive(:ensure_rakefile!).ordered.and_return(nil)
      expect(cli).to receive(:run_bin_setup!).ordered.and_return(nil)
      expect(cli).to receive(:run_bundle_binstubs!).ordered.and_return(nil)
      expect(cli).to receive(:run_kettle_install!).ordered.and_return(nil)
      expect(cli).to receive(:commit_bootstrap_changes!).ordered.and_return(nil)

      expect { cli.run! }.not_to raise_error
    end
  end

  describe "#ensure_modular_gemfiles!" do
    it "calls ModularGemfiles.sync! and rescues metadata errors (min_ruby=nil)" do
      cli = described_class.allocate
      helpers = class_double(Kettle::Jem::TemplateHelpers)
      allow(helpers).to receive_messages(
        project_root: "/tmp/project",
        template_root: "/tmp/checkout/template",
        opencollective_disabled?: false,
      )
      allow(helpers).to receive(:gemspec_metadata).and_raise(StandardError)
      allow(helpers).to receive(:configure_tokens!).and_raise(StandardError)
      stub_const("Kettle::Jem::TemplateHelpers", helpers)

      called = false
      expect(Kettle::Jem::ModularGemfiles).to receive(:sync!) do |args|
        called = true
        expect(args[:helpers]).to eq(helpers)
        expect(args[:project_root]).to eq("/tmp/project")
        expect(args[:min_ruby]).to be_nil
        expect(args[:gem_name]).to be_nil
        expect(args).not_to have_key(:token_replacer)
      end

      cli.send(:ensure_modular_gemfiles!)
      expect(called).to be true
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

      expect { cli.send(:ensure_dev_deps!) }.to output(/Development dependencies already up to date\./).to_stdout
      expect(File.read("target.gemspec")).to eq(text)
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
      expect { cli.send(:commit_bootstrap_changes!) }.to output(/No changes to commit/).to_stdout
    end

    it "uses Open3 path when GitAdapter constant is removed (else branch)", :check_output do
      %x(git init -q)
      hide_const("Kettle::Dev::GitAdapter")
      allow(Open3).to receive(:capture2).with("git", "status", "--porcelain").and_return(["", instance_double(Process::Status)])
      cli = described_class.allocate
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
      stub_env("DEBUG" => "true")
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
      stub_env("DEBUG" => "true")
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
      stub_env("DEBUG" => "true")
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
      stub_env("DEBUG" => "true")
      allow(Kettle::Dev::GitAdapter).to receive(:new).and_raise(RuntimeError, "kaput")
      cli = build_cli
      expect { cli.send(:derive_funding_org_from_git_if_missing!) }
        .to output(/Could not derive funding org from git: RuntimeError: kaput/).to_stderr
    end
  end

  describe "#initialize and parse!" do
    it "collects passthrough options and remaining args; shows help and exits with 0", :check_output do
      argv = ["--allowed=foo", "--force", "--quiet", "--hook_templates=bar", "--only=baz", "-h"]
      expect do
        expect { described_class.new(argv) }.to raise_error(MockSystemExit, /exit status 0/)
      end.to output(/Usage: kettle-jem.*--quiet/m).to_stdout
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

    it "tracks --quiet for downstream setup commands and rake passthrough" do
      cli = described_class.new(["--quiet"])

      expect(cli.instance_variable_get(:@passthrough)).to include("--quiet")
      expect(cli.send(:quiet?)).to be(true)
    end
  end

  it "--force sets ENV['force']=true for in-process auto-yes prompts" do
    # Normally we never modify ENV directly in specs, but
    #   using --force has the effect of modifying ENV, so we need to stub it completely here.
    stub_const("ENV", {})
    _cli = described_class.new(["--force"]) # parse! runs in initialize
    expect(ENV["force"]).to eq("true")
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
      stub_env("DEBUG" => "true")
      cli = described_class.allocate
      expect { cli.send(:debug, "hi") }.to output(/DEBUG: hi/).to_stderr
    end

    it "does not print when DEBUG=false", :check_output do
      stub_env("DEBUG" => "false")
      cli = described_class.allocate
      expect { cli.send(:debug, "hi") }.not_to output.to_stderr
    end
  end

  describe "#say and #abort!" do
    it "say prints with prefix", :check_output do
      cli = described_class.allocate
      expect { cli.send(:say, "msg") }.to output(/\[kettle-jem\] msg/).to_stdout
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
  end

  describe "#prechecks!" do
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
      stub_env("FUNDING_ORG" => nil, "DEBUG" => "true")
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

    it "initializes @gemspec_path before ensure_dev_deps! runs in bundled mode" do
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
      allow(cli).to receive(:bundled_execution_context?).and_return(true)
      allow(cli).to receive(:load_bundled_runtime!).and_return(nil)
      allow(cli).to receive(:ensure_gemfile_from_example!).and_return(nil)
      allow(cli).to receive(:ensure_modular_gemfiles!).and_return(nil)
      allow(cli).to receive(:ensure_rakefile!).and_return(nil)
      allow(cli).to receive(:run_bin_setup!).and_return(nil)
      allow(cli).to receive(:run_bundle_binstubs!).and_return(nil)
      allow(cli).to receive(:run_kettle_install!).and_return(nil)
      allow(cli).to receive(:commit_bootstrap_changes!).and_return(nil)

      expect(cli).to receive(:ensure_dev_deps!) do
        expect(cli.instance_variable_get(:@gemspec_path)).to eq("demo.gemspec")
      end

      expect { cli.run! }.not_to raise_error
    end

    it "does not raise a nil-path TypeError when bundled ensure_dev_deps! reads the target gemspec" do
      File.write("Gemfile", "source 'https://gem.coop'\n")
      File.write("demo.gemspec", <<~RUBY)
        Gem::Specification.new do |spec|
          spec.name = "demo"
          spec.version = "0.0.1"
        end
      RUBY

      cli = described_class.new([])
      example_path = File.expand_path("../../../template/gem.gemspec.example", __dir__)

      allow(cli).to receive(:installed_path).and_wrap_original do |orig, rel|
        rel == "gem.gemspec.example" ? example_path : orig.call(rel)
      end
      allow(cli).to receive(:debug_bundler_env)
      allow(cli).to receive(:debug_git_status)
      allow(cli).to receive(:say)
      allow(cli).to receive(:load_bundled_runtime!).and_return(nil)
      allow(cli).to receive(:ensure_gemfile_from_example!).and_return(nil)
      allow(cli).to receive(:ensure_modular_gemfiles!).and_return(nil)
      allow(cli).to receive(:ensure_rakefile!).and_return(nil)
      allow(cli).to receive(:run_bin_setup!).and_return(nil)
      allow(cli).to receive(:run_bundle_binstubs!).and_return(nil)
      allow(cli).to receive(:run_kettle_install!).and_return(nil)
      allow(cli).to receive(:commit_bootstrap_changes!).and_return(nil)

      expect(Kettle::Jem::PrismGemspec).to receive(:ensure_development_dependencies) do |target, wanted|
        expect(target).to eq(File.read("demo.gemspec"))
        expect(wanted).not_to be_empty
        target
      end

      expect { cli.send(:run_bundled_phase!) }.not_to raise_error
    end
  end

  describe "#ensure_bin_setup! and #ensure_rakefile!" do
    around do |ex|
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) { ex.run }
      end
    end

    it "copies bin/setup when missing", :check_output do
      cli = described_class.allocate
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
      File.write("bin/setup", "#!/usr/bin/env ruby\n")
      cli = described_class.allocate
      expect { cli.send(:ensure_bin_setup!) }.to output(/bin\/setup present\./).to_stdout
    end

    it "writes Rakefile from example and announces merge or creation", :check_output do
      cli = described_class.allocate
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
      cli = described_class.allocate
      src = File.expand_path("src_Rakefile.example", Dir.pwd)
      File.write(src, "# frozen_string_literal: true\nrequire \"bundler/gem_tasks\"\n")
      allow(cli).to receive(:installed_path).and_return(src)
      File.write("Rakefile", "existing content\n")
      stub_env("FAILURE_MODE" => "error")
      allow(Kettle::Jem::SourceMerger).to receive(:apply).and_raise(RuntimeError, "merge boom")

      expect {
        cli.send(:ensure_rakefile!)
      }.to raise_error(Kettle::Dev::Error, /Merge failed for Rakefile.*merge boom/)
    end

    it "falls back to template content when Rakefile merge fails in rescue mode", :check_output do
      cli = described_class.allocate
      src = File.expand_path("src_Rakefile.example", Dir.pwd)
      File.write(src, "# template content\n")
      allow(cli).to receive(:installed_path).and_return(src)
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
      expect { cli.send(:commit_bootstrap_changes!) }.to output(/No changes to commit/).to_stdout
    end

    it "adds and commits when dirty and prints messages", :check_output do
      %x(git init -q)
      File.write("file", "x")
      allow(Kettle::Dev::GitAdapter).to receive(:new).and_return(double(clean?: false))
      cli = described_class.allocate
      allow(cli).to receive(:sh!).and_call_original
      # Stub sh! internals to not actually execute
      allow(Open3).to receive(:capture3).and_return(["", "", instance_double(Process::Status, success?: true)])
      expect { cli.send(:commit_bootstrap_changes!) }.to output(/Committed template bootstrap changes/).to_stdout
    end

    it "run_bin_setup! and run_bundle_binstubs! invoke sh! with proper command" do
      cli = described_class.allocate
      expect(cli).to receive(:sh!).with(/bin\/setup/)
      cli.send(:run_bin_setup!)
      expect(cli).to receive(:sh!).with("bundle exec bundle binstubs --all")
      cli.send(:run_bundle_binstubs!)
    end

    it "run_bin_setup! passes --quiet through to bin/setup when requested" do
      cli = described_class.allocate
      cli.instance_variable_set(:@quiet, true)

      expect(cli).to receive(:sh!).with("bin/setup --quiet")
      cli.send(:run_bin_setup!)
    end

    it "handoff_to_bundled_phase! re-enters through bundle exec kettle-jem with the original argv" do
      cli = described_class.allocate
      cli.instance_variable_set(:@original_argv, ["--allowed=true", "--force"])

      expect(cli).to receive(:sh!).with(a_string_including("bundle exec kettle-jem --allowed\\=true --force"))
      cli.send(:handoff_to_bundled_phase!)
    end

    it "handoff_to_bundled_phase! preserves --quiet in the bundled re-entry" do
      cli = described_class.allocate
      cli.instance_variable_set(:@original_argv, ["--allowed=true", "--quiet"])

      expect(cli).to receive(:sh!).with(a_string_including("bundle exec kettle-jem --allowed\\=true --quiet"))
      cli.send(:handoff_to_bundled_phase!)
    end

    it "run_kettle_install! builds rake cmd with passthrough" do
      cli = described_class.allocate
      cli.instance_variable_set(:@passthrough, ["only=hooks"])
      expect(cli).to receive(:sh!).with(a_string_including("bin/rake kettle:jem:install only\\=hooks"))
      cli.send(:run_kettle_install!)
    end

    it "run_kettle_install! preserves --quiet for the final rake invocation" do
      cli = described_class.allocate
      cli.instance_variable_set(:@passthrough, ["--quiet", "only=hooks"])

      expect(cli).to receive(:sh!).with(a_string_including("bin/rake kettle:jem:install --quiet only\\=hooks"))
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
      %i[prechecks! template_config_present? ensure_gemfile_from_example! ensure_bootstrap_modular_gemfiles! ensure_bin_setup! run_bin_setup! run_bundle_binstubs! handoff_to_bundled_phase!].each do |m|
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
      %i[ensure_project_files! load_bundled_runtime! ensure_dev_deps! ensure_gemfile_from_example! ensure_modular_gemfiles! ensure_rakefile! run_bin_setup! run_bundle_binstubs! run_kettle_install! commit_bootstrap_changes!].each do |m|
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
      allow(Kettle::Jem::TemplateHelpers).to receive(:project_root).and_return(Dir.pwd)
      allow(Kettle::Jem::TemplateHelpers).to receive(:gemspec_metadata).and_return(
        gem_name: "demo-gem",
        min_ruby: Gem::Version.create("3.2"),
        forge_org: "acme",
        namespace: "DemoGem",
        namespace_shield: "Demo__Gem",
        gem_shield: "demo__gem",
        authors: ["Test User"],
        email: ["test@example.com"],
      )
      allow(Kettle::Jem::TemplateHelpers).to receive(:template_run_timestamp).and_return(Time.new(2026, 3, 14, 12, 0, 0, "+00:00"))
      allow(Kettle::Jem::TemplateHelpers).to receive(:kettle_jem_version).and_return("9.9.9")

      cli.send(:ensure_rakefile!)

      content = File.read("Rakefile")
      expect(content).to include("# demo-gem Rakefile v9.9.9 - 2026-03-14")
      expect(content).to include("# Copyright (c) 2026 Test User (example.com)")
    end
  end
end
# rubocop:enable ThreadSafety/DirChdir
