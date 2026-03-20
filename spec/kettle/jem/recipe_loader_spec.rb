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
        expect(preset).to be_a(Ast::Merge::Recipe::Config)
        expect(preset.name).to eq(name.to_s)
        expect(preset.freeze_token).to eq("kettle-jem")
      end
    end

    it "loads readme as an executable content recipe" do
      recipe = described_class.load(:readme)

      expect(recipe.content_recipe?).to be(true)
      expect(recipe.execution_steps.map { |step| step[:name] }).to eq(%w[preserve_sections preserve_h1])
    end

    it "loads changelog as an executable content recipe" do
      recipe = described_class.load(:changelog)

      expect(recipe.content_recipe?).to be(true)
      expect(recipe.execution_steps.map { |step| step[:name] }).to eq(%w[merge_unreleased replace_header finalize])
    end

    it "loads gemspec as an executable content recipe with explicit steps" do
      recipe = described_class.load(:gemspec)

      expect(recipe.content_recipe?).to be(true)
      expect(recipe.execution_steps.map { |step| step[:name] }).to eq(%w[smart_merge harmonize rewrite_version_loader])
      expect(recipe.execution_steps.map { |step| step[:kind] }).to eq(%i[smart_merge ruby_script ruby_script])
    end

    it "loads appraisals as an executable content recipe with explicit pruning policy" do
      recipe = described_class.load(:appraisals)

      expect(recipe.content_recipe?).to be(true)
      expect(recipe.execution_steps.map { |step| step[:name] }).to eq(%w[merge_appraisals prune_min_ruby])
      expect(recipe.execution_steps.map { |step| step[:kind] }).to eq(%i[smart_merge ruby_script])
    end

    it "raises ArgumentError for unknown recipe" do
      expect { described_class.load(:nonexistent) }.to raise_error(ArgumentError, /Unknown recipe/)
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
