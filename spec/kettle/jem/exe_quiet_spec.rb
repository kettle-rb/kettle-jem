# frozen_string_literal: true

require "open3"
require "rbconfig"

RSpec.describe "exe/kettle-jem quiet output" do # rubocop:disable RSpec/DescribeClass
  let(:exe_path) { File.expand_path("../../../exe/kettle-jem", __dir__) }

  it "suppresses the startup banner for --quiet help" do
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, exe_path, "--quiet", "--help")

    expect(status.success?).to be(true), "stdout=#{stdout.inspect}\nstderr=#{stderr.inspect}"
    expect(stdout).to include("Usage: kettle-jem [options]")
    expect(stdout).not_to include("begin ==")
    expect(stderr).to eq("")
  end
end
