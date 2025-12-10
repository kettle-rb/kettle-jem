# frozen_string_literal: true

# External gems
require "version_gem"

# This gem - only version can be required (never autoloaded)
require_relative "gem/version"

module Kettle
  module Jem
    # Base error class for all kettle-jem operations.
    # All *-merge gems should have their Error class inherit from this.
    # @api public
    class Error < StandardError; end
    end
  end
end

Kettle::Jem::Version.class_eval do
  extend VersionGem::Basic
end
