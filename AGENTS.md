# AGENTS.md - kettle-jem Development Guide

## 🎯 Project Overview

`kettle-jem` is a **collection of `Ast::Merge::MergerConfig` presets and utilities for gem templating**. It provides pre-configured merge settings (signature generators, node typing, section classifiers) for common file types used in gem development — Ruby files (Gemfile, Appraisals, gemspec), Markdown (README, CHANGELOG), YAML, JSON, RBS, and Dotenv files.

**Core Philosophy**: Extract reusable merge configuration from `kettle-dev` into declarative presets and YAML recipes, so gem templating logic is composable and testable.

**Repository**: https://github.com/kettle-rb/kettle-jem
**Current Version**: 1.0.0
**Required Ruby**: >= 3.2.0 (currently developed against Ruby 4.0.1)

## ⚠️ AI Agent Terminal Limitations

### Use `mise` for Project Environment

**CRITICAL**: The canonical project environment lives in `mise.toml`, with local overrides in `.env.local` loaded via `dotenvy`.

⚠️ **Watch for trust prompts**: After editing `mise.toml` or `.env.local`, `mise` may require trust to be refreshed before commands can load the project environment. That interactive trust screen can masquerade as missing terminal output, so commands may appear hung or silent until you handle it.

**Recovery rule**: If a `mise exec` command in this repo goes silent or appears hung, assume `mise trust` is needed first and recover with:

```bash
mise trust -C /home/pboling/src/kettle-rb/kettle-jem
mise exec -C /home/pboling/src/kettle-rb/kettle-jem -- bundle exec rspec
```

Do this before spending time on unrelated debugging; in this workspace, silent `mise` commands are usually a trust problem.

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

## 📝 Project Conventions

- Gemfiles are split into modular components under `gemfiles/modular/`. Each component handles a specific concern (coverage, style, debug, etc.). The main `Gemfile` loads these modular components via `eval_gemfile`.
- **CRITICAL**: All constructors and public API methods that accept keyword arguments MUST include `**options` as the final parameter for forward compatibility.
