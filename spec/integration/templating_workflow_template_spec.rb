# frozen_string_literal: true

RSpec.describe "templating workflow template" do # rubocop:disable RSpec/DescribeClass
  it "runs the self-test rake task in the templating appraisal" do
    template_path = File.join(Kettle::Jem::TemplateHelpers.template_root, ".github", "workflows", "templating.yml.example")
    content = File.read(template_path)

    expect(content).to include('exec_cmd: "rake kettle:jem:selftest"')
    expect(content).to include("Templating self-test for ${{ matrix.ruby }} via ${{ matrix.exec_cmd }}")
  end

  it "does not duplicate kettle-test guidance in this repo's contributing guide" do
    contributing_path = File.expand_path("../../CONTRIBUTING.md", __dir__)
    content = File.read(contributing_path)

    expect(content.scan("Run tests via `kettle-test`").size).to eq(1)
    expect(content).to include("For ordinary local spec runs, use the `kettle-test` commands in the [Run Tests](#run-tests)")
  end
end
