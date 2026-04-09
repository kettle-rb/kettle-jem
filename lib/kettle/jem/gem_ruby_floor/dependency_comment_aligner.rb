# frozen_string_literal: true

module Kettle
  module Jem
    module GemRubyFloor
      # Rewrites every dependency line in a gemspec so that each carries a
      # trailing +# ruby >= N.N+ comment aligned to a common column.
      #
      # The aligner:
      #   1. Parses every +add_dependency+ / +add_runtime_dependency+ /
      #      +add_development_dependency+ line using the same regex as
      #      +Kettle::Jem::PrismGemspec::DependencySectionPolicy+.
      #   2. Strips any existing +# ruby >= …+ comment from the line.
      #   3. Queries +resolver.min_ruby_version+ for the pinned version of
      #      each gem (using the first version constraint found in the dep
      #      arguments).  If no version is resolvable the line is left
      #      comment-free (no +# ruby >= ?+ is appended).
      #   4. Computes +column = max(bare_line_length) + 2+ across **all**
      #      matched dep lines (commented and uncommented alike).
      #   5. Right-pads every dep line to the computed column and appends
      #      the +# ruby >= N.N+ comment.
      #
      # Lines that are commented out (+^\\s*#+) are skipped entirely.
      # Non-dep lines are returned verbatim.
      #
      # @example
      #   aligner = Kettle::Jem::GemRubyFloor::DependencyCommentAligner
      #   resolver = Kettle::Jem::GemRubyFloor::Resolver.new
      #   updated = aligner.align(gemspec_content: File.read("my_gem.gemspec"), resolver: resolver)
      #   File.write("my_gem.gemspec", updated)
      module DependencyCommentAligner
        module_function

        # Regex for +# ruby >= N.N[.P]+ trailing comment (any freeform text after).
        RUBY_GTE_COMMENT_RE = /\s+#\s*ruby\s*>=\s*[\d.]+.*/

        # Regex for an entirely-commented line
        COMMENTED_LINE_RE   = /\A\s*#/

        # @param gemspec_content [String] full gemspec source
        # @param resolver [Resolver] used to resolve each gem's min Ruby
        # @return [String] updated gemspec content (same encoding / line endings)
        def align(gemspec_content:, resolver:)
          lines   = gemspec_content.lines
          records = collect_dep_records(lines, resolver)
          return gemspec_content if records.empty?

          # Compute alignment column from bare (comment-stripped) lines
          max_bare = records.map { |r| r[:bare_length] }.max
          column   = max_bare + 2

          # Rewrite the matched lines
          records.each do |r|
            next unless r[:min_ruby]

            bare    = r[:bare_line]
            padding = " " * [column - bare.length, 1].max
            lines[r[:index]] = "#{bare}#{padding}# ruby >= #{r[:min_ruby]}\n"
          end

          lines.join
        end

        private

        def collect_dep_records(lines, resolver)
          dep_re = Kettle::Jem::PrismGemspec::DependencySectionPolicy::GEMSPEC_DEPENDENCY_LINE_RE
          records = []

          lines.each_with_index do |line, idx|
            next if COMMENTED_LINE_RE.match?(line)

            m = dep_re.match(line)
            next unless m

            gem_name = m[:gem]
            next if gem_name.nil? || gem_name.strip.empty?

            # Strip ruby >= comment to get the bare line (preserving trailing newline separately)
            bare = line.chomp.gsub(RUBY_GTE_COMMENT_RE, "").rstrip
            min_ruby = resolve_min_ruby(gem_name, m[:args], resolver)

            records << {
              index: idx,
              gem: gem_name,
              bare_line: bare,
              bare_length: bare.length,
              min_ruby: min_ruby,
            }
          end

          records
        end

        # Extracts the first version number from the dep arguments and asks the
        # resolver for the gem's minimum Ruby.  Returns a +String+ like +"2.7"+
        # or +nil+ when unresolvable.
        def resolve_min_ruby(gem_name, args_str, resolver)
          version = extract_first_version(args_str.to_s)
          return nil unless version

          result = resolver.min_ruby_version(gem_name, version)
          return nil unless result

          # Format as N.N (drop trailing .0 if patch is zero)
          seg = result.segments
          if seg.length >= 3 && seg[2] == 0
            "#{seg[0]}.#{seg[1]}"
          else
            result.to_s
          end
        rescue StandardError
          nil
        end

        # Scans +args_str+ (the raw argument text of the dep call, e.g.
        # +"rake", "~> 13.0"+) for the first bare version string like +"1.2.3"+.
        def extract_first_version(args_str)
          # Match a quoted string that looks like a version number
          args_str.scan(/["']([~><=!\s]*\d[\d.]*(?:\.\d+)*)["']/).each do |m|
            candidate = m[0].gsub(/[~><=!\s]/, "").strip
            return candidate unless candidate.empty?
          end
          nil
        end
      end
    end
  end
end
