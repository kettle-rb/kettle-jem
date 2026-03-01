# frozen_string_literal: true

require "spec_helper"

RSpec.describe "exe/kettle-jem LoadError handling" do
  # BUG REPRO: The exe/kettle-jem script rescues StandardError around
  # `require "kettle/jem"`, but LoadError inherits from ScriptError,
  # NOT StandardError. So the rescue never catches it and the script
  # crashes instead of proceeding with a graceful warning.
  #
  # Ruby inheritance chain:
  #   LoadError < ScriptError < Exception
  #   StandardError < Exception
  #
  # LoadError is NOT a subclass of StandardError.

  it "LoadError is not caught by rescue StandardError" do
    # This documents the root cause of the exe crash.
    # LoadError < ScriptError < Exception (NOT < StandardError)
    expect(LoadError.ancestors).not_to include(StandardError)
    expect(LoadError.ancestors).to include(ScriptError)
  end

  describe "exe script rescue clause" do
    let(:exe_path) { File.expand_path("../../../exe/kettle-jem", __dir__) }
    let(:exe_content) { File.read(exe_path) }

    it "rescues LoadError (not just StandardError) around the require" do
      # The exe has a begin/rescue block around `require "kettle/jem"`.
      # It must rescue LoadError to handle the case where kettle-jem
      # is not in the bundle (e.g., when run from a binstub in a
      # project that doesn't have kettle-jem as a dependency).
      #
      # Extract the rescue clause from the begin block containing the require
      require_block = exe_content[/begin\s*\n.*?require "kettle\/jem".*?(?=\nend|\z)/m]
      expect(require_block).not_to be_nil, "Expected to find begin/rescue block around require"
      expect(require_block).to match(/rescue\s+LoadError/), <<~MSG
        Expected exe/kettle-jem to rescue LoadError around `require "kettle/jem"`.
        Currently it rescues StandardError, which does not catch LoadError
        (LoadError inherits from ScriptError, not StandardError).
      MSG
    end
  end
end
