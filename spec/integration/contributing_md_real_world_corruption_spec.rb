# frozen_string_literal: true

RSpec.describe "real-world CONTRIBUTING.md corruption repair" do
  let(:template) do
    <<~MARKDOWN
      Executables shipped by dependencies, such as {KJ|KETTLE_DEV_GEM}, and stone_checksums, are available
      after running `bin/setup`. These include:

      - gem_checksums
      - kettle-changelog
      - kettle-commit-msg
      - {KJ|KETTLE_DEV_GEM}-setup
      - kettle-dvcs
      - kettle-pre-release
      - kettle-readme-backers
      - kettle-release

      Coverage (kettle-soup-cover / SimpleCov)

      - K_SOUP_COV_DO: Enable coverage collection (default: true in `mise.toml`)
      - K_SOUP_COV_FORMATTERS: Comma-separated list of formatters (html, xml, rcov, lcov, json, tty)
      - K_SOUP_COV_MIN_LINE: Minimum line coverage threshold (integer, e.g., 100)
      - K_SOUP_COV_MIN_BRANCH: Minimum branch coverage threshold (integer, e.g., 100)
      - K_SOUP_COV_MIN_HARD: Fail the run if thresholds are not met (true/false)
      - K_SOUP_COV_MULTI_FORMATTERS: Enable multiple formatters at once (true/false)
      - K_SOUP_COV_OPEN_BIN: Path to browser opener for HTML (empty disables auto-open)
      - MAX_ROWS: Limit console output rows for simplecov-console (e.g., 1)

      GitHub API and CI helpers
      - GITHUB_TOKEN or GH_TOKEN: Token used by `ci:act` and release workflow checks to query GitHub Actions status at higher rate limits

      Releasing and signing

      - SKIP_GEM_SIGNING: If set, skip gem signing during build/release
      - GEM_CERT_USER: Username for selecting your public cert in `certs/<USER>.pem` (defaults to $USER)
      - SOURCE_DATE_EPOCH: Reproducible build timestamp.

      Git hooks and commit message helpers (exe/kettle-commit-msg)

      - GIT_HOOK_BRANCH_VALIDATE: Branch name validation mode (e.g., `jira`) or `false` to disable
      - GIT_HOOK_FOOTER_APPEND: Append a footer to commit messages when goalie allows (true/false)
      - GIT_HOOK_FOOTER_SENTINEL: Required when footer append is enabled — a unique first-line sentinel to prevent duplicates
      - GIT_HOOK_FOOTER_APPEND_DEBUG: Extra debug output in the footer template
    MARKDOWN
  end

  let(:destination) do
    <<~MARKDOWN
      Coverage (kettle-soup-cover / SimpleCov)

      ## Executables vs Rake tasks

      Executables shipped by dependencies, such as kettle-dev, and stone_checksums, are available
      after running `bin/setup`. These include:

      - gem_checksums
      - kettle-changelog
      - kettle-commit-msg
      - kettle-dev-setup
      - kettle-dvcs
      - kettle-pre-release
      - kettle-readme-backers
      - kettle-release

      - K_SOUP_COV_DO: Enable coverage collection (default: true in `mise.toml`)
      - K_SOUP_COV_FORMATTERS: Comma-separated list of formatters (html, xml, rcov, lcov, json, tty)
      - K_SOUP_COV_MIN_LINE: Minimum line coverage threshold (integer, e.g., 100)
      - K_SOUP_COV_MIN_BRANCH: Minimum branch coverage threshold (integer, e.g., 100)
      - K_SOUP_COV_MIN_HARD: Fail the run if thresholds are not met (true/false)
      - K_SOUP_COV_MULTI_FORMATTERS: Enable multiple formatters at once (true/false)
      - K_SOUP_COV_OPEN_BIN: Path to browser opener for HTML (empty disables auto-open)
      - MAX_ROWS: Limit console output rows for simplecov-console (e.g., 1)

      GitHub API and CI helpers
      - GITHUB_TOKEN or GH_TOKEN: Token used by `ci:act` and release workflow checks to query GitHub Actions status at higher rate limits

      Releasing and signing

      - SKIP_GEM_SIGNING: If set, skip gem signing during build/release
      - GEM_CERT_USER: Username for selecting your public cert in `certs/<USER>.pem` (defaults to $USER)
      - SOURCE_DATE_EPOCH: Reproducible build timestamp.

      Git hooks and commit message helpers (exe/kettle-commit-msg)

      - GIT_HOOK_BRANCH_VALIDATE: Branch name validation mode (e.g., `jira`) or `false` to disable
      - GIT_HOOK_FOOTER_APPEND: Append a footer to commit messages when goalie allows (true/false)
      - GIT_HOOK_FOOTER_SENTINEL: Required when footer append is enabled — a unique first-line sentinel to prevent duplicates
      - GIT_HOOK_FOOTER_APPEND_DEBUG: Extra debug output in the footer template
      - gem_checksums
      - kettle-changelog
      - kettle-commit-msg
      - kettle-dev-setup
      - kettle-dvcs
      - kettle-pre-release
      - kettle-readme-backers
      - kettle-release
      - gem_checksums
      - kettle-changelog
      - kettle-commit-msg
      - kettle-dev-setup
      - kettle-dvcs
      - kettle-pre-release
      - kettle-readme-backers
      - kettle-release
    MARKDOWN
  end

  def do_merge(src, dest)
    Markdown::Merge::SmartMerger.new(
      src,
      dest,
      backend: :markly,
      preference: :template,
      add_template_only_nodes: true,
      match_refiner: Kettle::Jem::Tasks::TemplateTask::MARKDOWN_MATCH_REFINER,
      inner_merge_lists: true,
    ).merge
  end

  it "collapses the repeated env-variable and executable lists to one copy each" do
    result = do_merge(template, destination)

    expect(result.scan("K_SOUP_COV_DO").length).to eq(1)
    expect(result.scan("GITHUB_TOKEN or GH_TOKEN").length).to eq(1)
    expect(result.scan("SKIP_GEM_SIGNING").length).to eq(1)
    expect(result.scan("GIT_HOOK_BRANCH_VALIDATE").length).to eq(1)
    expect(result.scan("gem_checksums").length).to eq(1)
  end

  it "is idempotent across repeated repair merges" do
    result1 = do_merge(template, destination)
    result2 = do_merge(template, result1)

    expect(result2).to eq(result1)
  end
end
