# frozen_string_literal: true

# External RSpec & related config
require "kettle/test/rspec"

# Internal ENV config
require_relative "config/debug"
require_relative "config/tree_haver"

# Config for development dependencies of this library
# i.e., not configured by this library
#
# Simplecov & related config (must run BEFORE any other requires)
# NOTE: Gemfiles for older rubies won't have kettle-soup-cover.
#       The rescue LoadError handles that scenario.
begin
  require "kettle-soup-cover"
  require "simplecov" if Kettle::Soup::Cover::DO_COV # `.simplecov` is run here!
rescue LoadError => e
  # check the error message and re-raise when unexpected
  raise e unless e.message.include?("kettle")
end

# this library
require "kettle/jem"

# Support files (shared contexts, helper classes, etc.)
# NOTE: Fixture files live in spec/fixtures/ — those .rb files are
# source code samples read as strings by merge tests, not loaded.
Dir[File.join(__dir__, "support", "{classes,shared_contexts}", "**", "*.rb")].each { |f| require f }

RSpec.configure do |config|
  config.before do
    # Speed up polling loops
    allow(described_class).to receive(:sleep) unless described_class.nil?
    # Clean environment so local direnv/.env.local values don't pollute tests.
    # Individual specs can override with stub_env as needed.
    hide_env(
      "FUNDING_ORG",
      "OPENCOLLECTIVE_HANDLE",
      "force",
      "allowed",
      "only",
      "include",
      "hook_templates",
      "KETTLE_DEV_HOOK_TEMPLATES",
    )
  end

  # Include mocked git adapter for all examples; it will skip when :real_git_adapter is set
  config.include_context "with mocked git adapter"

  # Include mocked exit adapter for all examples; it will skip when :real_exit_adapter is set
  config.include_context "with mocked exit adapter"

  # Include mocked input adapter for all examples; it will skip when :real_input_adapter is set
  # This prevents tests from hanging on Kettle::Dev::InputAdapter.gets calls.
  config.include_context "with mocked input adapter"

  # Include the stub so any spec that reaches ReleaseCLI.run_cmd!("bundle exec rake release") no-ops
  # it will skip when :real_rake_release is set
  config.include_context "with stubbed release rake"
end
