#!/usr/bin/env ruby
# frozen_string_literal: true

WORKSPACE_ROOT = File.expand_path("../..", __dir__)
ENV["KETTLE_RB_DEV"] = WORKSPACE_ROOT unless ENV.key?("KETTLE_RB_DEV")

require "bundler/inline"

gemfile do
  source "https://gem.coop"
  require File.expand_path("nomono/lib/nomono/bundler", WORKSPACE_ROOT)

  gem "optparse"

  eval_nomono_gems(
    gems: %w[markdown-merge],
    prefix: "KETTLE_RB",
    path_env: "KETTLE_RB_DEV",
    vendored_gems_env: "VENDORED_GEMS",
    vendor_gem_dir_env: "VENDOR_GEM_DIR",
    debug_env: "KETTLE_DEV_DEBUG"
  )
end

require "optparse"
require "pathname"
require "markdown/merge"

module WorkspaceRepair
  DEFAULT_REPOS = %w[
    ast-merge
    bash-merge
    json-merge
    jsonc-merge
    markly-merge
    markdown-merge
    prism-merge
    psych-merge
    rbs-merge
    toml-merge
    tree_haver
  ].freeze
  DEFAULT_MARKDOWN_FILES = %w[CONTRIBUTING.md RUBOCOP.md CODE_OF_CONDUCT.md README.md CHANGELOG.md].freeze

  module_function

  def parse_args(argv)
    options = {
      apply: false,
      repos: DEFAULT_REPOS.dup,
      files: DEFAULT_MARKDOWN_FILES.dup,
      workspace_root: WORKSPACE_ROOT,
    }

    OptionParser.new do |parser|
      parser.banner = "Usage: repair_workspace_markdown_templating_corruption.rb [options]"

      parser.on("--apply", "Rewrite files in place") do
        options[:apply] = true
      end

      parser.on("--repo NAME", "Limit to one repo (repeatable)") do |repo|
        options[:repos] = [] if options[:repos] == DEFAULT_REPOS
        options[:repos] << repo
      end

      parser.on("--file PATH", "Limit to one markdown file basename (repeatable)") do |path|
        options[:files] = [] if options[:files] == DEFAULT_MARKDOWN_FILES
        options[:files] << path
      end

      parser.on("--workspace-root PATH", "Workspace root to scan") do |path|
        options[:workspace_root] = File.expand_path(path)
      end
    end.parse!(argv)

    options
  end

  def run(options)
    total_changed = 0

    options.fetch(:repos).uniq.each do |repo|
      repo_root = File.join(options.fetch(:workspace_root), repo)
      next unless File.directory?(repo_root)

      puts "== #{repo} =="
      repo_changed = scan_repo(repo_root, basenames: options.fetch(:files).uniq, apply: options.fetch(:apply))
      total_changed += repo_changed
      puts "  clean" if repo_changed.zero?
    end

    puts
    puts(options.fetch(:apply) ? "Repaired #{total_changed} file(s)." : "Would repair #{total_changed} file(s).")
  end

  def scan_repo(repo_root, basenames:, apply:)
    changed = 0

    basenames.each do |basename|
      path = File.join(repo_root, basename)
      next unless File.file?(path)

      source = File.read(path)
      cleanser = Markdown::Merge::Cleanse::TemplatingCorruption.new(source)
      next unless cleanser.malformed?

      repaired = cleanser.fix
      next if repaired == source

      changed += 1
      issue_types = cleanser.issues.map { |issue| issue[:type] }.uniq
      puts "  #{Pathname(path).relative_path_from(Pathname(repo_root))} #{issue_types.join(', ')}"
      File.write(path, repaired) if apply
    end

    changed
  end
end

WorkspaceRepair.run(WorkspaceRepair.parse_args(ARGV))
