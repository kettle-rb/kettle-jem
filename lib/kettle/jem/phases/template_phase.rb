# frozen_string_literal: true

require "service_actor"
require "shellwords"

require_relative "phase_context"
require_relative "phase_stats"

module Kettle
  module Jem
    module Phases
      # Abstract base actor for template phases.
      #
      # Subclasses must implement +perform+ (the phase body) and define
      # +PHASE_EMOJI+, +PHASE_NAME+, and optionally +PHASE_DETAIL+.
      #
      # Lifecycle:
      #   1. snapshot_before! — captures template_results + git state
      #   2. perform          — subclass phase logic
      #   3. snapshot_after!  — computes stats from diff
      #   4. emit phase line  — prints summary with stats to CLI/report
      #
      # @example
      #   class ConfigSync < TemplatePhase
      #     PHASE_EMOJI = "⚙️"
      #     PHASE_NAME  = "Config sync"
      #     PHASE_DETAIL = ".kettle-jem.yml"
      #
      #     def perform
      #       # ... phase logic using context.helpers, context.out, etc.
      #     end
      #   end
      class TemplatePhase < Actor
        input :context, type: PhaseContext
        output :phase_stats, type: PhaseStats, default: -> { PhaseStats.new }, allow_nil: true

        def call
          self.phase_stats = PhaseStats.new
          phase_stats.snapshot_before!(context.helpers, context.project_root)

          run_phase_hooks(:before)
          perform
        rescue Kettle::Dev::Error
          raise # Re-raise intentional task aborts
        rescue StandardError => e
          Kettle::Dev.debug_error(e, self.class.name)
          context.out.warning("#{phase_name} failed: #{e.class}: #{e.message}")
        ensure
          run_phase_hooks(:after)
          phase_stats.snapshot_after!(context.helpers)
          emit_phase_line
        end

        private

        # Subclasses implement their phase logic here.
        def perform
          raise NotImplementedError, "#{self.class}#perform must be implemented"
        end

        # Emit the phase summary line with inline stats (after execution).
        # Stats are appended in parentheses when files were processed.
        def emit_phase_line
          detail = phase_detail
          stats_str = phase_stats.to_s
          full_detail = if detail && stats_str
            "#{detail} (#{stats_str})"
          elsif stats_str
            "(#{stats_str})"
          else
            detail
          end
          context.out.phase(phase_emoji, phase_name, detail: full_detail)
        end

        # @return [String] emoji for this phase
        def phase_emoji
          self.class::PHASE_EMOJI
        end

        # @return [String] human-readable phase name
        def phase_name
          self.class::PHASE_NAME
        end

        # @return [String, nil] optional detail string (path, etc.)
        def phase_detail
          self.class.const_defined?(:PHASE_DETAIL) ? self.class::PHASE_DETAIL : nil
        end

        def phase_key
          self.class.name.split("::").last
            .gsub(/([a-z0-9])([A-Z])/, '\1_\2')
            .downcase
            .to_sym
        end

        def run_phase_hooks(timing)
          context.plugins&.run(
            timing: timing,
            phase: phase_key,
            context: context,
            actor: self,
            phase_stats: phase_stats,
          )
        rescue StandardError => e
          Kettle::Dev.debug_error(e, self.class.name)
          context.out.warning("#{phase_name} plugin hook failed: #{e.class}: #{e.message}")
        end
      end
    end
  end
end
