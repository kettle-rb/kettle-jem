# frozen_string_literal: true

RSpec.describe "kettle-jem template assets", :jsonc_grammar do
  describe ".devcontainer/devcontainer.json.example" do
    let(:template_path) do
      File.expand_path("../../../template/.devcontainer/devcontainer.json.example", __dir__)
    end

    it "is valid JSONC for jsonc-merge templating" do
      analysis = Jsonc::Merge::FileAnalysis.new(File.read(template_path))

      expect(analysis.valid?).to be(true), <<~MSG
        expected #{template_path} to parse as JSONC, but got:
        #{analysis.errors.inspect}
      MSG
    end
  end
end
