# frozen_string_literal: true

require "prism/merge"

module Kettle
  module Jem
    # Prism-based AST merging for templated Ruby files.
    # Handles strategy dispatch for public strategies:
    # - merge
    # - accept_template
    # - keep_destination
    # - raw_copy
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
      RUBY_FILE_TYPES = %i[ruby gemfile appraisals gemspec rakefile].freeze

      module_function

      # Apply a templating strategy to merge source and destination Ruby files
      #
      # @param strategy [Symbol] Merge strategy - :merge, :accept_template, :keep_destination, :raw_copy
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

        return dest_content if strategy == :keep_destination

        configured_type = normalize_file_type(file_type)
        if configured_type && !ruby_file_type?(configured_type)
          raise Kettle::Jem::Error, "Unsupported Ruby merge file_type '#{file_type}' for #{path}."
        end

        detected_type = configured_type || detect_file_type(path)

        result =
          case strategy
          when :accept_template
            # Token-resolved template content wins; no AST merge with destination
            src_content
          when :raw_copy
            # Verbatim template content; should not reach here (handled earlier),
            # but return source unchanged as a safety net
            src_content
          when :merge
            apply_merge(src_content, dest_content, file_type: detected_type)
          else
            raise Kettle::Jem::Error, "Unknown templating strategy '#{strategy}' for #{path}."
          end

        result = ensure_trailing_newline(result)

        # Validate gemfile merges don't produce duplicate gems in blocks
        # with different signatures. When --force is set, fall back to
        # raw template content instead of raising.
        if detected_type == :gemfile
          begin
            PrismGemfile.validate_no_cross_nesting_duplicates(result, src_content, path: path)
          rescue Kettle::Jem::Error => e
            force_val = ENV.fetch("force", "false").to_s.strip
            if force_val.casecmp("true").zero?
              $stderr.puts("[kettle-jem] WARNING: #{e.message}")
              $stderr.puts("[kettle-jem] Falling back to template content for #{path} (--force)")
              result = ensure_trailing_newline(src_content)
            else
              raise
            end
          end
        end

        result
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

      def normalize_file_type(file_type)
        return nil if file_type.nil?

        file_type.to_s.downcase.strip.tr("-", "_").to_sym
      end

      def ruby_file_type?(file_type)
        RUBY_FILE_TYPES.include?(normalize_file_type(file_type))
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


      # @param strategy [Symbol, String, nil] Strategy to normalize
      # @return [Symbol] Normalized strategy (:merge if nil)
      def normalize_strategy(strategy)
        return :merge if strategy.nil?
        strategy.to_s.downcase.strip.to_sym
      end

      # Ensure text ends with exactly one newline
      #
      # @param text [String, nil] Text to process
      # @return [String] Text with trailing newline (empty string if nil)
      def ensure_trailing_newline(text)
        str = text.to_s
        return str if str.empty?
        str.end_with?("\n") ? str : str + "\n"
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
