# AGENTS.md - kettle-jem Development Guide

## 🎯 Project Overview

`kettle-jem` is a **collection of `Ast::Merge::MergerConfig` presets and utilities for gem templating**. It provides pre-configured merge settings (signature generators, node typing, section classifiers) for common file types used in gem development — Ruby files (Gemfile, Appraisals, gemspec), Markdown (README, CHANGELOG), YAML, JSON, RBS, and Dotenv files.

**Core Philosophy**: Extract reusable merge configuration from `kettle-dev` into declarative presets and YAML recipes, so gem templating logic is composable and testable.

**Repository**: https://github.com/kettle-rb/kettle-jem
**Current Version**: 1.0.0
**Required Ruby**: >= 3.2.0 (currently developed against Ruby 4.0.1)

## ⚠️ AI Agent Terminal Limitations

### Terminal Output Is Available, but Each Command Is Isolated

**CRITICAL**: AI agents can reliably read terminal output when commands run in the background and the output is polled afterward. However, each terminal command should be treated as a fresh shell with no shared state.

**Use this pattern**:
1. Run commands with background execution enabled.
2. Fetch the output afterward.
3. Make every command self-contained — do **not** rely on a previous `cd`, `export`, alias, or shell function.

### Use `mise` for Project Environment

**CRITICAL**: The canonical project environment now lives in `mise.toml`, with local overrides in `.env.local` loaded via `dotenvy`.

⚠️ **Watch for trust prompts**: After editing `mise.toml` or `.env.local`, `mise` may require trust to be refreshed before commands can load the project environment. That interactive trust screen can masquerade as missing terminal output, so commands may appear hung or silent until you handle it.

**Recovery rule**: If a `mise exec` command in this repo goes silent, appears hung, or terminal polling stops returning useful output, assume `mise trust` is needed first and recover with:

```bash
mise trust -C /home/pboling/src/kettle-rb/kettle-jem
mise exec -C /home/pboling/src/kettle-rb/kettle-jem -- bundle exec rspec
```

Do this before spending time on unrelated debugging; in this workspace, silent `mise` commands are usually a trust problem.

```bash
mise trust -C /home/pboling/src/kettle-rb/kettle-jem
```

✅ **CORRECT** — Run self-contained commands with `mise exec`:
```bash
mise exec -C /home/pboling/src/kettle-rb/kettle-jem -- bundle exec rspec
```

✅ **CORRECT** — If you need shell syntax first, load the environment in the same command:
```bash
eval "$(mise env -C /home/pboling/src/kettle-rb/kettle-jem -s bash)" && bundle exec rspec
```

❌ **WRONG** — Do not rely on a previous command changing directories:
```bash
cd /home/pboling/src/kettle-rb/kettle-jem
bundle exec rspec
```

❌ **WRONG** — A chained `cd` does not give directory-change hooks time to update the environment:
```bash
cd /home/pboling/src/kettle-rb/kettle-jem && bundle exec rspec
```

### Prefer Internal Tools Over Terminal

✅ **PREFERRED** — Use internal tools:
- `grep_search` instead of `grep` command
- `file_search` instead of `find` command
- `read_file` instead of `cat` command
- `list_dir` instead of `ls` command
- `replace_string_in_file` or `create_file` instead of `sed` / manual editing

❌ **AVOID** when possible:
- `run_in_terminal` for information gathering

Only use terminal for:
- Running tests (`bundle exec rspec`)
- Installing dependencies (`bundle install`)
- Git operations that require interaction
- Commands that actually need to execute (not just gather info)

### NEVER Pipe Test Commands Through head/tail

❌ **ABSOLUTELY FORBIDDEN**:
```bash
bundle exec rspec 2>&1 | tail -50
```

✅ **CORRECT** — Run the plain command and read the full output afterward:
```bash
mise exec -C /home/pboling/src/kettle-rb/kettle-jem -- bundle exec rspec
```

## 🏗️ Architecture

### What kettle-jem Provides

- **`Kettle::Jem::Presets`** — Pre-configured `MergerConfig` objects for each file type
  - `Presets::Gemfile` — Gemfile merging (destination-wins, template-wins)
  - `Presets::Gemspec` — Gemspec merging
  - `Presets::Appraisals` — Appraisals file merging
  - `Presets::Markdown` — Markdown merging with fenced code block handling
  - `Presets::Rakefile` — Rakefile merging
  - `Presets::Yaml` — YAML file merging
  - `Presets::Json` — JSON file merging
  - `Presets::Rbs` — RBS (type signature) merging
  - `Presets::Dotenv` — Dotenv file merging
