#!/usr/bin/env ruby
# frozen_string_literal: true

# Debug script: trace ModularGemfiles.sync! using the REAL code path.
#
# Usage (from workspace root or kettle-jem dir):
#   ruby kettle-jem/examples/debug_modular_gemfiles_sync.rb [/path/to/target]
#
# If no argument is given, uses the kettle-jem repo itself as the target.
# Runs read-only: patches write_file to log content without writing to disk.
# Auto-answers all prompts (simulates --force --allowed).
#
# Set FULL=1 to trace ALL writes during a full TemplateTask.run (not just
# ModularGemfiles.sync!). FULL mode suppresses git-clean checks and bin/setup.
#
# This script uses bundler/inline to guarantee local source is loaded.
# KETTLE_RB_DEV must be set (or defaults to the sibling workspace root).

WORKSPACE_ROOT = File.expand_path("../..", __dir__)
ENV["KETTLE_RB_DEV"] = WORKSPACE_ROOT unless ENV.key?("KETTLE_RB_DEV")

require "bundler/inline"

gemfile(true) do
  source "https://gem.coop"
  require File.expand_path("nomono/lib/nomono/bundler", WORKSPACE_ROOT)

  eval_nomono_gems(
    gems: %w[
      tree_haver
      ast-merge
      bash-merge
      dotenv-merge
      json-merge
      markdown-merge
      prism-merge
      psych-merge
      rbs-merge
      toml-merge
      markly-merge
      kettle-jem
    ],
    prefix: "KETTLE_RB",
    path_env: "KETTLE_RB_DEV",
    vendored_gems_env: "VENDORED_GEMS",
    vendor_gem_dir_env: "VENDOR_GEM_DIR",
    debug_env: "KETTLE_DEV_DEBUG"
  )
end

require "kettle/jem"

TARGET_ROOT = ARGV[0] || WORKSPACE_ROOT + "/kettle-jem"

puts "=== debug_modular_gemfiles_sync ==="
puts "Workspace root : #{WORKSPACE_ROOT}"
puts "Target project : #{TARGET_ROOT}"
puts "kettle/jem from: #{$LOADED_FEATURES.grep(/kettle\/jem\.rb/).first}"
puts

helpers = Kettle::Jem::TemplateHelpers
helpers.class_variable_set(:@@project_root_override, TARGET_ROOT)

# Auto-answer all prompts (simulates --force --allowed)
helpers.define_singleton_method(:ask) { |_prompt, _default| true }
# Suppress git clean check
helpers.define_singleton_method(:ensure_clean_git!) { |**| nil }

project_root = helpers.project_root
template_root = helpers.template_root
meta          = helpers.gemspec_metadata(project_root)
gem_name      = meta[:gem_name]
min_ruby      = meta[:min_ruby]

puts "gem_name  : #{gem_name.inspect}"
puts "min_ruby  : #{min_ruby.inspect}"
puts "template  : #{template_root}"
puts

# Set up token replacements so read_template works properly (same as TemplateTask.run)
forge_org       = meta[:forge_org] || meta[:gh_org]
funding_org     = helpers.opencollective_disabled? ? nil : meta[:funding_org] || forge_org
helpers.configure_tokens!(
  org:              forge_org,
  gem_name:         gem_name,
  namespace:        meta[:namespace],
  namespace_shield: meta[:namespace_shield],
  gem_shield:       meta[:gem_shield],
  funding_org:      funding_org,
  min_ruby:         min_ruby,
)
puts "Tokens configured."
puts

# Patch write_file to be a no-op but trace the content.
# copy_file_with_prompt, apply_strategy, remove_gem_dependency all run for real.
self_dep_re = /^\s*gem\s+['"]#{Regexp.escape(gem_name)}['"]/
helpers.define_singleton_method(:write_file) do |dest_path, content, **|
  rel = dest_path.to_s.sub("#{TARGET_ROOT}/", "")
  has_self_dep = content.to_s.match?(self_dep_re)
  if has_self_dep
    puts "  [WOULD-WRITE] #{rel}  *** SELF-DEP SURVIVES ***"
    content.each_line.with_index(1) do |line, i|
      puts "    L#{i}: #{line.chomp}" if line.match?(self_dep_re)
    end
  else
    puts "  [would-write] #{rel}  (ok)"
  end
end

puts "--- Running ModularGemfiles.sync! ---"
Kettle::Jem::ModularGemfiles.sync!(
  helpers:      helpers,
  project_root: project_root,
  min_ruby:     min_ruby,
  gem_name:     gem_name,
)
puts

if ENV["FULL"] == "1"
  puts "--- Running full TemplateTask.run ---"
  # Suppress install task so bin/setup is never executed
  Kettle::Jem::Tasks::InstallTask.define_singleton_method(:run) { nil }
  begin
    Kettle::Jem::Tasks::TemplateTask.run
  rescue Kettle::Dev::Error => e
    puts "[TemplateTask Kettle::Dev::Error] #{e.message}"
  rescue => e
    puts "[TemplateTask #{e.class}] #{e.message}"
    puts e.backtrace.first(5).join("\n")
  end
  puts
end

puts "=== Done ==="
