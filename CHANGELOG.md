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

- `PrismGemfile::CONFLICTING_GEMS` constant (`%w[appraisal]`) identifies gems
  that conflict with the kettle-jem template ecosystem. The `appraisal` gem is
  replaced by the `appraisal2` hard-fork (same `appraisal` executable,
  incompatible internals); keeping both causes execution conflicts.
- `SetupCLI#remove_conflicting_gems` strips `CONFLICTING_GEMS` from the main
  Gemfile during the bootstrap `ensure_gemfile_from_example!` merge, handling
  gems that carry the old `appraisal` dependency in their Gemfile.
- `TemplateHelpers#remove_conflicting_gemfile_gems` strips `CONFLICTING_GEMS`
  from `Appraisal.root.gemfile` after the destination-wins merge, where the old
  `gem "appraisal"` declaration would otherwise survive as a destination-only
  node and conflict with `appraisal2` at runtime.
- `SetupCLI#remove_scaffold_default_gems` now removes `rake`, `rspec`, and
  `rubocop` from a freshly scaffolded gem's Gemfile during templating. These
  gems are added by `bundle gem` but are redundant after kettle-jem applies:
  `rake` moves to gemspec dev-deps, `rspec` is pulled in transitively by
  `kettle-test`, and `rubocop` is managed by `standard` via `style.gemfile`.

- New `{KJ|GEM_MAJOR}` token, resolved from the target gem's gemspec version,
  emitting just the major version integer (e.g. `"3"` for a `3.1.0` gem). Use
  it in templates wherever a `"~> X.0"` dependency constraint is needed, such
  as the `spec.add_dependency` example line in README templates.
- Templating now writes a dedicated per-run Markdown report under
  `tmp/kettle-jem/`, capturing run status, warnings or errors, and the active
  merge-gem environment.
- Added `KETTLE_JEM_PLUGINS.md`, a root-level guide for authoring
  `kettle-jem` plugin gems against the supported plugin API

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
- Documentation templates now generate a `documentation_local.gemfile` companion
  so sibling YARD plugins can be loaded from source in workspace mode

### Deprecated

### Removed

### Fixed

- Packaged `kettle-jem` gems now include template files nested under
  dot-directories such as `.github/`, `.git-hooks/`, and `.devcontainer/`,
  keeping the installed template scaffold aligned with the source tree
- `Kettle::Jem::Signatures.gemfile` now normalizes ruby-version bucket segments
  (e.g. `/r3/`, `/r4/`) when building `eval_gemfile` signatures, so template
  paths like `../../erb/r4/v5.0.gemfile` and destination paths like
  `../../erb/r3/v5.0.gemfile` map to the same canonical signature and the
  template version replaces the destination version instead of being appended
  as a duplicate. This fixes the root cause of `erb`, `mutex_m`, `stringio`,
  and similar entries being duplicated in `x_std_libs/r4/libs.gemfile` (and
  any other sub-gemfile merged via `PrismGemfile.merge`) after a template run.
  The normalization was already present in `MergeEntryPolicy.signature_for`
  (used by `merge_gem_calls`) but was missing from the `Signatures.gemfile`
  lambda that `PrismGemfile.merge` uses for all other Gemfile-type file merges.
- README templates now use `"~> {KJ|GEM_MAJOR}.0"` for the `spec.add_dependency`
  example line instead of the hardcoded `"~> 1.0"`, so the generated constraint
  reflects the target gem's actual major version.
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
- `AGENTS.md` and other markdown files no longer duplicate the H1 document
  title when the template and destination use differently-worded headings
  (e.g. `# AGENTS.md - Development Guide` vs `# AGENTS.md - myGem Development Guide`).
  H1 is now a singleton structural slot in `markdown-merge`, so the preferred
  version replaces the other instead of both being kept.
- Existing duplicated instructional comment blocks in `.kettle-jem.yml` are now
  normalized away during config sync so duplicate-drift corruption can self-heal

### Security

[Unreleased]: https://github.com/kettle-rb/kettle-jem/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/kettle-rb/kettle-jem/compare/401785c4a8aba52c4eb5a75f734a7f383f1bbb0f...v1.0.0
[1.0.0t]: https://github.com/kettle-rb/kettle-jem/tags/v1.0.0
