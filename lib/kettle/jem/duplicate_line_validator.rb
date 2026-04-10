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

      # Appraisals dependency declaration lines (eval_gemfile or gem).  Multiple
      # appraisal blocks legitimately share the same dependency lines and
      # consecutive pairs of them are therefore not corruption signals.
      APPRAISALS_DEP_LINE_RE = /\A(?:eval_gemfile|gem)\s+["']/.freeze

      # Auto-generated coverage metric lines produced by kettle-changelog.
      # These repeat verbatim across CHANGELOG releases when coverage stays
      # stable and are therefore not corruption signals.
      CHANGELOG_METRIC_RE = /\A-\s+(?:(?:(?:line|branch)\s+)?coverage:|\d+\.\d+%\s+documented)/i.freeze

      # Files excluded entirely from duplicate detection.
      EXCLUDED_FILENAMES = Set.new(["CODE_OF_CONDUCT.md"]).freeze

      # Consecutive ENV assignment lines in Rakefiles.  Each named SimpleCov
      # task block sets the same ENV vars as part of its setup, so repeated
      # pairs are structural and not a corruption signal.
      RAKEFILE_ENV_ASSIGNMENT_RE = /\AENV\[["']/.freeze

      # rescue LoadError followed by # :nocov: is a template pattern for
      # optional gem loading blocks.  It repeats in every such block and is
      # structural, not a corruption signal.
      RESCUE_LOAD_ERROR_RE = /\Arescue\s+LoadError/.freeze
      NOCOV_MARKER_RE = /\A# :nocov:\z/.freeze

      # Standard keepachangelog.com release subheadings that repeat in every
      # release section.  These are always exempt from duplicate detection
      # because changelogs grow indefinitely and would otherwise produce an
      # ever-increasing number of false positives.
      CHANGELOG_SUBHEADINGS = Set.new([
        "### Added",
        "### Changed",
        "### Deprecated",
        "### Removed",
        "### Fixed",
        "### Security",
      ]).freeze

      # Scan a list of files for intra-file duplicate consecutive-line pairs.
      #
      # A sliding 2-line window moves through each file. Any pair of adjacent
      # lines (a "chunk") that appears at two or more distinct positions within
      # the same file is reported. Both lines of the pair must individually
      # exceed +min_chars+ non-whitespace characters to be considered.
      #
      # Keying on 2-line chunks instead of single lines dramatically reduces
      # false positives: a single word like "end" or a YAML key appearing
      # multiple times is not flagged unless its *successor* line also repeats
      # in the same context — a far stronger signal of actual corruption.
      #
      # Results are keyed by the chunk content ("line1\nline2"); each entry
      # lists every file + start-line pair where that chunk recurs.
      #
      # @param files [Array<String>] absolute paths to scan
      # @param min_chars [Integer] minimum non-whitespace character count
      # @return [Hash{String => Array<Hash>}] keyed by chunk content;
      #   values are arrays of `{ file:, lines: [Integer] }` hashes where
      #   +lines+ are the start line numbers of each repeated chunk occurrence
      def scan(files:, min_chars: DEFAULT_MIN_CHARS)
        duplicates = {}

        files.each do |path|
          next unless File.file?(path)
          next if EXCLUDED_FILENAMES.include?(File.basename(path.to_s))

          begin
            content = File.read(path)
          rescue StandardError
            next
          end

          fence_lines = (File.extname(path.to_s) == ".md") ? compute_fence_lines(content) : Set.new

          indexed = content.each_line.map.with_index(1) { |raw, n| [n, raw.strip] }

          chunk_map = Hash.new { |h, k| h[k] = [] }
          indexed.each_cons(2) do |(lineno1, line1), (lineno2, line2)|
            next if line1.gsub(/\s/, "").length <= min_chars
            next if line2.gsub(/\s/, "").length <= min_chars
            next if CHANGELOG_SUBHEADINGS.include?(line1)
            next if fence_lines.include?(lineno1) && fence_lines.include?(lineno2)
            next if ignored_duplicate_chunk?(path, line1, line2)

            chunk_map["#{line1}\n#{line2}"] << lineno1
          end

          chunk_map.each do |chunk_content, start_lines|
            next if start_lines.size < 2

            duplicates[chunk_content] ||= []
            duplicates[chunk_content] << {
              file: path,
              lines: start_lines,
            }
          end
        end

        duplicates
      end

      # Return +true+ to suppress a specific 2-line chunk from duplicate
      # detection.
      #
      # Built-in exclusions:
      # - Consecutive dependency declaration lines (+eval_gemfile+ or +gem+) in
      #   Appraisals files — different appraisal blocks legitimately share the
      #   same gemfile and gem lines, so repeated pairs are structural.
      # - Auto-generated coverage metric lines in CHANGELOG.md — both lines of
      #   the pair must match {CHANGELOG_METRIC_RE}.
      # - Consecutive +ENV+ assignment lines in Rakefiles — each named task
      #   block sets the same ENV vars as setup boilerplate.
      # - +rescue LoadError+ followed by +# :nocov:+ — template pattern for
      #   optional gem loading blocks that repeats in any Ruby file.
      #
      # @param path [String] path of the file being scanned
      # @param line1 [String] first stripped line of the chunk
      # @param line2 [String] second stripped line of the chunk
      # @return [Boolean]
      def ignored_duplicate_chunk?(path, line1, line2)
        basename = File.basename(path.to_s)

        if basename == "Appraisals"
          return true if APPRAISALS_DEP_LINE_RE.match?(line1) && APPRAISALS_DEP_LINE_RE.match?(line2)
          # Comment line immediately before a dep declaration repeats in every
          # appraisal block that uses the same gemfile — structural, not corruption.
          return true if line1.start_with?("#") && APPRAISALS_DEP_LINE_RE.match?(line2)
        end

        if basename == "CHANGELOG.md"
          return true if CHANGELOG_METRIC_RE.match?(line1) && CHANGELOG_METRIC_RE.match?(line2)
        end

        if basename == "Rakefile"
          return true if RAKEFILE_ENV_ASSIGNMENT_RE.match?(line1) && RAKEFILE_ENV_ASSIGNMENT_RE.match?(line2)
        end

        return true if RESCUE_LOAD_ERROR_RE.match?(line1) && NOCOV_MARKER_RE.match?(line2)

        # Markdown table rows: header + separator (or any two | ... | rows) repeat
        # across multiple documentation tables with the same column structure.
        if File.extname(path.to_s) == ".md"
          return true if line1.start_with?("|") && line2.start_with?("|")
        end

        false
      end

      # Compute the set of 1-based line numbers that fall inside fenced code
      # blocks in a markdown file (including the opening and closing fence lines
      # themselves).  Used by {scan} to suppress duplicate-chunk detection for
      # content that is intentionally repeated across code examples.
      #
      # Handles both backtick (```) and tilde (~~~) fences of any width ≥ 3.
      #
      # @param content [String] full file content
      # @return [Set<Integer>] line numbers inside code fences
      def compute_fence_lines(content)
        in_fence = false
        fence_marker = nil
        fence_lines = Set.new
        content.each_line.with_index(1) do |raw, lineno|
          stripped = raw.strip
          if in_fence
            fence_lines.add(lineno)
            if stripped.match?(/\A#{Regexp.escape(fence_marker)}\s*\z/)
              in_fence = false
              fence_marker = nil
            end
          elsif (m = stripped.match(/\A(`{3,}|~{3,})/))
            fence_marker = m[1]
            in_fence = true
            fence_lines.add(lineno)
          end
        end
        fence_lines
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
        lines << "| Chunk (line1 ↵ line2) | File | Start Lines |"
        lines << "|---|---|---|"

        results.each do |content, entries|
          # Render the 2-line chunk as a single readable string
          display = content.gsub("\n", " ↵ ")
          # Truncate very long lines for readability
          display = (display.length > 80) ? "#{display[0, 77]}..." : display
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
