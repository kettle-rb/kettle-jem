# frozen_string_literal: true

module Kettle
  module Jem
    module DuplicateLineValidator
      module_function

      DEFAULT_MIN_CHARS = Kettle::Drift::DuplicateLineValidator::DEFAULT_MIN_CHARS

      def scan(...)
        Kettle::Drift::DuplicateLineValidator.scan(...)
      end

      def scan_template_results(...)
        Kettle::Drift::DuplicateLineValidator.scan_template_results(...)
      end

      def warning_count(...)
        Kettle::Drift::DuplicateLineValidator.warning_count(...)
      end

      def subtract_baseline(...)
        Kettle::Drift::DuplicateLineValidator.subtract_baseline(...)
      end

      def to_json(...)
        Kettle::Drift::DuplicateLineValidator.to_json(...)
      end

      def write_json(...)
        Kettle::Drift::DuplicateLineValidator.write_json(...)
      end

      def report_summary(...)
        Kettle::Drift::DuplicateLineValidator.report_summary(...)
      end

      def baseline(template_dir: nil, min_chars: DEFAULT_MIN_CHARS)
        template_dir ||= kettle_template_dir
        Kettle::Drift::DuplicateLineValidator.baseline(template_dir: template_dir, min_chars: min_chars)
      end

      def template_managed_files(project_root:, template_dir: nil)
        template_dir ||= kettle_template_dir
        Kettle::Drift::DuplicateLineValidator.template_managed_files(
          project_root: project_root,
          template_dir: template_dir,
        )
      end

      def kettle_template_dir
        File.expand_path("../../../template", __dir__)
      end
    end
  end
end
