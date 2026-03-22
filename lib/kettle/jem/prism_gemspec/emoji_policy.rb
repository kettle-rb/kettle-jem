# frozen_string_literal: true

module Kettle
  module Jem
    module PrismGemspec
      module EmojiPolicy
        # Extract leading emoji from text using Unicode grapheme clusters.
        # @param text [String, nil] Text to extract emoji from
        # @return [String, nil] The first emoji grapheme cluster, or nil if none found
        def extract_leading_emoji(text)
          return unless text&.respond_to?(:scan)
          return if text.empty?

          first = text.scan(/\X/u).first
          return unless first

          emoji_re = Kettle::EmojiRegex::REGEX
          first if first.match?(/\A#{emoji_re.source}/u)
        end

        # Extract emoji from README H1 heading.
        # @param readme_content [String, nil] README content
        # @return [String, nil] The emoji from the first H1, or nil if none found
        def extract_readme_h1_emoji(readme_content)
          h1_line = readme_content.to_s.lines.find { |line| line =~ /^#\s+/ }
          return unless h1_line

          extract_leading_emoji(h1_line.sub(/^#\s+/, ""))
        end

        # Extract emoji from gemspec summary or description.
        # @param gemspec_content [String] Gemspec content
        # @return [String, nil] The emoji from summary/description, or nil if none found
        def extract_gemspec_emoji(gemspec_content)
          return unless gemspec_content

          context = gemspec_context(gemspec_content)
          return unless context

          %w[summary description].each do |field|
            emoji = gemspec_field_emoji(context, field)
            return emoji if emoji
          end

          nil
        end

        # Synchronize README H1 emoji with gemspec emoji.
        # @param readme_content [String] README content
        # @param gemspec_content [String] Gemspec content
        # @return [String] Updated README content
        def sync_readme_h1_emoji(readme_content:, gemspec_content:)
          return readme_content unless readme_content && gemspec_content

          gemspec_emoji = extract_gemspec_emoji(gemspec_content)
          return readme_content unless gemspec_emoji

          lines = readme_content.lines
          h1_idx = lines.index { |line| line =~ /^#\s+/ }
          return readme_content unless h1_idx

          text = strip_leading_emoji_graphemes(lines[h1_idx].sub(/^#\s+/, ""))
          lines[h1_idx] = ensure_h1_newline("# #{gemspec_emoji} #{text}")
          lines.join
        end

        private

        def gemspec_field_emoji(context, field)
          node = find_field_node(context[:stmt_nodes], context[:blk_param], field)
          return unless node

          first_arg = node.arguments&.arguments&.first
          value = PrismUtils.extract_literal_value(first_arg)
          return unless value

          extract_leading_emoji(value)
        end

        def strip_leading_emoji_graphemes(text)
          stripped = text.to_s
          emoji_re = Kettle::EmojiRegex::REGEX

          while stripped =~ /\A#{emoji_re.source}/u
            cluster = stripped[/\A\X/u]
            stripped = stripped[cluster.length..-1].to_s
          end

          stripped.sub(/\A\s+/, "")
        end

        def ensure_h1_newline(text)
          text.end_with?("\n") ? text : "#{text}\n"
        end
      end
    end
  end
end
