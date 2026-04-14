# frozen_string_literal: true

require "ruby-progress"

module Kettle
  module Jem
    # Emits a persistent, transcript-friendly progress line as templating phases complete.
    class TemplateProgress
      DEFAULT_STYLE = :bars
      EMOJI = "⏳"

      def initialize(total_steps:, cli_io: $stdout, enabled: true, style: DEFAULT_STYLE)
        @total_steps = [Integer(total_steps), 1].max
        @cli_io = cli_io
        @enabled = enabled
        @current_step = 0
        @style = resolve_style(style)
      end

      def start!
        return unless enabled?

        emit_line
      end

      def advance!(label: nil)
        return unless enabled?

        @current_step = [@current_step + 1, @total_steps].min
        emit_line(label: label)
      end

      def stop!
        nil
      end

      private

      def enabled?
        @enabled
      end

      def emit_line(label: nil)
        suffix = label ? " - #{label}" : ""
        @cli_io.puts("[kettle-jem] #{EMOJI}  Progress - #{bar} #{progress_fraction}#{suffix}")
      end

      def bar
        filled = @style.fetch(:full) * @current_step
        empty = @style.fetch(:empty) * (@total_steps - @current_step)
        "#{filled}#{empty}"
      end

      def progress_fraction
        "#{@current_step}/#{@total_steps}"
      end

      def resolve_style(style)
        RubyProgress::Fill::FILL_STYLES.fetch(style.to_sym, RubyProgress::Fill::FILL_STYLES.fetch(DEFAULT_STYLE))
      end
    end
  end
end
