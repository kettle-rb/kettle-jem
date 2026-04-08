# frozen_string_literal: true

RSpec.describe Kettle::Jem::FrameworkWorkflowGenerator do
  let(:helpers) { Kettle::Jem::TemplateHelpers }
  let(:template_content) do
    File.read(File.join(helpers.template_root, ".github", "workflows", "framework-ci.yml.example"))
  end

  before do
    helpers.class_variable_set(:@@kettle_config, nil)
    helpers.class_variable_set(:@@manifestation, nil)
    helpers.clear_warnings
  end

  describe "#generate" do
    context "when framework_matrix is not configured" do
      before do
        allow(helpers).to receive(:kettle_config).and_return({})
      end

      it "returns nil" do
        generator = described_class.new(template_content: template_content, helpers: helpers)
        expect(generator.generate).to be_nil
      end
    end

    context "with ActiveRecord matrix (dot-separated gemfiles)" do
      before do
        allow(helpers).to receive(:kettle_config).and_return({
          "workflows" => {
            "preset" => "framework",
            "framework_matrix" => {
              "dimension" => "activerecord",
              "versions" => ["7.0", "7.1", "7.2", "8.0"],
              "gemfile_pattern" => "ar-{version}.x",
            },
          },
        })
      end

      it "generates valid YAML" do
        generator = described_class.new(template_content: template_content, helpers: helpers)
        result = generator.generate
        expect(result).not_to be_nil
        parsed = Psych.safe_load(result)
        expect(parsed).to be_a(Hash)
      end

      it "sets workflow name with dimension" do
        generator = described_class.new(template_content: template_content, helpers: helpers)
        result = generator.generate
        parsed = Psych.safe_load(result)
        expect(parsed["name"]).to eq("Activerecord CI")
      end

      it "creates include entries with correct gemfile paths" do
        generator = described_class.new(template_content: template_content, helpers: helpers)
        result = generator.generate
        parsed = Psych.safe_load(result)
        includes = parsed.dig("jobs", "test", "strategy", "matrix", "include")
        expect(includes).to be_an(Array)
        expect(includes.length).to eq(4)
        expect(includes[0]["framework_version"]).to eq("7.0")
        expect(includes[0]["gemfile"]).to eq("gemfiles/ar-7.0.x")
        expect(includes[3]["framework_version"]).to eq("8.0")
        expect(includes[3]["gemfile"]).to eq("gemfiles/ar-8.0.x")
      end

      it "preserves ruby matrix dimension" do
        generator = described_class.new(template_content: template_content, helpers: helpers)
        result = generator.generate
        parsed = Psych.safe_load(result)
        ruby_versions = parsed.dig("jobs", "test", "strategy", "matrix", "ruby")
        expect(ruby_versions).to include("3.1", "3.2", "3.3", "3.4")
      end
    end

    context "with Rails matrix (underscore-separated gemfiles)" do
      before do
        allow(helpers).to receive(:kettle_config).and_return({
          "workflows" => {
            "preset" => "framework",
            "framework_matrix" => {
              "dimension" => "rails",
              "versions" => ["7.0", "7.1", "8.0", "8.1"],
              "gemfile_pattern" => "rails_{version}",
            },
          },
        })
      end

      it "generates underscore-separated gemfile names" do
        generator = described_class.new(template_content: template_content, helpers: helpers)
        result = generator.generate
        parsed = Psych.safe_load(result)
        includes = parsed.dig("jobs", "test", "strategy", "matrix", "include")
        expect(includes[0]["gemfile"]).to eq("gemfiles/rails_7_0")
        expect(includes[2]["gemfile"]).to eq("gemfiles/rails_8_0")
      end

      it "sets Rails in the workflow name" do
        generator = described_class.new(template_content: template_content, helpers: helpers)
        result = generator.generate
        parsed = Psych.safe_load(result)
        expect(parsed["name"]).to eq("Rails CI")
      end
    end
  end
end
