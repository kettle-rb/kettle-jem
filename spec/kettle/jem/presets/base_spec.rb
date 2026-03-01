# frozen_string_literal: true

RSpec.describe Kettle::Jem::Presets::Base do
  describe ".signature_generator" do
    it "raises NotImplementedError" do
      expect { described_class.signature_generator }.to raise_error(NotImplementedError, /signature_generator must be implemented/)
    end
  end

  describe ".default_freeze_token" do
    it "returns 'kettle-jem'" do
      expect(described_class.default_freeze_token).to eq("kettle-jem")
    end
  end

  describe ".default_node_typing" do
    it "returns nil" do
      expect(described_class.default_node_typing).to be_nil
    end
  end
end
