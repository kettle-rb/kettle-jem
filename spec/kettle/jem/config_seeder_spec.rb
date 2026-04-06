# frozen_string_literal: true

RSpec.describe Kettle::Jem::ConfigSeeder do
  describe ".placeholder_or_blank_kettle_config_scalar?" do
    it "returns truthy when YAML parsing raises (malformed scalar) and stripped value is a placeholder" do
      allow(YAML).to receive(:safe_load).and_raise(Psych::SyntaxError.new("file", 1, 1, 0, "error", "context"))
      raw = "{KJ|MY_TOKEN}"
      result = described_class.placeholder_or_blank_kettle_config_scalar?(raw)
      expect(result).to be_truthy
    end
  end

  describe ".yaml_scalar_for_kettle_config_backfill" do
    it "wraps the value in single-quotes when current_raw is single-quoted" do
      result = described_class.yaml_scalar_for_kettle_config_backfill("hello", "'world'")
      expect(result).to eq("'hello'")
    end

    it "dumps the value as a double-quoted YAML string when current_raw is not single-quoted" do
      result = described_class.yaml_scalar_for_kettle_config_backfill("hello", "world")
      expect(result).to eq('"hello"')
    end
  end
end
