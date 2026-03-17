# frozen_string_literal: true

require "spec_helper"

RSpec.describe "exe/kettle-jem bootstrap loading" do # rubocop:disable RSpec/DescribeClass
  let(:exe_path) { File.expand_path("../../../exe/kettle-jem", __dir__) }
  let(:exe_content) { File.read(exe_path) }

  it "loads the bootstrap runtime from the gem itself via require_relative" do
    expect(exe_content).to include('require_relative "../lib/kettle/jem/setup_cli"')
    expect(exe_content).to include('require_relative "../lib/kettle/jem/version"')
  end

  it "does not eagerly require the full bundled runtime before bootstrap handoff" do
    expect(exe_content).not_to include('require "kettle/jem"')
    expect(exe_content).not_to include('require "psych-merge"')
  end
end
