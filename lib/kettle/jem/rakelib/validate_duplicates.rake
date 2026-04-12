# frozen_string_literal: true

namespace :kettle do
  namespace :jem do
    desc "Scan templated files for intra-file duplicate lines"
    task :validate_duplicates do
      require_relative "../duplicate_line_validator"

      dlv = Kettle::Jem::DuplicateLineValidator
      project_root = ENV.fetch("PROJECT_ROOT") { Dir.pwd }
      min_chars = ENV.fetch("MIN_CHARS", dlv::DEFAULT_MIN_CHARS).to_i
      lock_path = ENV.fetch("LOCKFILE", File.join(project_root, ".kettle-jem.lock"))
      mode = if ENV["FORCE_UPDATE"].to_s == "true"
        :force_update
      elsif ENV["CHECK"].to_s == "true"
        :check
      else
        :update
      end

      # Collect files: either from the last template run's results, or use
      # template_managed_files to find template-managed files on disk.
      files = if defined?(Kettle::Jem::TemplateHelpers) && Kettle::Jem::TemplateHelpers.respond_to?(:template_results)
        results = Kettle::Jem::TemplateHelpers.template_results
        written = results.select { |_, rec| %i[create replace].include?(rec[:action]) }.keys
        written.empty? ? dlv.template_managed_files(project_root: project_root) : written
      else
        dlv.template_managed_files(project_root: project_root)
      end

      # Build baseline from template sources — expected duplicates are subtracted.
      baseline_set = dlv.baseline(min_chars: min_chars)

      results = dlv.scan(files: files, min_chars: min_chars)
      results = dlv.subtract_baseline(results, baseline_set: baseline_set)
      count = dlv.warning_count(results)

      if results.empty?
        puts "[kettle-jem] ✅  No duplicate lines detected (min_chars=#{min_chars}, baseline=#{baseline_set.size})"
      else
        puts "[kettle-jem] ⚠️  #{count} duplicate line warning(s) across #{results.size} unique line(s)"

        # Write JSON report
        report_dir = File.join(project_root, "tmp", "kettle-jem")
        timestamp = Time.now.utc.strftime("%Y%m%d-%H%M%S")
        json_path = File.join(report_dir, "duplicate-lines-#{timestamp}.json")
        dlv.write_json(results, json_path)
        puts "[kettle-jem] 📄  Report: #{Kettle::Jem.display_path(json_path)}"
      end

      exit(
        Kettle::Drift::Process.new(
          project_root: project_root,
          lock_path: lock_path,
          mode: mode,
          results: results,
          printer_class: nil,
        ).call,
      )
    end
  end
end
