# AGENTS.md - kettle-jem Development Guide

## 🎯 Project Overview

`kettle-jem` is a **collection of `Ast::Merge::MergerConfig` presets and utilities for gem templating**. It provides pre-configured merge settings (signature generators, node typing, section classifiers) for common file types used in gem development — Ruby files (Gemfile, Appraisals, gemspec), Markdown (README, CHANGELOG), YAML, JSON, RBS, and Dotenv files.

**Core Philosophy**: Extract reusable merge configuration from `kettle-dev` into declarative presets and YAML recipes, so gem templating logic is composable and testable.

**Repository**: https://github.com/kettle-rb/kettle-jem
**Current Version**: 1.0.0
**Required Ruby**: >= 3.2.0 (currently developed against Ruby 4.0.1)

## ⚠️ AI Agent Terminal Limitations

### Terminal Output Is Not Visible

**CRITICAL**: AI agents using `run_in_terminal` almost never see the command output. The terminal tool sends commands to a persistent Copilot terminal, but output is frequently lost or invisible to the agent.

**Workaround**: Always redirect output to a file in the project's local `tmp/` directory, then read it back:

```bash
bundle exec rspec spec/some_spec.rb > tmp/test_output.txt 2>&1
```
Then use `read_file` to see `tmp/test_output.txt`.

**NEVER** use `/tmp` or other system directories — always use the project's own `tmp/` directory.

### direnv Requires Separate `cd` Command

**CRITICAL**: The project uses `direnv` to load environment variables from `.envrc`. When you `cd` into the project directory, `direnv` initializes **after** the shell prompt returns. If you chain `cd` with other commands via `&&`, the subsequent commands run **before** `direnv` has loaded the environment.

✅ **CORRECT** — Run `cd` alone, then run commands separately:
```bash
cd /home/pboling/src/kettle-rb/ast-merge/vendor/kettle-jem
```
```bash
bundle exec rspec
```

❌ **WRONG** — Never chain `cd` with `&&`:
```bash
cd /home/pboling/src/kettle-rb/ast-merge/vendor/kettle-jem && bundle exec rspec
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

✅ **CORRECT** — Redirect to file:
```bash
bundle exec rspec > tmp/test_output.txt 2>&1
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

### Vendor Directory

**IMPORTANT**: This project lives in `vendor/kettle-jem/` within the `ast-merge` workspace. It is a **nested git project** with its own `.git/` directory. The `grep_search` tool **CANNOT search inside nested git projects** — use `read_file` and `list_dir` instead.

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
cd /home/pboling/src/kettle-rb/ast-merge/vendor/kettle-jem
```
```bash
bundle exec rspec > tmp/test_output.txt 2>&1
```

Single file (disable coverage threshold):
```bash
K_SOUP_COV_MIN_HARD=false bundle exec rspec spec/kettle/jem/presets/gemfile_spec.rb > tmp/test_output.txt 2>&1
```

### Coverage Reports

```bash
cd /home/pboling/src/kettle-rb/ast-merge/vendor/kettle-jem
```
```bash
bin/rake coverage > tmp/coverage_output.txt 2>&1
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

## 🚫 Common Pitfalls

1. **NEVER add backward compatibility** — No shims, aliases, or deprecation layers.
2. **NEVER chain `cd` with `&&`** — `direnv` won't initialize until after all chained commands finish.
3. **NEVER pipe test output through `head`/`tail`** — Redirect to `tmp/` files instead.
4. **Terminal output is invisible** — Always redirect to `tmp/` and read back with `read_file`.
5. **`grep_search` cannot search nested git projects** — Use `read_file` and `list_dir` to explore this codebase.
6. **Use `tmp/` for temporary files** — Never use `/tmp` or other system directories.
7. **Presets return `MergerConfig` objects** — Use `.to_h` to pass options to SmartMerger constructors.
