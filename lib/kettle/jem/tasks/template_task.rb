# frozen_string_literal: true

require "yaml"
require "set"
require "find"

module Kettle
  module Jem
    module Tasks
      # Thin wrapper to expose the kettle:jem:template task logic as a callable API
      # for testability. The rake task should only call this method.
      module TemplateTask
        MODULAR_GEMFILE_DIR = "gemfiles/modular"
        MARKDOWN_HEADING_EXTENSIONS = %w[.md .markdown].freeze
        OBSOLETE_WORKFLOWS = %w[ancient.yml legacy.yml supported.yml unsupported.yml main.yml hoary.yml].freeze

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
        # Minimum Jaccard-style token overlap ratio to fuzzy-match two list nodes via
        # the match refiner. Once matched, inner_merge_lists handles item-level merging.
        MARKDOWN_LIST_MATCH_THRESHOLD = 0.4
        # Fuzzy match refiner for unmatched Markdown block nodes.
        #
        # Handles two categories of unmatched nodes:
        #   • paragraphs – uses position-aware content similarity
        #   • lists      – uses significant-token overlap so that lists with similar
        #                  content (but different item counts or minor wording changes)
        #                  are paired and handed off to ListMerger for item-level merge
        MARKDOWN_PARAGRAPH_MATCH_REFINER = lambda do |template_nodes, dest_nodes, _context|
          template_paragraphs = template_nodes.select { |node| TemplateTask.markdown_paragraph_node?(node) }
          dest_paragraphs = dest_nodes.select { |node| TemplateTask.markdown_paragraph_node?(node) }
          template_lists = template_nodes.select { |node| TemplateTask.markdown_list_node?(node) }
          dest_lists = dest_nodes.select { |node| TemplateTask.markdown_list_node?(node) }

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

          unless template_lists.empty? || dest_lists.empty?
            template_lists.each do |template_node|
              dest_lists.each do |dest_node|
                score = TemplateTask.markdown_list_match_score(template_node, dest_node)
                next if score < MARKDOWN_LIST_MATCH_THRESHOLD

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

        def markdown_list_node?(node)
          return false unless node.respond_to?(:type)

          node.type.to_sym == :list
        rescue StandardError
          false
        end

        # Compute a similarity score for two list nodes based on Jaccard-style
        # overlap of their significant tokens.  Returns 0.0..1.0.
        def markdown_list_match_score(template_node, dest_node)
          template_tokens = markdown_significant_tokens(template_node&.text)
          dest_tokens = markdown_significant_tokens(dest_node&.text)
          return 0.0 if template_tokens.empty? || dest_tokens.empty?

          overlap = (template_tokens & dest_tokens).size
          overlap.to_f / [template_tokens.size, dest_tokens.size].max
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
          config_emoji = helpers.kettle_config["project_emoji"] || ENV["KJ_PROJECT_EMOJI"].to_s
          config_emoji = nil if config_emoji.to_s.strip.empty?

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
          puts "WARNING: Could not synchronize README H1 grapheme with gemspec metadata: #{e.class}: #{e.message}"
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
              RBS::Merge::SmartMerger.new(
                content,
                dest_content,
                preference: :template,
                add_template_only_nodes: true,
                freeze_token: "kettle-jem",
              ).merge
            elsif file_type == :tool_versions
              # .tool-versions: text-merge with first-word signature matching.
              # Lines match by tool name (e.g., "ruby"), so template version
              # values replace destination values while destination-only tools
              # are preserved.
              Ast::Merge::Text::SmartMerger.new(
                content,
                dest_content,
                preference: :template,
                add_template_only_nodes: true,
                signature_generator: TOOL_VERSIONS_SIGNATURE_GENERATOR,
              ).merge
            else
              # Text files: text-merge. For .gitignore specifically, include
              # template-only lines so new ignore rules are added to existing
              # destination files.
              text_merge_options = {
                preference: :template,
              }
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
          # tree-sitter or other structural parser unavailable for this file type;
          # fall back to line-based text merge so dest-only content is preserved.
          Kernel.warn("[kettle-jem] #{rel}: #{e.message}; falling back to text merge")
          result = Ast::Merge::Text::SmartMerger.new(
            content,
            dest_content,
            preference: :template,
            add_template_only_nodes: true,
          ).merge
          SourceMerger.ensure_trailing_newline((result.is_a?(String) && !result.empty?) ? result : content)
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
            elsif tool_versions_file?(rel)
              :tool_versions
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
          report_path: nil
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

        # Determine the failure mode for merge operations.
        #
        # @return [Symbol] :error (default) or :rescue
        #   - :error  — merge failures raise Kettle::Dev::Error, halting the template task
        #   - :rescue — merge failures are logged and the unmerged content is used instead
        def failure_mode
          val = ENV.fetch("FAILURE_MODE", "error").to_s.strip.downcase
          (val == "rescue") ? :rescue : :error
        end

        YAML_EXTENSIONS = %w[.yml .yaml].freeze
        BASH_EXTENSIONS = %w[.sh .bash].freeze
        # Basenames that are shell scripts without a shell extension
        BASH_BASENAMES = %w[.envrc].freeze
        # Tool-owned bootstrap files that should be refreshed from the template
        # rather than structurally merged.
        ACCEPT_TEMPLATE_PATHS = %w[bin/setup].freeze
        # Basenames that use "tool version" key-value format (first word = key)
        TOOL_VERSIONS_BASENAMES = %w[.tool-versions].freeze
        # Tree-sitter grammar languages whose paths we attempt to auto-discover
        # and write into mise.toml so they are available to subsequent runs.
        TREE_SITTER_GRAMMAR_LANGUAGES = %w[
          bash css javascript json jsonc python rbs ruby toml yaml
        ].freeze

        # Custom signature generator for .tool-versions files.
        # Matches lines by the tool name (first word) so that e.g.
        # "ruby 3.2.0" in the destination matches "ruby 4.0.0" in the template.
        # With preference: :template, the template version value wins while
        # destination-only tool entries are preserved.
        TOOL_VERSIONS_SIGNATURE_GENERATOR = ->(node) {
          return node unless node.respond_to?(:content)
          first_word = node.content.to_s.strip.split(/\s+/, 2).first
          return node if first_word.nil? || first_word.empty?
          [:line, first_word]
        }.freeze

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

        def tool_versions_file?(relative_path)
          base = File.basename(relative_path.to_s)
          TOOL_VERSIONS_BASENAMES.include?(base)
        end

        def accept_template_path?(relative_path)
          ACCEPT_TEMPLATE_PATHS.include?(relative_path.to_s)
        end

        # Abort wrapper that avoids terminating the entire process during specs
        def task_abort(msg)
          raise Kettle::Dev::Error, msg
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

          return :present if bootstrapped_files.empty?

          # Only require a manual review + re-run when .kettle-jem.yml itself
          # was freshly created.  Auto-generated infrastructure files like
          # mise.toml and .config/mise/env.sh don't need user review and
          # shouldn't block the rest of the template phases.
          unless config_bootstrapped
            bootstrapped_files.each { |f| puts "[kettle-jem] Wrote #{f}." }
            return :present
          end

          helpers.template_run_outcome = :bootstrap_only
          bootstrapped_files.each { |f| puts "[kettle-jem] Wrote #{f}." }
          puts "[kettle-jem] Review the file(s) above, fill in any missing token values, then:"
          puts "[kettle-jem]   mise trust -C #{project_root}"
          puts "[kettle-jem] Commit the changes and re-run kettle-jem."
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
            c
          end
          helpers.clear_kettle_config!
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
              File.basename(path).match?(/\A(Gemfile|Rakefile|Appraisals|REEK|\.envrc|\.env|\.rspec|\.yardopts|\.gitignore|\.rubocop|LICENSE)\z/i)

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
          Kettle::Jem::TemplatingReport.print(snapshot: templating_environment)
          puts "[kettle-jem] Per-run report: #{templating_report_path}" if templating_report_path

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
          project_emoji = helpers.kettle_config["project_emoji"] || ENV["KJ_PROJECT_EMOJI"].to_s
          unless project_emoji && !project_emoji.to_s.strip.empty?
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

          # 0) .kettle-jem.yml — keep existing config in sync with the template after
          # preflight has confirmed we have the required token values.
          begin
            sync_existing_kettle_config!(
              helpers: helpers,
              project_root: project_root,
              template_root: template_root,
              token_options: {
                org: forge_org,
                gem_name: gem_name,
                namespace: namespace,
                namespace_shield: namespace_shield,
                gem_shield: gem_shield,
                funding_org: funding_org,
                min_ruby: min_ruby,
              },
            )
          rescue StandardError => e
            Kettle::Dev.debug_error(e, __method__)
          end

          # sync_existing_kettle_config! temporarily seeds and clears token state
          # while rewriting .kettle-jem.yml, so restore the full replacement map
          # before templating the rest of the project files.
          # Token configuration failure is FATAL — see comment above.
          helpers.configure_tokens!(
            org: forge_org,
            gem_name: gem_name,
            namespace: namespace,
            namespace_shield: namespace_shield,
            gem_shield: gem_shield,
            funding_org: funding_org,
            min_ruby: min_ruby,
          )

          # 1) .devcontainer directory — per-file merging with format-appropriate merge gems
          devcontainer_src_dir = File.join(template_root, ".devcontainer")
          if Dir.exist?(devcontainer_src_dir)
            require "find"
            Find.find(devcontainer_src_dir) do |path|
              next if File.directory?(path)

              rel = path.sub(%r{^#{Regexp.escape(devcontainer_src_dir)}/?}, "")
              src = helpers.prefer_example(path)
              dest_rel = rel.sub(/\.example\z/, "")
              dest = File.join(project_root, ".devcontainer", dest_rel)
              next unless File.exist?(src)

              file_strategy = helpers.strategy_for(dest)
              next if file_strategy == :keep_destination
              if file_strategy == :raw_copy
                helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true, raw: true)
                next
              end

              helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true) do |content|
                c = content
                if file_strategy != :accept_template && File.exist?(dest)
                  begin
                    merger_class = case dest_rel
                    when /\.json$/
                      Json::Merge::SmartMerger
                    when /\.sh$/
                      Bash::Merge::SmartMerger
                    end
                    if merger_class
                      c = merger_class.new(
                        c,
                        File.read(dest),
                        preference: :template,
                        add_template_only_nodes: true,
                        freeze_token: "kettle-jem",
                      ).merge
                    end
                  rescue Ast::Merge::DestinationParseError => e
                    # Destination has syntax errors; cannot safely merge — use template content.
                    Kernel.warn("[kettle-jem] #{File.basename(dest)}: #{e.message}; destination is unparseable, using template content")
                  rescue Ast::Merge::ParseError => e
                    # tree-sitter parser unavailable; fall back to line-based text merge
                    Kernel.warn("[kettle-jem] #{File.basename(dest)}: #{e.message}; falling back to text merge")
                    c = Ast::Merge::Text::SmartMerger.new(
                      c,
                      File.read(dest),
                      preference: :template,
                      add_template_only_nodes: true,
                    ).merge
                  rescue StandardError => e
                    Kettle::Dev.debug_error(e, __method__)
                  end
                end
                c
              end
            end
          end

          # 2) .github/**/*.yml with FUNDING.yml customizations
          source_github_dir = File.join(template_root, ".github")
          if Dir.exist?(source_github_dir)
            # Build a unique set of logical .yml paths, preferring the .example variant when present
            candidates = Dir.glob(File.join(source_github_dir, "**", "*.yml")) +
              Dir.glob(File.join(source_github_dir, "**", "*.yml.example"))
            selected = {}
            candidates.each do |path|
              # Key by the path without the optional .example suffix
              key = path.sub(/\.example\z/, "")
              # Prefer example: overwrite a plain selection with .example, but do not downgrade
              if path.end_with?(".example")
                selected[key] = path
              else
                selected[key] ||= path
              end
            end
            # Parse optional include patterns (comma-separated globs relative to project root)
            include_raw = ENV["include"].to_s
            include_patterns = include_raw.split(",").map { |s| s.strip }.reject(&:empty?)
            matches_include = lambda do |abs_dest|
              return false if include_patterns.empty?
              begin
                rel_dest = abs_dest.to_s
                proj = project_root.to_s
                if rel_dest.start_with?(proj + "/")
                  rel_dest = rel_dest[(proj.length + 1)..-1]
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
            end

            selected.values.each do |orig_src|
              src = helpers.prefer_example_with_osc_check(orig_src)
              rel = orig_src.sub(/^#{Regexp.escape(template_root)}\/?/, "").sub(/\.example\z/, "")
              dest = File.join(project_root, rel)
              next unless File.exist?(src)

              file_strategy = helpers.strategy_for(dest)
              next if file_strategy == :keep_destination

              if helpers.skip_for_disabled_opencollective?(rel)
                puts "Skipping #{rel} (Open Collective disabled)"
                next
              end

              if helpers.skip_for_disabled_engine?(rel)
                puts "Skipping #{rel} (engine disabled)"
                next
              end

              if rel == ".github/workflows/discord-notifier.yml"
                unless matches_include.call(dest)
                  next
                end
              end

              if file_strategy == :raw_copy
                helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true, raw: true)
                next
              end

              if File.basename(rel) == "FUNDING.yml"
                helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true) do |content|
                  c = content
                  if file_strategy != :accept_template && File.exist?(dest)
                    begin
                      c = Psych::Merge::SmartMerger.new(
                        c,
                        File.read(dest),
                        preference: :template,
                        add_template_only_nodes: true,
                      ).merge
                    rescue StandardError => e
                      Kettle::Dev.debug_error(e, __method__)
                    end
                  end
                  c
                end
              else
                prepared = nil
                if rel.start_with?(".github/workflows/")
                  template_content = helpers.read_template(src)
                  c = template_content.dup
                  if file_strategy != :accept_template && File.exist?(dest)
                    begin
                      c = Psych::Merge::SmartMerger.new(
                        c,
                        File.read(dest),
                        **Presets::Yaml.workflow_config.to_h,
                      ).merge
                      # psych-merge strips the YAML document separator (---).
                      # Restore it when the template starts with one.
                      if template_content.start_with?("---\n") && !c.start_with?("---\n")
                        c = "---\n#{c}"
                      end
                    rescue StandardError => e
                      Kettle::Dev.debug_error(e, __method__)
                    end
                  end
                  c, _removed_count, _total_count, empty = prune_workflow_matrix_by_appraisals(c, removed_appraisals)
                  if empty
                    if File.exist?(dest)
                      helpers.add_warning("Workflow #{rel} has no remaining matrix entries for min Ruby #{min_ruby}; consider removing the file")
                    end
                    next
                  end
                  c, _eng_removed, _eng_total, eng_empty = prune_workflow_matrix_by_engines(c, helpers.engines_config)
                  if eng_empty
                    if File.exist?(dest)
                      helpers.add_warning("Workflow #{rel} has no remaining matrix entries after engine filtering; consider removing the file")
                    end
                    next
                  end
                  # Normalize stray blank lines left by engine/appraisal pruning.
                  # After removing matrix include blocks, trailing blank lines
                  # can remain before "steps:". Collapse triple+ newlines to
                  # double, and remove the blank line directly before "steps:".
                  c = c.gsub(/\n{3,}/, "\n\n")
                  c = c.gsub(/\n\n(\s+steps:)/, "\n\\1")
                  prepared = c
                end

                helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true) do |content|
                  prepared || content
                end
              end
            end
          end

          # 2b) Clean up obsolete workflow files that were replaced by per-ruby workflows.
          #     These filenames no longer exist in the template and would remain as orphans.
          actual_root = helpers.output_dir || project_root
          OBSOLETE_WORKFLOWS.each do |wf|
            wf_path = File.join(actual_root, ".github", "workflows", wf)
            next unless File.exist?(wf_path)

            if helpers.ask("Remove obsolete workflow #{wf}?", true)
              FileUtils.rm_f(wf_path)
              puts "Removed obsolete workflow: .github/workflows/#{wf}"
            else
              puts "Kept obsolete workflow: .github/workflows/#{wf}"
            end
          end

          # 3) .qlty/qlty.toml — merge with TOML-aware SmartMerger
          qlty_src = helpers.prefer_example(File.join(template_root, ".qlty/qlty.toml"))
          qlty_dest = File.join(project_root, ".qlty/qlty.toml")
          qlty_strategy = helpers.strategy_for(qlty_dest)
          unless qlty_strategy == :keep_destination
            if qlty_strategy == :raw_copy
              helpers.copy_file_with_prompt(
                qlty_src,
                qlty_dest,
                allow_create: true,
                allow_replace: true,
                raw: true,
              )
            else
              helpers.copy_file_with_prompt(
                qlty_src,
                qlty_dest,
                allow_create: true,
                allow_replace: true,
              ) do |content|
                c = content
                if qlty_strategy != :accept_template && File.exist?(qlty_dest)
                  begin
                    c = Toml::Merge::SmartMerger.new(
                      c,
                      File.read(qlty_dest),
                      preference: :template,
                      add_template_only_nodes: true,
                      freeze_token: "kettle-jem",
                    ).merge
                  rescue StandardError => e
                    Kettle::Dev.debug_error(e, __method__)
                  end
                end
                c
              end
            end
          end

          # 4) gemfiles/modular/* and nested directories (delegated for DRYness)
          Kettle::Jem::ModularGemfiles.sync!(
            helpers: helpers,
            project_root: project_root,
            min_ruby: min_ruby,
            gem_name: gem_name,
          )

          # 5) spec/spec_helper.rb (no create)
          dest_spec_helper = File.join(project_root, "spec/spec_helper.rb")
          if File.file?(dest_spec_helper)
            old = File.read(dest_spec_helper)
            if old.include?('require "kettle/dev"') || old.include?("require 'kettle/dev'")
              replacement = %(require "#{entrypoint_require}")
              new_content = old.gsub(/require\s+["']kettle\/dev["']/, replacement)
              if new_content != old
                if helpers.ask("Update require \"kettle/dev\" in spec/spec_helper.rb to #{replacement}?", true)
                  helpers.write_file(dest_spec_helper, new_content)
                  puts "Updated require in spec/spec_helper.rb"
                else
                  puts "Skipped modifying spec/spec_helper.rb"
                end
              end
            end
          end

          # 6) .env.local.example: merge template env vars with existing destination using dotenv-merge
          begin
            envlocal_src = File.join(template_root, ".env.local.example")
            envlocal_dest = File.join(project_root, ".env.local.example")
            if File.exist?(envlocal_src)
              envlocal_strategy = helpers.strategy_for(envlocal_dest)
              unless envlocal_strategy == :keep_destination
                if envlocal_strategy == :raw_copy
                  helpers.copy_file_with_prompt(envlocal_src, envlocal_dest, allow_create: true, allow_replace: true, raw: true)
                else
                  helpers.copy_file_with_prompt(envlocal_src, envlocal_dest, allow_create: true, allow_replace: true) do |content|
                    if envlocal_strategy != :accept_template && File.exist?(envlocal_dest)
                      begin
                        Dotenv::Merge::SmartMerger.new(
                          content,
                          File.read(envlocal_dest),
                          preference: :destination,
                          add_template_only_nodes: true,
                          freeze_token: "kettle-jem",
                        ).merge
                      rescue StandardError => e
                        Kettle::Dev.debug_error(e, __method__)
                        content
                      end
                    else
                      content
                    end
                  end
                end
              end
            end
          rescue StandardError => e
            Kettle::Dev.debug_error(e, __method__)
            puts "WARNING: Skipped .env.local example copy due to #{e.class}: #{e.message}"
          end

          begin
            bootstrap_version_gem_touchpoints!(helpers: helpers, project_root: project_root, meta: meta)
          rescue StandardError => e
            Kettle::Dev.debug_error(e, __method__)
            puts "WARNING: Skipped version_gem bootstrap due to #{e.class}: #{e.message}"
          end

          # 7a) Special-case: gemspec example must be renamed to destination gem's name
          begin
            # Prefer the .example variant when present
            gemspec_template_src = helpers.prefer_example(File.join(template_root, "gem.gemspec"))
            if File.exist?(gemspec_template_src)
              dest_gemspec = if gem_name && !gem_name.to_s.empty?
                File.join(project_root, "#{gem_name}.gemspec")
              else
                # Fallback rules:
                # 1) Prefer any existing gemspec in the destination project
                existing = Dir.glob(File.join(project_root, "*.gemspec")).sort.first
                if existing
                  existing
                else
                  # 2) If none, use the example file's name with ".example" removed
                  fallback_name = File.basename(gemspec_template_src).sub(/\.example\z/, "")
                  File.join(project_root, fallback_name)
                end
              end

              gemspec_strategy = helpers.strategy_for(dest_gemspec)
              unless gemspec_strategy == :keep_destination
                orig_meta = nil
                dest_existed = File.exist?(dest_gemspec)
                if dest_existed
                  begin
                    orig_meta = helpers.gemspec_metadata(File.dirname(dest_gemspec))
                  rescue StandardError => e
                    Kettle::Dev.debug_error(e, __method__)
                    orig_meta = nil
                  end
                end

                if gemspec_strategy == :raw_copy
                  helpers.copy_file_with_prompt(gemspec_template_src, dest_gemspec, allow_create: true, allow_replace: true, raw: true)
                else
                  helpers.copy_file_with_prompt(gemspec_template_src, dest_gemspec, allow_create: true, allow_replace: true) do |content|
                    c = content

                    if gemspec_strategy != :accept_template && orig_meta
                      repl = {}
                      if (name = orig_meta[:gem_name]) && !name.to_s.empty?
                        repl[:name] = name.to_s
                      end
                      repl[:authors] = Array(orig_meta[:authors]).map(&:to_s) if orig_meta[:authors]
                      repl[:email] = Array(orig_meta[:email]).map(&:to_s) if orig_meta[:email]
                      repl[:summary] = orig_meta[:summary].to_s if orig_meta[:summary] && !orig_meta[:summary].to_s.strip.empty?
                      repl[:description] = orig_meta[:description].to_s if orig_meta[:description] && !orig_meta[:description].to_s.strip.empty?
                      repl[:licenses] = helpers.resolved_licenses
                      if orig_meta[:required_ruby_version]
                        repl[:required_ruby_version] = orig_meta[:required_ruby_version].to_s
                      end
                      repl[:require_paths] = Array(orig_meta[:require_paths]).map(&:to_s) if orig_meta[:require_paths]
                      repl[:bindir] = orig_meta[:bindir].to_s if orig_meta[:bindir]
                      repl[:executables] = Array(orig_meta[:executables]).map(&:to_s) if orig_meta[:executables]

                      begin
                        c = Kettle::Jem::PrismGemspec.replace_gemspec_fields(c, repl)
                      rescue StandardError => e
                        Kettle::Dev.debug_error(e, __method__)
                      end

                    end

                    begin
                      if gem_name && !gem_name.to_s.empty?
                        begin
                          c = Kettle::Jem::PrismGemspec.remove_spec_dependency(c, gem_name)
                        rescue StandardError => e
                          Kettle::Dev.debug_error(e, __method__)
                        end
                      end
                    rescue StandardError => e
                      Kettle::Dev.debug_error(e, __method__)
                    end

                    gemspec_context = if orig_meta && orig_meta[:min_ruby] && orig_meta[:entrypoint_require] && orig_meta[:namespace]
                      {
                        min_ruby: orig_meta[:min_ruby],
                        entrypoint_require: orig_meta[:entrypoint_require],
                        namespace: orig_meta[:namespace],
                      }
                    end

                    if dest_existed || gemspec_context
                      begin
                        merged = helpers.apply_strategy(c, dest_gemspec, context: gemspec_context)
                        c = merged if merged.is_a?(String) && !merged.empty?
                      rescue StandardError => e
                        Kettle::Dev.debug_error(e, __method__)
                      end
                    end

                    c
                  end
                end
              end
            end
          rescue StandardError => e
            Kettle::Dev.debug_error(e, __method__)
          end

          # 7) Discover and copy all remaining template files.
          #
          # Walks the template/ directory to find every file. Files already
          # handled by earlier steps are excluded. Everything else gets
          # apply_common_replacements with per-file special handling for
          # README.md, CHANGELOG.md, and markdown spacing normalization.
          #
          # Prefixes that are handled by dedicated steps above:
          #   .devcontainer/      → step 1 (per-file merging: JSONC, JSON, Bash)
          #   .github/**/*.yml    → step 2 (dynamic discovery + FUNDING.yml; non-yml files handled here)
          #   .qlty/              → step 3 (TOML merge)
          #   gemfiles/modular/   → step 4 (ModularGemfiles.sync!)
          #   .env.local.example  → step 6 (dotenv-merge; rel is ".env.local" after .example strip)
          #   *.gemspec           → step 7a (renamed + field carry-over)
          #   .git-hooks/         → handled after this block (per-file merging: Text, Prism, Bash)
          handled_prefixes = %w[
            .devcontainer/
            .qlty/
            gemfiles/modular/
            .git-hooks/
          ]
          handled_files = %w[
            .env.local
            .kettle-jem.yml
            LICENSE.md
            MIT.md
            AGPL-3.0-only.md
            PolyForm-Noncommercial-1.0.0.md
            PolyForm-Small-Business-1.0.0.md
            Big-Time-Public-License.md
          ]

          template_root = helpers.template_root
          if Dir.exist?(template_root)
            require "find"
            Find.find(template_root) do |path|
              next if File.directory?(path)

              # Compute relative path from template root, stripping .example / .no-osc.example suffixes
              rel = path.sub(%r{^#{Regexp.escape(template_root)}/?}, "")
                .sub(/\.no-osc\.example\z/, "")
                .sub(/\.example\z/, "")

              # Skip files handled by dedicated steps
              next if handled_prefixes.any? { |prefix| rel.start_with?(prefix) }
              next if handled_files.include?(rel)
              next if rel.end_with?(".gemspec") # gemspec handled in step 7a
              # .github/**/*.yml files are handled by step 2 (dynamic discovery + FUNDING.yml)
              next if rel.start_with?(".github/") && rel.end_with?(".yml")

              # Skip opencollective-specific files when Open Collective is disabled
              if helpers.skip_for_disabled_opencollective?(rel)
                puts "Skipping #{rel} (Open Collective disabled)"
                next
              end

              src = helpers.prefer_example_with_osc_check(File.join(template_root, rel))
              dest = File.join(project_root, rel)
              next unless File.exist?(src)

              # Raw copy: no token resolution, no merging (e.g., certs/)
              if raw_copy?(rel)
                begin
                  helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true, raw: true)
                rescue StandardError => e
                  Kettle::Dev.debug_error(e, __method__)
                  puts "WARNING: Could not copy #{rel}: #{e.class}: #{e.message}"
                end
                next
              end

              begin
                file_strategy = helpers.strategy_for(dest)
                if file_strategy == :keep_destination
                  next
                end

                if file_strategy == :raw_copy
                  helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true, raw: true)
                  next
                end

                if accept_template_path?(rel)
                  helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true)
                elsif File.basename(rel) == "README.md"
                  prev_readme = File.exist?(dest) ? File.read(dest) : nil

                  helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true) do |content|
                    c = content
                    if file_strategy != :accept_template
                      begin
                        c = MarkdownMerger.merge(
                          template_content: c,
                          destination_content: prev_readme,
                        )
                      rescue StandardError => e
                        Kettle::Dev.debug_error(e, __method__)
                      end
                    end
                    c = normalize_markdown_spacing(c) if markdown_heading_file?(rel)
                    c = Kettle::Jem::ReadmePostProcessor.process(content: c, min_ruby: min_ruby, engines: helpers.engines_config)
                    c
                  end
                elsif File.basename(rel) == "CHANGELOG.md"
                  helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true) do |content|
                    c = content
                    if file_strategy != :accept_template
                      begin
                        dest_content = File.file?(dest) ? File.read(dest) : ""
                        c = ChangelogMerger.merge(
                          template_content: c,
                          destination_content: dest_content,
                        )
                      rescue StandardError => e
                        Kettle::Dev.debug_error(e, __method__)
                      end
                    end
                    c = normalize_markdown_spacing(c) if markdown_heading_file?(rel)
                    c
                  end
                else
                  helpers.copy_file_with_prompt(src, dest, allow_create: true, allow_replace: true) do |content|
                    c = content
                    if file_strategy == :accept_template
                      # token-resolved template content wins; no merge
                    elsif File.exist?(dest)
                      c = merge_by_file_type(c, dest, rel, helpers)
                    end
                    c = normalize_markdown_spacing(c) if markdown_heading_file?(rel)
                    # Prune Appraisals entries for Ruby versions below min_ruby
                    # so that stale ruby-2.x blocks don't survive the merge.
                    if File.basename(rel) == "Appraisals" && min_ruby
                      begin
                        c, _removed = Kettle::Jem::PrismAppraisals.prune_ruby_appraisals(c, min_ruby: min_ruby)
                      rescue StandardError => e
                        Kettle::Dev.debug_error(e, __method__)
                      end
                    end
                    c
                  end
                end
              rescue StandardError => e
                Kettle::Dev.debug_error(e, __method__)
                puts "WARNING: Could not template #{rel}: #{e.class}: #{e.message}"
              end
            end
          end

          sync_readme_gemspec_grapheme!(helpers: helpers, project_root: project_root, gem_name: gem_name)

          # After creating or replacing .envrc or .env.local.example, require review and exit unless allowed
          begin
            envrc_path = File.join(project_root, ".envrc")
            envlocal_example_path = File.join(project_root, ".env.local.example")
            changed_env_files = []
            changed_env_files << envrc_path if helpers.modified_by_template?(envrc_path)
            changed_env_files << envlocal_example_path if helpers.modified_by_template?(envlocal_example_path)
            if !changed_env_files.empty?
              if /\A(1|true|y|yes)\z/i.match?(ENV.fetch("allowed", "").to_s)
                puts "Detected updates to #{changed_env_files.map { |p| File.basename(p) }.join(" and ")}. Proceeding because allowed=true."
              else
                puts
                puts "IMPORTANT: The following environment-related files were created/updated:"
                changed_env_files.each { |p| puts "  - #{p}" }
                puts
                puts "Please review these files before continuing."
                puts "If mise prompts you to trust this repo, run:"
                puts "  mise trust"
                puts
                puts "After that, re-run to resume:"
                puts "  bundle exec rake kettle:jem:template allowed=true"
                puts "  # or to run the full install afterwards:"
                puts "  bundle exec rake kettle:jem:install allowed=true"
                task_abort("Aborting: review of environment files required before continuing.")
              end
            end
          rescue StandardError => e
            # Do not swallow intentional task aborts
            raise if e.is_a?(Kettle::Dev::Error)

            puts "WARNING: Could not determine env file changes: #{e.class}: #{e.message}"
          end

          # Handle .git-hooks files — per-file merging with format-appropriate merge gems
          source_hooks_dir = File.join(template_root, ".git-hooks")
          if Dir.exist?(source_hooks_dir)
            # Honor ENV["only"]: skip entire .git-hooks handling unless patterns include .git-hooks
            begin
              only_raw = ENV["only"].to_s
              if !only_raw.empty?
                patterns = only_raw.split(",").map { |s| s.strip }.reject(&:empty?)
                if !patterns.empty?
                  proj = helpers.project_root.to_s
                  target_dir = File.join(proj, ".git-hooks")
                  # Determine if any pattern would match either the directory itself (with /** semantics) or files within it
                  matches = patterns.any? do |pat|
                    if pat.end_with?("/**")
                      base = pat[0..-4]
                      base == ".git-hooks" || base == target_dir.sub(/^#{Regexp.escape(proj)}\/?/, "")
                    else
                      # Check for explicit .git-hooks or subpaths
                      File.fnmatch?(pat, ".git-hooks", File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH) ||
                        File.fnmatch?(pat, ".git-hooks/*", File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH)
                    end
                  end
                  unless matches
                    # No interest in .git-hooks => skip prompts and copies for hooks entirely
                    # Note: we intentionally do not record template_results for hooks
                    return
                  end
                end
              end
            rescue StandardError => e
              Kettle::Dev.debug_error(e, __method__)
              # If filter parsing fails, proceed as before
            end
            # Prefer .example variant when present for .git-hooks
            goalie_src = helpers.prefer_example(File.join(source_hooks_dir, "commit-subjects-goalie.txt"))
            footer_src = helpers.prefer_example(File.join(source_hooks_dir, "footer-template.erb.txt"))
            hook_ruby_src = helpers.prefer_example(File.join(source_hooks_dir, "commit-msg"))
            hook_sh_src = helpers.prefer_example(File.join(source_hooks_dir, "prepare-commit-msg"))

            # First: templates (.txt) — ask local/global/skip
            if File.file?(goalie_src) && File.file?(footer_src)
              puts
              puts "Git hooks templates found:"
              puts "  - #{goalie_src}"
              puts "  - #{footer_src}"
              puts
              puts "About these files:"
              puts "- commit-subjects-goalie.txt:"
              puts "  Lists commit subject prefixes to look for; if a commit subject starts with any listed prefix,"
              puts "  kettle-commit-msg will append a footer to the commit message (when GIT_HOOK_FOOTER_APPEND=true)."
              puts "  Defaults include release prep (🔖 Prepare release v) and checksum commits (🔒️ Checksums for v)."
              puts "- footer-template.erb.txt:"
              puts "  ERB template rendered to produce the footer. You can customize its contents and variables."
              puts
              puts "Where would you like to install these two templates?"
              puts "  [l] Local to this project (#{File.join(project_root, ".git-hooks")})"
              puts "  [g] Global for this user (#{File.join(ENV["HOME"], ".git-hooks")})"
              puts "  [s] Skip copying"
              # Allow non-interactive selection via environment
              # Precedence: CLI switch (hook_templates) > KETTLE_DEV_HOOK_TEMPLATES > prompt
              force_mode = Kettle::Dev::ENV_TRUE_RE.match?(ENV.fetch("force", "").to_s)
              non_interactive_mode = force_mode || !helpers.output_dir.nil?
              env_choice = ENV["hook_templates"]
              env_choice = ENV["KETTLE_DEV_HOOK_TEMPLATES"] if env_choice.nil? || env_choice.strip.empty?
              choice = env_choice&.strip
              unless choice && !choice.empty?
                if non_interactive_mode
                  choice = "l"
                  puts "Choose (l/g/s) [l]: l (non-interactive)"
                else
                  print("Choose (l/g/s) [l]: ")
                  choice = Kettle::Dev::InputAdapter.gets&.strip
                end
              end
              choice = "l" if choice.nil? || choice.empty?
              dest_dir = case choice.downcase
              when "g", "global" then File.join(ENV["HOME"], ".git-hooks")
              when "s", "skip" then nil
              else File.join(project_root, ".git-hooks")
              end

              if dest_dir
                FileUtils.mkdir_p(dest_dir)

                goalie_dest = File.join(dest_dir, "commit-subjects-goalie.txt")
                goalie_strategy = helpers.strategy_for(goalie_dest)
                unless goalie_strategy == :keep_destination
                  if goalie_strategy == :raw_copy
                    helpers.copy_file_with_prompt(goalie_src, goalie_dest, allow_create: true, allow_replace: true, raw: true)
                  else
                    helpers.copy_file_with_prompt(goalie_src, goalie_dest, allow_create: true, allow_replace: true) do |content|
                      if goalie_strategy != :accept_template && File.exist?(goalie_dest)
                        begin
                          content = Ast::Merge::Text::SmartMerger.new(
                            content,
                            File.read(goalie_dest),
                            preference: :template,
                            add_template_only_nodes: true,
                            freeze_token: "kettle-jem",
                          ).merge
                        rescue StandardError => e
                          Kettle::Dev.debug_error(e, __method__)
                        end
                      end
                      content
                    end
                  end
                end

                footer_dest = File.join(dest_dir, "footer-template.erb.txt")
                footer_strategy = helpers.strategy_for(footer_dest)
                unless footer_strategy == :keep_destination
                  if footer_strategy == :raw_copy
                    helpers.copy_file_with_prompt(footer_src, footer_dest, allow_create: true, allow_replace: true, raw: true)
                  else
                    helpers.copy_file_with_prompt(footer_src, footer_dest, allow_create: true, allow_replace: true) do |content|
                      c = helpers.apply_common_replacements(
                        content,
                        org: forge_org,
                        funding_org: funding_org,
                        gem_name: gem_name,
                        namespace: namespace,
                        namespace_shield: namespace_shield,
                        gem_shield: gem_shield,
                        min_ruby: min_ruby,
                      )
                      if footer_strategy != :accept_template && File.exist?(footer_dest)
                        begin
                          c = Ast::Merge::Text::SmartMerger.new(
                            c,
                            File.read(footer_dest),
                            preference: :template,
                            add_template_only_nodes: true,
                            freeze_token: "kettle-jem",
                          ).merge
                        rescue StandardError => e
                          Kettle::Dev.debug_error(e, __method__)
                        end
                      end
                      c
                    end
                  end
                end

                [goalie_dest, footer_dest].each do |txt_dest|
                  File.chmod(0o644, txt_dest) if File.exist?(txt_dest)
                rescue StandardError => e
                  Kettle::Dev.debug_error(e, __method__)
                end
              else
                puts "Skipping copy of .git-hooks templates."
              end
            end

            hook_dest_dir = File.join(project_root, ".git-hooks")
            begin
              FileUtils.mkdir_p(hook_dest_dir)
            rescue StandardError => e
              puts "WARNING: Could not create #{hook_dest_dir}: #{e.class}: #{e.message}"
              hook_dest_dir = nil
            end

            if hook_dest_dir
              if File.file?(hook_ruby_src)
                commit_msg_dest = File.join(hook_dest_dir, "commit-msg")
                commit_msg_strategy = helpers.strategy_for(commit_msg_dest)
                unless commit_msg_strategy == :keep_destination
                  if commit_msg_strategy == :raw_copy
                    helpers.copy_file_with_prompt(hook_ruby_src, commit_msg_dest, allow_create: true, allow_replace: true, raw: true)
                  else
                    helpers.copy_file_with_prompt(hook_ruby_src, commit_msg_dest, allow_create: true, allow_replace: true) do |content|
                      c = content
                      c = merge_by_file_type(c, commit_msg_dest, helpers.rel_path(commit_msg_dest), helpers) if commit_msg_strategy != :accept_template && File.exist?(commit_msg_dest)
                      c
                    end
                  end
                  begin
                    File.chmod(0o755, commit_msg_dest) if File.exist?(commit_msg_dest)
                  rescue StandardError => e
                    Kettle::Dev.debug_error(e, __method__)
                  end
                end
              end

              if File.file?(hook_sh_src)
                prepare_msg_dest = File.join(hook_dest_dir, "prepare-commit-msg")
                prepare_msg_strategy = helpers.strategy_for(prepare_msg_dest)
                unless prepare_msg_strategy == :keep_destination
                  if prepare_msg_strategy == :raw_copy
                    helpers.copy_file_with_prompt(hook_sh_src, prepare_msg_dest, allow_create: true, allow_replace: true, raw: true)
                  else
                    helpers.copy_file_with_prompt(hook_sh_src, prepare_msg_dest, allow_create: true, allow_replace: true) do |content|
                      c = content
                      c = merge_by_file_type(c, prepare_msg_dest, helpers.rel_path(prepare_msg_dest), helpers) if prepare_msg_strategy != :accept_template && File.exist?(prepare_msg_dest)
                      c
                    end
                  end
                  begin
                    File.chmod(0o755, prepare_msg_dest) if File.exist?(prepare_msg_dest)
                  rescue StandardError => e
                    Kettle::Dev.debug_error(e, __method__)
                  end
                end
              end
            end
          end

          # Copy selected SPDX license files + LICENSE.md, then migrate old LICENSE.txt.
          begin
            copy_selected_license_files!(
              helpers: helpers,
              project_root: project_root,
              template_root: template_root,
            )
            remove_obsolete_license_files!(
              helpers: helpers,
              project_root: project_root,
              template_root: template_root,
            )
            migrate_license_txt!(helpers: helpers, project_root: project_root)
            collect_git_copyright!(helpers: helpers, project_root: project_root)
          rescue StandardError => e
            Kettle::Dev.debug_error(e, __method__)
            puts "WARNING: License file migration failed: #{e.class}: #{e.message}"
          end

          # Scan all written files for unresolved {KJ|...} tokens and abort.
          # Unresolved tokens indicate missing configuration (e.g., AUTHOR_NAME,
          # FUNDING_LIBERAPAY). The user should add missing values to .kettle-jem.yml
          # or environment variables and re-run.
          begin
            unresolved_by_file = unresolved_written_tokens(
              helpers: helpers,
              project_root: project_root,
            )

            unless unresolved_by_file.empty?
              msg_lines = ["Unresolved {KJ|...} tokens found in #{unresolved_by_file.size} file(s):"]
              unresolved_by_file.each do |rel, tokens|
                msg_lines << "  #{rel}: #{tokens.join(", ")}"
              end
              msg_lines << ""
              msg_lines << "Please set the required environment variables or add values to .kettle-jem.yml and re-run."
              msg_lines << "Tip: .kettle-jem.yml was written first so you can commit it and fill in missing data."

              helpers.add_warning(msg_lines.join("\n"))
              helpers.print_warnings_summary

              task_abort(msg_lines.first)
            end
          rescue Kettle::Dev::Error
            raise # re-raise task_abort errors
          rescue StandardError => e
            Kettle::Dev.debug_error(e, __method__)
          end

          helpers.print_warnings_summary
          helpers.template_run_outcome = :complete

          nil
        ensure
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
          puts "Wrote #{lines.size} copyright line(s) to LICENSE.md."
        rescue StandardError => e
          Kettle::Dev.debug_error(e, __method__)
          puts "WARNING: Could not build copyright section: #{e.class}: #{e.message}"
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
            puts "WARNING: Could not copy license file #{base}.md: #{e.class}: #{e.message}"
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
                puts "Removed obsolete license file: #{base}.md (not in configured licenses)."
              rescue StandardError => e
                Kettle::Dev.debug_error(e, __method__)
                puts "WARNING: Could not remove obsolete license file #{base}.md: #{e.class}: #{e.message}"
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
            puts "LICENSE.txt does not appear to be an MIT license; leaving it in place."
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
            puts "Replaced fallback copyright with #{prefixed_lines.size} line(s) from LICENSE.txt in LICENSE.md."
          end

          File.delete(license_txt_path)
          puts "Deleted LICENSE.txt (content migrated to LICENSE.md)."
        rescue StandardError => e
          Kettle::Dev.debug_error(e, __method__)
          puts "WARNING: Could not migrate LICENSE.txt: #{e.class}: #{e.message}"
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
