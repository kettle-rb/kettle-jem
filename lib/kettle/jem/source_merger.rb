# frozen_string_literal: true

require "prism/merge"

module Kettle
  module Jem
    # Prism-based AST merging for templated Ruby files.
    # Handles strategy dispatch (skip/replace/append/merge).
    #
    # Uses prism-merge for AST-aware merging with support for:
    # - Freeze blocks (kettle-jem:freeze / kettle-jem:unfreeze)
    # - Comment preservation
    # - Signature-based node matching
    #
    # @see Kettle::Jem::Presets for MergerConfig presets
    module SourceMerger
      BUG_URL = "https://github.com/kettle-rb/kettle-jem/issues"
      FREEZE_TOKEN = "kettle-jem"

      module_function

      # Apply a templating strategy to merge source and destination Ruby files
      #
      # @param strategy [Symbol] Merge strategy - :skip, :replace, :append, or :merge
      # @param src [String] Template source content
      # @param dest [String] Destination file content
      # @param path [String] File path (for error messages)
      # @param file_type [Symbol, nil] File type hint (:gemfile, :appraisals, :gemspec, :rakefile, nil)
      # @return [String] Merged content with comments preserved
      # @raise [Kettle::Jem::Error] If strategy is unknown or merge fails
      def apply(strategy:, src:, dest:, path:, file_type: nil)
        strategy = normalize_strategy(strategy)
        dest ||= ""
        src_content = src.to_s
        dest_content = dest
        detected_type = file_type || detect_file_type(path)

        result =
          case strategy
          when :skip
            apply_merge(src_content, dest_content, file_type: detected_type)
          when :replace
            apply_merge(src_content, dest_content, file_type: detected_type)
          when :append
            apply_append(src_content, dest_content, file_type: detected_type)
          when :merge
            apply_merge(src_content, dest_content, file_type: detected_type)
          else
            raise Kettle::Jem::Error, "Unknown templating strategy '#{strategy}' for #{path}."
          end

        ensure_trailing_newline(result)
      end

      # Detect file type from path for preset selection.
      #
      # @param path [String] File path
      # @return [Symbol] File type (:gemfile, :appraisals, :gemspec, :rakefile, or :ruby)
      def detect_file_type(path)
        basename = File.basename(path.to_s)
        case basename
        when /\AGemfile/, /\.gemfile\z/
          :gemfile
        when /\AAppraisals/
          :appraisals
        when /\.gemspec\z/
          :gemspec
        when /\ARakefile/, /\.rake\z/
          :rakefile
        else
          :ruby
        end
      end

      # Get the appropriate MergerConfig preset for a file type.
      #
      # @param file_type [Symbol] File type
      # @param preference [Symbol] :template or :destination
      # @return [Ast::Merge::MergerConfig] The config preset
      def config_for_file_type(file_type, preference:)
        preset_class = preset_for(file_type)

        if preference == :template
          preset_class.template_wins(freeze_token: FREEZE_TOKEN)
        else
          preset_class.destination_wins(freeze_token: FREEZE_TOKEN)
        end
      end

      # Get the appropriate MergerConfig preset for append strategy.
      #
      # @param file_type [Symbol] File type
      # @return [Ast::Merge::MergerConfig] The config preset
      def config_for_file_type_append(file_type)
        preset_class = preset_for(file_type)

        preset_class.custom(
          preference: :destination,
          add_template_only: true,
          freeze_token: FREEZE_TOKEN,
        )
      end

      # @param strategy [Symbol, String, nil] Strategy to normalize
      # @return [Symbol] Normalized strategy (:skip if nil)
      def normalize_strategy(strategy)
        return :skip if strategy.nil?
        strategy.to_s.downcase.strip.to_sym
      end

      # Ensure text ends with exactly one newline
      #
      # @param text [String, nil] Text to process
      # @return [String] Text with trailing newline (empty string if nil)
      def ensure_trailing_newline(text)
        return "" if text.nil?
        text.end_with?("\n") ? text : text + "\n"
      end

      # Apply append strategy using prism-merge
      #
      # @param src_content [String] Template source content
      # @param dest_content [String] Destination content
      # @param file_type [Symbol] File type for preset selection
      # @return [String] Merged content
      def apply_append(src_content, dest_content, file_type: :ruby)
        config = config_for_file_type_append(file_type)

        merger = Prism::Merge::SmartMerger.new(
          src_content,
          dest_content,
          **config.to_h,
        )
        merger.merge
      end

      # Apply merge strategy using prism-merge
      #
      # @param src_content [String] Template source content
      # @param dest_content [String] Destination content
      # @param file_type [Symbol] File type for preset selection
      # @return [String] Merged content
      def apply_merge(src_content, dest_content, file_type: :ruby)
        config = config_for_file_type(file_type, preference: :template)

        merger = Prism::Merge::SmartMerger.new(
          src_content,
          dest_content,
          **config.to_h,
        )
        merger.merge
      end

      # @param file_type [Symbol]
      # @return [Class] Preset class
      def preset_for(file_type)
        case file_type
        when :gemfile then Kettle::Jem::Presets::Gemfile
        when :appraisals then Kettle::Jem::Presets::Appraisals
        when :gemspec then Kettle::Jem::Presets::Gemspec
        when :rakefile then Kettle::Jem::Presets::Rakefile
        else Kettle::Jem::Presets::Gemfile
        end
      end
    end
  end
end