- **`Kettle::Jem::Classifiers`** — AST node classifiers for section typing
  - `Classifiers::GemCall` — Classify `gem` method calls
  - `Classifiers::GemGroup` — Classify gem grouping blocks
  - `Classifiers::AppraisalBlock` — Classify Appraisal blocks
  - `Classifiers::MethodDef` — Classify method definitions
  - `Classifiers::SourceCall` — Classify `source` method calls
- **`Kettle::Jem::Signatures`** — Signature generators for structural matching
- **`Kettle::Jem::RecipeLoader`** — YAML recipe loading and resolution
- **YAML Recipes** — Declarative merge recipes for each file type (`recipes/*.yml`)

### Key Dependencies

| Gem | Role |
|-----|------|
| `ast-merge` (~> 4.0) | Shared merge infrastructure (SmartMergerBase, MergerConfig, etc.) |
| `tree_haver` (~> 5.0) | Unified AST parsing adapter |
| `prism-merge` (~> 2.0) | Ruby file merging (Gemfile, gemspec, Rakefile, Appraisals) |
| `markly-merge` (~> 1.0) | Markdown merging |
| `markdown-merge` (~> 1.0) | Generic markdown merging |
| `json-merge` (~> 1.1) | JSON file merging |
| `psych-merge` (~> 1.0) | YAML file merging |
| `rbs-merge` (~> 2.0) | RBS file merging |
| `bash-merge` (~> 2.0) | Bash file merging |
| `dotenv-merge` (~> 1.0) | Dotenv file merging |
| `version_gem` (~> 1.1) | Version management |

### Workspace layout

This repo is a sibling project inside the `/home/pboling/src/kettle-rb` workspace, not a vendored dependency under another repo.

## 📁 Project Structure

```
lib/kettle/jem/
├── classifiers/               # AST node classifiers
│   ├── appraisal_block.rb     # Appraisal block classifier
│   ├── gem_call.rb            # gem() call classifier
│   ├── gem_group.rb           # Gem grouping classifier
│   ├── method_def.rb          # Method definition classifier
│   └── source_call.rb         # source() call classifier
├── classifiers.rb             # Classifier loader
├── presets/                   # MergerConfig presets
│   ├── appraisals.rb          # Appraisals file preset
│   ├── base.rb                # Base preset class
│   ├── dotenv.rb              # Dotenv preset
│   ├── gemfile.rb             # Gemfile preset
│   ├── gemspec.rb             # Gemspec preset
│   ├── json.rb                # JSON preset
│   ├── markdown.rb            # Markdown preset
│   ├── rakefile.rb            # Rakefile preset
│   ├── rbs.rb                 # RBS preset
│   └── yaml.rb                # YAML preset
├── presets.rb                 # Preset loader
├── recipe_loader.rb           # YAML recipe loader
├── recipes/                   # YAML merge recipes
│   ├── appraisals/            # Appraisals recipes
│   │   └── signature_generator.rb
│   ├── appraisals.yml
│   ├── gemfile/               # Gemfile recipes
│   │   ├── signature_generator.rb
│   │   └── typing/
│   │       └── call_node.rb
│   ├── gemfile.yml
│   ├── gemspec/               # Gemspec recipes
│   │   └── signature_generator.rb
│   ├── gemspec.yml
│   ├── markdown/              # Markdown recipes
│   │   └── signature_generator.rb
│   ├── markdown.yml
│   ├── rakefile/              # Rakefile recipes
│   │   └── signature_generator.rb
│   └── rakefile.yml
├── signatures.rb              # Signature generator helpers
└── version.rb                 # Version constant

spec/kettle/jem/
├── classifiers/               # Classifier specs
├── presets/                   # Preset specs
├── signatures_spec.rb         # Signature specs
```

## 🔧 Development Workflows

### Running Tests

```bash
mise exec -C /home/pboling/src/kettle-rb/kettle-jem -- bundle exec rspec
```

Single file (disable coverage threshold):
```bash
mise exec -C /home/pboling/src/kettle-rb/kettle-jem -- env K_SOUP_COV_MIN_HARD=false bundle exec rspec spec/kettle/jem/presets/gemfile_spec.rb
```

### Coverage Reports

```bash
mise exec -C /home/pboling/src/kettle-rb/kettle-jem -- bin/rake coverage
```

## 📝 Project Conventions

### Preset API Pattern

Each preset provides class methods that return `Ast::Merge::MergerConfig` objects:

```ruby
# Get a destination-wins config for Gemfile merging
config = Kettle::Jem::Presets::Gemfile.destination_wins
merger = Prism::Merge::SmartMerger.new(template, dest, **config.to_h)
result = merger.merge

# Get a template-wins config for Markdown merging
config = Kettle::Jem::Presets::Markdown.template_wins
merger = Markly::Merge::SmartMerger.new(template, dest, **config.to_h)
```

### YAML Recipe Format

Recipes are YAML files that declare merge configuration:

