# frozen_string_literal: true

require "json"

module Kettle
  module Jem
    module Tasks
      # Implements the `kettle:jem:selftest` rake task.
      #
      # The task validates that the templating process produces correct output
      # by templating kettle-jem *itself* as the target gem.  Since kettle-jem
      # was originally set up by this very toolchain, the expectation is that
      # re-running the template against a pristine copy should yield a result
      # that closely matches what already exists.
      #
      # == Three-directory layout
      #
      #   tmp/template_test/
      #   ├── destination/   # Pristine copy (the "before" snapshot)
      #   ├── output/        # Where templated results are written ("after" state)
      #   └── report/        # Manifests, diffs, and score report
      #
      # The merge logic *reads* from +destination/+ and *writes* to +output/+
      # so that the before-snapshot is never mutated.
      module SelfTestTask
        # Directories that are excluded when copying the gem into the
        # destination sandbox — they are either generated or have no bearing
        # on templating correctness.
        EXCLUDED_DIRS = %w[
          .git
          .yardoc
          bin
          checksums
          coverage
          docs
          node_modules
          pkg
          results
          tmp
        ].freeze

        # Default minimum unchanged-score threshold (percentage of unchanged files).
        # Override via ENV["KJ_SELFTEST_THRESHOLD"].
        DEFAULT_THRESHOLD = 0

        # Directory prefixes and exact filenames for files that are part of the
        # gem source but are NOT expected to be produced by the template task.
        # These are classified as "skipped" (informational) rather than
        # "removed" (potentially concerning) in the self-test report.
        SKIPPED_PREFIXES = %w[
          examples/
          exe/
          lib/
          sig/
          spec/
          template/
        ].freeze

        # Exact filenames that are source-only and not templated.
        SKIPPED_FILES = %w[
          .kettle-jem.yml
          .rubocop_gradual.lock
          Gemfile.lock
        ].freeze

        GENERATED_RUNTIME_PREFIXES = %w[
          tmp/kettle-jem/templating-report-
        ].freeze

        APPRAISAL_GENERATED_GEMFILE_PATTERN = %r{\Agemfiles/[^/]+\.gemfile\z}

        module_function

        # Entry point invoked by the rake task.
        # @return [void]
        def run
          helpers = Kettle::Jem::TemplateHelpers
          manifest = Kettle::Jem::SelfTest::Manifest
          reporter = Kettle::Jem::SelfTest::Reporter

          project_root = helpers.project_root
          base_dir = File.join(project_root, "tmp", "template_test")

          dest_dir = File.join(base_dir, "destination")
          output_dir = File.join(base_dir, "output")
          report_dir = File.join(base_dir, "report")
          diffs_dir = File.join(report_dir, "diffs")

          threshold_mode, threshold = self_test_threshold(helpers)
          templating_environment = Kettle::Jem::TemplatingReport.snapshot

          # ── Step 0: Clean slate ───────────────────────────────────────────
          FileUtils.rm_rf(base_dir)
          [dest_dir, output_dir, report_dir, diffs_dir].each { |d| FileUtils.mkdir_p(d) }

          # ── Step 1: Copy gem into destination/ ────────────────────────────
          copy_gem_tree(project_root, dest_dir)

          # ── Step 2: Manifest A (before) ───────────────────────────────────
          before = manifest.generate(dest_dir)
          File.write(
            File.join(report_dir, "before.json"),
            JSON.pretty_generate(before),
          )

          # ── Step 3: Run the template task with output_dir ─────────────────
          run_template(helpers, dest_dir, output_dir)

          # ── Step 4: Manifest B (after) ────────────────────────────────────
          after = manifest.generate(output_dir)
          File.write(
            File.join(report_dir, "after.json"),
            JSON.pretty_generate(after),
          )

          # ── Step 5: Compare ───────────────────────────────────────────
          comparison = manifest.compare(before, after)
          comparison[:added] = comparison[:added].reject do |rel|
            generated_runtime_artifact?(rel) ||
              force_copied_template_addition?(rel, output_dir: output_dir, helpers: helpers)
          end

          # Classify "removed" files into expected skips vs truly unexpected.
          # Files under lib/, spec/, template/, exe/, sig/, etc. are part of
          # the gem source and are never produced by the template task.
          skipped, truly_removed = comparison[:removed].partition do |rel|
            expected_non_templated_path?(rel, project_root: project_root)
          end
          comparison[:removed] = truly_removed
          comparison[:skipped] = skipped

          # ── Step 6: Diffs ─────────────────────────────────────────────────
          diff_count = 0
          comparison[:changed].each do |rel|
            file_a = File.join(dest_dir, rel)
            file_b = File.join(output_dir, rel)
            diff_output = reporter.diff(file_a, file_b)
            next if diff_output.empty?

            diff_path = File.join(diffs_dir, "#{rel}.diff")
            FileUtils.mkdir_p(File.dirname(diff_path))
            File.write(diff_path, diff_output)
            diff_count += 1
          end

          # ── Step 7: Report ────────────────────────────────────────────────
          report = reporter.summary(
            comparison,
            output_dir: output_dir,
            templating_environment: templating_environment,
            diff_count: diff_count,
          )
          report_path = File.join(report_dir, "summary.md")
          File.write(report_path, report)

          score, divergence = score_and_divergence(comparison)

          puts "[selftest] 📄  Report - #{report_path}"
          puts "[selftest] #{(score >= 100.0) ? "✅" : "⚠️"}  Score: #{score}% · Divergence: #{divergence}% · Threshold: #{threshold_label(threshold_mode, threshold)}"

          if threshold_failed?(threshold_mode, threshold, score, divergence)
            raise Kettle::Dev::Error,
              threshold_failure_message(threshold_mode, threshold, score, divergence)
          end
        end

        def score_and_divergence(comparison)
          total = comparison[:matched].size + comparison[:changed].size + comparison[:added].size
          score = total.zero? ? 0.0 : (comparison[:matched].size.to_f / total * 100).round(1)
          divergence = (100.0 - score).round(1)
          [score, divergence]
        end

        def self_test_threshold(helpers)
          env_threshold = ENV["KJ_SELFTEST_THRESHOLD"].to_s.strip
          return [:score, env_threshold.to_f] unless env_threshold.empty?

          configured_threshold = helpers.kettle_config["min_divergence_threshold"]
          return [:none, nil] if configured_threshold.nil? || configured_threshold.to_s.strip.empty?

          [:divergence, Float(configured_threshold)]
        rescue ArgumentError, TypeError
          raise Kettle::Dev::Error,
            "[selftest] Invalid min_divergence_threshold #{configured_threshold.inspect} in .kettle-jem.yml"
        end

        def threshold_failed?(mode, threshold, score, divergence)
          case mode
          when :score
            score < threshold
          when :divergence
            divergence >= threshold
          else
            false
          end
        end

        def threshold_label(mode, threshold)
          case mode
          when :score
            "minimum unchanged score #{threshold}%"
          when :divergence
            "fail when divergence reaches #{threshold}%"
          else
            "none"
          end
        end

        def threshold_failure_message(mode, threshold, score, divergence)
          case mode
          when :score
            "[selftest] FAIL — score #{score}% is below threshold #{threshold}%"
          when :divergence
            "[selftest] FAIL — divergence #{divergence}% meets or exceeds threshold #{threshold}%"
          else
            "[selftest] FAIL — threshold condition triggered"
          end
        end

        # Copy the gem tree into +dest+ respecting EXCLUDED_DIRS.
        # Uses `git ls-files` when available, otherwise falls back to
        # a recursive copy that skips excluded directories.
        # @param src [String] gem checkout root
        # @param dest [String] destination directory
        # @return [void]
        def copy_gem_tree(src, dest)
          tracked = git_ls_files(src)
          if tracked
            tracked.each do |rel|
              next if EXCLUDED_DIRS.any? { |ex| rel == ex || rel.start_with?("#{ex}/") }

              src_path = File.join(src, rel)
              dest_path = File.join(dest, rel)
              FileUtils.mkdir_p(File.dirname(dest_path))
              FileUtils.cp(src_path, dest_path) if File.file?(src_path)
            end
          else
            # Fallback: recursive copy excluding EXCLUDED_DIRS
            require "find"
            Find.find(src) do |path|
              rel = path.sub(%r{^#{Regexp.escape(src)}/?}, "")
              next if rel.empty?

              top_dir = rel.split("/").first
              if EXCLUDED_DIRS.include?(top_dir)
                Find.prune if File.directory?(path)
                next
              end

              dest_path = File.join(dest, rel)
              if File.directory?(path)
                FileUtils.mkdir_p(dest_path)
              else
                FileUtils.mkdir_p(File.dirname(dest_path))
                FileUtils.cp(path, dest_path)
              end
            end
          end
        end

        # Run the template task against the sandbox.
        # @param helpers [Module] TemplateHelpers
        # @param dest_dir [String] the sandbox "project root"
        # @param output_dir [String] where writes are redirected
        # @return [void]
        def run_template(helpers, dest_dir, output_dir)
          # Save prior state
          prior_output_dir = helpers.output_dir
          prior_results = helpers.send(:class_variable_get, :@@template_results).dup

          begin
            # Configure redirection
            helpers.send(:output_dir=, output_dir)

            # Force mode: skip all interactive prompts and git-clean check
            prev_force = ENV["force"]
            prev_allowed = ENV["allowed"]
            prev_hook_templates = ENV["hook_templates"]
            prev_dev_hook_templates = ENV["KETTLE_DEV_HOOK_TEMPLATES"]
            ENV["force"] = "true"
            ENV["allowed"] = "true"
            ENV["hook_templates"] = "l" if prev_hook_templates.nil? || prev_hook_templates.strip.empty?
            if prev_dev_hook_templates.nil? || prev_dev_hook_templates.strip.empty?
              ENV["KETTLE_DEV_HOOK_TEMPLATES"] = "l"
            end

            # Bypass ensure_clean_git! — the sandbox is a disposable copy
            helpers.define_singleton_method(:ensure_clean_git!) { |**_| nil }

            # Redirect project_root to the sandbox copy
            allow_project_root(helpers, dest_dir) do
              Kettle::Jem::Tasks::TemplateTask.run
            end
          ensure
            # Restore prior state
            ENV["force"] = prev_force
            ENV["allowed"] = prev_allowed
            ENV["hook_templates"] = prev_hook_templates
            ENV["KETTLE_DEV_HOOK_TEMPLATES"] = prev_dev_hook_templates
            helpers.send(:output_dir=, prior_output_dir)
            helpers.send(:class_variable_set, :@@template_results, prior_results)

            # Restore ensure_clean_git! from the module's instance method
            class << helpers
              remove_method :ensure_clean_git! if method_defined?(:ensure_clean_git!)
            end
          end
        end

        # Temporarily override project_root on helpers.
        # Uses a block-scoped override via a class variable so that the
        # module_function dispatch is unaffected.
        # @param helpers [Module]
        # @param dir [String]
        # @yield
        # @return [void]
        def allow_project_root(helpers, dir)
          helpers.send(:class_variable_set, :@@project_root_override, dir)
          yield
        ensure
          helpers.send(:class_variable_set, :@@project_root_override, nil)
        end

        # List git-tracked files in +dir+.
        # @param dir [String]
        # @return [Array<String>, nil] relative paths or nil when git is unavailable
        def git_ls_files(dir)
          require "open3"
          out, status = Open3.capture2("git", "-C", dir, "ls-files", "-z")
          return unless status.success?

          out.split("\0").reject(&:empty?)
        rescue StandardError
          nil
        end

        def generated_runtime_artifact?(relative_path)
          GENERATED_RUNTIME_PREFIXES.any? { |prefix| relative_path.start_with?(prefix) }
        end

        # Files created during self-test force mode that are byte-for-byte copies
        # of their template source should not be treated as divergent "new files".
        def force_copied_template_addition?(relative_path, output_dir:, helpers:)
          actual_path = File.join(output_dir, relative_path.to_s)
          return false unless File.file?(actual_path)

          template_source = helpers.prefer_example_with_osc_check(
            File.join(helpers.template_root, relative_path.to_s),
          )
          return false unless File.file?(template_source)

          File.binread(actual_path) == File.binread(template_source)
        rescue StandardError => e
          Kettle::Dev.debug_error(e, __method__)
          false
        end

        def expected_non_templated_path?(relative_path, project_root:)
          SKIPPED_FILES.include?(relative_path) ||
            SKIPPED_PREFIXES.any? { |prefix| relative_path.start_with?(prefix) } ||
            appraisal_generated_gemfile?(relative_path) ||
            project_gemspec?(relative_path, project_root: project_root)
        end

        def appraisal_generated_gemfile?(relative_path)
          relative_path.match?(APPRAISAL_GENERATED_GEMFILE_PATTERN)
        end

        def project_gemspec?(relative_path, project_root:)
          return false if relative_path.include?("/") || !relative_path.end_with?(".gemspec")

          Dir.glob(File.join(project_root, "*.gemspec")).any? do |path|
            File.basename(path) == relative_path
          end
        end
      end
    end
  end
end
