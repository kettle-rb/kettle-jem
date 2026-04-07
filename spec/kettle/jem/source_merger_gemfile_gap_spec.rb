# frozen_string_literal: true

# Unit regression spec for blank-line / gap handling in Gemfile merging.
#
# Exercises Kettle::Jem::SourceMerger.apply directly against fixtures
# derived from token-resolver/Gemfile (destination) and the kettle-jem
# Gemfile.example template with tokens pre-substituted.
#
# After the merge the output must have exactly the same blank-line
# structure as the destination — no extra blank lines inserted, no
# trailing blank line added at EOF.
RSpec.describe Kettle::Jem::SourceMerger do
  let(:template_content) { File.read("spec/fixtures/gemfile_gap/template.rb") }
  let(:dest_content) { File.read("spec/fixtures/gemfile_gap/destination.rb") }

  def gemfile_merge(src, dest)
    described_class.apply(strategy: :merge, src: src, dest: dest, path: "Gemfile")
  end

  describe "Gemfile gap / blank-line preservation" do
    it "does not insert extra blank lines" do
      result = gemfile_merge(template_content, dest_content)
      expect(result).to eq(dest_content)
    end

    it "preserves exactly the same number of blank lines as the destination" do
      result = gemfile_merge(template_content, dest_content)
      dest_blanks = dest_content.lines.count { |l| l.strip.empty? }
      result_blanks = result.lines.count { |l| l.strip.empty? }
      expect(result_blanks).to eq(dest_blanks)
    end

    it "does not add a trailing blank line at EOF" do
      result = gemfile_merge(template_content, dest_content)
      expect(result).not_to end_with("\n\n")
    end

    it "preserves destination node order" do
      result = gemfile_merge(template_content, dest_content)
      # Destination has templating.gemfile at the end, not after gemspec
      templating_idx = result.lines.index { |l| l.include?("templating.gemfile") }
      debug_idx = result.lines.index { |l| l.include?("debug.gemfile") }
      expect(templating_idx).to be > debug_idx
    end
  end
end
