# frozen_string_literal: true

require_relative "template_phase"

module Kettle
  module Jem
    module Phases
      # Phase 8: Sync .git-hooks/ directory with format-appropriate merging.
      class GitHooks < TemplatePhase
        PHASE_EMOJI = "🪝"
        PHASE_NAME = "Git hooks"
        PHASE_DETAIL = ".git-hooks/"

        private

        def perform
          helpers = context.helpers
          out = context.out
          project_root = context.project_root
          template_root = context.template_root
          forge_org = context.forge_org
          funding_org = context.funding_org
          gem_name = context.gem_name
          namespace = context.namespace
          namespace_shield = context.namespace_shield
          gem_shield = context.gem_shield
          min_ruby = context.min_ruby

          source_hooks_dir = File.join(template_root, ".git-hooks")
          return unless Dir.exist?(source_hooks_dir)

          # Honor ENV["only"]: skip entire .git-hooks handling unless patterns include .git-hooks
          begin
            only_raw = ENV["only"].to_s
            if !only_raw.empty?
              patterns = only_raw.split(",").map { |s| s.strip }.reject(&:empty?)
              if !patterns.empty?
                proj = helpers.project_root.to_s
                target_dir = File.join(proj, ".git-hooks")
                matches = patterns.any? do |pat|
                  if pat.end_with?("/**")
                    base = pat[0..-4]
                    base == ".git-hooks" || base == target_dir.sub(/^#{Regexp.escape(proj)}\/?/, "")
                  else
                    File.fnmatch?(pat, ".git-hooks", File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH) ||
                      File.fnmatch?(pat, ".git-hooks/*", File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH)
                  end
                end
                return unless matches
              end
            end
          rescue StandardError => e
            Kettle::Dev.debug_error(e, __method__)
            # If filter parsing fails, proceed as before
          end

          # Prefer .example variant when present for .git-hooks
          goalie_src = helpers.prefer_example(File.join(source_hooks_dir, "commit-subjects-goalie.txt"))
          footer_src = helpers.prefer_example(File.join(source_hooks_dir, "footer-template.erb.txt"))
          hook_ruby_src = helpers.prefer_example(File.join(source_hooks_dir, "commit-msg"))
          hook_sh_src = helpers.prefer_example(File.join(source_hooks_dir, "prepare-commit-msg"))

          # First: templates (.txt) — ask local/global/skip
          if File.file?(goalie_src) && File.file?(footer_src)
            unless Kettle::Jem::Tasks::TemplateTask.quiet?
              puts
              puts "Git hooks templates found:"
              puts "  - #{goalie_src}"
              puts "  - #{footer_src}"
              puts
              puts "About these files:"
              puts "- commit-subjects-goalie.txt:"
              puts "  Lists commit subject prefixes to look for; if a commit subject starts with any listed prefix,"
              puts "  kettle-commit-msg will append a footer to the commit message (when GIT_HOOK_FOOTER_APPEND=true)."
              puts "  Defaults include release prep (🔖 Prepare release v) and checksum commits (🔒️ Checksums for v)."
              puts "- footer-template.erb.txt:"
              puts "  ERB template rendered to produce the footer. You can customize its contents and variables."
              puts
              puts "Where would you like to install these two templates?"
              puts "  [l] Local to this project (#{File.join(project_root, ".git-hooks")})"
              puts "  [g] Global for this user (#{File.join(ENV["HOME"], ".git-hooks")})"
              puts "  [s] Skip copying"
            end
            # Allow non-interactive selection via environment
            # Precedence: CLI switch (hook_templates) > KETTLE_DEV_HOOK_TEMPLATES > prompt
            force_mode = Kettle::Dev::ENV_TRUE_RE.match?(ENV.fetch("force", "").to_s)
            non_interactive_mode = force_mode || !helpers.output_dir.nil?
            env_choice = ENV["hook_templates"]
            env_choice = ENV["KETTLE_DEV_HOOK_TEMPLATES"] if env_choice.nil? || env_choice.strip.empty?
            choice = env_choice&.strip
            unless choice && !choice.empty?
              if non_interactive_mode
                choice = "l"
                out.detail("Choose (l/g/s) [l]: l (non-interactive)")
              else
                print("Choose (l/g/s) [l]: ")
                choice = Kettle::Dev::InputAdapter.gets&.strip
              end
            end
            choice = "l" if choice.nil? || choice.empty?
            dest_dir = case choice.downcase
            when "g", "global" then File.join(ENV["HOME"], ".git-hooks")
            when "s", "skip" then nil
            else File.join(project_root, ".git-hooks")
            end

            if dest_dir
              FileUtils.mkdir_p(dest_dir)

              sync_goalie_template!(helpers, goalie_src, dest_dir)
              sync_footer_template!(helpers, footer_src, dest_dir, forge_org, funding_org, gem_name, namespace, namespace_shield, gem_shield, min_ruby)

              [File.join(dest_dir, "commit-subjects-goalie.txt"), File.join(dest_dir, "footer-template.erb.txt")].each do |txt_dest|
                File.chmod(0o644, txt_dest) if File.exist?(txt_dest)
              rescue StandardError => e
                Kettle::Dev.debug_error(e, __method__)
              end
            else
              out.detail("Skipping copy of .git-hooks templates.")
            end
          end

          hook_dest_dir = File.join(project_root, ".git-hooks")
          begin
            FileUtils.mkdir_p(hook_dest_dir)
          rescue StandardError => e
            context.out.warning("Could not create #{hook_dest_dir}: #{e.class}: #{e.message}")
            hook_dest_dir = nil
          end

          return unless hook_dest_dir

          sync_hook_script!(helpers, hook_ruby_src, hook_dest_dir, "commit-msg")
          sync_hook_script!(helpers, hook_sh_src, hook_dest_dir, "prepare-commit-msg")
        end

        def sync_goalie_template!(helpers, goalie_src, dest_dir)
          goalie_dest = File.join(dest_dir, "commit-subjects-goalie.txt")
          goalie_strategy = helpers.strategy_for(goalie_dest)
          return if goalie_strategy == :keep_destination

          if goalie_strategy == :raw_copy
            helpers.copy_file_with_prompt(goalie_src, goalie_dest, allow_create: true, allow_replace: true, raw: true)
          else
            helpers.copy_file_with_prompt(goalie_src, goalie_dest, allow_create: true, allow_replace: true) do |content|
              if goalie_strategy != :accept_template && File.exist?(goalie_dest)
                begin
                  content = Ast::Merge::Text::SmartMerger.new(
                    content,
                    File.read(goalie_dest),
                    preference: :template,
                    add_template_only_nodes: true,
                    freeze_token: "kettle-jem",
                  ).merge
                rescue StandardError => e
                  Kettle::Dev.debug_error(e, __method__)
                end
              end
              content
            end
          end
        end

        def sync_footer_template!(helpers, footer_src, dest_dir, forge_org, funding_org, gem_name, namespace, namespace_shield, gem_shield, min_ruby)
          footer_dest = File.join(dest_dir, "footer-template.erb.txt")
          footer_strategy = helpers.strategy_for(footer_dest)
          return if footer_strategy == :keep_destination

          if footer_strategy == :raw_copy
            helpers.copy_file_with_prompt(footer_src, footer_dest, allow_create: true, allow_replace: true, raw: true)
          else
            helpers.copy_file_with_prompt(footer_src, footer_dest, allow_create: true, allow_replace: true) do |content|
              c = helpers.apply_common_replacements(
                content,
                org: forge_org,
                funding_org: funding_org,
                gem_name: gem_name,
                namespace: namespace,
                namespace_shield: namespace_shield,
                gem_shield: gem_shield,
                min_ruby: min_ruby,
              )
              if footer_strategy != :accept_template && File.exist?(footer_dest)
                begin
                  c = Ast::Merge::Text::SmartMerger.new(
                    c,
                    File.read(footer_dest),
                    preference: :template,
                    add_template_only_nodes: true,
                    freeze_token: "kettle-jem",
                  ).merge
                rescue StandardError => e
                  Kettle::Dev.debug_error(e, __method__)
                end
              end
              c
            end
          end
        end

        def sync_hook_script!(helpers, hook_src, hook_dest_dir, hook_name)
          return unless File.file?(hook_src)

          hook_dest = File.join(hook_dest_dir, hook_name)
          hook_strategy = helpers.strategy_for(hook_dest)
          return if hook_strategy == :keep_destination

          if hook_strategy == :raw_copy
            helpers.copy_file_with_prompt(hook_src, hook_dest, allow_create: true, allow_replace: true, raw: true)
          else
            helpers.copy_file_with_prompt(hook_src, hook_dest, allow_create: true, allow_replace: true) do |content|
              c = content
              if hook_strategy != :accept_template && File.exist?(hook_dest)
                c = Kettle::Jem::Tasks::TemplateTask.merge_by_file_type(c, hook_dest, helpers.rel_path(hook_dest), helpers)
              end
              c
            end
          end
          begin
            File.chmod(0o755, hook_dest) if File.exist?(hook_dest)
          rescue StandardError => e
            Kettle::Dev.debug_error(e, __method__)
          end
        end
      end
    end
  end
end
