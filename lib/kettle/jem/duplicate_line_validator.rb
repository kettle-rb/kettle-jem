# frozen_string_literal: true

require "json"
require "fileutils"
require "set"

module Kettle
  module Jem
    # Scans templated files for intra-file duplicate lines.
    #
    # Duplicate lines within a single file often indicate corruption from a
    # merge gone wrong — e.g. a YAML block appended twice, or a gemspec
    # attribute block doubled. This validator flags those cases.
    #
    # @example Standalone usage
    #   results = DuplicateLineValidator.scan(
    #     files: ["/path/to/file1.rb", "/path/to/file2.gemspec"],
    #     min_chars: 6,
    #   )
    #   DuplicateLineValidator.write_json(results, "/path/to/report.json")
    #
    # @example From template_results
    #   results = DuplicateLineValidator.scan_template_results(
    #     template_results: helpers.template_results,
    #     min_chars: 6,
    #   )
    module DuplicateLineValidator
      module_function

      # Default minimum non-whitespace characters for a line to be considered.
      DEFAULT_MIN_CHARS = 6

      # Scan a list of files for intra-file duplicate lines.
      #
      # Only lines with more than +min_chars+ non-whitespace characters are
      # considered. Results are keyed by the stripped line content; each entry
      # lists every file+line-number pair where that content appears more than
      # once in the same file.
      #
      # @param files [Array<String>] absolute paths to scan
      # @param min_chars [Integer] minimum non-whitespace character count
      # @return [Hash{String => Array<Hash>}] keyed by line content;
      #   values are arrays of `{ file:, lines: [Integer] }` hashes
      def scan(files:, min_chars: DEFAULT_MIN_CHARS)
        duplicates = {}

        files.each do |path|
          next unless File.file?(path)

          begin
            content = File.read(path)
          rescue StandardError
            next
          end

          # Build a map of line content → [line_numbers]
          line_map = Hash.new { |h, k| h[k] = [] }
          content.each_line.with_index(1) do |raw_line, lineno|
            stripped = raw_line.strip
            # Only consider lines with enough non-whitespace substance
            next if stripped.gsub(/\s/, "").length <= min_chars

            line_map[stripped] << lineno
          end

          # Keep only lines that appear more than once in this file
          line_map.each do |line_content, line_numbers|
            next if line_numbers.size < 2

            duplicates[line_content] ||= []
            duplicates[line_content] << {
              file: path,
              lines: line_numbers,
            }
          end
        end

        duplicates
      end

      # Convenience wrapper: scan files from a template_results hash.
      #
      # Only files with +:create+ or +:replace+ actions are scanned (i.e.,
      # files actually written by the template run).
      #
      # @param template_results [Hash] from TemplateHelpers#template_results
      # @param min_chars [Integer] minimum non-whitespace character count
      # @return [Hash] same shape as {scan}
      def scan_template_results(template_results:, min_chars: DEFAULT_MIN_CHARS)
        written_files = template_results.select do |_path, rec|
          %i[create replace].include?(rec[:action])
        end.keys

        scan(files: written_files, min_chars: min_chars)
      end

      # Scan the template directory itself to build a baseline of expected
      # duplicate lines. Any line that is already duplicated within a template
      # source file is considered intentional and should not be flagged when
      # that same duplication appears in a destination project.
      #
      # The baseline is a +Set+ of stripped line contents — if a line appears
      # in this set it means the template itself contains that duplicate and
      # the destination is simply mirroring template structure.
      #
      # @param template_dir [String, nil] override for the template directory
      # @param min_chars [Integer] minimum non-whitespace character count
      # @return [Set<String>] line contents that are duplicated in the template
      def baseline(template_dir: nil, min_chars: DEFAULT_MIN_CHARS)
        template_dir ||= File.expand_path("../../../template", __dir__)
        return Set.new unless File.directory?(template_dir)

        template_files = Dir.glob(
          File.join(template_dir, "**", "*"),
          File::FNM_DOTMATCH,
        ).select { |f| File.file?(f) }

        template_dups = scan(files: template_files, min_chars: min_chars)
        Set.new(template_dups.keys)
      end

      # Remove baseline (expected) duplicates from a results hash.
      #
      # @param results [Hash] output from {scan}
      # @param baseline_set [Set<String>] from {baseline}
      # @return [Hash] filtered results with baseline entries removed
      def subtract_baseline(results, baseline_set:)
        results.reject { |line_content, _| baseline_set.include?(line_content) }
      end

      # Resolve the set of template-managed file paths that exist in a project.
      #
      # Derives the file list from the kettle-jem template directory: each
      # template file (stripped of +.example+ suffix) maps to a destination
      # path under +project_root+. Only paths that exist on disk are returned.
      #
      # @param project_root [String] absolute path to the target project
      # @param template_dir [String, nil] override for the template directory
      #   (defaults to the gem's built-in template/ directory)
      # @return [Array<String>] absolute paths of existing template-managed files
      def template_managed_files(project_root:, template_dir: nil)
        template_dir ||= File.expand_path("../../../template", __dir__)
        return [] unless File.directory?(template_dir)

        managed = []
        Dir.glob(File.join(template_dir, "**", "*"), File::FNM_DOTMATCH).each do |src|
          next unless File.file?(src)

          rel = src.sub(%r{^#{Regexp.escape(template_dir)}/?}, "")
          # Strip .example suffix to get the destination filename
          rel = rel.sub(/\.example\z/, "")
          # Skip .no-osc variants (they map to the same destination as the primary)
          next if rel.include?(".no-osc")

          dest = File.join(project_root, rel)
          managed << dest if File.file?(dest)
        end

        managed.uniq
      end

      # Total number of duplicate warnings (one per duplicated line per file).
      #
      # @param results [Hash] output from {scan}
      # @return [Integer]
      def warning_count(results)
        results.values.flatten.size
      end

      # Serialize results to JSON.
      #
      # @param results [Hash] output from {scan}
      # @return [String] JSON string
      def to_json(results)
        JSON.pretty_generate(results.transform_values do |entries|
          entries.map { |e| {file: e[:file], lines: e[:lines]} }
        end)
      end

      # Write results to a JSON file alongside the markdown report.
      #
      # @param results [Hash] output from {scan}
      # @param json_path [String] absolute path for the JSON file
      # @return [String] the path written
      def write_json(results, json_path)
        FileUtils.mkdir_p(File.dirname(json_path))
        File.write(json_path, to_json(results))
        json_path
      end

      # Format a summary suitable for report file inclusion.
      #
      # @param results [Hash] output from {scan}
      # @param project_root [String, nil] strip this prefix from file paths for readability
      # @return [String] markdown-formatted summary
      def report_summary(results, project_root: nil)
        return "No duplicate lines detected.\n" if results.empty?

        lines = ["### Duplicate Line Report\n"]
        lines << "| Line Content | File | Line Numbers |"
        lines << "|---|---|---|"

        results.each do |content, entries|
          # Truncate very long lines for readability
          display = content.length > 80 ? "#{content[0, 77]}..." : content
          # Escape pipes for markdown table
          display = display.gsub("|", "\\|")

          entries.each do |entry|
            file = entry[:file]
            file = file.sub(%r{^#{Regexp.escape(project_root)}/?}, "") if project_root
            lines << "| `#{display}` | #{file} | #{entry[:lines].join(", ")} |"
          end
        end

        lines << ""
        lines.join("\n")
      end
    end
  end
end
