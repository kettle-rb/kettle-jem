# frozen_string_literal: true

RSpec.describe Kettle::Jem::RecipeLoader do
  describe ".available" do
    it "includes all expected recipe names" do
      available = described_class.available
      expect(available).to include(:gemfile, :gemspec, :rakefile, :appraisals, :markdown)
      expect(available).to include(:readme, :changelog, :dotenv)
    end
  end

  describe ".load" do
    %i[gemfile gemspec rakefile appraisals markdown readme changelog dotenv].each do |name|
      it "loads the #{name} preset successfully" do
        preset = described_class.load(name)
        expect(preset).to be_a(Ast::Merge::Recipe::Preset)
        expect(preset.name).to eq(name.to_s)
        expect(preset.freeze_token).to eq("kettle-jem")
      end
    end

    it "raises ArgumentError for unknown recipe" do
      expect { described_class.load(:nonexistent) }.to raise_error(ArgumentError, /Unknown preset/)
    end
  end

  describe ".exists?" do
    it "returns true for existing recipes" do
      expect(described_class.exists?(:gemfile)).to be true
      expect(described_class.exists?(:readme)).to be true
      expect(described_class.exists?(:changelog)).to be true
      expect(described_class.exists?(:dotenv)).to be true
    end

    it "returns false for non-existing recipes" do
      expect(described_class.exists?(:nonexistent)).to be false
    end
  end
end
