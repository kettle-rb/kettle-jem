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
      SUPPORTED_PREFERENCES = %i[template destination].freeze

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
      def apply(strategy:, src:, dest:, path:, file_type: nil, context: nil, **options)
        strategy = normalize_strategy(strategy)
        dest ||= ""
        src_content = src.to_s
        dest_content = dest
        merge_options = normalize_merge_options(options)

        return dest_content if strategy == :keep_destination

        configured_type = normalize_file_type(file_type)
        if configured_type && !ruby_file_type?(configured_type)
          raise Kettle::Jem::Error, "Unsupported Ruby merge file_type '#{file_type}' for #{path}."
        end

        detected_type = configured_type || detect_file_type(path)

        result =
          case strategy
          when :accept_template
            if detected_type == :gemspec && context
              PrismGemspec.merge(src_content, "", context: context)
            else
              # Token-resolved template content wins; no AST merge with destination
              src_content
            end
          when :raw_copy
            # Verbatim template content; should not reach here (handled earlier),
            # but return source unchanged as a safety net
            src_content
          when :merge
            apply_merge(
              src_content,
              dest_content,
              file_type: detected_type,
              context: context,
              path: path,
              **merge_options,
            )
          else
            raise Kettle::Jem::Error, "Unknown templating strategy '#{strategy}' for #{path}."
          end

        result = ensure_trailing_newline(result)

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
        return if file_type.nil?

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
      def config_for_file_type(file_type, preference:, add_template_only_nodes: nil, freeze_token: FREEZE_TOKEN)
        preset_class = preset_for(file_type)

        return preset_class.template_wins(freeze_token: freeze_token) if preference == :template && add_template_only_nodes.nil?
        return preset_class.destination_wins(freeze_token: freeze_token) if preference == :destination && add_template_only_nodes.nil?

        preset_class.custom(
          preference: preference,
          add_template_only: add_template_only_nodes.nil? ? (preference == :template) : add_template_only_nodes,
          freeze_token: freeze_token,
        )
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
      def apply_merge(src_content, dest_content, file_type: :ruby, context: nil, path: nil, **options)
        if file_type == :appraisals
          appraisals_options = options.dup
          appraisals_options[:context] = context if context
          return PrismAppraisals.merge(src_content, dest_content, **appraisals_options)
        end

        if file_type == :gemspec
          gemspec_options = options.dup
          gemspec_options[:context] = context if context
          return PrismGemspec.merge(src_content, dest_content, **gemspec_options)
        end

        config = merger_options_for(file_type, **options)

        if file_type == :gemfile
          gemfile_options = config.to_h.dup
          gemfile_options.delete(:signature_generator)

          return PrismGemfile.merge(
            src_content,
            dest_content,
            merger_options: gemfile_options,
            filter_template: false,
            path: path || "Gemfile",
            force: options.fetch(:force, false),
          )
        end

        merger = Prism::Merge::SmartMerger.new(
          src_content,
          dest_content,
          **config.to_h,
        )
        merger.merge
      end

      def merger_options_for(file_type, **options)
        config = config_for_file_type(
          file_type,
          preference: normalize_preference_option(options[:preference]) || :template,
          add_template_only_nodes: normalize_boolean_option(options[:add_template_only_nodes]),
          freeze_token: normalize_string_option(options[:freeze_token]) || FREEZE_TOKEN,
        )

        merger_options = config.to_h
        max_recursion_depth = normalize_integer_option(options[:max_recursion_depth])
        merger_options[:max_recursion_depth] = max_recursion_depth unless max_recursion_depth.nil?
        merger_options
      end

      def normalize_merge_options(options)
        {
          preference: normalize_preference_option(options[:preference]),
          add_template_only_nodes: normalize_boolean_option(options[:add_template_only_nodes]),
          freeze_token: normalize_string_option(options[:freeze_token]),
          max_recursion_depth: normalize_integer_option(options[:max_recursion_depth]),
          force: normalize_boolean_option(options[:force]),
        }.reject { |_, value| value.nil? }
      end

      def normalize_preference_option(preference)
        return if preference.nil?
        return preference if preference.is_a?(Hash)

        normalized = preference.to_s.downcase.strip.tr("-", "_").to_sym
        return normalized if SUPPORTED_PREFERENCES.include?(normalized)

        raise Kettle::Jem::Error, "Unknown merge preference '#{preference}'"
      end

      def normalize_boolean_option(value)
        return if value.nil?
        return value if value == true || value == false

        normalized = value.to_s.strip.downcase
        return true if %w[1 true yes y].include?(normalized)
        return false if %w[0 false no n].include?(normalized)

        value
      end

      def normalize_string_option(value)
        return if value.nil?

        normalized = value.to_s.strip
        normalized.empty? ? nil : normalized
      end

      def normalize_integer_option(value)
        return if value.nil?
        return value if value.is_a?(Integer)

        normalized = value.to_s.strip
        return if normalized.empty?

        Integer(normalized, 10)
      rescue ArgumentError, TypeError
        value
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
