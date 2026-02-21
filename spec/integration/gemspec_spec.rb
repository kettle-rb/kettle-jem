# frozen_string_literal: true

RSpec.describe "kettle-jem.gemspec file list" do # rubocop:disable RSpec/DescribeClass
  it "includes modular gemfile examples so TemplateTask can prefer them (regression for optional.gemfile.example)" do
    spec = Gem::Specification.load(File.expand_path("../../kettle-jem.gemspec", __dir__))
    expect(spec).not_to be_nil
    files = spec.files
    expect(files).to include("template/gemfiles/modular/optional.gemfile.example")
  end
end
