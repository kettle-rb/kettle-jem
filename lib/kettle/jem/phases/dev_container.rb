# frozen_string_literal: true

require_relative "template_phase"

module Kettle
  module Jem
    module Phases
      # Phase 1: Sync .devcontainer/ directory.
      class DevContainer < TemplatePhase
        PHASE_EMOJI = "📦"
        PHASE_NAME = "Dev container"
        PHASE_DETAIL = ".devcontainer/"

        private

        def perform
          helpers = context.helpers
          devcontainer_src_dir = File.join(context.template_root, ".devcontainer")
          return unless Dir.exist?(devcontainer_src_dir)

          require "find"
          Find.find(devcontainer_src_dir) do |path|
            next if File.directory?(path)

            rel = path.sub(%r{^#{Regexp.escape(devcontainer_src_dir)}/?}, "")
            src = helpers.prefer_example(path)
            dest_rel = rel.sub(/\.example\z/, "")
            dest = File.join(context.project_root, ".devcontainer", dest_rel)
            next unless File.exist?(src)

            file_strategy = helpers.strategy_for(dest)
            next if file_strategy == :keep_destination
            if file_strategy == :raw_copy
              helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true, raw: true)
              next
            end

            helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true) do |content|
              c = content
              if file_strategy != :accept_template && File.exist?(dest)
                begin
                  merger_class = case dest_rel
                  when /\.json$/
                    Json::Merge::SmartMerger
                  when /\.sh$/
                    Bash::Merge::SmartMerger
                  end
                  if merger_class
                    c = merger_class.new(
                      c,
                      File.read(dest),
                      preference: :template,
                      add_template_only_nodes: true,
                      freeze_token: "kettle-jem",
                    ).merge
                  end
                rescue Ast::Merge::ParseError => e
                  if destination_parse_error?(e)
                    Kernel.warn("[kettle-jem] #{File.basename(dest)}: #{e.message}; destination is unparseable, using template content")
                    c = content
                  elsif Kettle::Jem::Tasks::TemplateTask.parse_error_mode == :skip
                    Kernel.warn("[kettle-jem] #{File.basename(dest)}: SKIPPED — #{e.message}")
                    c = File.read(dest)
                  else
                    raise Kettle::Dev::Error, "[kettle-jem] #{File.basename(dest)}: AST merge failed — #{e.message}. " \
                      "Set PARSE_ERROR_MODE=skip to skip files when parsers are unavailable."
                  end
                rescue StandardError => e
                  Kettle::Dev.debug_error(e, __method__)
                end
              end
              c
            end
          end
        end

        def destination_parse_error?(error)
          error.is_a?(Ast::Merge::DestinationParseError) || error.class.name.end_with?("::DestinationParseError")
        end
      end
    end
  end
end
