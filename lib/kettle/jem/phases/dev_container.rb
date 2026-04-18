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
                    destination_content = File.read(dest)
                    c = merge_devcontainer_file(
                      merger_class: merger_class,
                      template_content: c,
                      destination_content: destination_content,
                      destination_basename: File.basename(dest),
                    )
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

        def merge_devcontainer_file(merger_class:, template_content:, destination_content:, destination_basename:)
          merger_class.new(
            template_content,
            destination_content,
            preference: :template,
            add_template_only_nodes: true,
            freeze_token: "kettle-jem",
          ).merge
        rescue Ast::Merge::ParseError => e
          raise unless destination_parse_error?(e)

          sanitized_destination = strip_trailing_commas(destination_content)
          raise if sanitized_destination == destination_content

          Kernel.warn("[kettle-jem] #{destination_basename}: destination had trailing commas; retrying merge with sanitized JSON")
          merger_class.new(
            template_content,
            sanitized_destination,
            preference: :template,
            add_template_only_nodes: true,
            freeze_token: "kettle-jem",
          ).merge
        end

        def strip_trailing_commas(content)
          source = content.to_s
          result = +""
          in_string = false
          in_line_comment = false
          in_block_comment = false
          escaping = false
          i = 0

          while i < source.length
            char = source[i]
            nxt = source[i + 1]

            if in_line_comment
              result << char
              in_line_comment = false if char == "\n"
              i += 1
              next
            end

            if in_block_comment
              result << char
              if char == "*" && nxt == "/"
                result << nxt
                in_block_comment = false
                i += 2
              else
                i += 1
              end
              next
            end

            if in_string
              result << char
              if escaping
                escaping = false
              elsif char == "\\"
                escaping = true
              elsif char == '"'
                in_string = false
              end
              i += 1
              next
            end

            if char == "/" && nxt == "/"
              result << char << nxt
              in_line_comment = true
              i += 2
              next
            end

            if char == "/" && nxt == "*"
              result << char << nxt
              in_block_comment = true
              i += 2
              next
            end

            if char == '"'
              result << char
              in_string = true
              i += 1
              next
            end

            if char == ","
              j = i + 1
              while j < source.length
                lookahead = source[j]
                lookahead_next = source[j + 1]

                if lookahead.match?(/\s/)
                  j += 1
                  next
                end

                if lookahead == "/" && lookahead_next == "/"
                  j += 2
                  j += 1 while j < source.length && source[j] != "\n"
                  next
                end

                if lookahead == "/" && lookahead_next == "*"
                  j += 2
                  while j < source.length - 1
                    break if source[j] == "*" && source[j + 1] == "/"

                    j += 1
                  end
                  j += 2
                  next
                end

                break
              end

              if j < source.length && ["}", "]"].include?(source[j])
                i += 1
                next
              end
            end

            result << char
            i += 1
          end

          result
        end
      end
    end
  end
end
