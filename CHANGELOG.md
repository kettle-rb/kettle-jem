# Changelog

[![SemVer 2.0.0][📌semver-img]][📌semver] [![Keep-A-Changelog 1.0.0][📗keep-changelog-img]][📗keep-changelog]

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog][📗keep-changelog],
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html),
and [yes][📌major-versions-not-sacred], platform and engine support are part of the [public API][📌semver-breaking].
Please file a bug if you notice a violation of semantic versioning.

[📌semver]: https://semver.org/spec/v2.0.0.html
[📌semver-img]: https://img.shields.io/badge/semver-2.0.0-FFDD67.svg?style=flat
[📌semver-breaking]: https://github.com/semver/semver/issues/716#issuecomment-869336139
[📌major-versions-not-sacred]: https://tom.preston-werner.com/2022/05/23/major-version-numbers-are-not-sacred.html
[📗keep-changelog]: https://keepachangelog.com/en/1.0.0/
[📗keep-changelog-img]: https://img.shields.io/badge/keep--a--changelog-1.0.0-FFDD67.svg?style=flat

## [Unreleased]

### Added

- Templating now writes a dedicated per-run Markdown report under
  `tmp/kettle-jem/`, capturing run status, warnings or errors, and the active
  merge-gem environment.

### Changed

- Ruby templating now normalizes and applies `.kettle-jem.yml` merge settings
  for Ruby/Gemfile/Rakefile merges instead of silently dropping configured
  `preference`, `add_template_only_nodes`, `freeze_token`, and
  `max_recursion_depth` values on the Ruby merge path.
- README and CHANGELOG templating now run through recipe-backed partial-template
  merges instead of manual section splitting and heading scanning, leaving only
  narrow H1/header normalization and Keep-a-Changelog ordering policy local to
  `kettle-jem`
- Gemfile duplicate-conflict validation and `--force` fallback now live inside
  `PrismGemfile.merge`, keeping `SourceMerger` as a dispatcher instead of a
  second Gemfile-policy boundary.
- Recipe-backed Gemspec and Appraisals merges now share one internal runtime
  context normalizer so caller-supplied context keys are symbolized and merged
  consistently before recipe execution.
- Gemfile, Gemspec, and Appraisals merge flows now lean on shared recipe and
  structural-edit primitives behind their existing policy seams instead of
  bespoke post-merge text surgery and offset deletion paths

### Deprecated

### Removed

### Fixed

- `kettle-jem --quiet` now propagates into each `bin/setup` run so its
  `bundle install` stays quiet, suppresses the direct `bundle binstubs --all`
  step during setup, trims extra setup progress banners/command echoes, and
  preserves the quiet flag for the final bundled install handoff.
- `ChangelogMerger` now inserts blank lines between subheadings in the Unreleased
  section, following Keep-a-Changelog convention. Previously, the canonical
  headings (Added/Changed/Deprecated/Removed/Fixed/Security) were emitted with
  no blank lines between them. Also strips trailing blank lines from item groups
  to prevent double blank lines between populated sections.
- Modular `*_local.gemfile` templating now preserves destination workspace
  override wiring (`local_gems` / `VENDORED_GEMS`) instead of stripping entries
  merely because those gems also appear in the destination gemspec, while still
  excluding the current gem from self-referential local override lists
- Gemfile-like Ruby merges now normalize equivalent `nomono/bundler` loader
  requires to one logical signature, reducing duplicate loader churn and
  preserving idempotent output when local workspace bootstrap paths differ
- Prism Gemfile local-override merges now leave logically equivalent
  `local_gems` / `VENDORED_GEMS` metadata blocks unchanged, preserving existing
  comments and blank-line layout instead of rewriting already-correct output
- Markdown templating now uses low-threshold paragraph refinement for
  non-README/CHANGELOG merges, preventing near-matching `AGENTS.md`
  paragraphs from being misclassified as separate destination-only and
  template-only blocks and then both surviving output during self-merges.

### Security

[Unreleased]: https://github.com/kettle-rb/kettle-jem/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/kettle-rb/kettle-jem/compare/401785c4a8aba52c4eb5a75f734a7f383f1bbb0f...v1.0.0
[1.0.0t]: https://github.com/kettle-rb/kettle-jem/tags/v1.0.0

