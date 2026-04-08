# frozen_string_literal: true

module Kettle
  module Jem
    module Phases
      # Tracks per-phase file statistics by snapshotting template_results
      # before and after a phase runs, and using git to distinguish
      # identical from changed pre-existing files.
      #
      # Counts:
      #   📄 templates  — total template source files processed in this phase
      #   🆕 created    — destination files that did not exist before
      #   📋 pre-existing — destination files that already existed
      #   🟰 identical  — pre-existing files whose content was unchanged
      #   ✏️  changed    — pre-existing files whose content was modified
      class PhaseStats
        EMOJI = {
          templates: "📄",
          created: "🆕",
          pre_existing: "📋",
          identical: "🟰",
          changed: "✏️",
        }.freeze

        attr_reader :templates, :created, :pre_existing, :identical, :changed

        def initialize
          @templates = 0
          @created = 0
          @pre_existing = 0
          @identical = 0
          @changed = 0
          @before_keys = nil
          @project_root = nil
        end

        # Call before the phase body executes.
        # Snapshots current template_results keys and git dirty set.
        #
        # @param helpers [Module] TemplateHelpers module
        # @param project_root [String] absolute path to project root
        def snapshot_before!(helpers, project_root)
          @project_root = project_root
          @before_keys = helpers.template_results.keys.to_set
          @git_dirty_before = git_modified_files(project_root)
        end

        # Call after the phase body executes.
        # Computes all five stats from the diff between snapshots.
        #
        # @param helpers [Module] TemplateHelpers module
        def snapshot_after!(helpers)
          after_results = helpers.template_results
          new_keys = after_results.keys.to_set - @before_keys

          new_keys.each do |path|
            record = after_results[path]
            next unless record

            action = record[:action]
            # :skip means the file was not processed (filtered out, declined, etc.)
            next if action == :skip

            @templates += 1

            case action
            when :create, :dir_create
              @created += 1
            when :replace, :dir_replace
              @pre_existing += 1
              if file_changed_by_git?(path)
                @changed += 1
              else
                @identical += 1
              end
            end
          end
        end

        # Format stats for display on a phase summary line.
        # Returns nil when no templates were processed (avoids empty parens).
        #
        # @return [String, nil]
        def to_s
          return nil if @templates.zero?

          parts = [
            "#{EMOJI[:templates]} #{@templates}",
            "#{EMOJI[:created]} #{@created}",
            "#{EMOJI[:pre_existing]} #{@pre_existing}",
            "#{EMOJI[:identical]} #{@identical}",
            "#{EMOJI[:changed]} #{@changed}",
          ]
          parts.join(" ")
        end

        # @return [Boolean] true if any templates were processed
        def any?
          @templates > 0
        end

        private

        # Returns the set of files git considers modified (dirty) relative to HEAD.
        #
        # @param project_root [String]
        # @return [Set<String>] absolute paths of modified files
        def git_modified_files(project_root)
          output = `git -C #{Shellwords.escape(project_root)} diff --name-only 2>/dev/null`.strip
          output.split("\n").map { |rel| File.expand_path(rel, project_root) }.to_set
        rescue StandardError
          Set.new
        end

        # Checks whether a file was modified by this phase by comparing
        # git status before and after.
        #
        # @param path [String] absolute path
        # @return [Boolean]
        def file_changed_by_git?(path)
          return true unless @project_root

          current_dirty = git_modified_files(@project_root)
          # File is changed if it's now dirty but wasn't before
          current_dirty.include?(path) && !@git_dirty_before.include?(path)
        end
      end
    end
  end
end
