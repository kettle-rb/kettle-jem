# frozen_string_literal: true

RSpec.describe Kettle::Jem::ReadmePostProcessor do
  describe ".compatibility_badge_min_mri" do
    it "maps fixed JRuby and TruffleRuby badges to MRI compatibility versions" do
      expect(described_class.compatibility_badge_min_mri("💎jruby-10.0i")).to eq(Gem::Version.new("3.4"))
      expect(described_class.compatibility_badge_min_mri("💎truby-23.2i")).to eq(Gem::Version.new("3.2"))
      expect(described_class.compatibility_badge_min_mri("💎truby-24.2i")).to eq(Gem::Version.new("3.3"))
      expect(described_class.compatibility_badge_min_mri("💎truby-25.0i")).to eq(Gem::Version.new("3.3"))
    end

    it "returns nil for dynamic current and HEAD badges that are intentionally omitted from the matrix" do
      expect(described_class.compatibility_badge_min_mri("💎ruby-c-i")).to be_nil
      expect(described_class.compatibility_badge_min_mri("💎jruby-c-i")).to be_nil
      expect(described_class.compatibility_badge_min_mri("💎truby-c-i")).to be_nil
      expect(described_class.compatibility_badge_min_mri("💎ruby-headi")).to be_nil
      expect(described_class.compatibility_badge_min_mri("💎jruby-headi")).to be_nil
      expect(described_class.compatibility_badge_min_mri("💎truby-headi")).to be_nil
    end
  end

  describe ".normalize_compatibility_badge_cell" do
    it "removes redundant whitespace and drops empty leading or trailing breaks" do
      cell = "  <br/>   [![Truffle Ruby 23.2 Compat][💎truby-23.2i]][🚎9-t-wf]   <br/>    [![Truffle Ruby 24.2 Compat][💎truby-24.2i]][🚎11-c-wf]   <br/>  "

      expect(described_class.normalize_compatibility_badge_cell(cell)).to eq(
        "[![Truffle Ruby 23.2 Compat][💎truby-23.2i]][🚎9-t-wf] <br/> [![Truffle Ruby 24.2 Compat][💎truby-24.2i]][🚎11-c-wf]",
      )
    end
  end

  describe ".process" do
    it "keeps a fixed JRuby 10.0 badge when the minimum Ruby is 3.4" do
      content = <<~MD
        | Works with JRuby | ![JRuby 9.4 Compat][💎jruby-9.4i] <br/> [![JRuby 10.0 Compat][💎jruby-10.0i]][🚎11-c-wf] [![JRuby HEAD Compat][💎jruby-headi]][🚎3-hd-wf] |

        [💎jruby-9.4i]: https://example/jruby-94
        [💎jruby-10.0i]: https://example/jruby-100
        [💎jruby-headi]: https://example/jruby-head
        [🚎11-c-wf]: https://example/current
        [🚎3-hd-wf]: https://example/head
      MD

      processed = described_class.process(content: content, min_ruby: Gem::Version.new("3.4"))
      jruby_line = processed.lines.find { |line| line.start_with?("| Works with JRuby") }

      expect(jruby_line).not_to include("jruby-9.4i")
      expect(jruby_line).to include("jruby-10.0i")
      expect(jruby_line).to include("jruby-headi")
      expect(processed).not_to match(/^\[💎jruby-9\.4i\]:/)
      expect(processed).to match(/^\[💎jruby-10\.0i\]:/)
      expect(processed).to match(/^\[🚎11-c-wf\]:/)
      expect(processed).to match(/^\[🚎3-hd-wf\]:/)
    end

    it "keeps fixed TruffleRuby 23.2+ badges that satisfy the minimum Ruby and prunes older ones" do
      content = <<~MD
        | Works with Truffle Ruby | ![Truffle Ruby 23.1 Compat][💎truby-23.1i] <br/> [![Truffle Ruby 23.2 Compat][💎truby-23.2i]][🚎9-t-wf] [![Truffle Ruby 24.2 Compat][💎truby-24.2i]][🚎9-t-wf] [![Truffle Ruby 25.0 Compat][💎truby-25.0i]][🚎9-t-wf] [![Truffle Ruby current Compat][💎truby-c-i]][🚎11-c-wf] |

        [💎truby-23.1i]: https://example/truby-231
        [💎truby-23.2i]: https://example/truby-232
        [💎truby-24.2i]: https://example/truby-242
        [💎truby-25.0i]: https://example/truby-250
        [💎truby-c-i]: https://example/truby-current
        [🚎9-t-wf]: https://example/truffle
        [🚎11-c-wf]: https://example/current
      MD

      processed = described_class.process(content: content, min_ruby: Gem::Version.new("3.2"))
      truby_line = processed.lines.find { |line| line.start_with?("| Works with Truffle Ruby") }

      expect(truby_line).not_to include("truby-23.1i")
      expect(truby_line).to include("truby-23.2i")
      expect(truby_line).to include("truby-24.2i")
      expect(truby_line).to include("truby-25.0i")
      expect(truby_line).to include("truby-c-i")
      expect(processed).not_to match(/^\[💎truby-23\.1i\]:/)
      expect(processed).to match(/^\[💎truby-23\.2i\]:/)
      expect(processed).to match(/^\[💎truby-24\.2i\]:/)
      expect(processed).to match(/^\[💎truby-25\.0i\]:/)
      expect(processed).to match(/^\[🚎9-t-wf\]:/)
      expect(processed).to match(/^\[🚎11-c-wf\]:/)
    end
  end
end
