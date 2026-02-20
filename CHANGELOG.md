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

- **RecipeLoader**: YAML-based preset loading for merge configurations
  - Load presets via `Kettle::Jem.recipe(:gemfile)` or `RecipeLoader.load(:gemfile)`
  - Returns `Ast::Merge::Recipe::Preset` instances (not Config, since no template required)
  - Presets stored in `lib/kettle/jem/recipes/` directory
  - Each preset has a companion folder for Ruby scripts (signature generators, node typing)
  - Use with SmartMerger: `merger = Prism::Merge::SmartMerger.new(template, dest, **preset.to_h)`
- **Presets**: YAML-based presets for common file types
  - `gemfile.yml` - Gemfile merging with gem name matching and categorization
  - `gemspec.yml` - gemspec merging with attribute and dependency matching
  - `rakefile.yml` - Rakefile merging with task and namespace matching
  - `appraisals.yml` - Appraisals merging with appraise block matching
  - `markdown.yml` - Markdown merging with heading and section matching
- **Preset Scripts**: Ruby scripts for each preset
  - Signature generators for intelligent node matching
  - Node typing scripts for gem categorization (lint, test, doc, dev, coverage, kettle gems)
  - Scripts return lambdas that are evaluated by `ScriptLoader`
- Initial release of programmatic presets (`Presets::*`) and classifiers (`Classifiers::*`)

### Changed

- Updated documentation on hostile takeover of RubyGems
  - https://dev.to/galtzo/hostile-takeover-of-rubygems-my-thoughts-5hlo

### Deprecated

### Removed

### Fixed

### Security

[Unreleased]: https://github.com/kettle-rb/kettle-jem/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/kettle-rb/kettle-jem/compare/401785c4a8aba52c4eb5a75f734a7f383f1bbb0f...v1.0.0
[1.0.0t]: https://github.com/kettle-rb/kettle-jem/tags/v1.0.0
