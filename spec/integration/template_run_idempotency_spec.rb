# frozen_string_literal: true

# End-to-end idempotency test: runs TemplateTask.run multiple times against a
# scaffolded gem project and asserts that the second run produces no file
# changes compared to the first. This catches regressions such as comment
# duplication, heading re-insertion, whitespace drift, or node inflation.

RSpec.describe "template run idempotency", :e2e do
  let(:helpers) { Kettle::Jem::TemplateHelpers }

  after do
    helpers.send(:class_variable_set, :@@template_results, {})
    helpers.send(:class_variable_set, :@@output_dir, nil)
    helpers.send(:class_variable_set, :@@project_root_override, nil)
    helpers.send(:class_variable_set, :@@template_warnings, [])
    helpers.send(:class_variable_set, :@@manifestation, nil)
    helpers.send(:class_variable_set, :@@kettle_config, nil)
  end

  before do
    stub_env("KJ_PROJECT_EMOJI" => "🔧")
    stub_env("allowed" => "true")
    stub_env("FUNDING_ORG" => "false")
  end

  # Snapshot every file under `root` as { relative_path => content }.
  def snapshot_files(root)
    Dir.glob("#{root}/**/*", File::FNM_DOTMATCH).each_with_object({}) do |path, memo|
      next unless File.file?(path)
      # Skip report files — they contain timestamps that change per run
      rel = path.sub("#{root}/", "")
      next if rel.start_with?("tmp/kettle-jem/templating-report-")

      memo[rel] = File.read(path)
    end
  end

  def reset_helpers_state!
    helpers.send(:class_variable_set, :@@template_results, {})
    helpers.send(:class_variable_set, :@@output_dir, nil)
    helpers.send(:class_variable_set, :@@project_root_override, nil)
    helpers.send(:class_variable_set, :@@template_warnings, [])
    helpers.send(:class_variable_set, :@@manifestation, nil)
    helpers.send(:class_variable_set, :@@kettle_config, nil)
  end

  # rubocop:disable RSpec/ExampleLength
  shared_examples "idempotent across successive runs" do
    it "produces identical files on second and third run" do
      Dir.mktmpdir do |gem_root|
        Dir.mktmpdir do |project_root|
          template_root = File.join(gem_root, "template")
          setup_template!(template_root)
          setup_project!(project_root)

          fixed_time = Time.new(2026, 4, 8, 12, 0, 0, "+00:00")

          mock_helpers = proc do
            allow(helpers).to receive_messages(
              project_root: project_root,
              template_root: template_root,
              ensure_clean_git!: nil,
              ask: true,
              template_run_timestamp: fixed_time,
            )
          end

          # Run 1: seed — may transform files from their initial state
          mock_helpers.call
          expect { Kettle::Jem::Tasks::TemplateTask.run }.not_to raise_error
          snapshot_after_run1 = snapshot_files(project_root)

          # Reset class-level state between runs (simulates a fresh process)
          reset_helpers_state!

          # Run 2: should converge — no further changes
          mock_helpers.call
          expect { Kettle::Jem::Tasks::TemplateTask.run }.not_to raise_error
          snapshot_after_run2 = snapshot_files(project_root)

          # Run 3: confirm stability
          reset_helpers_state!
          mock_helpers.call
          expect { Kettle::Jem::Tasks::TemplateTask.run }.not_to raise_error
          snapshot_after_run3 = snapshot_files(project_root)

          # Compare run 2 vs run 1 — identify any files that drifted
          changed_run2 = diff_snapshots(snapshot_after_run1, snapshot_after_run2)
          changed_run3 = diff_snapshots(snapshot_after_run2, snapshot_after_run3)

          aggregate_failures "run 2 should not change any files from run 1" do
            changed_run2.each do |path, (before, after)|
              expect(after).to eq(before),
                "File #{path} changed between run 1 and run 2:\n" \
                  "--- run 1\n#{before}\n+++ run 2\n#{after}"
            end
          end

          aggregate_failures "run 3 should not change any files from run 2" do
            changed_run3.each do |path, (before, after)|
              expect(after).to eq(before),
                "File #{path} changed between run 2 and run 3:\n" \
                  "--- run 2\n#{before}\n+++ run 3\n#{after}"
            end
          end
        end
      end
    end
  end
  # rubocop:enable RSpec/ExampleLength

  # Returns { path => [before, after] } for files that differ
  def diff_snapshots(snap_a, snap_b)
    all_paths = (snap_a.keys | snap_b.keys).sort
    diffs = {}
    all_paths.each do |path|
      a = snap_a[path]
      b = snap_b[path]
      diffs[path] = [a, b] if a != b
    end
    diffs
  end

  context "with YAML config + trailing comment (psych-merge)" do
    def setup_template!(template_root)
      FileUtils.mkdir_p(File.join(template_root, "tmp"))

      File.write(File.join(template_root, ".kettle-jem.yml.example"), <<~YAML)
        defaults:
          preference: destination
          add_template_only_nodes: true
          freeze_token: kettle-jem
        tokens:
          forge:
            gh_user: ""
        patterns: []
        files: {}

        # To override specific files:
        #
        # files:
        #   README.md:
        #     strategy: accept_template
      YAML

      File.write(File.join(template_root, "tmp", ".gitignore.example"), <<~GITIGNORE)
        *
        !.gitignore
      GITIGNORE
    end

    def setup_project!(project_root)
      File.write(File.join(project_root, ".kettle-jem.yml"), <<~YAML)
        defaults:
          preference: destination
          add_template_only_nodes: true
          freeze_token: kettle-jem
        tokens:
          forge:
            gh_user: "test-user"
        patterns: []
        files:
          AGENTS.md:
            strategy: accept_template

        # To override specific files:
        #
        # files:
        #   README.md:
        #     strategy: accept_template
      YAML

      File.write(File.join(project_root, "demo.gemspec"), <<~GEMSPEC)
        Gem::Specification.new do |spec|
          spec.name = "demo"
          spec.version = "0.1.0"
          spec.summary = "test"
          spec.authors = ["Test User"]
          spec.email = ["test@example.com"]
          spec.required_ruby_version = ">= 3.1"
          spec.homepage = "https://github.com/acme/demo"
        end
      GEMSPEC
    end

    it_behaves_like "idempotent across successive runs"
  end

  context "with multi-file template (YAML, Ruby, Bash, Markdown)" do
    def setup_template!(template_root)
      FileUtils.mkdir_p(File.join(template_root, "tmp"))
      FileUtils.mkdir_p(File.join(template_root, "bin"))

      File.write(File.join(template_root, ".kettle-jem.yml.example"), <<~YAML)
        defaults:
          preference: destination
          add_template_only_nodes: true
          freeze_token: kettle-jem
        tokens:
          forge:
            gh_user: ""
        patterns: []
        files: {}

        # Self-test / templating CI threshold.
        # Set to a number from 0 to 100 to fail `rake kettle:jem:selftest` once
        # divergence exceeds this %.
        min_divergence_threshold:
      YAML

      File.write(File.join(template_root, "tmp", ".gitignore.example"), <<~GITIGNORE)
        *
        !.gitignore
      GITIGNORE

      File.write(File.join(template_root, "Rakefile.example"), <<~RUBY)
        # frozen_string_literal: true

        # {KJ|GEM_NAME} Rakefile
        require "bundler/gem_tasks"

        # kettle-jem:freeze
        # Custom tasks go here
        # kettle-jem:unfreeze
      RUBY

      File.write(File.join(template_root, "Gemfile.example"), <<~RUBY)
        # frozen_string_literal: true

        # Include dependencies from {KJ|GEM_NAME}.gemspec
        gemspec
      RUBY

      File.write(File.join(template_root, "bin", "setup.example"), <<~BASH)
        #!/usr/bin/env bash
        set -euo pipefail
        IFS=$'\\n\\t'
        set -vx

        bundle install
      BASH
    end

    def setup_project!(project_root)
      FileUtils.mkdir_p(File.join(project_root, "bin"))

      File.write(File.join(project_root, ".kettle-jem.yml"), <<~YAML)
        defaults:
          preference: destination
          add_template_only_nodes: true
          freeze_token: kettle-jem
        tokens:
          forge:
            gh_user: "test-user"
        patterns: []
        files:
          AGENTS.md:
            strategy: accept_template
          Rakefile:
            strategy: merge

        # Self-test / templating CI threshold.
        # Set to a number from 0 to 100 to fail `rake kettle:jem:selftest` once
        # divergence exceeds this %.
        min_divergence_threshold:
      YAML

      File.write(File.join(project_root, "demo.gemspec"), <<~GEMSPEC)
        Gem::Specification.new do |spec|
          spec.name = "demo"
          spec.version = "0.1.0"
          spec.summary = "test"
          spec.authors = ["Test User"]
          spec.email = ["test@example.com"]
          spec.required_ruby_version = ">= 3.1"
          spec.homepage = "https://github.com/acme/demo"
        end
      GEMSPEC

      File.write(File.join(project_root, "Rakefile"), <<~RUBY)
        # frozen_string_literal: true

        # demo Rakefile
        require "bundler/gem_tasks"

        # kettle-jem:freeze
        task :my_custom_task do
          puts "hello"
        end
        # kettle-jem:unfreeze
      RUBY

      File.write(File.join(project_root, "Gemfile"), <<~RUBY)
        # frozen_string_literal: true

        # Include dependencies from demo.gemspec
        gemspec
      RUBY

      File.write(File.join(project_root, "bin", "setup"), <<~BASH)
        #!/usr/bin/env bash
        set -euo pipefail
        IFS=$'\\n\\t'
        set -vx

        bundle install
      BASH
    end

    it_behaves_like "idempotent across successive runs"
  end
end
