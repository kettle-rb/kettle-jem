# frozen_string_literal: true

require_relative "template_phase"

module Kettle
  module Jem
    module Phases
      # Phase 2: Sync .github/ directory (workflows, FUNDING.yml, etc.).
      class GithubWorkflows < TemplatePhase
        PHASE_EMOJI = "🔄"
        PHASE_NAME = "GitHub workflows"
        PHASE_DETAIL = ".github/"

        private

        def perform
          helpers = context.helpers
          out = context.out
          project_root = context.project_root
          template_root = context.template_root

          source_github_dir = File.join(template_root, ".github")
          if Dir.exist?(source_github_dir)
            # Build a unique set of logical .yml paths, preferring the .example variant when present
            candidates = Dir.glob(File.join(source_github_dir, "**", "*.yml")) +
              Dir.glob(File.join(source_github_dir, "**", "*.yml.example"))
            selected = {}
            candidates.each do |path|
              # Key by the path without the optional .example suffix
              key = path.sub(/\.example\z/, "")
              # Prefer example: overwrite a plain selection with .example, but do not downgrade
              if path.end_with?(".example")
                selected[key] = path
              else
                selected[key] ||= path
              end
            end
            # Parse optional include patterns (comma-separated globs relative to project root)
            include_raw = ENV["include"].to_s
            include_patterns = include_raw.split(",").map { |s| s.strip }.reject(&:empty?)
            matches_include = lambda do |abs_dest|
              return false if include_patterns.empty?
              begin
                rel_dest = abs_dest.to_s
                proj = project_root.to_s
                if rel_dest.start_with?(proj + "/")
                  rel_dest = rel_dest[(proj.length + 1)..-1]
                elsif rel_dest == proj
                  rel_dest = ""
                end
                include_patterns.any? do |pat|
                  if pat.end_with?("/**")
                    base = pat[0..-4]
                    rel_dest == base || rel_dest.start_with?(base + "/")
                  else
                    File.fnmatch?(pat, rel_dest, File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH)
                  end
                end
              rescue StandardError => e
                Kettle::Dev.debug_error(e, __method__)
                false
              end
            end

            selected.values.each do |orig_src|
              src = helpers.prefer_example_with_osc_check(orig_src)
              rel = orig_src.sub(/^#{Regexp.escape(template_root)}\/?/, "").sub(/\.example\z/, "")
              dest = File.join(project_root, rel)
              next unless File.exist?(src)

              file_strategy = helpers.strategy_for(dest)
              next if file_strategy == :keep_destination

              if helpers.skip_for_disabled_opencollective?(rel)
                out.report_detail("Skipping #{rel} (Open Collective disabled)")
                next
              end

              if helpers.skip_for_disabled_engine?(rel)
                out.report_detail("Skipping #{rel} (engine disabled)")
                next
              end

              if rel == ".github/workflows/discord-notifier.yml"
                unless matches_include.call(dest)
                  next
                end
              end

              if file_strategy == :raw_copy
                helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true, raw: true)
                next
              end

              if File.basename(rel) == "FUNDING.yml"
                helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true) do |content|
                  c = content
                  if file_strategy != :accept_template && File.exist?(dest)
                    begin
                      c = Psych::Merge::SmartMerger.new(
                        c,
                        File.read(dest),
                        preference: :template,
                        add_template_only_nodes: true,
                      ).merge
                    rescue StandardError => e
                      Kettle::Dev.debug_error(e, __method__)
                    end
                  end
                  c
                end
              else
                prepared = nil
                if rel.start_with?(".github/workflows/")
                  template_content = helpers.read_template(src)
                  c = template_content.dup
                  if file_strategy != :accept_template && File.exist?(dest)
                    begin
                      c = Psych::Merge::SmartMerger.new(
                        c,
                        File.read(dest),
                        **Kettle::Jem::Presets::Yaml.workflow_config.to_h,
                      ).merge
                      # psych-merge strips the YAML document separator (---).
                      # Restore it when the template starts with one.
                      if template_content.start_with?("---\n") && !c.start_with?("---\n")
                        c = "---\n#{c}"
                      end
                    rescue StandardError => e
                      Kettle::Dev.debug_error(e, __method__)
                    end
                  end
                  c, _removed_count, _total_count, empty = Kettle::Jem::Tasks::TemplateTask.prune_workflow_matrix_by_appraisals(c, context.removed_appraisals)
                  if empty
                    if File.exist?(dest)
                      helpers.add_warning("Workflow #{rel} has no remaining matrix entries for min Ruby #{context.min_ruby}; consider removing the file")
                    end
                    next
                  end
                  c, _eng_removed, _eng_total, eng_empty = Kettle::Jem::Tasks::TemplateTask.prune_workflow_matrix_by_engines(c, helpers.engines_config)
                  if eng_empty
                    if File.exist?(dest)
                      helpers.add_warning("Workflow #{rel} has no remaining matrix entries after engine filtering; consider removing the file")
                    end
                    next
                  end
                  # Collapse triple+ consecutive newlines left by engine/appraisal
                  # pruning into double newlines.
                  c = c.gsub(/\n{3,}/, "\n\n")
                  prepared = c
                end

                helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true) do |content|
                  prepared || content
                end
              end
            end
          end

          # 2b) Clean up obsolete workflow files that were replaced by per-ruby workflows.
          #     These filenames no longer exist in the template and would remain as orphans.
          actual_root = helpers.output_dir || project_root
          Kettle::Jem::Tasks::TemplateTask::OBSOLETE_WORKFLOWS.each do |wf|
            wf_path = File.join(actual_root, ".github", "workflows", wf)
            next unless File.exist?(wf_path)

            if helpers.ask("Remove obsolete workflow #{wf}?", true)
              FileUtils.rm_f(wf_path)
              out.detail("Removed obsolete workflow: .github/workflows/#{wf}")
            else
              out.detail("Kept obsolete workflow: .github/workflows/#{wf}")
            end
          end
        end
      end
    end
  end
end
