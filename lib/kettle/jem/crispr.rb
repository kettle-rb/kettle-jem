# frozen_string_literal: true

require "service_actor"

module Kettle
  module Jem
    # CRISPR provides low-level, actor-backed structural editing primitives for
    # AST-first managed content. Owner selectors identify deterministic
    # structural owners and comment regions; actors then replace, insert,
    # delete, or move the owned spans.
    module Crispr
      class Error < Kettle::Jem::Error
        attr_reader :details

        def initialize(message, details: {}, **options)
          @details = details.merge(options)
          super(message)
        end
      end

      class Limit
        Constraint = Struct.new(:description, :predicate, keyword_init: true)

        class << self
          def coerce(limit = nil, **options)
            limit.is_a?(self) ? limit : new(limit, **options)
          end
        end

        attr_reader :constraints

        def initialize(limit = nil, **options)
          @constraints = normalize(limit, **options)
        end

        def allows?(count)
          constraints.all? { |constraint| constraint.predicate.call(count) }
        end

        def describe
          constraints.map(&:description).join(" and ")
        end

        private

        def normalize(limit, **options)
          spec = limit.nil? ? options.fetch(:default, {exactly: 1}) : limit

          case spec
          when Limit
            spec.constraints.dup
          when Hash
            normalize_hash(spec)
          when Array
            spec.flat_map { |entry| normalize(entry) }
          when String
            [constraint_for_operator(spec)]
          else
            raise Error.new("Unsupported CRISPR limit specification", details: {limit: spec.inspect})
          end
        end

        def normalize_hash(spec)
          constraints = []
          constraints << constraint("== #{spec.fetch(:exactly)}") { |count| count == spec.fetch(:exactly) } if spec.key?(:exactly)
          constraints << constraint("<= #{spec.fetch(:at_most)}") { |count| count <= spec.fetch(:at_most) } if spec.key?(:at_most)
          constraints << constraint(">= #{spec.fetch(:at_least)}") { |count| count >= spec.fetch(:at_least) } if spec.key?(:at_least)
          constraints << constraint("between #{spec.fetch(:between)}") { |count| spec.fetch(:between).cover?(count) } if spec.key?(:between)
          constraints << constraint("<= 1") { |count| count <= 1 } if spec[:none_or_one]
          raise Error.new("CRISPR limit must define at least one constraint", details: {limit: spec.inspect}) if constraints.empty?

          constraints
        end

        def constraint_for_operator(spec)
          match = /\A(==|!=|<=|>=|<|>)\s*(\d+)\z/.match(spec.strip)
          raise Error.new("Invalid CRISPR limit expression", details: {limit: spec.inspect}) unless match

          operator = match[1]
          value = match[2].to_i
          predicate = lambda do |count|
            case operator
            when "==" then count == value
            when "!=" then count != value
            when "<=" then count <= value
            when ">=" then count >= value
            when "<" then count < value
            when ">" then count > value
            else false
            end
          end
          constraint("#{operator} #{value}", &predicate)
        end

        def constraint(description, &predicate)
          Constraint.new(description: description, predicate: predicate)
        end
      end

      class Match
        attr_reader :target, :node, :start_line, :end_line, :metadata

        def initialize(target: nil, node: nil, start_line:, end_line:, metadata: {}, **options)
          @target = target
          @node = node
          @start_line = Integer(start_line)
          @end_line = Integer(end_line)
          @metadata = metadata.merge(options)
          raise Error.new("CRISPR match end_line must be >= start_line", details: {start_line: @start_line, end_line: @end_line}) if @end_line < @start_line
        end

        def with_target(target)
          return self if self.target.equal?(target)

          self.class.new(
            target: target,
            node: node,
            start_line: start_line,
            end_line: end_line,
            metadata: metadata,
          )
        end

        def line_range
          start_line..end_line
        end

        def slice_from(content)
          lines = content.to_s.lines
          return "" if lines.empty?

          lines[(start_line - 1)..(end_line - 1)].to_a.join
        end
      end

      module Adapters
        class RubyPrism
          def read_ast(document)
            result = Kettle::Jem::PrismUtils.parse_with_comments(document.content)
            return result if result.success?

            raise Error.new("Unable to read structural owners from #{document.source_label}", details: {source_label: document.source_label})
          end

          def structural_owners(document, owner_scope: :shared_default)
            parse_result = document.ast
            case owner_scope
            when :shared_default, :line_bound_statements, :top_level_statements
              Kettle::Jem::PrismUtils.extract_statements(parse_result.value.statements)
            else
              raise Error.new("Unsupported CRISPR owner scope", details: {owner_scope: owner_scope})
            end
          end

          def comment_regions_for(document, owner, region: :leading, owner_scope: :shared_default)
            parse_result = document.ast
            owners = structural_owners(document, owner_scope: owner_scope)
            index = owners.index(owner)
            return [] unless index

            case region
            when :leading
              previous_owner = index.positive? ? owners[index - 1] : nil
              if previous_owner
                Kettle::Jem::PrismUtils.find_leading_comments(parse_result, owner, previous_owner, parse_result.value.statements)
              else
                parse_result.comments.select { |comment| comment.location.start_line < owner.location.start_line }
              end
            else
              raise Error.new("Unsupported CRISPR comment region", details: {region: region})
            end
          end

          def comment_region_text(document, comment_region)
            document.location_slice(comment_region.location).rstrip
          end
        end

        class MarkdownMarkly
          Location = Struct.new(:start_line, :end_line, keyword_init: true)
          HeadingSectionOwner = Struct.new(
            :location,
            :heading_text,
            :heading_source,
            :level,
            :base,
            keyword_init: true,
          )

          def read_ast(document)
            analysis = Markly::Merge::FileAnalysis.new(document.content)
            return analysis if analysis.valid?

            raise Error.new("Unable to read structural owners from #{document.source_label}", details: {source_label: document.source_label})
          end

          def structural_owners(document, owner_scope: :shared_default)
            analysis = document.ast
            case owner_scope
            when :shared_default, :heading_sections
              build_heading_sections(analysis)
            else
              raise Error.new("Unsupported CRISPR owner scope", details: {owner_scope: owner_scope})
            end
          end

          def comment_regions_for(_document, _owner, region: :leading, owner_scope: :shared_default)
            raise Error.new(
              "Unsupported CRISPR comment region",
              details: {region: region, owner_scope: owner_scope},
            )
          end

          def comment_region_text(_document, _comment_region)
            raise Error.new("Markdown CRISPR adapter does not expose comment regions")
          end

          private

          def build_heading_sections(analysis)
            headings = Array(analysis.statements).filter_map do |statement|
              next unless heading_statement?(statement)

              build_heading_owner(statement, analysis)
            end

            headings.each_with_index.map do |owner, index|
              branch_end_line = branch_end_line(headings, index, analysis)
              HeadingSectionOwner.new(
                location: Location.new(start_line: owner.location.start_line, end_line: branch_end_line),
                heading_text: owner.heading_text,
                heading_source: owner.heading_source,
                level: owner.level,
                base: owner.base,
              )
            end
          end

          def heading_statement?(statement)
            merge_type = if statement.respond_to?(:merge_type)
              statement.merge_type
            else
              unwrap_markdown_statement(statement)&.type
            end

            merge_type.to_s == "heading" || merge_type.to_s == "header"
          end

          def build_heading_owner(statement, analysis)
            node = unwrap_markdown_statement(statement)
            position = node&.source_position
            return unless node && position

            heading_source = analysis.source_range(position[:start_line], position[:end_line]).sub(/\n\z/, "")
            heading_text = node.to_plaintext.to_s.sub(/\n+\z/, "")
            HeadingSectionOwner.new(
              location: Location.new(start_line: position[:start_line], end_line: position[:end_line]),
              heading_text: heading_text,
              heading_source: heading_source,
              level: node.header_level,
              base: normalize_heading_base(heading_text),
            )
          rescue StandardError
            nil
          end

          def branch_end_line(headings, index, analysis)
            current = headings[index]
            cursor = index + 1
            while cursor < headings.length
              return headings[cursor].location.start_line - 1 if headings[cursor].level <= current.level

              cursor += 1
            end

            analysis.source.to_s.lines.length
          end

          def unwrap_markdown_statement(statement)
            if defined?(Ast::Merge::NodeTyping)
              Ast::Merge::NodeTyping.unwrap(statement)
            else
              statement
            end
          rescue StandardError
            statement
          end

          def normalize_heading_base(text)
            text.to_s.sub(/\A(?:\d\uFE0F?\u20E3|[^[:alnum:][:space:]])+[ \t]*/u, "").strip.downcase
          end
        end
      end

      class DocumentContext
        attr_reader :content, :source_label, :metadata, :adapter

        def initialize(content:, source_label: "source", adapter: Adapters::RubyPrism.new, metadata: {}, **options)
          @content = content.to_s
          @source_label = source_label
          @adapter = adapter
          @metadata = metadata.merge(options)
        end

        def lines
          @lines ||= content.lines
        end

        def ast
          @ast ||= adapter.read_ast(self)
        end

        def structural_owners(owner_scope: :shared_default)
          adapter.structural_owners(self, owner_scope: owner_scope)
        end

        def comment_regions_for(owner, region: :leading, owner_scope: :shared_default)
          adapter.comment_regions_for(self, owner, region: region, owner_scope: owner_scope)
        end

        def comment_region_text(comment_region)
          adapter.comment_region_text(self, comment_region)
        end

        def location_slice(location)
          content.byteslice(location.start_offset...location.end_offset).to_s
        end

        def expand_following_gap(line_number)
          last_line = line_number
          while line_blank?(last_line + 1)
            last_line += 1
          end
          last_line
        end

        def line_blank?(line_number)
          line = lines[line_number - 1]
          !line.nil? && line.strip.empty?
        end
      end

      Context = DocumentContext

      class OwnerSelector
        attr_reader :id, :locate, :owned_span, :anchor, :limit, :metadata

        def initialize(id:, locate:, owned_span: nil, anchor: nil, limit: nil, metadata: {}, **options)
          @id = id
          @locate = locate
          @owned_span = owned_span
          @anchor = anchor
          @limit = Limit.coerce(limit, default: {exactly: 1})
          @metadata = metadata.merge(options)
        end

        def locate_matches(context)
          Array(invoke(locate, context)).flatten.compact.map { |candidate| coerce_match(candidate) }
        end

        def resolve_owned_match(context, match)
          candidate = owned_span ? invoke(owned_span, context, match) : match
          coerce_match(candidate).with_target(self)
        end

        def resolve_anchor(context, match = nil)
          return unless anchor

          invoke(anchor, context, match)
        end

        private

        def coerce_match(candidate)
          case candidate
          when Match
            candidate.with_target(self)
          when Hash
            Match.new(target: self, **candidate)
          else
            if candidate.respond_to?(:location) && candidate.location
              Match.new(
                target: self,
                node: candidate,
                start_line: candidate.location.start_line,
                end_line: candidate.location.end_line,
              )
            else
              raise Error.new("Unsupported CRISPR match result", details: {target: id, candidate: candidate.inspect})
            end
          end
        end

        def invoke(callable, *args)
          return callable.call(*args) if callable.arity.negative?

          callable.call(*args.first(callable.arity))
        end
      end

      Target = OwnerSelector

      module Selectors
        module_function

        def owner_filter(id:, limit: nil, owner_scope: :shared_default, include_trailing_gap: false, metadata: {}, &block)
          raise ArgumentError, "owner_filter requires a block" unless block

          OwnerSelector.new(
            id: id,
            limit: limit,
            metadata: metadata,
            locate: lambda do |context|
              context.structural_owners(owner_scope: owner_scope).filter_map do |owner|
                next unless owner.respond_to?(:location) && owner.location

                match = block.call(context, owner)
                next unless match

                if match.is_a?(Match)
                  match
                else
                  end_line = owner.location.end_line
                  end_line = context.expand_following_gap(end_line) if include_trailing_gap
                  Match.new(
                    node: owner,
                    start_line: owner.location.start_line,
                    end_line: end_line,
                    metadata: (match == true ? {} : match.to_h),
                  )
                end
              end
            end,
          )
        end

        def heading_section(heading_text:, level: nil, id: nil, limit: nil, adapter: Adapters::MarkdownMarkly.new, **options)
          OwnerSelector.new(
            id: id || "heading_section_#{heading_text}",
            limit: limit,
            metadata: options.merge(adapter: adapter),
            locate: lambda do |context|
              context.structural_owners(owner_scope: :heading_sections).filter_map do |owner|
                next unless owner.heading_text.to_s.strip == heading_text.to_s.strip
                next if level && owner.level != level

                Match.new(
                  node: owner,
                  start_line: owner.location.start_line,
                  end_line: owner.location.end_line,
                  metadata: {
                    heading_text: owner.heading_text,
                    level: owner.level,
                    base: owner.base,
                  },
                )
              end
            end,
          )
        end

        def comment_region_owned_owner(marker:, id: nil, limit: nil, owner_scope: :shared_default, comment_region: :leading, include_trailing_gap: true, **options)
          marker_text = marker.to_s.rstrip
          OwnerSelector.new(
            id: id || marker_text,
            limit: limit,
            locate: lambda do |context|
              context.structural_owners(owner_scope: owner_scope).filter_map do |owner|
                marker_region = context.comment_regions_for(owner, region: comment_region, owner_scope: owner_scope).find do |region|
                  context.comment_region_text(region) == marker_text
                end
                next unless marker_region

                end_line = owner.location.end_line
                end_line = context.expand_following_gap(end_line) if include_trailing_gap
                Match.new(
                  node: owner,
                  start_line: marker_region.location.start_line,
                  end_line: end_line,
                  metadata: {
                    marker: marker_text,
                    owner_scope: owner_scope,
                    comment_region: comment_region,
                    region: marker_region,
                  },
                )
              end
            end,
            **options,
          )
        end
      end

      Targets = Selectors

      module OperationSupport
        private

        def normalize_matches(target, context)
          matches = target.locate_matches(context)
          enforce_limit!(target, matches.size)
          matches.map { |match| target.resolve_owned_match(context, match) }
        end

        def context_for(content:, source_label:, target: nil)
          adapter = target&.metadata&.[](:adapter)
          if adapter
            DocumentContext.new(content: content, source_label: source_label, adapter: adapter)
          else
            DocumentContext.new(content: content, source_label: source_label)
          end
        end

        def enforce_limit!(target, count)
          return if target.limit.allows?(count)

          raise Error.new(
            "CRISPR target #{target.id.inspect} matched #{count} node(s); expected #{target.limit.describe}",
            details: {target: target.id, count: count, limit: target.limit.describe},
          )
        end

        def replace_line_ranges(source, matches, replacement)
          assert_non_overlapping!(matches)
          plans = matches.map do |match|
            Ast::Merge::StructuralEdit::SplicePlan.new(
              source: source,
              replace_start_line: match.start_line,
              replace_end_line: match.end_line,
              replacement: replacement,
            )
          end
          Ast::Merge::StructuralEdit::PlanSet.new(source: source, plans: plans).merged_content
        end

        def assert_non_overlapping!(matches)
          ranges = matches.map(&:line_range).sort_by(&:begin)
          ranges.each_cons(2) do |left, right|
            next if left.end < right.begin

            raise Error.new("CRISPR target spans overlap", details: {left: left, right: right})
          end
        end

        def insertion_from(content, destination, if_missing:, source_label:)
          return [:append, nil] if destination.nil? && if_missing == :append
          raise Error.new("Missing CRISPR insertion destination", details: {source_label: source_label}) if destination.nil?

          target = destination if destination.is_a?(OwnerSelector)
          context = context_for(content: content, source_label: source_label, target: target)
          anchor = if destination.is_a?(OwnerSelector)
            matches = normalize_matches(destination, context)
            raise Error.new("CRISPR destination target cannot be empty", details: {target: destination.id}) if matches.empty?

            destination.resolve_anchor(context, matches.first)
          else
            invoke_callable(destination, context)
          end

          if anchor.nil?
            return [:append, nil] if if_missing == :append

            raise Error.new("Unable to resolve CRISPR insertion destination", details: {source_label: source_label})
          end

          [:anchor, anchor]
        end

        def insert_text(content, text, destination:, if_missing:, source_label:)
          mode, anchor = insertion_from(content, destination, if_missing: if_missing, source_label: source_label)
          return append_to_end_of_file(content, text) if mode == :append

          splice_after_anchor(content, anchor, text)
        end

        def splice_after_anchor(content, injection_point, text)
          lines = content.lines
          start_line = statement_start_line(injection_point.anchor)
          end_line = expand_following_blank_lines(lines, statement_end_line(injection_point.anchor))
          raise Error.new("CRISPR insertion anchor is missing statement location") unless start_line && end_line

          replacement = lines[(start_line - 1)..(end_line - 1)].join + text.to_s.rstrip + "\n\n"
          Ast::Merge::StructuralEdit::PlanSet.new(
            source: content,
            plans: [
              Ast::Merge::StructuralEdit::SplicePlan.new(
                source: content,
                replace_start_line: start_line,
                replace_end_line: end_line,
                replacement: replacement,
              ),
            ],
          ).merged_content
        end

        def statement_start_line(statement)
          statement.start_line || statement.node&.location&.start_line
        end

        def statement_end_line(statement)
          statement.end_line || statement.node&.location&.end_line
        end

        def expand_following_blank_lines(lines, line_number)
          last_line = line_number
          while !lines[last_line].nil? && lines[last_line].strip.empty?
            last_line += 1
          end
          last_line
        end

        def append_to_end_of_file(content, text)
          body = content.rstrip
          return text.to_s if body.empty?

          body + "\n\n" + text.to_s
        end

        def capture_text(content, matches)
          matches.map { |match| match.slice_from(content).rstrip }.reject(&:empty?).join("\n\n")
        end

        def crispr_fail!(error)
          fail!(error: error.message, details: error.details)
        end

        def invoke_callable(callable, *args)
          return callable.call(*args) if callable.arity.negative?

          callable.call(*args.first(callable.arity))
        end
      end

      class Replace < Actor
        include OperationSupport

        input :content, type: String
        input :target, type: OwnerSelector
        input :replacement, allow_nil: true, default: nil
        input :source_label, type: String, default: "source"

        output :updated_content
        output :matches, default: -> { [] }
        output :match_count, type: Integer, default: 0
        output :changed, default: false
        output :captured_text, allow_nil: true, default: nil

        def call
          context = context_for(content: content, source_label: source_label, target: target)
          self.matches = normalize_matches(target, context)
          self.match_count = matches.size
          self.captured_text = capture_text(content, matches)
          if matches.empty?
            self.updated_content = content
            self.changed = false
            return
          end
          self.updated_content = replace_line_ranges(content, matches, replacement.to_s)
          self.changed = updated_content != content
        rescue Error => e
          crispr_fail!(e)
        end
      end

      class Delete < Actor
        include OperationSupport

        input :content, type: String
        input :target, type: OwnerSelector
        input :source_label, type: String, default: "source"

        output :updated_content
        output :matches, default: -> { [] }
        output :match_count, type: Integer, default: 0
        output :changed, default: false
        output :captured_text, allow_nil: true, default: nil

        def call
          actor = Replace.result(
            content: content,
            target: target,
            replacement: "",
            source_label: source_label,
          )
          fail!(error: actor.error, details: actor.details) if actor.failure?

          self.updated_content = actor.updated_content
          self.matches = actor.matches
          self.match_count = actor.match_count
          self.changed = actor.changed
          self.captured_text = actor.captured_text
        end
      end

      class Insert < Actor
        include OperationSupport

        input :content, type: String
        input :text, type: String
        input :destination, allow_nil: true, default: nil
        input :if_missing, type: Symbol, default: :raise
        input :source_label, type: String, default: "source"

        output :updated_content
        output :changed, default: false

        def call
          self.updated_content = insert_text(content, text, destination: destination, if_missing: if_missing, source_label: source_label)
          self.changed = updated_content != content
        rescue Error => e
          crispr_fail!(e)
        end
      end

      class Move < Actor
        include OperationSupport

        input :content, type: String
        input :source_target, type: OwnerSelector, allow_nil: true, default: nil
        input :destination, allow_nil: true, default: nil
        input :replacement, allow_nil: true, default: nil
        input :if_missing, type: Symbol, default: :raise
        input :source_label, type: String, default: "source"

        output :updated_content
        output :source_matches, default: -> { [] }
        output :source_match_count, type: Integer, default: 0
        output :changed, default: false
        output :captured_text, allow_nil: true, default: nil

        def call
          working_content = content
          if source_target
            context = context_for(content: content, source_label: source_label, target: source_target)
            self.source_matches = normalize_matches(source_target, context)
            self.source_match_count = source_matches.size
            self.captured_text = capture_text(content, source_matches)
            working_content = replace_line_ranges(content, source_matches, "") unless source_matches.empty?
          end

          text_to_insert = replacement.nil? ? captured_text.to_s : replacement.to_s
          self.updated_content =
            if text_to_insert.empty?
              working_content
            else
              insert_text(working_content, text_to_insert, destination: destination, if_missing: if_missing, source_label: source_label)
            end
          self.changed = updated_content != content
        rescue Error => e
          crispr_fail!(e)
        end
      end
    end
  end
end
