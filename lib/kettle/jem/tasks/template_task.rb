# frozen_string_literal: true

require "yaml"
require "set"
require "find"

require_relative "../template_output"
require_relative "../template_progress"
require_relative "../template_checksums"
require_relative "../duplicate_line_validator"
require_relative "../phases"

module Kettle
  module Jem
    module Tasks
      # Thin wrapper to expose the kettle:jem:template task logic as a callable API
      # for testability. The rake task should only call this method.
      module TemplateTask
        MODULAR_GEMFILE_DIR = "gemfiles/modular"
        MARKDOWN_HEADING_EXTENSIONS = %w[.md .markdown].freeze
        OBSOLETE_WORKFLOWS = %w[ancient.yml legacy.yml supported.yml unsupported.yml main.yml hoary.yml].freeze

        # Matches a +spec.authors = [...]+ assignment on a single line.
        # Capture group 1: everything up to and including the opening +[+
        # (preserving indentation and the block-param variable name).
        # Capture group 2: anything after the closing +]+ (e.g. a comment).
        GEMSPEC_AUTHORS_RE = /^(\s*\w+\.authors\s*=\s*)\[.*?\](.*)/

        # Extracts the human name from a bare copyright line:
        #   "Copyright (c) 2024-2026 Jane Contributor" => "Jane Contributor"
        # Years may be a single year, a hyphenated range, or a comma-separated list.
        COPYRIGHT_NAME_RE = /\ACopyright \(c\) [\d,\s\-]+ (.+)\z/

        # Markdown basenames that live in template/ as *.md.example but are NOT
        # SPDX license files.  Used to distinguish license files from other
        # template-managed markdown documents when pruning obsolete licenses.
        NON_LICENSE_MD_BASENAMES = %w[
          AGENTS CHANGELOG CODE_OF_CONDUCT CONTRIBUTING FUNDING LICENSE README RUBOCOP SECURITY
        ].to_set.freeze
        MARKDOWN_PARAGRAPH_BASE_REFINER = Ast::Merge::ContentMatchRefiner.new(
          threshold: 0.3,
          node_types: [:paragraph],
        )
        MARKDOWN_LABEL_STYLE_PARAGRAPH_RE = /\A.{1,120}:\z/m
        MARKDOWN_MATCH_STOPWORDS = %w[
          about after all and are before false for from hard into must not only or the this true use when with
        ].to_set.freeze
        # Minimum list-refiner score to fuzzy-match two markdown lists before handing
        # them to inner_merge_lists for item-level deduplication and repair.
        MARKDOWN_LIST_MATCH_THRESHOLD = 0.45
        # Fuzzy match refiner for unmatched Markdown block nodes.
        #
        # Handles unmatched paragraphs with position-aware content similarity. List
        # matching is delegated to Markdown::Merge::ListMatchRefiner so the same
        # fuzzy list-repair logic is shared with markdown-merge itself.
        MARKDOWN_PARAGRAPH_MATCH_REFINER = lambda do |template_nodes, dest_nodes, _context|
          template_paragraphs = template_nodes.select { |node| TemplateTask.markdown_paragraph_node?(node) }
          dest_paragraphs = dest_nodes.select { |node| TemplateTask.markdown_paragraph_node?(node) }

          candidates = []

          unless template_paragraphs.empty? || dest_paragraphs.empty?
            total_template = template_paragraphs.size
            total_dest = dest_paragraphs.size

            template_paragraphs.each_with_index do |template_node, template_idx|
              dest_paragraphs.each_with_index do |dest_node, dest_idx|
                score = TemplateTask.markdown_paragraph_match_score(
                  template_node,
                  dest_node,
                  template_idx: template_idx,
                  dest_idx: dest_idx,
                  total_template: total_template,
                  total_dest: total_dest,
                )
                next if score < MARKDOWN_PARAGRAPH_BASE_REFINER.threshold

                candidates << Ast::Merge::MatchRefinerBase::MatchResult.new(
                  template_node: template_node,
                  dest_node: dest_node,
                  score: score,
                  metadata: {},
                )
              end
            end
          end

          used_template = Set.new
          used_dest = Set.new
          candidates.sort_by { |match| -match.score }.each_with_object([]) do |match, matches|
            next if used_template.include?(match.template_node) || used_dest.include?(match.dest_node)

            matches << match
            used_template << match.template_node
            used_dest << match.dest_node
          end
        end
        MARKDOWN_LIST_REFINER = lambda do |template_nodes, dest_nodes, context|
          Markdown::Merge::ListMatchRefiner.new(
            threshold: MARKDOWN_LIST_MATCH_THRESHOLD,
          ).call(template_nodes, dest_nodes, context)
        end

        # HTML comment block refiner — matches `<!-- ... -->` blocks that differ
        # slightly between template and destination. These are top-level HTML nodes
        # in the Markdown AST. After NodeTypeNormalizer wrapping, type is the string
        # "html_block". Uses string_content for text extraction since Markly/CommonMark
        # nodes return empty plaintext for HTML blocks.
        MARKDOWN_HTML_COMMENT_REFINER = Ast::Merge::TokenMatchRefiner.new(
          threshold: 0.35,
          node_types: [:html_block, :html, "html_block", "html"],
          text_extractor: ->(node) {
            if node.respond_to?(:string_content)
              node.string_content.to_s
            elsif node.respond_to?(:node) && node.node.respond_to?(:string_content)
              node.node.string_content.to_s
            else
              node.text.to_s
            end
          },
        )

        # Composite refiner chaining paragraph/list matching with HTML comment matching.
        # The paragraph/list refiner runs first (consuming its matches), then the
        # HTML comment refiner processes any remaining unmatched :html_block nodes.
        MARKDOWN_MATCH_REFINER = Ast::Merge::CompositeMatchRefiner.new(
          MARKDOWN_PARAGRAPH_MATCH_REFINER,
          MARKDOWN_LIST_REFINER,
          MARKDOWN_HTML_COMMENT_REFINER,
        )

        module_function

        # Whether a relative template path should be raw-copied (no tokens, no merge).
        # Checks the .kettle-jem.yml config for `strategy: raw_copy` on the given path.
        # @param rel [String] relative path from template root (with .example stripped)
        # @return [Boolean]
        def raw_copy?(rel)
          config = TemplateHelpers.config_for(rel)
          config&.fetch(:strategy, nil) == :raw_copy
        end

        # Normalize whitespace in Markdown content using AST-based processing.
        #
        # Performs a self-merge through Markdown::Merge::SmartMerger which:
        # 1. Parses the content into a proper AST (via Markly/Commonmarker)
        # 2. Applies WhitespaceNormalizer to collapse excessive blank lines
        #
        # Then ensures blank lines around headings. The SmartMerger self-merge
        # suppresses auto-spacing for same-source-adjacent nodes, so this
        # post-processing step is needed. It is AST-aware via the fenced code
        # block tracking to avoid modifying lines inside code blocks.
        #
        # @param text [String] Markdown content to normalize
        # @return [String] Normalized content
        def normalize_markdown_spacing(text)
          merged = Markdown::Merge::SmartMerger.new(
            text,
            text,
            backend: :markly,
            preference: :destination,
            normalize_whitespace: :basic,
          ).merge

          ensure_heading_spacing(merged)
        rescue StandardError => e
          Kettle::Dev.debug_error(e, __method__)
          # If AST parsing fails, return content unchanged
          text
        end

        # Ensure blank lines before and after Markdown headings.
        # Skips lines inside fenced code blocks.
        #
        # @param text [String] Markdown content
        # @return [String] Content with blank lines around headings
        def ensure_heading_spacing(text)
          lines = text.split("\n", -1)
          result = []
          in_fence = false

          lines.each_with_index do |line, i|
            # Track fenced code block state
            if line.match?(/\A\s{0,3}(`{3,}|~{3,})/)
              in_fence = !in_fence
              result << line
              next
            end

            if !in_fence && line.match?(/\A\#{1,6}\s/)
              # Insert blank line before heading if previous line is non-blank, non-heading content
              if result.any? && result.last != "" && !result.last.match?(/\A\s*\z/)
                result << ""
              end
              result << line
              # Insert blank line after heading if next line is non-blank content
              next_line = lines[i + 1]
              if next_line && !next_line.match?(/\A\s*\z/)
                result << ""
              end
            else
              result << line
            end
          end

          result.join("\n")
        end

        def markdown_heading_file?(relative_path)
          ext = File.extname(relative_path.to_s).downcase
          MARKDOWN_HEADING_EXTENSIONS.include?(ext)
        end

        def markdown_paragraph_match_acceptable?(template_node, dest_node)
          template_text = normalize_markdown_match_text(template_node&.text)
          dest_text = normalize_markdown_match_text(dest_node&.text)
          return false if template_text.empty? || dest_text.empty?
          return true unless label_style_markdown_paragraph?(template_text) || label_style_markdown_paragraph?(dest_text)

          !!markdown_significant_tokens(template_text).intersect?(markdown_significant_tokens(dest_text))
        end

        def markdown_paragraph_match_score(template_node, dest_node, template_idx:, dest_idx:, total_template:, total_dest:)
          score = MARKDOWN_PARAGRAPH_BASE_REFINER.send(
            :compute_content_similarity,
            template_node,
            dest_node,
            template_idx,
            dest_idx,
            total_template,
            total_dest,
          )

          return 0.0 unless markdown_paragraph_match_acceptable?(template_node, dest_node)

          template_text = normalize_markdown_match_text(template_node&.text)
          dest_text = normalize_markdown_match_text(dest_node&.text)
          if label_style_markdown_paragraph?(template_text) || label_style_markdown_paragraph?(dest_text)
            overlap_count = (markdown_significant_tokens(template_text) & markdown_significant_tokens(dest_text)).size
            score = [score + [overlap_count * 0.05, 0.25].min, 1.0].min
          end

          score
        end

        def markdown_paragraph_node?(node)
          return false unless node.respond_to?(:type)

          node.type.to_sym == :paragraph
        rescue StandardError
          false
        end

        def normalize_markdown_match_text(text)
          text.to_s.strip.gsub(/\s+/, " ")
        end

        def label_style_markdown_paragraph?(text)
          MARKDOWN_LABEL_STYLE_PARAGRAPH_RE.match?(text.to_s.strip)
        end

        def markdown_significant_tokens(text)
          text.to_s.downcase.scan(/[[:alpha:]][[:alnum:]_-]{3,}/).reject do |token|
            MARKDOWN_MATCH_STOPWORDS.include?(token)
          end.to_set
        end

        def sync_readme_gemspec_grapheme!(helpers:, project_root:, gem_name:)
          actual_root = helpers.output_dir || project_root
          readme_path = File.join(actual_root, "README.md")
          gemspec_path = File.join(actual_root, "#{gem_name}.gemspec")
          return unless File.file?(readme_path) && File.file?(gemspec_path)

          readme = File.read(readme_path)
          gemspec = File.read(gemspec_path)

          # Use project_emoji from config as the authoritative source.
          # This prevents the template's family emoji from ever overwriting a
          # project's chosen emoji — the config value always wins.
          # Fall back to README H1 extraction only if config has no value set.
          config_emoji = helpers.resolved_config_string("project_emoji", env_key: "KJ_PROJECT_EMOJI")

          synced_readme, synced_gemspec, chosen_grapheme = Kettle::Jem::ReadmeGemspecSynchronizer.synchronize(
            readme_content: readme,
            gemspec_content: gemspec,
            grapheme: config_emoji,
          )
          return unless chosen_grapheme

          helpers.write_file(File.join(project_root, "README.md"), synced_readme) if synced_readme != readme
          helpers.write_file(File.join(project_root, "#{gem_name}.gemspec"), synced_gemspec) if synced_gemspec != gemspec
        rescue StandardError => e
          Kettle::Dev.debug_error(e, __method__)
          Kernel.warn("[kettle-jem] ⚠️  Could not synchronize README H1 grapheme with gemspec metadata: #{e.class}: #{e.message}")
        end

        # Merge template content with an existing destination file using the
        # appropriate AST-aware merge gem based on file type.
        #
        # @param content [String] Token-resolved template content
        # @param dest [String] Destination file path
        # @param rel [String] Relative path (for type detection)
        # @param helpers [Module] TemplateHelpers
        # @return [String] Merged content (or original content on failure when failure_mode is rescue)
        # @raise [Kettle::Dev::Error] When merge fails and failure_mode is error (default)
        def merge_by_file_type(content, dest, rel, helpers)
          dest_content = File.read(dest)
          file_type = merge_file_type_for(rel, dest, helpers)

          merged =
            if Kettle::Jem::SourceMerger.ruby_file_type?(file_type)
              # Ruby files: prism-merge via SourceMerger
              helpers.apply_strategy(content, dest)
            elsif file_type == :yaml
              # YAML files: psych-merge
              Psych::Merge::SmartMerger.new(
                content,
                dest_content,
                preference: :template,
                add_template_only_nodes: true,
              ).merge
            elsif file_type == :markdown
              # Markdown files (not README/CHANGELOG, which have dedicated steps):
              # use SmartMerger with template preference. Fuzzy paragraph
              # matching helps near-matching unmatched paragraphs align so they
              # are not emitted separately. Fuzzy list matching pairs lists with
              # similar content across minor wording differences; inner_merge_lists
              # then merges those paired lists at the individual item level, using
              # destination preference per item (preserving project customisations)
              # and preventing the "growing list" bug caused by the CommonMark parser
              # silently merging adjacent ordered lists into one larger list.
              Markdown::Merge::SmartMerger.new(
                content,
                dest_content,
                backend: :markly,
                preference: :template,
                add_template_only_nodes: true,
                match_refiner: MARKDOWN_MATCH_REFINER,
                inner_merge_lists: true,
              ).merge
            elsif file_type == :bash
              # Shell / bash files: bash-merge
              Bash::Merge::SmartMerger.new(
                content,
                dest_content,
                preference: :template,
                add_template_only_nodes: true,
              ).merge
            elsif file_type == :dotenv
              Dotenv::Merge::SmartMerger.new(
                content,
                dest_content,
                preference: :template,
                add_template_only_nodes: true,
                freeze_token: "kettle-jem",
              ).merge
            elsif file_type == :json
              Json::Merge::SmartMerger.new(
                content,
                dest_content,
                preference: :template,
                add_template_only_nodes: true,
                freeze_token: "kettle-jem",
              ).merge
            elsif file_type == :toml
              Toml::Merge::SmartMerger.new(
                content,
                dest_content,
                preference: :template,
                add_template_only_nodes: true,
                freeze_token: "kettle-jem",
              ).merge
            elsif file_type == :rbs
              Rbs::Merge::SmartMerger.new(
                content,
                dest_content,
                preference: :template,
                add_template_only_nodes: true,
                freeze_token: "kettle-jem",
              ).merge
            else
              # Text files: text-merge. For .gitignore specifically, include
              # template-only lines so new ignore rules are added to existing
              # destination files. Other text files should respect the same
              # configured merge options as the AST-aware backends.
              text_merge_options = {
                preference: :template,
              }
              if helpers.respond_to?(:merge_options_for_path)
                text_merge_options.merge!(helpers.merge_options_for_path(rel))
              end
              text_merge_options[:add_template_only_nodes] = true if File.basename(rel.to_s) == ".gitignore"

              Ast::Merge::Text::SmartMerger.new(
                content,
                dest_content,
                **text_merge_options,
              ).merge
            end

          result = (merged.is_a?(String) && !merged.empty?) ? merged : content
          # Ensure all merge results end with a trailing newline (standard file convention)
          SourceMerger.ensure_trailing_newline(result)
        rescue Ast::Merge::DestinationParseError => e
          # Destination has syntax errors; cannot safely merge — use template content.
          Kernel.warn("[kettle-jem] #{rel}: #{e.message}; destination is unparseable, using template content")
          SourceMerger.ensure_trailing_newline(content)
        rescue Ast::Merge::ParseError => e
          # AST parser unavailable for this file type — no silent fallback to text merge.
          # Either skip the file (preserving destination) or abort the run.
          if parse_error_mode == :skip
            Kernel.warn("[kettle-jem] #{rel}: SKIPPED — #{e.message}")
            SourceMerger.ensure_trailing_newline(dest_content)
          else
            raise Kettle::Dev::Error, "[kettle-jem] #{rel}: AST merge failed — #{e.message}. " \
              "Set PARSE_ERROR_MODE=skip to skip files when parsers are unavailable."
          end
        rescue StandardError => e
          if failure_mode == :rescue
            Kettle::Dev.debug_error(e, __method__)
            content
          else
            raise Kettle::Dev::Error, "Merge failed for #{rel}: #{e.class}: #{e.message}"
          end
        end

        def merge_file_type_for(rel, dest, helpers)
          helpers.configured_file_type_for(dest) ||
            if helpers.ruby_template?(dest)
              :ruby
            elsif yaml_file?(rel)
              :yaml
            elsif markdown_heading_file?(rel)
              :markdown
            elsif bash_file?(rel)
              :bash
            elsif toml_file?(rel)
              :toml
            elsif json_file?(rel)
              :json
            elsif rbs_file?(rel)
              :rbs
            else
              :text
            end
        end

        def write_templating_run_report(
          project_root:,
          output_dir:,
          snapshot:,
          run_started_at:,
          finished_at: nil,
          status: nil,
          warnings: [],
          error: nil,
          report_path: nil,
          template_diff: nil,
          template_commit_sha: nil
        )
          Kettle::Jem::TemplatingReport.write(
            project_root: project_root,
            output_dir: output_dir,
            snapshot: snapshot,
            report_path: report_path,
            run_started_at: run_started_at,
            finished_at: finished_at,
            status: status,
            warnings: warnings,
            error: error,
            template_diff: template_diff,
            template_commit_sha: template_commit_sha,
          )
        rescue StandardError => e
          Kettle::Dev.debug_error(e, __method__)
          warn("[kettle-jem] WARNING: Could not write templating report: #{e.class}: #{e.message}")
          report_path
        end

        def templating_run_status(helpers, error)
          outcome = helpers.template_run_outcome
          return outcome || :failed if error

          outcome || :complete
        end

        # Auto-commit all changes made by the template run.
        #
        # If the working tree is clean (no changes), returns nil.
        # Otherwise stages everything, commits with a descriptive message, and
        # returns the short SHA of the new commit.
        #
        # @param root    [String] project root
        # @param helpers [Module] TemplateHelpers
        # @param out     [TemplateOutput::Formatter]
        # @return [String, nil] 7-char short SHA of the new commit, or nil if no commit was made
        def make_template_commit!(root:, helpers:, out:)
          return if Kettle::Dev::ENV_TRUE_RE.match?(ENV.fetch("KETTLE_JEM_SKIP_COMMIT", "false").to_s)

          ga = Kettle::Dev::GitAdapter.new
          return if ga.clean?

          version = helpers.kettle_jem_version
          msg = "🎨 Apply kettle-jem template#{" v#{version}" if version}"

          _, add_ok = ga.capture(["-C", root.to_s, "add", "-A"])
          unless add_ok
            out.warning("Could not stage files for template commit (git add -A failed)")
            return
          end

          _, commit_ok = ga.capture(["-C", root.to_s, "commit", "-m", msg])
          unless commit_ok
            out.warning("Template commit failed (git commit returned non-zero)")
            return
          end

          sha, sha_ok = ga.capture(["-C", root.to_s, "rev-parse", "--short", "HEAD"])
          sha_ok ? sha.strip : nil
        rescue StandardError => e
          Kettle::Dev.debug_error(e, __method__) if defined?(Kettle::Dev)
          nil
        end

        # Build the detail string appended to the "Template complete" phase line.
        #
        # @param template_diff [Hash, nil] result of TemplateChecksums.diff, or nil if unavailable
        # @param commit_sha    [String, nil] short SHA of the template commit, or nil if no commit
        # @param verbose       [Boolean]
        # @return [String, nil]
        def build_complete_detail(template_diff:, commit_sha:, verbose:)
          parts = []

          if template_diff
            count = Kettle::Jem::TemplateChecksums.diff_count(template_diff)
            parts << Kettle::Jem::TemplateChecksums.summary(template_diff) if count.positive?
          end

          parts << "commit #{commit_sha}" if commit_sha

          parts.empty? ? nil : parts.join(" | ")
        end

        # Determine the failure mode for merge operations.
        #
        # @return [Symbol] :error (default) or :rescue
        #   - :error  — merge failures raise Kettle::Dev::Error, halting the template task
        #   - :rescue — merge failures are logged and the unmerged content is used instead
        def failure_mode
          val = ENV.fetch("FAILURE_MODE", "error").to_s.strip.downcase
          (val == "rescue") ? :rescue : :error
        end

        # Determines behavior when an AST parser is unavailable for a file type.
        #
        # Controlled by the PARSE_ERROR_MODE environment variable:
        #   - :fail (default) — raise Kettle::Dev::Error, halting the template task immediately
        #   - :skip — warn and preserve the destination file content unchanged
        #
        # There is intentionally NO text-merge fallback. AST merge or nothing.
        #
        # @return [Symbol] :fail or :skip
        def parse_error_mode
          val = ENV.fetch("PARSE_ERROR_MODE", "fail").to_s.strip.downcase
          (val == "skip") ? :skip : :fail
        end

        # Whether quiet mode is active — suppresses all CLI output except phase summaries.
        #
        # Quiet is the default. Pass --verbose (sets KETTLE_JEM_VERBOSE=true) to
        # get extra output.
        #
        # @return [Boolean]
        def quiet?
          return false if verbose? || debug?

          (!Kettle::Dev::ENV_TRUE_RE.match?(ENV.fetch("KETTLE_JEM_QUIET", "true").to_s)) ? false : true
        end

        # Whether verbose mode is active — shows all CLI output.
        #
        # Controlled by KETTLE_JEM_VERBOSE environment variable (set by --verbose CLI flag).
        #
        # @return [Boolean]
        def verbose?
          Kettle::Dev::ENV_TRUE_RE.match?(ENV.fetch("KETTLE_JEM_VERBOSE", "false").to_s)
        end

        # Whether template-layer debug mode is active.
        #
        # KETTLE_JEM_DEBUG is the narrow flag for kettle-jem orchestration and
        # templating behavior. KETTLE_DEV_DEBUG also enables this so a single
        # shared-stack debug flag is sufficient when debugging end-to-end runs.
        #
        # @return [Boolean]
        def debug?
          Kettle::Dev::ENV_TRUE_RE.match?(ENV.fetch("KETTLE_JEM_DEBUG", "false").to_s) ||
            Kettle::Dev::ENV_TRUE_RE.match?(ENV.fetch("KETTLE_DEV_DEBUG", "false").to_s)
        end

        YAML_EXTENSIONS = %w[.yml .yaml].freeze
        BASH_EXTENSIONS = %w[.sh .bash].freeze
        TOML_EXTENSIONS = %w[.toml].freeze
        JSON_EXTENSIONS = %w[.json .jsonc].freeze
        RBS_EXTENSIONS = %w[.rbs].freeze
        # Basenames that are shell scripts without a shell extension
        BASH_BASENAMES = %w[.envrc].freeze
        # Tree-sitter grammar languages whose paths we attempt to auto-discover
        # and write into mise.toml so they are available to subsequent runs.
        TREE_SITTER_GRAMMAR_LANGUAGES = %w[
          bash css javascript json jsonc python rbs ruby toml yaml
        ].freeze

        def yaml_file?(relative_path)
          ext = File.extname(relative_path.to_s).downcase
          # CITATION.cff is YAML-structured
          return true if File.basename(relative_path.to_s).casecmp("citation.cff").zero?
          YAML_EXTENSIONS.include?(ext)
        end

        def bash_file?(relative_path)
          ext = File.extname(relative_path.to_s).downcase
          base = File.basename(relative_path.to_s)
          BASH_EXTENSIONS.include?(ext) || BASH_BASENAMES.include?(base)
        end

        def toml_file?(relative_path)
          TOML_EXTENSIONS.include?(File.extname(relative_path.to_s).downcase)
        end

        def json_file?(relative_path)
          JSON_EXTENSIONS.include?(File.extname(relative_path.to_s).downcase)
        end

        def rbs_file?(relative_path)
          RBS_EXTENSIONS.include?(File.extname(relative_path.to_s).downcase)
        end

        # Abort wrapper that avoids terminating the entire process during specs
        def task_abort(msg)
          raise Kettle::Dev::Error, msg
        end

        def refresh_mise_trust_if_needed!(helpers:, project_root:)
          mise_path = File.join(project_root, "mise.toml")
          return unless helpers.modified_by_template?(mise_path)

          command = ["mise", "trust", "-C", project_root].freeze
          command_text = command.join(" ")

          unless helpers.force_mode?
            approved = helpers.ask("Run `#{command_text}` now?", true)
            unless approved
              task_abort(
                "Aborting: mise trust refresh required before continuing. " \
                  "Run `#{command_text}` and re-run kettle-jem.",
              )
            end
          end

          success = system(*command, out: $stdout, err: $stderr)
          return if success

          task_abort("Aborting: `#{command_text}` failed after mise.toml changed.")
        rescue StandardError => e
          raise if e.is_a?(Kettle::Dev::Error)

          task_abort(
            "Aborting: unable to refresh mise trust after mise.toml changed. " \
              "#{e.class}: #{e.message}",
          )
        end

        def token_options(meta, helpers)
          forge_org = meta[:forge_org] || meta[:gh_org]
          funding_org = helpers.opencollective_disabled? ? nil : meta[:funding_org] || forge_org

          {
            org: forge_org,
            gem_name: meta[:gem_name],
            namespace: meta[:namespace],
            namespace_shield: meta[:namespace_shield],
            gem_shield: meta[:gem_shield],
            funding_org: funding_org,
            min_ruby: meta[:min_ruby],
          }
        end

        def prerequisite_validation_available?(options)
          %i[org gem_name].all? { |key| !options[key].to_s.strip.empty? }
        end

        def seeded_kettle_config_content(helpers, config_src, token_options)
          began_with_tokens = helpers.tokens_configured?
          helpers.configure_tokens!(**token_options, include_config_tokens: false)
          seeded_content = helpers.read_template(config_src)
          seeded_content = helpers.seed_kettle_config_content(seeded_content, helpers.derived_token_config_values)
          helpers.seed_gemspec_licenses_in_config_content(seeded_content)
        ensure
          helpers.clear_tokens! unless began_with_tokens
        end

        def placeholder_or_blank_scalar?(raw_value)
          Kettle::Jem::TemplateHelpers.placeholder_or_blank_kettle_config_scalar?(raw_value)
        end

        def yaml_scalar_for_backfill(value, current_raw)
          Kettle::Jem::TemplateHelpers.yaml_scalar_for_kettle_config_backfill(value, current_raw)
        end

        def backfill_kettle_config_token_lines(content, token_values, helpers:)
          helpers.backfill_kettle_config_token_lines(content, token_values)
        end

        def merge_missing_backfilled_token_values(destination_content, token_values)
          Kettle::Jem::TemplateHelpers.merge_missing_kettle_config_token_values(destination_content, token_values)
        end

        def bootstrap_version_gem_touchpoints!(helpers:, project_root:, meta:)
          Kettle::Jem::VersionGemBootstrap.bootstrap!(
            helpers: helpers,
            project_root: project_root,
            entrypoint_require: meta[:entrypoint_require],
            namespace: meta[:namespace],
            version: meta[:version],
          )
        end

        def backfill_project_kettle_config_tokens!(helpers:, project_root:)
          config_dest = File.join(project_root, ".kettle-jem.yml")
          return false unless File.exist?(config_dest)

          token_values = helpers.derived_token_config_values
          return false if token_values.empty?

          current_content = File.read(config_dest)
          updated_content, replaced_existing_values = backfill_kettle_config_token_lines(current_content, token_values, helpers: helpers)
          merged_content = merge_missing_backfilled_token_values(updated_content, token_values)
          return false if merged_content == current_content

          merged_content += "\n" unless merged_content.empty? || merged_content.end_with?("\n")
          FileUtils.mkdir_p(File.dirname(config_dest))
          File.open(config_dest, "w") { |f| f.write(merged_content) }
          helpers.record_template_result(config_dest, :replace)
          helpers.clear_kettle_config!
          replaced_existing_values || merged_content != updated_content
        end

        def bootstrap_bin_setup!(helpers:, project_root:, template_root:, token_options:, bootstrapped_files:)
          setup_dest = File.join(project_root, "bin/setup")
          return if File.exist?(setup_dest)

          setup_src = helpers.prefer_example(File.join(template_root, "bin/setup"))
          return unless File.exist?(setup_src)

          began_with_tokens = helpers.tokens_configured?
          helpers.configure_tokens!(**token_options, include_config_tokens: false) unless began_with_tokens
          rendered_content = helpers.read_template(setup_src)
          helpers.write_file(setup_dest, rendered_content)
          actual_setup_dest = helpers.respond_to?(:output_path) ? helpers.output_path(setup_dest) : setup_dest
          File.chmod(0o755, actual_setup_dest) if File.exist?(actual_setup_dest)
          helpers.record_template_result(setup_dest, :create)
          bootstrapped_files << setup_dest
        ensure
          helpers.clear_tokens! unless began_with_tokens
        end

        def ensure_kettle_config_bootstrap!(helpers:, project_root:, template_root:, token_options:)
          config_src = helpers.prefer_example(File.join(template_root, ".kettle-jem.yml"))
          config_dest = File.join(project_root, ".kettle-jem.yml")
          return :missing_template unless File.exist?(config_src)

          bootstrapped_files = []
          config_bootstrapped = false

          # .kettle-jem.yml — copy (seeded with token values) if absent.
          unless File.exist?(config_dest)
            seeded_config_content = seeded_kettle_config_content(helpers, config_src, token_options)
            helpers.write_file(config_dest, seeded_config_content)
            helpers.record_template_result(config_dest, :create)
            helpers.clear_kettle_config!
            bootstrapped_files << config_dest
            config_bootstrapped = true
          end

          # mise.toml — copy if absent; merge template into dest if present;
          # then inject any auto-discovered TREE_SITTER_*_PATH values that
          # are missing so users have an editable handle for each grammar.
          mise_src = helpers.prefer_example_with_osc_check(File.join(template_root, "mise.toml"))
          mise_dest = File.join(project_root, "mise.toml")
          if File.exist?(mise_src)
            # Tokens must be configured before read_template and resolve_tokens work correctly.
            # We do a short-lived configure/clear here because this method runs before the
            # main configure_tokens! call in run(). include_config_tokens: false avoids
            # reading the just-written .kettle-jem.yml before it's committed.
            helpers.configure_tokens!(**token_options, include_config_tokens: false) unless helpers.tokens_configured?
            began_with_tokens = helpers.tokens_configured?
            if !File.exist?(mise_dest)
              base_content = helpers.read_template(mise_src)
              fragment = discovered_grammar_toml_fragment(base_content)
              final_content = if fragment
                Toml::Merge::SmartMerger.new(
                  fragment,
                  base_content,
                  preference: :destination,
                  add_template_only_nodes: true,
                  sort_keys: true,
                ).merge
              else
                base_content
              end
              helpers.write_file(mise_dest, final_content)
              helpers.record_template_result(mise_dest, :create)
              bootstrapped_files << mise_dest
            else
              begin
                dest_content = File.read(mise_dest)
                # Resolve any unresolved token placeholders in dest before merging,
                # so destination-wins preference doesn't preserve stale token text.
                resolved_dest_content = helpers.resolve_tokens(dest_content)
                # Pass 1: merge template keys into dest (dest wins on conflicts, except unresolved token placeholders)
                merged = Toml::Merge::SmartMerger.new(
                  helpers.read_template(mise_src),
                  resolved_dest_content,
                  preference: :destination,
                  add_template_only_nodes: true,
                  freeze_token: "kettle-jem",
                  sort_keys: true,
                ).merge
                # Pass 2: inject newly-discovered grammar paths not yet in dest
                fragment = discovered_grammar_toml_fragment(merged)
                merged = if fragment
                  Toml::Merge::SmartMerger.new(
                    fragment,
                    merged,
                    preference: :destination,
                    add_template_only_nodes: true,
                    sort_keys: true,
                  ).merge
                else
                  merged
                end
                if merged != dest_content
                  helpers.write_file(mise_dest, merged)
                  helpers.record_template_result(mise_dest, :replace)
                  bootstrapped_files << mise_dest
                end
              rescue StandardError => e
                Kettle::Dev.debug_error(e, __method__)
              end
            end
            helpers.clear_tokens! unless began_with_tokens
          end

          # .config/mise/env.sh — copy if absent.
          env_sh_src = File.join(template_root, ".config/mise/env.sh")
          env_sh_dest = File.join(project_root, ".config/mise/env.sh")
          if File.exist?(env_sh_src) && !File.exist?(env_sh_dest)
            FileUtils.mkdir_p(File.dirname(env_sh_dest))
            FileUtils.cp(env_sh_src, env_sh_dest)
            helpers.record_template_result(env_sh_dest, :create)
            bootstrapped_files << env_sh_dest
          end

          bootstrap_bin_setup!(
            helpers: helpers,
            project_root: project_root,
            template_root: template_root,
            token_options: token_options,
            bootstrapped_files: bootstrapped_files,
          )

          return :present if bootstrapped_files.empty?

          # Only require a manual review + re-run when .kettle-jem.yml itself
          # was freshly created.  Auto-generated infrastructure files like
          # mise.toml and .config/mise/env.sh don't need user review and
          # shouldn't block the rest of the template phases.
          unless config_bootstrapped
            bootstrapped_files.each { |f| puts "[kettle-jem] Wrote #{Kettle::Jem.display_path(f)}." }
            return :present
          end

          helpers.template_run_outcome = :bootstrap_only
          unless TemplateTask.quiet?
            bootstrapped_files.each { |f| puts "[kettle-jem] Wrote #{Kettle::Jem.display_path(f)}." }
            puts "[kettle-jem] Review the file(s) above, fill in any missing token values, then:"
            puts "[kettle-jem]   mise trust -C #{Kettle::Jem.display_path(project_root)}"
            puts "[kettle-jem] Commit the changes and re-run kettle-jem."
          end
          :bootstrap_only
        end

        def sync_existing_kettle_config!(helpers:, project_root:, template_root:, token_options:)
          config_src = helpers.prefer_example(File.join(template_root, ".kettle-jem.yml"))
          config_dest = File.join(project_root, ".kettle-jem.yml")
          return unless File.exist?(config_src) && File.exist?(config_dest)

          seeded_config_content = seeded_kettle_config_content(helpers, config_src, token_options)
          helpers.copy_file_with_prompt(
            config_src,
            config_dest,
            allow_create: true,
            allow_replace: true,
            content_override: seeded_config_content,
          ) do |content|
            c = content
            if File.exist?(config_dest)
              begin
                c = Psych::Merge::SmartMerger.new(
                  c,
                  File.read(config_dest),
                  preference: :destination,
                  add_template_only_nodes: true,
                  add_template_only_sequence_items: false,
                ).merge
              rescue StandardError => e
                Kettle::Dev.debug_error(e, __method__)
              end
            end
            begin
              c = helpers.resolve_tokens(c)
            rescue StandardError => e
              Kettle::Dev.debug_error(e, __method__)
            end
            c = dedupe_kettle_config_instructional_comment_blocks(c)
            c
          end
          helpers.clear_kettle_config!
        end

        def dedupe_kettle_config_instructional_comment_blocks(content)
          lines = content.to_s.lines
          marker = "# To override specific files, add entries like:"
          occurrences = []
          index = 0

          while index < lines.length
            unless lines[index].rstrip == marker
              index += 1
              next
            end

            end_index = index + 1
            while end_index < lines.length && (lines[end_index].start_with?("#") || lines[end_index].strip.empty?)
              end_index += 1
            end

            occurrences << {
              start: index,
              finish: end_index,
              block: lines[index...end_index].join,
              normalized_block: lines[index...end_index].join.sub(/\n+\z/, "\n"),
            }
            index = end_index
          end

          return content if occurrences.size < 2

          canonical_block = occurrences.first[:normalized_block]
          duplicate_ranges = occurrences.drop(1)
            .select { |occurrence| occurrence[:normalized_block] == canonical_block }
            .map { |occurrence| occurrence[:start]...occurrence[:finish] }
          return content if duplicate_ranges.empty?

          rebuilt = []
          lines.each_with_index do |line, line_index|
            next if duplicate_ranges.any? { |range| range.cover?(line_index) }

            rebuilt << line
          end

          rebuilt.join
        end

        def preflight_destination_for(rel, project_root, gem_name)
          return if rel == ".kettle-jem.yml"
          return File.join(project_root, ".env.local.example") if rel == ".env.local"

          return File.join(project_root, rel) unless rel.end_with?(".gemspec")

          return File.join(project_root, "#{gem_name}.gemspec") if gem_name && !gem_name.to_s.empty?

          Dir.glob(File.join(project_root, "*.gemspec")).sort.first || File.join(project_root, rel)
        end

        def logical_template_paths(template_root)
          rels = Set.new
          Find.find(template_root) do |path|
            next if File.directory?(path)

            rel = path.sub(%r{^#{Regexp.escape(template_root)}/?}, "")
              .sub(/\.no-osc\.example\z/, "")
              .sub(/\.example\z/, "")
            rels << rel unless rel.empty?
          end
          rels.to_a.sort
        end

        def include_matches?(project_root, abs_dest)
          include_patterns = ENV["include"].to_s.split(",").map { |s| s.strip }.reject(&:empty?)
          return false if include_patterns.empty?

          rel_dest = abs_dest.to_s
          proj = project_root.to_s
          if rel_dest.start_with?(proj + "/")
            rel_dest = rel_dest[(proj.length + 1)..]
          elsif rel_dest == proj
            rel_dest = ""
          end

          include_patterns.any? do |pat|
            if pat.end_with?("/**")
              base = pat[0..-4]
              rel_dest == base || rel_dest.start_with?(base + "/")
            else
              File.fnmatch?(pat, rel_dest, File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH)
            end
          end
        rescue StandardError => e
          Kettle::Dev.debug_error(e, __method__)
          false
        end

        def unresolved_required_tokens(helpers:, project_root:, template_root:, gem_name:)
          return {} unless Dir.exist?(template_root)

          logical_template_paths(template_root).each_with_object({}) do |rel, unresolved_by_file|
            next if rel == ".kettle-jem.yml"
            next if helpers.skip_for_disabled_opencollective?(rel)

            dest = preflight_destination_for(rel, project_root, gem_name)
            next unless dest
            next if rel == ".github/workflows/discord-notifier.yml" && !include_matches?(project_root, dest)

            strategy = helpers.strategy_for(dest)
            next if %i[keep_destination raw_copy].include?(strategy)

            src = helpers.prefer_example_with_osc_check(File.join(template_root, rel))
            next unless File.exist?(src)

            tokens = helpers.unresolved_token_keys(File.read(src))
            next if tokens.empty?

            display_rel = helpers.rel_path(dest)
            unresolved_by_file[display_rel] = tokens.sort
          end
        end

        def unresolved_written_tokens(helpers:, project_root:)
          token_pattern = /\{KJ\|[A-Z][A-Z0-9_:]*\}/
          scan_root = (helpers.output_dir || project_root).to_s
          unresolved_by_file = {}
          scan_paths = []

          helpers.template_results.each do |dest_path, record|
            actual_path = helpers.output_path(dest_path)

            case record[:action]
            when :create, :replace
              scan_paths << actual_path if File.file?(actual_path)
            when :dir_create, :dir_replace
              next unless Dir.exist?(actual_path)

              Find.find(actual_path) do |path|
                scan_paths << path if File.file?(path)
              end
            end
          end

          scan_paths.uniq.each do |path|
            rel = path.sub(%r{^#{Regexp.escape(scan_root)}/?}, "")
            next if rel.empty? || rel == ".kettle-jem.yml"
            next if helpers.config_for(rel)&.fetch(:skip_unresolved_scan, false)

            ext = File.extname(path)
            next unless %w[.rb .gemspec .gemfile .yml .yaml .toml .md .txt .sh .json .jsonc .cff .example .lock].include?(ext) ||
              File.basename(path).match?(/\A(Gemfile|Rakefile|Appraisals|\.envrc|\.env|\.rspec|\.yardopts|\.gitignore|\.rubocop|LICENSE)\z/i)

            begin
              content = File.read(path)
              # For markdown files, strip code spans and fenced code blocks before
              # scanning so that tokens documented by name (e.g. `{KJ|GEM_MAJOR}` in
              # CHANGELOG.md) are not treated as unresolved placeholders.
              scan_content = if ext == ".md"
                content
                  .gsub(/^```.*?^```/m, "")        # fenced code blocks
                  .gsub(/`[^`\n]+`/, "")            # inline code spans
              else
                content
              end
              tokens = scan_content.scan(token_pattern).uniq
              unresolved_by_file[rel] = tokens unless tokens.empty?
            rescue StandardError
              # Skip files that can't be read as text.
            end
          end

          unresolved_by_file
        end

        def validate_required_token_values!(helpers:, project_root:, template_root:, gem_name:)
          unresolved_by_file = unresolved_required_tokens(
            helpers: helpers,
            project_root: project_root,
            template_root: template_root,
            gem_name: gem_name,
          )
          return if unresolved_by_file.empty?

          msg_lines = ["Unresolved {KJ|...} tokens would be written to #{unresolved_by_file.size} template file(s):"]
          unresolved_by_file.each do |rel, tokens|
            msg_lines << "  #{rel}: #{tokens.join(", ")}"
          end
          msg_lines << ""
          msg_lines << "Please set the required environment variables or add values to .kettle-jem.yml and re-run."
          msg_lines << "Tip: .kettle-jem.yml is the first file to review when token values are missing."

          helpers.add_warning(msg_lines.join("\n"))
          helpers.print_warnings_summary
          task_abort(msg_lines.first)
        end

        # Execute the template operation into the current project.
        # All options/IO are controlled via TemplateHelpers and ENV.
        def run
          helpers = Kettle::Jem::TemplateHelpers
          helpers.clear_warnings
          helpers.clear_template_run_outcome!

          progress = Kettle::Jem::TemplateProgress.new(total_steps: Phases::TemplateRun.phase_count)
          out = Kettle::Jem::TemplateOutput::Formatter.new(quiet: quiet?, progress: progress)

          # Initialized early so the ensure block can always reference them,
          # even if an exception occurs before they are assigned below.
          template_diff = nil
          template_commit_sha = nil

          project_root = helpers.project_root
          template_root = helpers.template_root
          run_started_at = helpers.template_run_timestamp
          templating_environment = Kettle::Jem::TemplatingReport.snapshot
          templating_report_path = write_templating_run_report(
            project_root: project_root,
            output_dir: helpers.output_dir,
            snapshot: templating_environment,
            run_started_at: run_started_at,
            status: :started,
          )
          Kettle::Jem::TemplatingReport.print(snapshot: templating_environment, project_root: project_root) unless quiet?
          out.phase("📄", "Report", detail: Kettle::Jem.display_path(templating_report_path)) if templating_report_path

          # Ensure git working tree is clean before making changes (when run standalone)
          helpers.ensure_clean_git!(root: project_root, task_label: "kettle:jem:template")

          meta = helpers.gemspec_metadata(project_root)
          gem_name = meta[:gem_name]
          min_ruby = meta[:min_ruby]
          forge_org = meta[:forge_org] || meta[:gh_org]
          funding_org = helpers.opencollective_disabled? ? nil : meta[:funding_org] || forge_org
          entrypoint_require = meta[:entrypoint_require]
          namespace = meta[:namespace]
          namespace_shield = meta[:namespace_shield]
          gem_shield = meta[:gem_shield]

          prerequisites = Kettle::Jem::Tasks::PrepareTask.run(
            helpers: helpers,
            project_root: project_root,
            template_root: template_root,
            meta: meta,
          )
          return :bootstrap_only if prerequisites == :bootstrap_only
          return prerequisites unless prerequisites == :ready

          # Configure token replacements once for the entire session.
          # All template reads (via read_template) will automatically resolve tokens.
          # Token configuration failure is FATAL — continuing without tokens would
          # silently write raw {KJ|...} patterns to every downstream gem.
          helpers.configure_tokens!(
            org: forge_org,
            gem_name: gem_name,
            namespace: namespace,
            namespace_shield: namespace_shield,
            gem_shield: gem_shield,
            funding_org: funding_org,
            min_ruby: min_ruby,
          )

          # Require project_emoji to be set before processing any templates.
          # Without it the {KJ|PROJECT_EMOJI} token is unresolved, which corrupts
          # README H1 and gemspec summary/description on every downstream gem.
          project_emoji = helpers.resolved_config_string("project_emoji", env_key: "KJ_PROJECT_EMOJI")
          unless helpers.present_string?(project_emoji)
            task_abort(
              "Missing required config: project_emoji\n" \
                "Please add a `project_emoji:` key to .kettle-jem.yml with your gem's " \
                "identifying emoji (e.g. 🪙). " \
                "ENV override: KJ_PROJECT_EMOJI",
            )
          end

          removed_appraisals = []
          appraisals_src = helpers.prefer_example(File.join(template_root, "Appraisals"))
          if File.exist?(appraisals_src)
            begin
              content = File.read(appraisals_src)
              _pruned, removed_appraisals = Kettle::Jem::PrismAppraisals.prune_ruby_appraisals(content, min_ruby: min_ruby)
            rescue StandardError => e
              Kettle::Dev.debug_error(e, __method__)
              removed_appraisals = []
            end
          end

          plugins = Kettle::Jem::PluginLoader.load!(plugin_names: helpers.plugin_names)

          # Build immutable context for all phase actors.
          phase_context = Phases::PhaseContext.new(
            helpers: helpers,
            out: out,
            project_root: project_root,
            template_root: template_root,
            progress: progress,
            plugins: plugins,
            gem_name: gem_name,
            namespace: namespace,
            namespace_shield: namespace_shield,
            gem_shield: gem_shield,
            forge_org: forge_org,
            funding_org: funding_org,
            min_ruby: min_ruby,
            entrypoint_require: entrypoint_require,
            meta: meta,
            removed_appraisals: removed_appraisals,
            parse_error_mode: parse_error_mode,
          )

          # Run all template phases via the orchestrator actor.
          progress.start!
          Phases::TemplateRun.call(
            context: phase_context,
            templating_report_path: templating_report_path,
          )

          # --- Template checksum diff ---
          # Compute current template checksums and compare with what was stored on
          # the previous run.  Store the updated checksums into the destination's
          # .kettle-jem.yml before committing so the commit includes them.
          template_diff = begin
            config_path = File.join(project_root, ".kettle-jem.yml")
            current_sums = Kettle::Jem::TemplateChecksums.compute(template_root: template_root)
            stored_sums = Kettle::Jem::TemplateChecksums.load_stored(config_path: config_path)
            d = Kettle::Jem::TemplateChecksums.diff(current: current_sums, stored: stored_sums)
            Kettle::Jem::TemplateChecksums.write_to_config(
              config_path: config_path,
              checksums:   current_sums,
              version:     helpers.kettle_jem_version,
            )
            d
          rescue StandardError => e
            Kettle::Dev.debug_error(e, __method__) if defined?(Kettle::Dev)
            nil
          end

          # --- Auto-commit template changes ---
          template_commit_sha = make_template_commit!(root: project_root, helpers: helpers, out: out)

          helpers.print_warnings_summary unless quiet?
          helpers.template_run_outcome = :complete

          complete_detail = build_complete_detail(
            template_diff: template_diff,
            commit_sha: template_commit_sha,
            verbose: verbose?,
          )
          out.phase("✅", "Template complete", detail: complete_detail)

          if verbose? && template_diff
            Kettle::Jem::TemplateChecksums.detail_lines(template_diff).each { |l| out.detail(l) }
          end

          nil
        ensure
          progress&.stop!

          if project_root && run_started_at && templating_environment
            error = $!
            write_templating_run_report(
              project_root: project_root,
              output_dir: helpers.output_dir,
              snapshot: templating_environment,
              report_path: templating_report_path,
              run_started_at: run_started_at,
              finished_at: helpers.template_run_timestamp,
              status: templating_run_status(helpers, error),
              warnings: helpers.warnings,
              error: error,
              template_diff: template_diff,
              template_commit_sha: template_commit_sha,
            )
          end
        end

        # Copy only the SPDX license files selected in `.kettle-jem.yml` (or gemspec fallback)
        # into the destination project, and write the LICENSE.md index file.
        #
        # Files are sourced from the template directory as `<SPDX-basename>.md.example`.
        # Token substitution is applied by +helpers.read_template+.
        # Only files that exist in the template are copied; unknown SPDX IDs are skipped
        # with a warning.
        #
        # @param helpers [TemplateHelpers]
        # @param project_root [String] absolute path to destination project
        # @param template_root [String] absolute path to the template directory
        # Build the authoritative copyright section in LICENSE.md by running
        # `git blame --porcelain` across all tracked files via GitAdapter.
        #
        # Replaces whatever copyright content is currently at the bottom of
        # LICENSE.md — either the single fallback line written from the template
        # or a `## Copyright Notice` section left by +migrate_license_txt!+ —
        # with a fully populated list derived from git history.
        #
        # No-ops gracefully when:
        # - LICENSE.md does not exist
        # - git is unavailable
        # - the collector returns no human contributors
        #
        # @param helpers [TemplateHelpers]
        # @param project_root [String] absolute path to destination project
        def collect_git_copyright!(helpers:, project_root:)
          license_md_path = File.join(project_root, "LICENSE.md")
          # When writes are redirected to an output_dir (e.g. during selftest), the
          # template has already written LICENSE.md to the output path. Read from and
          # write to that path so the selftest output stays consistent. In normal mode
          # output_path returns the path unchanged.
          actual_license_md_path = helpers.output_path(license_md_path)
          return unless File.exist?(actual_license_md_path)

          ga = Kettle::Dev::GitAdapter.new
          collector = Kettle::Jem::CopyrightCollector.new(
            git_adapter:   ga,
            project_root:  project_root,
            machine_users: helpers.resolved_machine_users,
          )
          lines = collector.copyright_lines
          return if lines.empty?

          # Sync author names to gemspec before applying the PolyForm prefix so
          # the names are extracted from bare "Copyright (c) YEARS NAME" strings.
          sync_gemspec_authors!(helpers: helpers, project_root: project_root, copyright_lines: lines)

          prefix = helpers.polyform_licenses?(helpers.resolved_licenses) ? "Required Notice: " : ""
          lines = lines.map { |l| "#{prefix}#{l}" } if prefix != ""

          md_content = File.read(actual_license_md_path)
          md_lines = md_content.lines

          # Strip trailing blank lines
          md_lines.pop while md_lines.last&.strip&.empty?

          # Remove an existing "## Copyright Notice" section (heading + body
          # until end-of-file or the next ## heading) …
          if (heading_idx = md_lines.rindex { |l| l.strip == "## Copyright Notice" })
            md_lines = md_lines.first(heading_idx)
          # … or a bare "Copyright (c) …" / "Required Notice: Copyright (c) …" fallback line
          elsif md_lines.last&.strip&.match?(/\A(?:Required Notice: )?Copyright \(c\)/)
            md_lines.pop
          end

          # Strip any newly exposed trailing blanks
          md_lines.pop while md_lines.last&.strip&.empty?

          section = "\n\n## Copyright Notice\n\n" + lines.join("\n") + "\n"
          File.write(actual_license_md_path, md_lines.join + section)
          puts "Wrote #{lines.size} copyright line(s) to LICENSE.md." unless TemplateTask.quiet?
        rescue StandardError => e
          Kettle::Dev.debug_error(e, __method__)
          Kernel.warn("[kettle-jem] ⚠️  Could not build copyright section: #{e.class}: #{e.message}")
        end

        # Overwrites +spec.authors+ in the project gemspec with the set of human
        # contributors derived from git blame (the same set used to populate the
        # LICENSE.md copyright section).
        #
        # Author names are extracted from bare copyright lines of the form:
        #   "Copyright (c) YEARS NAME"
        # where YEARS may be a single year, a range ("2024-2026"), or a
        # comma-separated list.
        #
        # The gemspec line is expected to be a single-line array assignment, e.g.:
        #   spec.authors = ["Peter H. Boling"]
        # and is replaced with the full contributor list:
        #   spec.authors = ["Alice Contributor", "Bob Contributor"]
        #
        # Skipped silently if no gemspec is found or the line is absent.
        #
        # @param helpers [TemplateHelpers]
        # @param project_root [String] absolute path to destination project
        # @param copyright_lines [Array<String>] bare copyright strings
        #   (before any PolyForm "Required Notice: " prefix is applied)
        def sync_gemspec_authors!(helpers:, project_root:, copyright_lines:)
          authors = extract_author_names(copyright_lines)
          return if authors.empty?

          actual_root = helpers.output_dir || project_root
          gemspec_path = Dir.glob(File.join(actual_root, "*.gemspec")).first
          return unless gemspec_path && File.file?(gemspec_path)

          content = File.read(gemspec_path)
          array_literal = "[#{authors.map { |a| a.inspect }.join(", ")}]"
          updated = content.gsub(GEMSPEC_AUTHORS_RE) do
            "#{::Regexp.last_match(1)}#{array_literal}#{::Regexp.last_match(2)}"
          end

          if updated != content
            File.write(gemspec_path, updated)
            puts "Updated spec.authors with #{authors.size} contributor(s) in #{File.basename(gemspec_path)}." unless TemplateTask.quiet?
          end
        rescue StandardError => e
          Kettle::Dev.debug_error(e, __method__)
          Kernel.warn("[kettle-jem] ⚠️  Could not sync gemspec authors: #{e.class}: #{e.message}")
        end

        # Extracts bare author names from copyright lines produced by
        # {CopyrightCollector#copyright_lines}.
        #
        # @param copyright_lines [Array<String>] e.g. ["Copyright (c) 2024 Jane Doe"]
        # @return [Array<String>] e.g. ["Jane Doe"]
        def extract_author_names(copyright_lines)
          Array(copyright_lines).filter_map do |line|
            m = COPYRIGHT_NAME_RE.match(line.to_s.strip)
            next unless m
            name = m[1].strip
            name unless name.empty?
          end
        end

        def copy_selected_license_files!(helpers:, project_root:, template_root:)
          licenses = helpers.resolved_licenses

          # Write each selected SPDX license file
          licenses.each do |spdx_id|
            base = helpers.spdx_basename(spdx_id)
            src_candidates = [
              File.join(template_root, "#{base}.md.example"),
              File.join(template_root, "#{base}.md"),
            ]
            src = src_candidates.find { |c| File.exist?(c) }
            unless src
              helpers.add_warning("License template not found for #{spdx_id} (looked for #{base}.md.example in template/). Skipping.")
              next
            end
            dest = File.join(project_root, "#{base}.md")
            helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true)
          rescue StandardError => e
            Kettle::Dev.debug_error(e, __method__)
            Kernel.warn("[kettle-jem] ⚠️  Could not copy license file #{base}.md: #{e.class}: #{e.message}")
          end

          # Write LICENSE.md from the template (expands {KJ|LICENSE_MD_CONTENT})
          license_md_src_candidates = [
            File.join(template_root, "LICENSE.md.example"),
            File.join(template_root, "LICENSE.md"),
          ]
          license_md_src = license_md_src_candidates.find { |c| File.exist?(c) }
          if license_md_src
            license_md_dest = File.join(project_root, "LICENSE.md")
            helpers.copy_file_with_prompt(license_md_src, license_md_dest, allow_create: true, allow_replace: true)
          else
            helpers.add_warning("LICENSE.md.example not found in template/. LICENSE.md was not written.")
          end
        end

        # Remove license files that are no longer listed in `.kettle-jem.yml`.
        #
        # Any `<basename>.md` file in the project root that was previously written
        # by kettle-jem (i.e. it has a corresponding `<basename>.md.example` in
        # the template directory and is not a non-license markdown document) but
        # whose SPDX identifier is absent from the current +resolved_licenses+ list
        # is deleted.  This keeps the project's license files in sync with the
        # configured license set.
        #
        # @param helpers [TemplateHelpers]
        # @param project_root [String] absolute path to destination project
        # @param template_root [String] absolute path to the kettle-jem template directory
        def remove_obsolete_license_files!(helpers:, project_root:, template_root:)
          active_basenames = helpers.resolved_licenses
            .map { |id| helpers.spdx_basename(id) }
            .to_set

          Dir.glob(File.join(template_root, "*.md.example"))
            .map { |f| File.basename(f, ".md.example") }
            .reject { |b| NON_LICENSE_MD_BASENAMES.include?(b) }
            .reject { |b| active_basenames.include?(b) }
            .each do |base|
              path = File.join(project_root, "#{base}.md")
              next unless File.exist?(path)

              begin
                File.delete(path)
                puts "Removed obsolete license file: #{base}.md (not in configured licenses)." unless TemplateTask.quiet?
              rescue StandardError => e
                Kettle::Dev.debug_error(e, __method__)
                Kernel.warn("[kettle-jem] ⚠️  Could not remove obsolete license file #{base}.md: #{e.class}: #{e.message}")
              end
            end
        end

        # Migrate an existing LICENSE.txt into the new multi-license layout:
        #
        # 1. Detect whether LICENSE.txt is an MIT license via phrase matching.
        # 2. If so, extract any copyright lines from the preamble and replace
        #    the template-generated fallback copyright line in LICENSE.md with a
        #    `## Copyright Notice` section containing the real lines.
        # 3. Delete the old LICENSE.txt.
        #
        # Non-MIT LICENSE.txt files are left untouched (no deletion).
        # When no copyright lines are found, the template fallback line written
        # from `LICENSE.md.example` is preserved as-is.
        #
        # @param helpers [TemplateHelpers]
        # @param project_root [String] absolute path to destination project
        def migrate_license_txt!(helpers:, project_root:)
          license_txt_path = File.join(project_root, "LICENSE.txt")
          return unless File.exist?(license_txt_path)

          content = File.read(license_txt_path)
          migrator = Kettle::Jem::LicenseTxtMigrator.new(content)

          unless migrator.mit_license?
            puts "LICENSE.txt does not appear to be an MIT license; leaving it in place." unless TemplateTask.quiet?
            return
          end

          copyright_lines = migrator.copyright_lines
          license_md_path = File.join(project_root, "LICENSE.md")

          if copyright_lines.any? && File.exist?(license_md_path)
            prefix = helpers.polyform_licenses?(helpers.resolved_licenses) ? "Required Notice: " : ""
            prefixed_lines = copyright_lines.map { |l| "#{prefix}#{l.strip}" }

            # Strip the template-generated fallback "Copyright (c) ..." line (last
            # non-empty line of the file), then append a proper ## Copyright Notice
            # section containing the real copyright lines from the old LICENSE.txt.
            md_content = File.read(license_md_path)
            md_lines = md_content.lines
            # Remove trailing blank lines and the fallback Copyright line, if present
            while md_lines.last&.strip&.empty?
              md_lines.pop
            end
            if md_lines.last&.strip&.match?(/\A(?:Required Notice: )?Copyright \(c\)/)
              md_lines.pop
            end
            # Strip any newly exposed trailing blanks
            while md_lines.last&.strip&.empty?
              md_lines.pop
            end
            section = "\n\n## Copyright Notice\n\n" + prefixed_lines.join("\n") + "\n"
            File.write(license_md_path, md_lines.join + section)
            puts "Replaced fallback copyright with #{prefixed_lines.size} line(s) from LICENSE.txt in LICENSE.md." unless TemplateTask.quiet?
          end

          File.delete(license_txt_path)
          puts "Deleted LICENSE.txt (content migrated to LICENSE.md)." unless TemplateTask.quiet?
        rescue StandardError => e
          Kettle::Dev.debug_error(e, __method__)
          Kernel.warn("[kettle-jem] ⚠️  Could not migrate LICENSE.txt: #{e.class}: #{e.message}")
        end

        def prune_workflow_matrix_by_appraisals(content, removed_appraisals)
          removed = Array(removed_appraisals).map(&:to_s).uniq
          return [content, 0, 0, false] if removed.empty?

          analysis = Psych::Merge::FileAnalysis.new(content)
          return [content, 0, 0, false] unless analysis.valid?

          lines = content.lines
          remove_lines = Set.new
          removed_count = 0
          total_count = 0

          root_entries = analysis.root_mapping_entries
          jobs_value = mapping_value_for(root_entries, "jobs")
          return [content, 0, 0, false] unless jobs_value&.mapping?

          jobs_value.mapping_entries(comment_tracker: analysis.comment_tracker).each do |_job_key, job_value|
            next unless job_value.mapping?
            strategy_value = mapping_value_for(job_value.mapping_entries(comment_tracker: analysis.comment_tracker), "strategy")
            next unless strategy_value&.mapping?
            matrix_value = mapping_value_for(strategy_value.mapping_entries(comment_tracker: analysis.comment_tracker), "matrix")
            next unless matrix_value&.mapping?
            include_value = mapping_value_for(matrix_value.mapping_entries(comment_tracker: analysis.comment_tracker), "include")
            next unless include_value&.sequence?

            items = include_value.sequence_items(comment_tracker: analysis.comment_tracker)
            total_count += items.size

            items.each do |item|
              next unless item.mapping?
              appraisal_value = mapping_value_for(item.mapping_entries(comment_tracker: analysis.comment_tracker), "appraisal")
              next unless appraisal_value&.scalar?

              appraisal = appraisal_value.value.to_s
              next unless removed.include?(appraisal)

              removed_count += 1
              start_line = item.start_line
              leading = item.leading_comments
              if leading&.any?
                start_line = [start_line, leading.first[:line]].min
              end
              end_line = item.end_line || start_line

              (start_line..end_line).each { |ln| remove_lines << ln }
            end
          end

          return [content, 0, 0, false] if removed_count.zero?

          new_lines = []
          lines.each_with_index do |line, idx|
            new_lines << line unless remove_lines.include?(idx + 1)
          end

          empty = total_count.positive? && removed_count == total_count
          [new_lines.join, removed_count, total_count, empty]
        rescue StandardError => e
          Kettle::Dev.debug_error(e, __method__)
          [content, 0, 0, false]
        end

        def mapping_value_for(entries, key_name)
          pair = entries.find do |k, _v|
            k.respond_to?(:scalar?) && k.scalar? && k.value.to_s == key_name.to_s
          end
          pair ? pair[1] : nil
        end

        # Remove matrix include entries whose `ruby:` value belongs to a
        # disabled engine. Uses the same YAML-aware approach as
        # prune_workflow_matrix_by_appraisals.
        #
        # @param content [String] YAML workflow content
        # @param engines [Array<String>] enabled engine names (e.g. ["ruby", "jruby"])
        # @return [Array(String, Integer, Integer, Boolean)]
        def prune_workflow_matrix_by_engines(content, engines)
          enabled = Array(engines).map { |e| e.to_s.strip.downcase }
          disabled_prefixes = Kettle::Jem::TemplateHelpers::ENGINE_MATRIX_PREFIXES.each_with_object([]) do |(engine, prefixes), acc|
            acc.concat(prefixes) unless enabled.include?(engine)
          end
          return [content, 0, 0, false] if disabled_prefixes.empty?

          analysis = Psych::Merge::FileAnalysis.new(content)
          return [content, 0, 0, false] unless analysis.valid?

          lines = content.lines
          remove_lines = Set.new
          removed_count = 0
          total_count = 0

          root_entries = analysis.root_mapping_entries
          jobs_value = mapping_value_for(root_entries, "jobs")
          return [content, 0, 0, false] unless jobs_value&.mapping?

          jobs_value.mapping_entries(comment_tracker: analysis.comment_tracker).each do |_job_key, job_value|
            next unless job_value.mapping?
            strategy_value = mapping_value_for(job_value.mapping_entries(comment_tracker: analysis.comment_tracker), "strategy")
            next unless strategy_value&.mapping?
            matrix_value = mapping_value_for(strategy_value.mapping_entries(comment_tracker: analysis.comment_tracker), "matrix")
            next unless matrix_value&.mapping?
            include_value = mapping_value_for(matrix_value.mapping_entries(comment_tracker: analysis.comment_tracker), "include")
            next unless include_value&.sequence?

            items = include_value.sequence_items(comment_tracker: analysis.comment_tracker)
            total_count += items.size

            items.each do |item|
              next unless item.mapping?
              ruby_value = mapping_value_for(item.mapping_entries(comment_tracker: analysis.comment_tracker), "ruby")
              next unless ruby_value&.scalar?

              ruby_str = ruby_value.value.to_s
              next unless disabled_prefixes.any? { |prefix| ruby_str.start_with?(prefix) }

              removed_count += 1
              start_line = item.start_line
              leading = item.leading_comments
              if leading&.any?
                start_line = [start_line, leading.first[:line]].min
              end
              end_line = item.end_line || start_line

              (start_line..end_line).each { |ln| remove_lines << ln }
            end
          end

          return [content, 0, 0, false] if removed_count.zero?

          new_lines = []
          lines.each_with_index do |line, idx|
            new_lines << line unless remove_lines.include?(idx + 1)
          end

          empty = total_count.positive? && removed_count == total_count
          [new_lines.join, removed_count, total_count, empty]
        rescue StandardError => e
          Kettle::Dev.debug_error(e, __method__)
          [content, 0, 0, false]
        end

        # Build a minimal TOML [env] fragment containing auto-discovered
        # TREE_SITTER_*_PATH values for all languages in TREE_SITTER_GRAMMAR_LANGUAGES
        # that (a) have a grammar .so on this machine and (b) are not already
        # present in +existing_toml_content+.
        #
        # Returns nil when nothing new was discovered.
        #
        # @param existing_toml_content [String]
        # @return [String, nil]
        def discovered_grammar_toml_fragment(existing_toml_content)
          lines = []
          TREE_SITTER_GRAMMAR_LANGUAGES.each do |lang|
            env_key = "TREE_SITTER_#{lang.upcase}_PATH"
            # Skip if already present (don't overwrite user customisation)
            next if existing_toml_content.include?(env_key)

            finder = TreeHaver::GrammarFinder.new(lang)
            path = finder.find_library_path
            next unless path

            lines << "#{env_key} = #{path.inspect}"
          rescue StandardError
            next
          end
          return if lines.empty?

          "[env]\n#{lines.join("\n")}\n"
        end
      end
    end
  end
end
