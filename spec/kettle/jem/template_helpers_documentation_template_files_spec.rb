# frozen_string_literal: true

RSpec.describe Kettle::Jem::TemplateHelpers do
  let(:template_root) { File.expand_path("../../../template", __dir__) }

  it "includes yard-timekeeper in the documentation gemfile template" do
    content = File.read(File.join(template_root, "gemfiles/modular/documentation.gemfile.example"))

    expect(content).to include('gem "yard-timekeeper", "~> 0.1", require: false')
  end

  it "enables the timekeeper YARD plugin in the yardopts template" do
    content = File.read(File.join(template_root, ".yardopts.example"))

    expect(content).to include("--plugin timekeeper")
    expect(content.index("--plugin timekeeper")).to be < content.index("--plugin fence")
  end
end