```yaml
# recipes/gemfile.yml
signature_generator: "Kettle::Jem::Recipes::Gemfile::SignatureGenerator"
node_typing:
  call_node: "Kettle::Jem::Recipes::Gemfile::Typing::CallNode"
```

### Forward Compatibility with `**options`

**CRITICAL**: All constructors and public API methods that accept keyword arguments MUST include `**options` as the final parameter.

### Relationship to kettle-dev

`kettle-jem` extracts reusable merge presets and recipes that were previously embedded directly in `kettle-dev`'s templating code. `kettle-dev` depends on `kettle-jem` for its merge configurations when performing template updates.

## 🧪 Testing Patterns

### Dependency Tags

Use dependency tags from `ast-merge` to conditionally skip tests:

```ruby
RSpec.describe SomeClass, :prism_merge do
  # Skipped if prism-merge unavailable
end
```

### kettle-test Helpers

All specs use `require "kettle/test/rspec"` for RSpec helpers (stubbed_env, block_is_expected, silent_stream, timecop).

## 🔍 Critical Files

| File | Purpose |
|------|---------|
| `lib/kettle/jem/presets/gemfile.rb` | Gemfile merge preset |
| `lib/kettle/jem/presets/base.rb` | Base preset class |
| `lib/kettle/jem/classifiers/gem_call.rb` | gem() call classifier |
| `lib/kettle/jem/recipe_loader.rb` | YAML recipe loading |
| `lib/kettle/jem/signatures.rb` | Signature generators |
| `lib/kettle/jem/recipes/gemfile.yml` | Gemfile merge recipe |
| `mise.toml` | Shared development environment variables and local `.env.local` loading |

## 🚫 Common Pitfalls

1. **NEVER add backward compatibility** — No shims, aliases, or deprecation layers.
2. **NEVER expect `cd` to persist** — Every terminal command is isolated; use a self-contained `mise exec -C ... -- ...` invocation.
3. **NEVER pipe test output through `head`/`tail`** — Run tests without truncation so you can inspect the full output.
4. **Terminal commands do not share shell state** — Previous `cd`, `export`, aliases, and functions are not available to the next command.
5. **Use `tmp/` for temporary files** — Never use `/tmp` or other system directories.
6. **Presets return `MergerConfig` objects** — Use `.to_h` to pass options to SmartMerger constructors.

# AGENTS.md - Development Guide

