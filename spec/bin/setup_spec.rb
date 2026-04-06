# frozen_string_literal: true

require "fileutils"
require "open3"

# rubocop:disable RSpec/DescribeClass
RSpec.describe "bin/setup" do
  let(:script_path) { File.expand_path("../../bin/setup", __dir__) }

  it "passes --quiet through to bundle install and suppresses shell tracing" do
    Dir.mktmpdir do |dir|
      stub_bin = File.join(dir, "stub-bin")
      FileUtils.mkdir_p(stub_bin)
      args_path = File.join(dir, "bundle-args.txt")
      bundle_path = File.join(stub_bin, "bundle")
      File.write(bundle_path, <<~BASH)
        #!/usr/bin/env bash
        set -euo pipefail
        printf '%s\n' "$@" > "$SETUP_BUNDLE_ARGS_FILE"
      BASH
      FileUtils.chmod("+x", bundle_path)

      env = {
        "PATH" => "#{stub_bin}:#{ENV.fetch("PATH", "")}",
        "SETUP_BUNDLE_ARGS_FILE" => args_path,
      }

      stdout, stderr, status = Open3.capture3(env, script_path, "--quiet", chdir: dir)

      expect(status.success?).to be(true), "stdout=#{stdout.inspect}\nstderr=#{stderr.inspect}"
      expect(stdout).to eq("")
      expect(stderr).to eq("")
      expect(File.readlines(args_path, chomp: true)).to eq(["install", "--quiet"])
    end
  end
end
# rubocop:enable RSpec/DescribeClass
