# frozen_string_literal: true

module Kettle
  module Jem
    module ReadmeGemspecSynchronizer
      module_function

      def synchronize(readme_content:, gemspec_content:, grapheme: nil)
        chosen_grapheme = normalized_grapheme(grapheme) || extract_readme_h1_grapheme(readme_content)
        return [readme_content, gemspec_content, nil] unless chosen_grapheme

        [
          normalize_readme_h1(readme_content, chosen_grapheme),
          normalize_gemspec_summary_and_description(gemspec_content, chosen_grapheme),
          chosen_grapheme,
        ]
      end

      def extract_readme_h1_grapheme(readme_content)
        first_h1 = readme_content.to_s.lines.find { |line| line.match?(/^#\s+/) }
        return unless first_h1

        tail = first_h1.sub(/^#\s+/, "")
        emoji_re = Kettle::EmojiRegex::REGEX
        return unless /\A#{emoji_re.source}/u.match?(tail)

        normalized_grapheme(tail[/\A\X/u])
      rescue StandardError => e
        Kettle::Dev.debug_error(e, __method__)
        nil
      end

      def normalize_readme_h1(readme_content, grapheme)
        lines = readme_content.to_s.split("\n", -1)
        idx = lines.index { |line| line.match?(/^#\s+/) }
        return readme_content unless idx

        rest = lines[idx].sub(/^#\s+/, "")
        lines[idx] = ["#", grapheme, strip_leading_graphemes(rest)].join(" ").sub(/^#\s+/, "# ")
        lines.join("\n")
      rescue StandardError => e
        Kettle::Dev.debug_error(e, __method__)
        readme_content
      end

      def normalize_gemspec_summary_and_description(gemspec_content, grapheme)
        %w[spec.summary spec.description].reduce(gemspec_content.to_s) do |text, field|
          text.gsub(/(\b#{Regexp.escape(field)}\s*=\s*)(["'])([^"']*)(\2)/) do
            pre = Regexp.last_match(1)
            quote = Regexp.last_match(2)
            body = Regexp.last_match(3)
            pre + quote + "#{grapheme} #{strip_leading_graphemes(body)}" + quote
          end
        end
      rescue StandardError => e
        Kettle::Dev.debug_error(e, __method__)
        gemspec_content
      end

      def strip_leading_graphemes(text)
        stripped = text.to_s.sub(/\A\s+/, "")
        emoji_re = Kettle::EmojiRegex::REGEX

        while /\A#{emoji_re.source}/u.match?(stripped)
          cluster = stripped[/\A\X/u]
          stripped = stripped[cluster.length..].to_s
          stripped = stripped.sub(/\A\s+/, "")
        end

        stripped.sub(/\A\s+/, "")
      rescue StandardError => e
        Kettle::Dev.debug_error(e, __method__)
        text.to_s.sub(/\A\s+/, "")
      end

      def normalized_grapheme(text)
        grapheme = text.to_s.strip[/\A\X/u].to_s
        grapheme.empty? ? nil : grapheme
      end
    end
  end
end