This project is a **RubyGem** managed with the [kettle-rb](https://github.com/kettle-rb) toolchain.
**Minimum Supported Ruby**: See the gemspec `required_ruby_version` constraint.
**Local Development Ruby**: See `.tool-versions` for the version used in local development (typically the latest stable Ruby).
⚠️ **Watch for trust prompts**: After editing `mise.toml` or `.env.local`, `mise` may require trust to be refreshed before commands can load the project environment. Until that trust step is handled, commands can appear hung or produce no output, which can look like terminal access is broken.
**Recovery rule**: If a `mise exec` command goes silent, appears hung, or terminal polling keeps returning `null`, assume `mise trust` is the first thing to check. Recover by running:

```bash
mise trust -C /path/to/project
mise exec -C /path/to/project -- bundle exec rspec
```

Do this before spending time on unrelated debugging; in this workspace pattern, silent `mise` commands are usually a trust problem first.

```bash
mise trust -C /path/to/project
```

```bash
mise exec -C /path/to/project -- bundle exec rspec
```

```bash
eval "$(mise env -C /path/to/project -s bash)" && bundle exec rspec
```

```bash
cd /path/to/project
bundle exec rspec
```

```bash
cd /path/to/project && bundle exec rspec
```

```bash
mise exec -C /path/to/project -- bundle exec rspec
```

### Toolchain Dependencies

This gem is part of the **kettle-rb** ecosystem. Key development tools:

| Tool | Purpose |
|------|---------|
| `kettle-dev` | Development dependency: Rake tasks, release tooling, CI helpers |
| `kettle-test` | Test infrastructure: RSpec helpers, stubbed_env, timecop |
| `kettle-jem` | Template management and gem scaffolding |

### Executables (from kettle-dev)

| Executable | Purpose |
|-----------|---------|
| `kettle-release` | Full gem release workflow |
| `kettle-pre-release` | Pre-release validation |
| `kettle-changelog` | Changelog generation |
| `kettle-dvcs` | DVCS (git) workflow automation |
| `kettle-commit-msg` | Commit message validation |
| `kettle-check-eof` | EOF newline validation |

```
lib/
├── <gem_namespace>/           # Main library code
│   └── version.rb             # Version constant (managed by kettle-release)
spec/
├── fixtures/                  # Test fixture files (NOT auto-loaded)
├── support/
│   ├── classes/               # Helper classes for specs
│   └── shared_contexts/       # Shared RSpec contexts
├── spec_helper.rb             # RSpec configuration (loaded by .rspec)
gemfiles/
├── modular/                   # Modular Gemfile components
│   ├── coverage.gemfile       # SimpleCov dependencies
│   ├── debug.gemfile          # Debugging tools
│   ├── documentation.gemfile  # YARD/documentation
│   ├── optional.gemfile       # Optional dependencies
│   ├── rspec.gemfile          # RSpec testing
│   ├── style.gemfile          # RuboCop/linting
│   └── x_std_libs.gemfile     # Extracted stdlib gems
├── ruby_*.gemfile             # Per-Ruby-version Appraisal Gemfiles
└── Appraisal.root.gemfile     # Root Gemfile for Appraisal builds
.git-hooks/
├── commit-msg                 # Commit message validation hook
├── prepare-commit-msg         # Commit message preparation
├── commit-subjects-goalie.txt # Commit subject prefix filters
└── footer-template.erb.txt    # Commit footer ERB template
```

```bash
mise exec -C /path/to/project -- bundle exec rspec
```

```bash
mise exec -C /path/to/project -- env K_SOUP_COV_MIN_HARD=false bundle exec rspec spec/path/to/spec.rb
```

```bash
mise exec -C /path/to/project -- bin/rake coverage
mise exec -C /path/to/project -- bin/kettle-soup-cover -d
```

**Key ENV variables** (set in `mise.toml`, with local overrides in `.env.local`):
- `K_SOUP_COV_DO=true` – Enable coverage
- `K_SOUP_COV_MIN_LINE` – Line coverage threshold
- `K_SOUP_COV_MIN_BRANCH` – Branch coverage threshold
- `K_SOUP_COV_MIN_HARD=true` – Fail if thresholds not met

### Code Quality

```bash
mise exec -C /path/to/project -- bundle exec rake reek
mise exec -C /path/to/project -- bundle exec rubocop-gradual
```

### Releasing

```bash
bin/kettle-pre-release    # Validate everything before release
bin/kettle-release        # Full release workflow
```

### Freeze Block Preservation

Template updates preserve custom code wrapped in freeze blocks:

```ruby
# kettle-jem:freeze
# ... custom code preserved across template runs ...
# kettle-jem:unfreeze
```

### Modular Gemfile Architecture

Gemfiles are split into modular components under `gemfiles/modular/`. Each component handles a specific concern (coverage, style, debug, etc.). The main `Gemfile` loads these modular components via `eval_gemfile`.
**CRITICAL**: All constructors and public API methods that accept keyword arguments MUST include `**options` as the final parameter for forward compatibility.

### Test Infrastructure

- Uses `kettle-test` for RSpec helpers (stubbed_env, block_is_expected, silent_stream, timecop)
- Uses `Dir.mktmpdir` for isolated filesystem tests
- Spec helper is loaded by `.rspec` — never add `require "spec_helper"` to spec files

### Environment Variable Helpers

```ruby
before do
  stub_env("MY_ENV_VAR" => "value")
end

before do
  hide_env("HOME", "USER")
end
```

Use dependency tags to conditionally skip tests when optional dependencies are not available:

```ruby
RSpec.describe SomeClass, :prism_merge do
  # Skipped if prism-merge is not available
end
```

1. **NEVER add backward compatibility** — No shims, aliases, or deprecation layers. Bump major version instead.
2. **NEVER expect `cd` to persist** — Every terminal command is isolated; use a self-contained `mise exec -C ... -- ...` invocation.
3. **NEVER pipe test output through `head`/`tail`** — Run tests without truncation so you can inspect the full output.
4. **Terminal commands do not share shell state** — Previous `cd`, `export`, aliases, and functions are not available to the next command.

This project is a **RubyGem** managed with the [kettle-rb](https://github.com/kettle-rb) toolchain.
**Minimum Supported Ruby**: See the gemspec `required_ruby_version` constraint.
**Local Development Ruby**: See `.tool-versions` for the version used in local development (typically the latest stable Ruby).
⚠️ **Watch for trust prompts**: After editing `mise.toml` or `.env.local`, `mise` may require trust to be refreshed before commands can load the project environment. Until that trust step is handled, commands can appear hung or produce no output, which can look like terminal access is broken.
**Recovery rule**: If a `mise exec` command goes silent, appears hung, or terminal polling keeps returning `null`, assume `mise trust` is the first thing to check. Recover by running:
Gemfiles are split into modular components under `gemfiles/modular/`. Each component handles a specific concern (coverage, style, debug, etc.). The main `Gemfile` loads these modular components via `eval_gemfile`.
**CRITICAL**: All constructors and public API methods that accept keyword arguments MUST include `**options` as the final parameter for forward compatibility.
