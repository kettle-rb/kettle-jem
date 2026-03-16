# frozen_string_literal: true

RSpec.describe "kettle-jem.gemspec file list" do # rubocop:disable RSpec/DescribeClass
  it "includes modular gemfile examples so TemplateTask can prefer them (regression for optional.gemfile.example)" do
    gemspec_path = File.expand_path("../../kettle-jem.gemspec", __dir__)
    gemspec_dir = File.dirname(gemspec_path)

    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        expect(Dir.pwd).to eq(dir)

        spec = Dir.chdir(gemspec_dir) do
          Gem::Specification.load(File.basename(gemspec_path))
        end

        expect(Dir.pwd).to eq(dir)
        expect(spec).not_to be_nil
        files = spec.files
        expect(files).to include("template/gemfiles/modular/optional.gemfile.example")
      end
    end
  end
end
