# frozen_string_literal: true

module Kettle
  module Jem
    module PrismGemspec
      module DevelopmentDependencySyncPolicy
        # Ensure development dependency lines in a gemspec match the desired lines.
        # `desired` is a hash mapping gem_name => desired_line (string, without leading indentation).
        #
        # Normal operation prefers a Prism-backed edit because that lets setup/bootstrap
        # update real Gem::Specification bodies structurally. We still keep a narrow,
        # line-oriented fallback for the bootstrap case where the target file exists but
        # Prism cannot provide a usable gemspec context yet (for example: empty content,
        # a fragment missing the final `end`, or a file that is temporarily mid-edit).
        # That fallback is intentionally best-effort resilience for early setup flows,
        # not a claim that arbitrary malformed gemspecs are a first-class supported API.
        def ensure_development_dependencies(content, desired)
          return content if desired.nil? || desired.empty?

          lines = content.to_s.lines
          return bootstrap_development_dependency_seed_content(content, desired) if lines.empty?

          context = safe_gemspec_context(content)
          return ensure_development_dependencies_fallback(content, desired, lines: lines) unless context

          ensure_development_dependencies_ast(content, desired, context: context, lines: lines)
        rescue StandardError => e
          debug_error(e, __method__)
          content
        end

        # Best-effort bootstrap fallback when Prism parsing/context extraction is
        # unavailable. This only syncs dependency lines conservatively so SetupCLI can
        # seed or repair development dependencies without hard-failing on an incomplete
        # gemspec that may be normalized later in the same workflow.
        def ensure_development_dependencies_fallback(content, desired, lines: content.to_s.lines)
          sync_snapshot = development_dependency_sync_snapshot_for(desired, lines: lines)
          updated = materialize_development_dependency_sync(content, lines: lines, sync_snapshot: sync_snapshot)

          finalize_development_dependency_sync(
            content: content,
            desired: desired,
            updated: updated,
          )
        end

        def fallback_development_dependency_sync_snapshot(desired, lines)
          index = DependencySectionPolicy.dependency_record_index(lines)
          development_dependency_sync_snapshot(desired, index)
        end

        def ast_development_dependency_sync_snapshot(desired, context)
          dependency_index = dependency_node_index(context[:stmt_nodes], context[:blk_param])
          development_dependency_sync_snapshot(desired, dependency_index)
        end

        def development_dependency_sync_snapshot_for(desired, lines:, context: nil)
          return fallback_development_dependency_sync_snapshot(desired, lines) unless context

          ast_development_dependency_sync_snapshot(desired, context)
        end

        def ensure_development_dependencies_ast(content, desired, context:, lines:)
          sync_snapshot = development_dependency_sync_snapshot_for(desired, lines: lines, context: context)
          updated = materialize_development_dependency_sync(content, lines: lines, sync_snapshot: sync_snapshot, context: context)

          finalize_development_dependency_sync(
            content: content,
            desired: desired,
            updated: updated,
          )
        end

        def materialize_development_dependency_sync(content, lines:, sync_snapshot:, context: nil)
          return apply_fallback_development_dependency_sync(lines, sync_snapshot).join unless context

          plans = ast_development_dependency_sync_plans(sync_snapshot, content: content, lines: lines)
          materialize_development_dependency_sync_plans(content, plans)
        end

        def ast_development_dependency_sync_plans(sync_snapshot, content:, lines:)
          plans = ast_replacement_development_dependency_plans(sync_snapshot, content: content)

          ast_missing_development_dependency_plans(
            plans,
            sync_snapshot,
            content: content,
            lines: lines,
          )
        end

        def ast_replacement_development_dependency_plans(sync_snapshot, content:)
          sync_actions = sync_snapshot[:sync_actions]
          ast_development_dependency_replacement_plans(sync_actions, content: content)
        end

        def ast_missing_development_dependency_plans(plans, sync_snapshot, content:, lines:)
          missing_lines = sync_snapshot[:missing_lines]
          add_missing_development_dependency_plans(
            plans,
            content: content,
            lines: lines,
            missing_lines: missing_lines,
          )
        end

        def materialize_development_dependency_sync_plans(content, plans)
          return content if plans.empty?

          merged_content_from_plans(
            content: content,
            plans: plans,
            metadata: {source: :kettle_jem_prism_gemspec, edit: :ensure_development_dependencies},
          )
        end

        def apply_fallback_development_dependency_sync(lines, sync_snapshot)
          updated_lines = apply_fallback_replacement_development_dependency_sync(lines, sync_snapshot)

          apply_fallback_missing_development_dependency_sync(updated_lines, sync_snapshot)
        end

        def apply_fallback_replacement_development_dependency_sync(lines, sync_snapshot)
          sync_actions = sync_snapshot[:sync_actions]
          apply_fallback_development_dependency_replacements(lines, sync_actions)
        end

        def apply_fallback_missing_development_dependency_sync(updated_lines, sync_snapshot)
          missing_lines = sync_snapshot[:missing_lines]
          apply_fallback_missing_development_dependency_insertions(updated_lines, missing_lines)
        end

        def development_dependency_sync_actions(desired, dependency_index)
          Array(desired).map do |gem_name, desired_line|
            development_dependency_sync_action(gem_name, desired_line, dependency_index)
          end
        end

        def development_dependency_sync_action(gem_name, desired_line, dependency_index)
          if dependency_index[:runtime_gems].include?(gem_name)
            {
              action: :skip_runtime,
              gem_name: gem_name,
              desired_line: desired_line,
            }
          else
            dev_record = dependency_index[:development_by_gem][gem_name]

            {
              action: dev_record ? :replace_existing_dev : :insert_missing,
              gem_name: gem_name,
              desired_line: desired_line,
              record: dev_record,
            }
          end
        end

        def development_dependency_missing_lines(sync_actions, indent: "  ")
          Array(sync_actions).filter_map do |action|
            development_dependency_missing_line(action, indent: indent)
          end
        end

        def development_dependency_missing_line(action, indent: "  ")
          return unless action[:action] == :insert_missing

          formatted_dependency_line(action[:desired_line], indent: indent)
        end

        def development_dependency_sync_snapshot(desired, dependency_index, indent: "  ")
          sync_actions = development_dependency_sync_actions(desired, dependency_index)

          development_dependency_sync_snapshot_payload(sync_actions, indent: indent)
        end

        def development_dependency_sync_snapshot_payload(sync_actions, indent: "  ")
          {
            sync_actions: sync_actions,
            missing_lines: development_dependency_missing_lines(sync_actions, indent: indent),
          }
        end

        def ast_development_dependency_replacement_plans(sync_actions, content:)
          development_dependency_replacement_actions(sync_actions).filter_map do |action|
            ast_development_dependency_replacement_plan(action, content: content)
          end
        end

        def ast_development_dependency_replacement_plan(action, content:)
          payload = development_dependency_replacement_payload(action, content: content)
          return unless payload

          build_splice_plan(
            content: content,
            replacement: payload[:replacement_text],
            start_line: payload[:record][:start_line],
            end_line: payload[:record][:end_line],
            metadata: {
              source: :kettle_jem_prism_gemspec,
              edit: :ensure_development_dependency_replace,
              gem_name: payload[:gem_name],
            },
          )
        end

        def apply_fallback_development_dependency_replacements(lines, sync_actions)
          updated_lines = Array(lines).dup

          development_dependency_replacement_actions(sync_actions).each do |action|
            apply_fallback_development_dependency_replacement(updated_lines, action)
          end

          updated_lines
        end

        def apply_fallback_development_dependency_replacement(updated_lines, action)
          payload = development_dependency_replacement_payload(action)
          return unless payload

          updated_lines[payload[:record][:line_index]] = payload[:replacement_text]
        end

        def apply_fallback_missing_development_dependency_insertions(lines, missing_lines)
          updated_lines = Array(lines).dup
          apply_fallback_missing_development_dependency_insertion(updated_lines, missing_lines)
          updated_lines
        end

        def apply_fallback_missing_development_dependency_insertion(updated_lines, missing_lines)
          insertion = development_dependency_insertion_payload(updated_lines, missing_lines)
          return unless insertion

          updated_lines.insert(insertion[:line_index], insertion[:insertion_text])
        end

        def finalize_development_dependency_sync(content:, desired:, updated:)
          desired_content = desired.values.join("\n")

          normalize_dependency_sections(
            updated,
            template_content: desired_content,
            destination_content: content,
            prefer_template: true,
          )
        end

        def bootstrap_development_dependency_seed_content(content, desired)
          out = content.to_s.dup
          out << "\n" unless out.end_with?("\n") || out.empty?
          Array(desired).each do |_gem, line|
            out << line.to_s.strip << "\n"
          end
          out
        end

        def dependency_node_index(stmt_nodes, blk_param)
          DependencySectionPolicy.build_dependency_index(dependency_node_records(stmt_nodes, blk_param))
        end

        def formatted_dependency_line(desired_line, indent: "  ")
          "#{indent}#{desired_line.to_s.strip}\n"
        end

        def add_missing_development_dependency_plans(plans, content:, lines:, missing_lines:)
          insertion = development_dependency_insertion_payload(lines, missing_lines)
          return plans unless insertion

          add_missing_development_dependency_plan(
            plans,
            content: content,
            lines: lines,
            insertion: insertion,
            missing_count: missing_lines.size,
          )
        end

        def add_missing_development_dependency_plan(plans, content:, lines:, insertion:, missing_count:)
          anchor_line = insertion[:line_index] + 1
          insertion_text = insertion[:insertion_text]

          add_anchor_splice_plan(
            plans: plans,
            content: content,
            lines: lines,
            anchor_line: anchor_line,
            insertion_text: insertion_text,
            metadata: {
              source: :kettle_jem_prism_gemspec,
              edit: :ensure_development_dependency_insert,
              inserted_missing_dependencies: missing_count,
            },
          ) do |plan|
            plan.metadata.merge(inserted_missing_dependencies: missing_count)
          end
        end

        def missing_development_dependency_insertion_text(missing_lines)
          Array(missing_lines).join
        end

        def development_dependency_insertion_payload(lines, missing_lines)
          return if missing_lines.empty?

          {
            line_index: DependencySectionPolicy.insertion_line_index(lines),
            insertion_text: missing_development_dependency_insertion_text(missing_lines),
          }
        end

        def development_dependency_replacement_payload(action, content: nil)
          record = development_dependency_replacement_record(action)
          return unless record

          {
            gem_name: action[:gem_name],
            record: record,
            replacement_text: development_dependency_replacement_text(action[:desired_line], record, content: content),
          }
        end

        def development_dependency_replacement_record(action)
          return unless action[:action] == :replace_existing_dev

          action[:record]
        end

        def development_dependency_replacement_actions(sync_actions)
          Array(sync_actions).select do |action|
            development_dependency_replacement_record(action)
          end
        end

        def development_dependency_replacement_indent(record, content: nil)
          if content && record[:start_line]
            content.lines[record[:start_line] - 1].to_s[/^(\s*)/, 1] || ""
          elsif record[:node]
            dependency_indent(record[:node])
          else
            record[:line][/^(\s*)/, 1] || ""
          end
        end

        def development_dependency_replacement_text(desired_line, record, content: nil)
          indent = development_dependency_replacement_indent(record, content: content)

          formatted_dependency_line(desired_line, indent: indent)
        end
      end
    end
  end
end
