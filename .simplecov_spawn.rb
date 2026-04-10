# frozen_string_literal: true

# Loaded via RUBYOPT in spawned subprocesses so they contribute coverage
# without depending on the subprocess working directory.
ENV["K_SOUP_COV_CLEAN_RESULTSET"] = "false"

require "kettle-soup-cover"
require "simplecov"

SimpleCov.print_error_status = false
SimpleCov.formatter(SimpleCov::Formatter::SimpleFormatter)
SimpleCov.minimum_coverage(0)
SimpleCov.command_name(
  "#{ENV.fetch("K_SOUP_COV_COMMAND_NAME", "RSpec (COVERAGE)")} (spawn:#{Process.pid})",
)
