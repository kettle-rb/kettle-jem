# frozen_string_literal: true

RSpec.describe "kettle-jem gemspec packaging" do
  it "includes nested template files under dot-directories" do
    spec = Gem::Specification.load(File.expand_path("../../../kettle-jem.gemspec", __dir__))

    expect(spec.files).to include("template/.github/workflows/current.yml.example")
    expect(spec.files).to include("template/.git-hooks/commit-msg.example")
    expect(spec.files).to include("template/.devcontainer/devcontainer.json.example")
    expect(spec.files).to include("template/bin/setup.example")
    expect(spec.files).to include("partials/.github/workflow-snippets/triggers.yml")
  end
end
