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
          .idea
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

        # Default score threshold (percentage of unchanged files).
        # Override via ENV["KJ_SELFTEST_THRESHOLD"].
        DEFAULT_THRESHOLD = 0

        module_function

        # Entry point invoked by the rake task.
        # @return [void]
        def run
          helpers = Kettle::Jem::TemplateHelpers
          manifest = Kettle::Jem::SelfTest::Manifest
          reporter = Kettle::Jem::SelfTest::Reporter

          gem_root = helpers.gem_checkout_root
          base_dir = File.join(gem_root, "tmp", "template_test")

          dest_dir = File.join(base_dir, "destination")
          output_dir = File.join(base_dir, "output")
          report_dir = File.join(base_dir, "report")
          diffs_dir = File.join(report_dir, "diffs")

          threshold = (ENV["KJ_SELFTEST_THRESHOLD"] || DEFAULT_THRESHOLD).to_f

          # ── Step 0: Clean slate ───────────────────────────────────────────
          FileUtils.rm_rf(base_dir)
          [dest_dir, output_dir, report_dir, diffs_dir].each { |d| FileUtils.mkdir_p(d) }

          # ── Step 1: Copy gem into destination/ ────────────────────────────
          puts "[selftest] Copying #{gem_root} → #{dest_dir}"
          copy_gem_tree(gem_root, dest_dir)

          # ── Step 2: Manifest A (before) ───────────────────────────────────
          before = manifest.generate(dest_dir)
          File.write(
            File.join(report_dir, "before.json"),
            JSON.pretty_generate(before),
          )
          puts "[selftest] Before manifest: #{before.size} files"

          # ── Step 3: Run the template task with output_dir ─────────────────
          puts "[selftest] Running template task…"
          run_template(helpers, dest_dir, output_dir)

          # ── Step 4: Manifest B (after) ────────────────────────────────────
          after = manifest.generate(output_dir)
          File.write(
            File.join(report_dir, "after.json"),
            JSON.pretty_generate(after),
          )
          puts "[selftest] After manifest: #{after.size} files"

          # ── Step 5: Compare ───────────────────────────────────────────────
          comparison = manifest.compare(before, after)

          # ── Step 6: Diffs ─────────────────────────────────────────────────
          comparison[:changed].each do |rel|
            file_a = File.join(dest_dir, rel)
            file_b = File.join(output_dir, rel)
            diff_output = reporter.diff(file_a, file_b)
            next if diff_output.empty?

            diff_path = File.join(diffs_dir, "#{rel}.diff")
            FileUtils.mkdir_p(File.dirname(diff_path))
            File.write(diff_path, diff_output)
          end

          # ── Step 7: Report ────────────────────────────────────────────────
          report = reporter.summary(comparison, output_dir: output_dir)
          report_path = File.join(report_dir, "summary.md")
          File.write(report_path, report)

          total = comparison[:matched].size + comparison[:changed].size + comparison[:added].size
          score = total.zero? ? 0.0 : (comparison[:matched].size.to_f / total * 100).round(1)

          puts
          puts report
          puts "[selftest] Report written to #{report_path}"
          puts "[selftest] Score: #{score}% (threshold: #{threshold}%)"

          if score < threshold
            raise Kettle::Dev::Error,
              "[selftest] FAIL — score #{score}% is below threshold #{threshold}%"
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
            ENV["force"] = "true"
            ENV["allowed"] = "true"

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
      end
    end
  end
end
