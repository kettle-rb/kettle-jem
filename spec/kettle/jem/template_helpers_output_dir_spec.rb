# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Kettle::Jem::TemplateHelpers do
  subject(:helpers) { described_class }

  after do
    # Always reset output_dir to avoid leaking state to other specs
    helpers.send(:output_dir=, nil)
  end

  describe ".output_dir / .output_dir=" do
    it "defaults to nil" do
      expect(helpers.output_dir).to be_nil
    end

    it "can be set and read back" do
      helpers.send(:output_dir=, "/tmp/test_output")
      expect(helpers.output_dir).to eq("/tmp/test_output")
    end

    it "can be reset to nil" do
      helpers.send(:output_dir=, "/tmp/test_output")
      helpers.send(:output_dir=, nil)
      expect(helpers.output_dir).to be_nil
    end
  end

  describe ".output_path" do
    let(:project_root) { helpers.project_root }

    context "when output_dir is nil" do
      it "returns dest_path unchanged" do
        dest = File.join(project_root, "lib/kettle/jem.rb")
        expect(helpers.output_path(dest)).to eq(dest)
      end
    end

    context "when output_dir is set" do
      let(:output_dir) { "/tmp/selftest_output" }

      before { helpers.send(:output_dir=, output_dir) }

      it "rewrites dest_path under output_dir" do
        dest = File.join(project_root, "lib/kettle/jem.rb")
        expect(helpers.output_path(dest)).to eq("#{output_dir}/lib/kettle/jem.rb")
      end

      it "handles dest_path without trailing slash in project_root" do
        dest = File.join(project_root, "Gemfile")
        expect(helpers.output_path(dest)).to eq("#{output_dir}/Gemfile")
      end

      it "handles nested paths" do
        dest = File.join(project_root, "spec/kettle/jem/version_spec.rb")
        expect(helpers.output_path(dest)).to eq("#{output_dir}/spec/kettle/jem/version_spec.rb")
      end
    end
  end

  describe ".write_file with output_dir" do
    let(:tmpdir) { Dir.mktmpdir("kettle_jem_test") }
    let(:output_dir) { File.join(tmpdir, "output") }
    let(:dest_path) { File.join(helpers.project_root, "test_write_file.txt") }
    let(:content) { "hello from write_file test" }

    before { helpers.send(:output_dir=, output_dir) }

    after { FileUtils.rm_rf(tmpdir) }

    it "writes to output_dir instead of project_root" do
      helpers.write_file(dest_path, content)

      expected_actual = File.join(output_dir, "test_write_file.txt")
      expect(File.exist?(expected_actual)).to be(true)
      expect(File.read(expected_actual)).to eq(content)

      # The original dest_path should NOT exist (unless it coincidentally exists)
      # We just verify the write went to the right place
    end

    it "creates intermediate directories as needed" do
      nested_dest = File.join(helpers.project_root, "a/b/c/deep.txt")
      helpers.write_file(nested_dest, content)

      expected_actual = File.join(output_dir, "a/b/c/deep.txt")
      expect(File.exist?(expected_actual)).to be(true)
      expect(File.read(expected_actual)).to eq(content)
    end
  end
end
