[![Galtzo FLOSS Logo by Aboling0, CC BY-SA 4.0][🖼️galtzo-i]][🖼️galtzo-discord] [![ruby-lang Logo, Yukihiro Matsumoto, Ruby Visual Identity Team, CC BY-SA 2.5][🖼️ruby-lang-i]][🖼️ruby-lang] [![kettle-rb Logo by Aboling0, CC BY-SA 4.0][🖼️kettle-rb-i]][🖼️kettle-rb]

[🖼️galtzo-i]: https://logos.galtzo.com/assets/images/galtzo-floss/avatar-192px.svg
[🖼️galtzo-discord]: https://discord.gg/3qme4XHNKN
[🖼️ruby-lang-i]: https://logos.galtzo.com/assets/images/ruby-lang/avatar-192px.svg
[🖼️ruby-lang]: https://www.ruby-lang.org/
[🖼️kettle-rb-i]: https://logos.galtzo.com/assets/images/kettle-rb/avatar-192px.svg
[🖼️kettle-rb]: https://github.com/kettle-rb

# 🍲 Kettle::Jem

[![Version][👽versioni]][👽version] [![GitHub tag (latest SemVer)][⛳️tag-img]][⛳️tag] [![License: MIT][📄license-img]][📄license-ref] [![Downloads Rank][👽dl-ranki]][👽dl-rank] [![Open Source Helpers][👽oss-helpi]][👽oss-help] [![CodeCov Test Coverage][🏀codecovi]][🏀codecov] [![Coveralls Test Coverage][🏀coveralls-img]][🏀coveralls] [![QLTY Test Coverage][🏀qlty-covi]][🏀qlty-cov] [![QLTY Maintainability][🏀qlty-mnti]][🏀qlty-mnt] [![CI Heads][🚎3-hd-wfi]][🚎3-hd-wf] [![CI Runtime Dependencies @ HEAD][🚎12-crh-wfi]][🚎12-crh-wf] [![CI Current][🚎11-c-wfi]][🚎11-c-wf] [![CI Truffle Ruby][🚎9-t-wfi]][🚎9-t-wf] [![CI JRuby][🚎10-j-wfi]][🚎10-j-wf] [![Deps Locked][🚎13-🔒️-wfi]][🚎13-🔒️-wf] [![Deps Unlocked][🚎14-🔓️-wfi]][🚎14-🔓️-wf] [![CI Test Coverage][🚎2-cov-wfi]][🚎2-cov-wf] [![CI Style][🚎5-st-wfi]][🚎5-st-wf] [![CodeQL][🖐codeQL-img]][🖐codeQL] [![Apache SkyWalking Eyes License Compatibility Check][🚎15-🪪-wfi]][🚎15-🪪-wf]

`if ci_badges.map(&:color).detect { it != "green"}` ☝️ [let me know][🖼️galtzo-discord], as I may have missed the [discord notification][🖼️galtzo-discord].

---

`if ci_badges.map(&:color).all? { it == "green"}` 👇️ send money so I can do more of this. FLOSS maintenance is now my full-time job.

[![OpenCollective Backers][🖇osc-backers-i]][🖇osc-backers] [![OpenCollective Sponsors][🖇osc-sponsors-i]][🖇osc-sponsors] [![Sponsor Me on Github][🖇sponsor-img]][🖇sponsor] [![Liberapay Goal Progress][⛳liberapay-img]][⛳liberapay] [![Donate on PayPal][🖇paypal-img]][🖇paypal] [![Buy me a coffee][🖇buyme-small-img]][🖇buyme] [![Donate on Polar][🖇polar-img]][🖇polar] [![Donate at ko-fi.com][🖇kofi-img]][🖇kofi]

<details>
    <summary>👣 How will this project approach the September 2025 hostile takeover of RubyGems? 🚑️</summary>

I've summarized my thoughts in [this blog post](https://dev.to/galtzo/hostile-takeover-of-rubygems-my-thoughts-5hlo).

</details>

## 🌻 Synopsis

Kettle::Jem is an AST-aware gem templating system that keeps hundreds of Ruby gems
in sync with a shared template while preserving each project's customizations.
Unlike line-based copy/merge tools, Kettle::Jem understands the *structure* of
every file it touches — Ruby via Prism, YAML via Psych, Markdown via Markly,
TOML via tree-sitter, and more — so template updates land precisely where they
belong, and project-specific additions are never clobbered.

### Key Features

- **AST-aware merging** — 10 format-specific merge engines (prism, psych, markly, toml, json, jsonc, bash, dotenv, rbs, text)
- **Token substitution** — `{KJ|TOKEN}` patterns resolved from config, ENV, or auto-derived from gemspec
- **Freeze blocks** — protect any section from template overwrites with `# kettle-jem:freeze` / `# kettle-jem:unfreeze`
- **Per-file strategies** — `merge`, `accept_template`, `keep_destination`, or `raw_copy`
- **Multi-phase pipeline** — 11 ordered phases (service_actor-based) from config sync through duplicate checking
- **SHA-pinned GitHub Actions** — template `uses:` always wins, propagating immutable SHAs
- **Convergence in one pass** — a single `rake kettle:jem:install` applies all changes; a second run produces zero diff
- **Selftest divergence check** — CI verifies that project drift stays within a configurable threshold

## 💡 Info you can shake a stick at

| Tokens to Remember      | [![Gem name][⛳️name-img]][⛳️gem-name] [![Gem namespace][⛳️namespace-img]][⛳️gem-namespace]                                                                                                                                                                                                                                                                          |
|-------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Works with JRuby        | [![JRuby current Compat][💎jruby-c-i]][🚎10-j-wf] [![JRuby HEAD Compat][💎jruby-headi]][🚎3-hd-wf]|
| Works with Truffle Ruby | [![Truffle Ruby 24.2 Compat][💎truby-24.2i]][🚎truby-24.2-wf] [![Truffle Ruby 25.0 Compat][💎truby-25.0i]][🚎truby-25.0-wf] [![Truffle Ruby current Compat][💎truby-c-i]][🚎9-t-wf]|
| Works with MRI Ruby 4   | [![Ruby 4.0 Compat][💎ruby-4.0i]][🚎11-c-wf] [![Ruby current Compat][💎ruby-c-i]][🚎11-c-wf] [![Ruby HEAD Compat][💎ruby-headi]][🚎3-hd-wf]|
| Works with MRI Ruby 3   | [![Ruby 3.2 Compat][💎ruby-3.2i]][🚎ruby-3.2-wf] [![Ruby 3.3 Compat][💎ruby-3.3i]][🚎ruby-3.3-wf] [![Ruby 3.4 Compat][💎ruby-3.4i]][🚎ruby-3.4-wf]|
| Support & Community     | [![Join Me on Daily.dev's RubyFriends][✉️ruby-friends-img]][✉️ruby-friends] [![Live Chat on Discord][✉️discord-invite-img-ftb]][✉️discord-invite] [![Get help from me on Upwork][👨🏼‍🏫expsup-upwork-img]][👨🏼‍🏫expsup-upwork] [![Get help from me on Codementor][👨🏼‍🏫expsup-codementor-img]][👨🏼‍🏫expsup-codementor]                                       |
| Source                  | [![Source on GitLab.com][📜src-gl-img]][📜src-gl] [![Source on CodeBerg.org][📜src-cb-img]][📜src-cb] [![Source on Github.com][📜src-gh-img]][📜src-gh] [![The best SHA: dQw4w9WgXcQ!][🧮kloc-img]][🧮kloc]                                                                                                                                                         |
| Documentation           | [![Current release on RubyDoc.info][📜docs-cr-rd-img]][🚎yard-current] [![YARD on Galtzo.com][📜docs-head-rd-img]][🚎yard-head] [![Maintainer Blog][🚂maint-blog-img]][🚂maint-blog] [![GitLab Wiki][📜gl-wiki-img]][📜gl-wiki] [![GitHub Wiki][📜gh-wiki-img]][📜gh-wiki]                                                                                          |
| Compliance              | [![License: MIT][📄license-img]][📄license-ref] [![Compatible with Apache Software Projects: Verified by SkyWalking Eyes][📄license-compat-img]][📄license-compat] [![📄ilo-declaration-img]][📄ilo-declaration] [![Security Policy][🔐security-img]][🔐security] [![Contributor Covenant 2.1][🪇conduct-img]][🪇conduct] [![SemVer 2.0.0][📌semver-img]][📌semver] |
| Style                   | [![Enforced Code Style Linter][💎rlts-img]][💎rlts] [![Keep-A-Changelog 1.0.0][📗keep-changelog-img]][📗keep-changelog] [![Gitmoji Commits][📌gitmoji-img]][📌gitmoji] [![Compatibility appraised by: appraisal2][💎appraisal2-img]][💎appraisal2]                                                                                                                  |
| Maintainer 🎖️          | [![Follow Me on LinkedIn][💖🖇linkedin-img]][💖🖇linkedin] [![Follow Me on Ruby.Social][💖🐘ruby-mast-img]][💖🐘ruby-mast] [![Follow Me on Bluesky][💖🦋bluesky-img]][💖🦋bluesky] [![Contact Maintainer][🚂maint-contact-img]][🚂maint-contact] [![My technical writing][💖💁🏼‍♂️devto-img]][💖💁🏼‍♂️devto]                                                      |
| `...` 💖                | [![Find Me on WellFound:][💖✌️wellfound-img]][💖✌️wellfound] [![Find Me on CrunchBase][💖💲crunchbase-img]][💖💲crunchbase] [![My LinkTree][💖🌳linktree-img]][💖🌳linktree] [![More About Me][💖💁🏼‍♂️aboutme-img]][💖💁🏼‍♂️aboutme] [🧊][💖🧊berg] [🐙][💖🐙hub]  [🛖][💖🛖hut] [🧪][💖🧪lab]                                                                   |

### Compatibility

Compatible with MRI Ruby 3.2.0+, and concordant releases of JRuby, and TruffleRuby.

| 🚚 _Amazing_ test matrix was brought to you by | 🔎 appraisal2 🔎 and the color 💚 green 💚             |
|------------------------------------------------|--------------------------------------------------------|
| 👟 Check it out!                               | ✨ [github.com/appraisal-rb/appraisal2][💎appraisal2] ✨ |

### Federated DVCS

<details markdown="1">
  <summary>Find this repo on federated forges (Coming soon!)</summary>

| Federated [DVCS][💎d-in-dvcs] Repository        | Status                                                                | Issues                    | PRs                      | Wiki                      | CI                       | Discussions                  |
|-------------------------------------------------|-----------------------------------------------------------------------|---------------------------|--------------------------|---------------------------|--------------------------|------------------------------|
| 🧪 [kettle-rb/kettle-jem on GitLab][📜src-gl]   | The Truth                                                             | [💚][🤝gl-issues]         | [💚][🤝gl-pulls]         | [💚][📜gl-wiki]           | 🐭 Tiny Matrix           | ➖                            |
| 🧊 [kettle-rb/kettle-jem on CodeBerg][📜src-cb] | An Ethical Mirror ([Donate][🤝cb-donate])                             | [💚][🤝cb-issues]         | [💚][🤝cb-pulls]         | ➖                         | ⭕️ No Matrix             | ➖                            |
| 🐙 [kettle-rb/kettle-jem on GitHub][📜src-gh]   | Another Mirror                                                        | [💚][🤝gh-issues]         | [💚][🤝gh-pulls]         | [💚][📜gh-wiki]           | 💯 Full Matrix           | [💚][gh-discussions]         |
| 🎮️ [Discord Server][✉️discord-invite]          | [![Live Chat on Discord][✉️discord-invite-img-ftb]][✉️discord-invite] | [Let's][✉️discord-invite] | [talk][✉️discord-invite] | [about][✉️discord-invite] | [this][✉️discord-invite] | [library!][✉️discord-invite] |

</details>

[gh-discussions]: https://github.com/kettle-rb/kettle-jem/discussions

### Enterprise Support [![Tidelift](https://tidelift.com/badges/package/rubygems/kettle-jem)](https://tidelift.com/subscription/pkg/rubygems-kettle-jem?utm_source=rubygems-kettle-jem&utm_medium=referral&utm_campaign=readme)

Available as part of the Tidelift Subscription.

<details markdown="1">
  <summary>Need enterprise-level guarantees?</summary>

The maintainers of this and thousands of other packages are working with Tidelift to deliver commercial support and maintenance for the open source packages you use to build your applications. Save time, reduce risk, and improve code health, while paying the maintainers of the exact packages you use.

[![Get help from me on Tidelift][🏙️entsup-tidelift-img]][🏙️entsup-tidelift]

- 💡Subscribe for support guarantees covering _all_ your FLOSS dependencies
- 💡Tidelift is part of [Sonar][🏙️entsup-tidelift-sonar]
- 💡Tidelift pays maintainers to maintain the software you depend on!<br/>📊`@`Pointy Haired Boss: An [enterprise support][🏙️entsup-tidelift] subscription is "[never gonna let you down][🧮kloc]", and *supports* open source maintainers

Alternatively:

- [![Live Chat on Discord][✉️discord-invite-img-ftb]][✉️discord-invite]
- [![Get help from me on Upwork][👨🏼‍🏫expsup-upwork-img]][👨🏼‍🏫expsup-upwork]
- [![Get help from me on Codementor][👨🏼‍🏫expsup-codementor-img]][👨🏼‍🏫expsup-codementor]

</details>

## ✨ Installation

Install the gem and add to the application's Gemfile by executing:

```console
bundle add kettle-jem
```

If bundler is not being used to manage dependencies, install the gem by executing:

```console
gem install kettle-jem
```

### 🔒 Secure Installation

<details markdown="1">
  <summary>For Medium or High Security Installations</summary>

This gem is cryptographically signed and has verifiable [SHA-256 and SHA-512][💎SHA_checksums] checksums by
[stone_checksums][💎stone_checksums]. Be sure the gem you install hasn’t been tampered with
by following the instructions below.

Add my public key (if you haven’t already; key expires 2045-04-29) as a trusted certificate:

```console
gem cert --add <(curl -Ls https://raw.github.com/galtzo-floss/certs/main/pboling.pem)
```

You only need to do that once.  Then proceed to install with:

```console
gem install kettle-jem -P HighSecurity
```

The `HighSecurity` trust profile will verify signed gems, and not allow the installation of unsigned dependencies.

If you want to up your security game full-time:

```console
bundle config set --global trust-policy MediumSecurity
```

`MediumSecurity` instead of `HighSecurity` is necessary if not all the gems you use are signed.

NOTE: Be prepared to track down certs for signed gems and add them the same way you added mine.

</details>

## ⚙️ Configuration

Each gem that uses Kettle::Jem has a `.kettle-jem.yml` file at its root. This file controls
every aspect of how the template is applied.

### Minimal Configuration

```yaml
project_emoji: "🔮"
engines:
  - ruby
licenses:
  - MIT
tokens:
  forge:
    gh_user: "your-username"
  author:
    name: "Your Name"
    email: "you@example.com"
```

### Full Configuration Reference

```yaml
# REQUIRED — unique emoji used in badges and gemspec summary
project_emoji: "🔮"

# Ruby engines to include in CI matrix (remove to skip)
engines:
  - ruby
  - jruby
  - truffleruby

# SPDX license identifiers
licenses:
  - MIT

# Logo layout in README header: org | project | org_and_project
readme:
  top_logo_mode: org

# Bot accounts to exclude from contributor lists
machine_users:
  - dependabot

# Maximum allowed divergence (%) for selftest CI check
min_divergence_threshold: 5

# Default merge behavior applied to all files
defaults:
  preference: "template"           # template | destination
  add_template_only_nodes: true    # add nodes that only exist in template
  freeze_token: "kettle-jem"       # marker for frozen sections

# Token values for {KJ|TOKEN} substitution
tokens:
  forge:
    gh_user: "github-username"
    gl_user: "gitlab-username"
    cb_user: "codeberg-username"
  author:
    name: "Full Name"
    email: "you@example.com"
    domain: "example.com"
    orcid: "0000-0000-0000-0000"
  funding:
    patreon: "username"
    kofi: "username"
    polar: "username"
    liberapay: "username"
  social:
    mastodon: "username"
    bluesky: "user.bsky.social"
    linktree: "username"
    devto: "username"

# Glob-based overrides (first match wins)
patterns:
  - path: "certs/**"
    strategy: raw_copy

# Per-file overrides
files:
  Rakefile:
    strategy: merge
    preference: destination        # preserve local tasks
  AGENTS.md:
    strategy: accept_template      # always use template version
```

### Framework Matrix vs. Appraisals

`workflows.preset: framework` and `workflows.framework_matrix` are meant for a
simple 2D matrix: **Ruby versions × one framework gem/version axis**. This is a
good fit when you want kettle-jem to generate CI matrix entries and gemfile
references directly without using `Appraisals`.

If you need a deeper or more complex matrix, prefer
**`kettle-jem-appraisals`**, which generates `Appraisals` entries and is the
better fit for Appraisals-style combinations.

### Strategies

| Strategy           | Behavior                                                              |
|--------------------|-----------------------------------------------------------------------|
| `merge`            | Resolve tokens, then AST-merge template + destination (default)       |
| `accept_template`  | Resolve tokens, overwrite destination with template result            |
| `keep_destination`  | Skip entirely — no merge, no creation                                |
| `raw_copy`         | Copy bytes as-is — no token resolution, no merge (for binary assets) |

### Token Substitution

Tokens use `{KJ|TOKEN}` syntax and are resolved in priority order:

1. **ENV variables** (highest) — e.g., `KJ_AUTHOR_NAME`
2. **`.kettle-jem.yml` `tokens:` section** — explicit values
3. **Auto-derived from gemspec** (lowest) — author name, email, domain

Common tokens:

| Token                  | Source                            |
|------------------------|-----------------------------------|
| `{KJ\|GEM_NAME}`       | Gem name from gemspec             |
| `{KJ\|NAMESPACE}`      | Ruby module namespace             |
| `{KJ\|AUTHOR:NAME}`    | Author full name                  |
| `{KJ\|AUTHOR:EMAIL}`   | Author email                      |
| `{KJ\|GH:USER}`        | GitHub username                   |
| `{KJ\|PROJECT_EMOJI}`  | Project emoji from config         |
| `{KJ\|MIN_RUBY}`       | Minimum Ruby version              |
| `{KJ\|FREEZE_TOKEN}`   | Freeze marker name                |

### Freeze Blocks

Protect sections in any file from template overwrites:

```ruby
# kettle-jem:freeze
gem "my-local-fork", path: "../custom"
# kettle-jem:unfreeze
```

Content between freeze/unfreeze markers is always preserved from the destination,
regardless of what the template contains. Works in all supported formats (Ruby, YAML,
Markdown, TOML, JSON, Bash, etc.).

### Merge Engine Selection

Kettle::Jem selects the merge engine by file type:

| File Pattern                                             | Merge Engine  | Key Behaviors                              |
|----------------------------------------------------------|---------------|--------------------------------------------|
| `*.rb`, `Gemfile`, `*.gemspec`, `Rakefile`, `Appraisals` | Prism::Merge  | Three-phase matching, gemspec var renaming |
| `*.yml`, `*.yaml`                                        | Psych::Merge  | SHA-pinned `uses:`, per-key preferences    |
| `*.md`, `*.markdown`                                     | Markly::Merge | Heading/list matching, inner list merge    |
| `*.toml`                                                 | Toml::Merge   | Sort keys, table matching                  |
| `*.json`                                                 | Json::Merge   | Key-based matching                         |
| `*.jsonc`                                                | Json::Merge   | With comment preservation                  |
| `*.sh`, `*.bash`, `.envrc`                               | Bash::Merge   | Block matching                             |
| `.env*`                                                  | Dotenv::Merge | KEY=value matching                         |
| `*.rbs`                                                  | RBS::Merge    | Type signature matching                    |
| `.gitignore`                                             | Text::Merge   | Intentional line-based merge               |

> **No silent fallback:** If a tree-sitter grammar is unavailable for a file
> type that requires AST merging, kettle-jem will **fail** (default) or
> **skip** the file — never silently degrade to text-based merging.
> See `PARSE_ERROR_MODE` below.

## 🔧 Basic Usage

### Initial Setup

```bash
gem install kettle-jem
cd my-gem
kettle-jem
```

The setup CLI runs a two-phase bootstrap:

1. **Bootstrap** — creates `.kettle-jem.yml`, installs modular gemfiles, ensures dev dependencies
2. **Bundled** — loads the full runtime and runs `rake kettle:jem:install`

### Applying Template Updates

After initial setup, re-run the template process to pull in updates:

```bash
bundle exec rake kettle:jem:install
```

This applies all 11 phases:

| Phase | Description                          | Files Affected                        |
|-------|--------------------------------------|---------------------------------------|
| 0     | Config sync                          | `.kettle-jem.yml`                     |
| 1     | Dev container                        | `.devcontainer/`                      |
| 2     | GitHub workflows                     | `.github/workflows/`, `FUNDING.yml`   |
| 3     | Quality config                       | `.qlty/qlty.toml`                     |
| 4     | Modular gemfiles                     | `gemfiles/modular/`                   |
| 5     | Spec helper                          | `spec/spec_helper.rb`                 |
| 6     | Environment templates                | `.env.local.example`                  |
| 7     | Remaining files                      | gemspec, README, LICENSE, Rakefile, … |
| 8     | Git hooks                            | `.git-hooks/`                         |
| 9     | License files                        | `LICENSE*`                            |
| 10    | Duplicate check                      | _(validation only)_                   |

Each phase is implemented as a composable [service_actor](https://github.com/sunny/actor)
actor, enabling per-phase statistics (📄 templates, 🆕 created, 📋 pre-existing,
🟰 identical, ✏️ changed) and future slice-based workflows.

### Checking Divergence

CI can verify that a project hasn't drifted too far from the template:

```bash
bundle exec rake kettle:jem:selftest
```

This re-applies the template in a temporary checkout and measures the diff.
Output is condensed to two summary lines after the template run:

```
[selftest] 📄  Report - tmp/template_test/report/summary.md
[selftest] ✅  Score: 100.0% · Divergence: 0.0% · Threshold: fail when divergence reaches 5.0%
```

If divergence exceeds `min_divergence_threshold` (default 5%), the check fails.

### Workflow-Specific Options

For GitHub Actions workflows, the template always wins for `uses:` lines
(SHA-pinned action references) while destination wins for job configuration:

```yaml
# Template updates this SHA automatically:
uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683

# Your matrix customizations are preserved:
matrix:
  ruby: ["3.2", "3.3", "3.4"]
```

### Per-File Overrides

Override merge behavior for specific files in `.kettle-jem.yml`:

```yaml
files:
  Rakefile:
    strategy: merge
    preference: destination     # keep your custom tasks
  certs/my.pem:
    strategy: raw_copy          # binary file, no merging
  generated/report.md:
    strategy: keep_destination  # never touch this file
```

### Environment Variables & CLI Options

Kettle::Jem behavior is controlled via environment variables (which double as
Rake task arguments) and CLI flags passed to `kettle-jem setup`.

#### Merge & Error Handling

| Variable | CLI Flag | Default | Description |
|----------|----------|---------|-------------|
| `FAILURE_MODE` | `--failure-mode=VAL` | `error` | How general merge failures are handled. `error` raises and halts; `rescue` logs a warning and uses unmerged content. |
| `PARSE_ERROR_MODE` | — | `fail` | How AST parser unavailability is handled. `fail` raises immediately (recommended); `skip` warns and preserves the destination file unchanged. **There is no text-merge fallback** — AST merge or nothing. |

#### Task Control

| Variable | CLI Flag | Default | Description |
|----------|----------|---------|-------------|
| `allowed` | `--allowed=VAL` | `true` | Set to `false`/`0`/`no` to require manual review of env file changes before continuing. |
| — | `--interactive` | _(off)_ | Enable interactive prompts (opt-in). Overrides the default non-interactive behavior. |
| `KETTLE_JEM_VERBOSE` | `--verbose` | `false` | Show detailed output including per-file messages and setup progress. Overrides the default quiet behavior. |
| `only` | `--only=VAL` | _(all)_ | Comma-separated glob patterns — only template files matching at least one pattern are processed. |
| `include` | `--include=VAL` | _(all)_ | Comma-separated glob patterns — additional files to include beyond the default set. |
| `hook_templates` | `--hook_templates=VAL` | _(prompt)_ | Git hook install location: `l`/`local`, `g`/`global`, or `n`/`none`. Also via `KETTLE_DEV_HOOK_TEMPLATES`. |

#### Config & Identity (KJ_ prefix)

These seed `.kettle-jem.yml` values when the config is freshly created or when
a key is missing. They are also used as runtime overrides.

| Variable | Description |
|----------|-------------|
| `KJ_PROJECT_EMOJI` | Project identifying emoji (e.g. `🪙`). Required in config. |
| `KJ_AUTHOR_NAME` | Gem author full name |
| `KJ_AUTHOR_EMAIL` | Gem author email |
| `KJ_AUTHOR_DOMAIN` | Author website domain (derived from email if unset) |
| `KJ_AUTHOR_GIVEN_NAMES` | First/given names |
| `KJ_AUTHOR_FAMILY_NAMES` | Last/family names |
| `KJ_AUTHOR_ORCID` | ORCID identifier |
| `KJ_GH_USER` | GitHub username |
| `KJ_GL_USER` | GitLab username |
| `KJ_CB_USER` | Codeberg username |
| `KJ_SH_USER` | SourceHut username |

#### Workspace & Funding

| Variable | Description |
|----------|-------------|
| `KETTLE_RB_DEV` | Workspace root for local sibling gems. `true` = `~/src/kettle-rb`; a path = that path; unset/`false` = released gems. |
| `KETTLE_DEV_DEBUG` | Set to `true` for verbose debug output. |
| `FUNDING_ORG` | OpenCollective organization handle for FUNDING.yml. Auto-derived from git remote if unset. |
| `OPENCOLLECTIVE_HANDLE` | Alternative to `FUNDING_ORG` for personal OpenCollective pages. |
| `KJ_FUNDING_PATREON` | Patreon handle for FUNDING.yml |
| `KJ_FUNDING_KOFI` | Ko-fi handle for FUNDING.yml |
| `KJ_FUNDING_PAYPAL` | PayPal handle for FUNDING.yml |

#### Rake Task Examples

```bash
# Standard template update (quiet, non-interactive — the default)
bundle exec rake kettle:jem:install

# Verbose output
KETTLE_JEM_VERBOSE=true bundle exec rake kettle:jem:install

# Interactive mode (prompts before each change)
bundle exec rake kettle:jem:install force=false

# Only workflow files, skip unparseable
PARSE_ERROR_MODE=skip bundle exec rake kettle:jem:install only=".github/**"

# Rescue on merge failure (don't halt)
bundle exec rake kettle:jem:install FAILURE_MODE=rescue
```

## 🦷 FLOSS Funding

While kettle-rb tools are free software and will always be, the project would benefit immensely from some funding.
Raising a monthly budget of... "dollars" would make the project more sustainable.

We welcome both individual and corporate sponsors! We also offer a
wide array of funding channels to account for your preferences
(although currently [Open Collective][🖇osc] is our preferred funding platform).

**If you're working in a company that's making significant use of kettle-rb tools we'd
appreciate it if you suggest to your company to become a kettle-rb sponsor.**

You can support the development of kettle-rb tools via
[GitHub Sponsors][🖇sponsor],
[Liberapay][⛳liberapay],
[PayPal][🖇paypal],
[Open Collective][🖇osc]
and [Tidelift][🏙️entsup-tidelift].

| 📍 NOTE                                                                                                                                                                                                              |
|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| If doing a sponsorship in the form of donation is problematic for your company <br/> from an accounting standpoint, we'd recommend the use of Tidelift, <br/> where you can get a support-like subscription instead. |

### Open Collective for Individuals

Support us with a monthly donation and help us continue our activities. [[Become a backer](https://opencollective.com/kettle-rb#backer)]

NOTE: [kettle-readme-backers][kettle-readme-backers] updates this list every day, automatically.

<!-- OPENCOLLECTIVE-INDIVIDUALS:START -->
No backers yet. Be the first!
<!-- OPENCOLLECTIVE-INDIVIDUALS:END -->

### Open Collective for Organizations

Become a sponsor and get your logo on our README on GitHub with a link to your site. [[Become a sponsor](https://opencollective.com/kettle-rb#sponsor)]

NOTE: [kettle-readme-backers][kettle-readme-backers] updates this list every day, automatically.

<!-- OPENCOLLECTIVE-ORGANIZATIONS:START -->
No sponsors yet. Be the first!
<!-- OPENCOLLECTIVE-ORGANIZATIONS:END -->

[kettle-readme-backers]: https://github.com/kettle-rb/kettle-jem/blob/main/exe/kettle-readme-backers

### Another way to support open-source

I’m driven by a passion to foster a thriving open-source community – a space where people can tackle complex problems, no matter how small.  Revitalizing libraries that have fallen into disrepair, and building new libraries focused on solving real-world challenges, are my passions.  I was recently affected by layoffs, and the tech jobs market is unwelcoming. I’m reaching out here because your support would significantly aid my efforts to provide for my family, and my farm (11 🐔 chickens, 2 🐶 dogs, 3 🐰 rabbits, 8 🐈‍ cats).

If you work at a company that uses my work, please encourage them to support me as a corporate sponsor. My work on gems you use might show up in `bundle fund`.

I’m developing a new library, [floss_funding][🖇floss-funding-gem], designed to empower open-source developers like myself to get paid for the work we do, in a sustainable way. Please give it a look.

**[Floss-Funding.dev][🖇floss-funding.dev]: 👉️ No network calls. 👉️ No tracking. 👉️ No oversight. 👉️ Minimal crypto hashing. 💡 Easily disabled nags**

[![OpenCollective Backers][🖇osc-backers-i]][🖇osc-backers] [![OpenCollective Sponsors][🖇osc-sponsors-i]][🖇osc-sponsors] [![Sponsor Me on Github][🖇sponsor-img]][🖇sponsor] [![Liberapay Goal Progress][⛳liberapay-img]][⛳liberapay] [![Donate on PayPal][🖇paypal-img]][🖇paypal] [![Buy me a coffee][🖇buyme-small-img]][🖇buyme] [![Donate on Polar][🖇polar-img]][🖇polar] [![Donate to my FLOSS efforts at ko-fi.com][🖇kofi-img]][🖇kofi] [![Donate to my FLOSS efforts using Patreon][🖇patreon-img]][🖇patreon]

## 🔐 Security

See [SECURITY.md][🔐security].

## 🤝 Contributing

If you need some ideas of where to help, you could work on adding more code coverage,
or if it is already 💯 (see [below](#code-coverage)) check [reek](REEK), [issues][🤝gh-issues], or [PRs][🤝gh-pulls],
or use the gem and think about how it could be better.

We [![Keep A Changelog][📗keep-changelog-img]][📗keep-changelog] so if you make changes, remember to update it.

See [CONTRIBUTING.md][🤝contributing] for more detailed instructions.

### 🚀 Release Instructions

See [CONTRIBUTING.md][🤝contributing].

### Code Coverage

[![Coverage Graph][🏀codecov-g]][🏀codecov]

[![Coveralls Test Coverage][🏀coveralls-img]][🏀coveralls]

[![QLTY Test Coverage][🏀qlty-covi]][🏀qlty-cov]

### 🪇 Code of Conduct

Everyone interacting with this project's codebases, issue trackers,
chat rooms and mailing lists agrees to follow the [![Contributor Covenant 2.1][🪇conduct-img]][🪇conduct].

## 🌈 Contributors

[![Contributors][🖐contributors-img]][🖐contributors]

Made with [contributors-img][🖐contrib-rocks].

Also see GitLab Contributors: [https://gitlab.com/kettle-rb/kettle-jem/-/graphs/main][🚎contributors-gl]

<details>
    <summary>⭐️ Star History</summary>

<a href="https://star-history.com/#kettle-rb/kettle-jem&Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=kettle-rb/kettle-jem&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=kettle-rb/kettle-jem&type=Date" />
   <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=kettle-rb/kettle-jem&type=Date" />
 </picture>
</a>

</details>

## 📌 Versioning

This Library adheres to [![Semantic Versioning 2.0.0][📌semver-img]][📌semver].
Violations of this scheme should be reported as bugs.
Specifically, if a minor or patch version is released that breaks backward compatibility,
a new version should be immediately released that restores compatibility.
Breaking changes to the public API will only be introduced with new major versions.

> dropping support for a platform is both obviously and objectively a breaking change <br/>
>—Jordan Harband ([@ljharb](https://github.com/ljharb), maintainer of SemVer) [in SemVer issue 716][📌semver-breaking]

I understand that policy doesn't work universally ("exceptions to every rule!"),
but it is the policy here.
As such, in many cases it is good to specify a dependency on this library using
the [Pessimistic Version Constraint][📌pvc] with two digits of precision.

For example:

```ruby
spec.add_dependency("kettle-jem", "~> 1.0")
```

<details markdown="1">
<summary>📌 Is "Platform Support" part of the public API? More details inside.</summary>

SemVer should, IMO, but doesn't explicitly, say that dropping support for specific Platforms
is a *breaking change* to an API, and for that reason the bike shedding is endless.

To get a better understanding of how SemVer is intended to work over a project's lifetime,
read this article from the creator of SemVer:

- ["Major Version Numbers are Not Sacred"][📌major-versions-not-sacred]

</details>

See [CHANGELOG.md][📌changelog] for a list of releases.

## 📄 License

The gem is available under the following license: [AGPL-3.0-only](AGPL-3.0-only.md).
See [LICENSE.md][📄license] for details.

If none of the available licenses suit your use case, please [contact us](mailto:floss@galtzo.com) to discuss a custom commercial license.

### © Copyright

See [LICENSE.md][📄license] for the official copyright notice.

## 🤑 A request for help

Maintainers have teeth and need to pay their dentists.
After getting laid off in an RIF in March, and encountering difficulty finding a new one,
I began spending most of my time building open source tools.
I'm hoping to be able to pay for my kids' health insurance this month,
so if you value the work I am doing, I need your support.
Please consider sponsoring me or the project.

To join the community or get help 👇️ Join the Discord.

[![Live Chat on Discord][✉️discord-invite-img-ftb]][✉️discord-invite]

To say "thanks!" ☝️ Join the Discord or 👇️ send money.

[![Sponsor kettle-rb/kettle-jem on Open Source Collective][🖇osc-all-bottom-img]][🖇osc] 💌 [![Sponsor me on GitHub Sponsors][🖇sponsor-bottom-img]][🖇sponsor] 💌 [![Sponsor me on Liberapay][⛳liberapay-bottom-img]][⛳liberapay] 💌 [![Donate on PayPal][🖇paypal-bottom-img]][🖇paypal]

### Please give the project a star ⭐ ♥.

Thanks for RTFM. ☺️

[⛳liberapay-img]: https://img.shields.io/liberapay/goal/pboling.svg?logo=liberapay&color=a51611&style=flat
[⛳liberapay-bottom-img]: https://img.shields.io/liberapay/goal/pboling.svg?style=for-the-badge&logo=liberapay&color=a51611
[⛳liberapay]: https://liberapay.com/pboling/donate
[🖇osc-all-img]: https://img.shields.io/opencollective/all/kettle-rb
[🖇osc-sponsors-img]: https://img.shields.io/opencollective/sponsors/kettle-rb
[🖇osc-backers-img]: https://img.shields.io/opencollective/backers/kettle-rb
[🖇osc-backers]: https://opencollective.com/kettle-rb#backer
[🖇osc-backers-i]: https://opencollective.com/kettle-rb/backers/badge.svg?style=flat
[🖇osc-sponsors]: https://opencollective.com/kettle-rb#sponsor
[🖇osc-sponsors-i]: https://opencollective.com/kettle-rb/sponsors/badge.svg?style=flat
[🖇osc-all-bottom-img]: https://img.shields.io/opencollective/all/kettle-rb?style=for-the-badge
[🖇osc-sponsors-bottom-img]: https://img.shields.io/opencollective/sponsors/kettle-rb?style=for-the-badge
[🖇osc-backers-bottom-img]: https://img.shields.io/opencollective/backers/kettle-rb?style=for-the-badge
[🖇osc]: https://opencollective.com/kettle-rb
[🖇sponsor-img]: https://img.shields.io/badge/Sponsor_Me!-pboling.svg?style=social&logo=github
[🖇sponsor-bottom-img]: https://img.shields.io/badge/Sponsor_Me!-pboling-blue?style=for-the-badge&logo=github
[🖇sponsor]: https://github.com/sponsors/pboling
[🖇polar-img]: https://img.shields.io/badge/polar-donate-a51611.svg?style=flat
[🖇polar]: https://polar.sh/pboling
[🖇kofi-img]: https://img.shields.io/badge/ko--fi-%E2%9C%93-a51611.svg?style=flat
[🖇kofi]: https://ko-fi.com/pboling
[🖇patreon-img]: https://img.shields.io/badge/patreon-donate-a51611.svg?style=flat
[🖇patreon]: https://patreon.com/galtzo
[🖇buyme-small-img]: https://img.shields.io/badge/buy_me_a_coffee-%E2%9C%93-a51611.svg?style=flat
[🖇buyme-img]: https://img.buymeacoffee.com/button-api/?text=Buy%20me%20a%20latte&emoji=&slug=pboling&button_colour=FFDD00&font_colour=000000&font_family=Cookie&outline_colour=000000&coffee_colour=ffffff
[🖇buyme]: https://www.buymeacoffee.com/pboling
[🖇paypal-img]: https://img.shields.io/badge/donate-paypal-a51611.svg?style=flat&logo=paypal
[🖇paypal-bottom-img]: https://img.shields.io/badge/donate-paypal-a51611.svg?style=for-the-badge&logo=paypal&color=0A0A0A
[🖇paypal]: https://www.paypal.com/paypalme/peterboling
[🖇floss-funding.dev]: https://floss-funding.dev
[🖇floss-funding-gem]: https://github.com/galtzo-floss/floss_funding
[✉️discord-invite]: https://discord.gg/3qme4XHNKN
[✉️discord-invite-img-ftb]: https://img.shields.io/discord/1373797679469170758?style=for-the-badge&logo=discord
[✉️ruby-friends-img]: https://img.shields.io/badge/daily.dev-%F0%9F%92%8E_Ruby_Friends-0A0A0A?style=for-the-badge&logo=dailydotdev&logoColor=white
[✉️ruby-friends]: https://app.daily.dev/squads/rubyfriends

[✇bundle-group-pattern]: https://gist.github.com/pboling/4564780
[⛳️gem-namespace]: https://github.com/kettle-rb/kettle-jem
[⛳️namespace-img]: https://img.shields.io/badge/namespace-Kettle::Jem-3C2D2D.svg?style=square&logo=ruby&logoColor=white
[⛳️gem-name]: https://bestgems.org/gems/kettle-jem
[⛳️name-img]: https://img.shields.io/badge/name-kettle--jem-3C2D2D.svg?style=square&logo=rubygems&logoColor=red
[⛳️tag-img]: https://img.shields.io/github/tag/kettle-rb/kettle-jem.svg
[⛳️tag]: http://github.com/kettle-rb/kettle-jem/releases
[🚂maint-blog]: http://www.railsbling.com/tags/kettle-jem
[🚂maint-blog-img]: https://img.shields.io/badge/blog-railsbling-0093D0.svg?style=for-the-badge&logo=rubyonrails&logoColor=orange
[🚂maint-contact]: http://www.railsbling.com/contact
[🚂maint-contact-img]: https://img.shields.io/badge/Contact-Maintainer-0093D0.svg?style=flat&logo=rubyonrails&logoColor=red
[💖🖇linkedin]: http://www.linkedin.com/in/peterboling
[💖🖇linkedin-img]: https://img.shields.io/badge/LinkedIn-Profile-0B66C2?style=flat&logo=newjapanprowrestling
[💖✌️wellfound]: https://wellfound.com/u/peter-boling
[💖✌️wellfound-img]: https://img.shields.io/badge/peter--boling-orange?style=flat&logo=wellfound
[💖💲crunchbase]: https://www.crunchbase.com/person/peter-boling
[💖💲crunchbase-img]: https://img.shields.io/badge/peter--boling-purple?style=flat&logo=crunchbase
[💖🐘ruby-mast]: https://ruby.social/@galtzo
[💖🐘ruby-mast-img]: https://img.shields.io/mastodon/follow/109447111526622197?domain=https://ruby.social&style=flat&logo=mastodon&label=Ruby%20@galtzo
[💖🦋bluesky]: https://bsky.app/profile/galtzo.com
[💖🦋bluesky-img]: https://img.shields.io/badge/@galtzo.com-0285FF?style=flat&logo=bluesky&logoColor=white
[💖🌳linktree]: https://linktr.ee/galtzo
[💖🌳linktree-img]: https://img.shields.io/badge/galtzo-purple?style=flat&logo=linktree
[💖💁🏼‍♂️devto]: https://dev.to/galtzo
[💖💁🏼‍♂️devto-img]: https://img.shields.io/badge/dev.to-0A0A0A?style=flat&logo=devdotto&logoColor=white
[💖💁🏼‍♂️aboutme]: https://about.me/peter.boling
[💖💁🏼‍♂️aboutme-img]: https://img.shields.io/badge/about.me-0A0A0A?style=flat&logo=aboutme&logoColor=white
[💖🧊berg]: https://codeberg.org/pboling
[💖🐙hub]: https://github.org/pboling
[💖🛖hut]: https://sr.ht/~galtzo/
[💖🧪lab]: https://gitlab.com/pboling
[👨🏼‍🏫expsup-upwork]: https://www.upwork.com/freelancers/~014942e9b056abdf86?mp_source=share
[👨🏼‍🏫expsup-upwork-img]: https://img.shields.io/badge/UpWork-13544E?style=for-the-badge&logo=Upwork&logoColor=white
[👨🏼‍🏫expsup-codementor]: https://www.codementor.io/peterboling?utm_source=github&utm_medium=button&utm_term=peterboling&utm_campaign=github
[👨🏼‍🏫expsup-codementor-img]: https://img.shields.io/badge/CodeMentor-Get_Help-1abc9c?style=for-the-badge&logo=CodeMentor&logoColor=white
[🏙️entsup-tidelift]: https://tidelift.com/subscription/pkg/rubygems-kettle-jem?utm_source=rubygems-kettle-jem&utm_medium=referral&utm_campaign=readme
[🏙️entsup-tidelift-img]: https://img.shields.io/badge/Tidelift_and_Sonar-Enterprise_Support-FD3456?style=for-the-badge&logo=sonar&logoColor=white
[🏙️entsup-tidelift-sonar]: https://blog.tidelift.com/tidelift-joins-sonar
[💁🏼‍♂️peterboling]: http://www.peterboling.com
[🚂railsbling]: http://www.railsbling.com
[📜src-gl-img]: https://img.shields.io/badge/GitLab-FBA326?style=for-the-badge&logo=Gitlab&logoColor=orange
[📜src-gl]: https://gitlab.com/kettle-rb/kettle-jem/
[📜src-cb-img]: https://img.shields.io/badge/CodeBerg-4893CC?style=for-the-badge&logo=CodeBerg&logoColor=blue
[📜src-cb]: https://codeberg.org/kettle-rb/kettle-jem
[📜src-gh-img]: https://img.shields.io/badge/GitHub-238636?style=for-the-badge&logo=Github&logoColor=green
[📜src-gh]: https://github.com/kettle-rb/kettle-jem
[📜docs-cr-rd-img]: https://img.shields.io/badge/RubyDoc-Current_Release-943CD2?style=for-the-badge&logo=readthedocs&logoColor=white
[📜docs-head-rd-img]: https://img.shields.io/badge/YARD_on_Galtzo.com-HEAD-943CD2?style=for-the-badge&logo=readthedocs&logoColor=white
[📜gl-wiki]: https://gitlab.com/kettle-rb/kettle-jem/-/wikis/home
[📜gh-wiki]: https://github.com/kettle-rb/kettle-jem/wiki
[📜gl-wiki-img]: https://img.shields.io/badge/wiki-examples-943CD2.svg?style=for-the-badge&logo=gitlab&logoColor=white
[📜gh-wiki-img]: https://img.shields.io/badge/wiki-examples-943CD2.svg?style=for-the-badge&logo=github&logoColor=white
[👽dl-rank]: https://bestgems.org/gems/kettle-jem
[👽dl-ranki]: https://img.shields.io/gem/rd/kettle-jem.svg
[👽oss-help]: https://www.codetriage.com/kettle-rb/kettle-jem
[👽oss-helpi]: https://www.codetriage.com/kettle-rb/kettle-jem/badges/users.svg
[👽version]: https://bestgems.org/gems/kettle-jem
[👽versioni]: https://img.shields.io/gem/v/kettle-jem.svg
[🏀qlty-mnt]: https://qlty.sh/gh/kettle-rb/projects/kettle-jem
[🏀qlty-mnti]: https://qlty.sh/gh/kettle-rb/projects/kettle-jem/maintainability.svg
[🏀qlty-cov]: https://qlty.sh/gh/kettle-rb/projects/kettle-jem/metrics/code?sort=coverageRating
[🏀qlty-covi]: https://qlty.sh/gh/kettle-rb/projects/kettle-jem/coverage.svg
[🏀codecov]: https://codecov.io/gh/kettle-rb/kettle-jem
[🏀codecovi]: https://codecov.io/gh/kettle-rb/kettle-jem/graph/badge.svg
[🏀coveralls]: https://coveralls.io/github/kettle-rb/kettle-jem?branch=main
[🏀coveralls-img]: https://coveralls.io/repos/github/kettle-rb/kettle-jem/badge.svg?branch=main
[🖐codeQL]: https://github.com/kettle-rb/kettle-jem/security/code-scanning
[🖐codeQL-img]: https://github.com/kettle-rb/kettle-jem/actions/workflows/codeql-analysis.yml/badge.svg
[🚎ruby-3.2-wf]: https://github.com/kettle-rb/kettle-jem/actions/workflows/ruby-3.2.yml
[🚎ruby-3.3-wf]: https://github.com/kettle-rb/kettle-jem/actions/workflows/ruby-3.3.yml
[🚎ruby-3.4-wf]: https://github.com/kettle-rb/kettle-jem/actions/workflows/ruby-3.4.yml
[🚎truby-24.2-wf]: https://github.com/kettle-rb/kettle-jem/actions/workflows/truffleruby-24.2.yml
[🚎truby-25.0-wf]: https://github.com/kettle-rb/kettle-jem/actions/workflows/truffleruby-25.0.yml
[🚎2-cov-wf]: https://github.com/kettle-rb/kettle-jem/actions/workflows/coverage.yml
[🚎2-cov-wfi]: https://github.com/kettle-rb/kettle-jem/actions/workflows/coverage.yml/badge.svg
[🚎3-hd-wf]: https://github.com/kettle-rb/kettle-jem/actions/workflows/heads.yml
[🚎3-hd-wfi]: https://github.com/kettle-rb/kettle-jem/actions/workflows/heads.yml/badge.svg
[🚎5-st-wf]: https://github.com/kettle-rb/kettle-jem/actions/workflows/style.yml
[🚎5-st-wfi]: https://github.com/kettle-rb/kettle-jem/actions/workflows/style.yml/badge.svg
[🚎9-t-wf]: https://github.com/kettle-rb/kettle-jem/actions/workflows/truffle.yml
[🚎9-t-wfi]: https://github.com/kettle-rb/kettle-jem/actions/workflows/truffle.yml/badge.svg
[🚎10-j-wf]: https://github.com/kettle-rb/kettle-jem/actions/workflows/jruby.yml
[🚎10-j-wfi]: https://github.com/kettle-rb/kettle-jem/actions/workflows/jruby.yml/badge.svg
[🚎11-c-wf]: https://github.com/kettle-rb/kettle-jem/actions/workflows/current.yml
[🚎11-c-wfi]: https://github.com/kettle-rb/kettle-jem/actions/workflows/current.yml/badge.svg
[🚎12-crh-wf]: https://github.com/kettle-rb/kettle-jem/actions/workflows/dep-heads.yml
[🚎12-crh-wfi]: https://github.com/kettle-rb/kettle-jem/actions/workflows/dep-heads.yml/badge.svg
[🚎13-🔒️-wf]: https://github.com/kettle-rb/kettle-jem/actions/workflows/locked_deps.yml
[🚎13-🔒️-wfi]: https://github.com/kettle-rb/kettle-jem/actions/workflows/locked_deps.yml/badge.svg
[🚎14-🔓️-wf]: https://github.com/kettle-rb/kettle-jem/actions/workflows/unlocked_deps.yml
[🚎14-🔓️-wfi]: https://github.com/kettle-rb/kettle-jem/actions/workflows/unlocked_deps.yml/badge.svg
[🚎15-🪪-wf]: https://github.com/kettle-rb/kettle-jem/actions/workflows/license-eye.yml
[🚎15-🪪-wfi]: https://github.com/kettle-rb/kettle-jem/actions/workflows/license-eye.yml/badge.svg
[💎ruby-3.2i]: https://img.shields.io/badge/Ruby-3.2-CC342D?style=for-the-badge&logo=ruby&logoColor=white
[💎ruby-3.3i]: https://img.shields.io/badge/Ruby-3.3-CC342D?style=for-the-badge&logo=ruby&logoColor=white
[💎ruby-3.4i]: https://img.shields.io/badge/Ruby-3.4-CC342D?style=for-the-badge&logo=ruby&logoColor=white
[💎ruby-4.0i]: https://img.shields.io/badge/Ruby-4.0-CC342D?style=for-the-badge&logo=ruby&logoColor=white
[💎ruby-c-i]: https://img.shields.io/badge/Ruby-current-CC342D?style=for-the-badge&logo=ruby&logoColor=green
[💎ruby-headi]: https://img.shields.io/badge/Ruby-HEAD-CC342D?style=for-the-badge&logo=ruby&logoColor=blue
[💎truby-24.2i]: https://img.shields.io/badge/Truffle_Ruby-24.2-34BCB1?style=for-the-badge&logo=ruby&logoColor=pink
[💎truby-25.0i]: https://img.shields.io/badge/Truffle_Ruby-25.0-34BCB1?style=for-the-badge&logo=ruby&logoColor=pink
[💎truby-c-i]: https://img.shields.io/badge/Truffle_Ruby-current-34BCB1?style=for-the-badge&logo=ruby&logoColor=green
[💎jruby-c-i]: https://img.shields.io/badge/JRuby-current-FBE742?style=for-the-badge&logo=ruby&logoColor=green
[💎jruby-headi]: https://img.shields.io/badge/JRuby-HEAD-FBE742?style=for-the-badge&logo=ruby&logoColor=blue
[🤝gh-issues]: https://github.com/kettle-rb/kettle-jem/issues
[🤝gh-pulls]: https://github.com/kettle-rb/kettle-jem/pulls
[🤝gl-issues]: https://gitlab.com/kettle-rb/kettle-jem/-/issues
[🤝gl-pulls]: https://gitlab.com/kettle-rb/kettle-jem/-/merge_requests
[🤝cb-issues]: https://codeberg.org/kettle-rb/kettle-jem/issues
[🤝cb-pulls]: https://codeberg.org/kettle-rb/kettle-jem/pulls
[🤝cb-donate]: https://donate.codeberg.org/
[🤝contributing]: CONTRIBUTING.md
[🏀codecov-g]: https://codecov.io/gh/kettle-rb/kettle-jem/graphs/tree.svg
[🖐contrib-rocks]: https://contrib.rocks
[🖐contributors]: https://github.com/kettle-rb/kettle-jem/graphs/contributors
[🖐contributors-img]: https://contrib.rocks/image?repo=kettle-rb/kettle-jem
[🚎contributors-gl]: https://gitlab.com/kettle-rb/kettle-jem/-/graphs/main
[🪇conduct]: CODE_OF_CONDUCT.md
[🪇conduct-img]: https://img.shields.io/badge/Contributor_Covenant-2.1-259D6C.svg
[📌pvc]: http://guides.rubygems.org/patterns/#pessimistic-version-constraint
[📌semver]: https://semver.org/spec/v2.0.0.html
[📌semver-img]: https://img.shields.io/badge/semver-2.0.0-259D6C.svg?style=flat
[📌semver-breaking]: https://github.com/semver/semver/issues/716#issuecomment-869336139
[📌major-versions-not-sacred]: https://tom.preston-werner.com/2022/05/23/major-version-numbers-are-not-sacred.html
[📌changelog]: CHANGELOG.md
[📗keep-changelog]: https://keepachangelog.com/en/1.0.0/
[📗keep-changelog-img]: https://img.shields.io/badge/keep--a--changelog-1.0.0-34495e.svg?style=flat
[📌gitmoji]: https://gitmoji.dev
[📌gitmoji-img]: https://img.shields.io/badge/gitmoji_commits-%20%F0%9F%98%9C%20%F0%9F%98%8D-34495e.svg?style=flat-square
[🧮kloc]: https://www.youtube.com/watch?v=dQw4w9WgXcQ
[🧮kloc-img]: https://img.shields.io/badge/KLOC-5.053-FFDD67.svg?style=for-the-badge&logo=YouTube&logoColor=blue
[🔐security]: SECURITY.md
[🔐security-img]: https://img.shields.io/badge/security-policy-259D6C.svg?style=flat
[📄copyright-notice-explainer]: https://opensource.stackexchange.com/questions/5778/why-do-licenses-such-as-the-mit-license-specify-a-single-year
[📄license]: LICENSE.md
[📄license-compat]: https://dev.to/galtzo/how-to-check-license-compatibility-41h0
[📄license-compat-img]: https://img.shields.io/badge/Apache_Compatible:_Category_A-%E2%9C%93-259D6C.svg?style=flat&logo=Apache
[📄ilo-declaration]: https://www.ilo.org/declaration/lang--en/index.htm
[📄ilo-declaration-img]: https://img.shields.io/badge/ILO_Fundamental_Principles-✓-259D6C.svg?style=flat
[🚎yard-current]: http://rubydoc.info/gems/kettle-jem
[🚎yard-head]: https://kettle-jem.galtzo.com
[💎stone_checksums]: https://github.com/galtzo-floss/stone_checksums
[💎SHA_checksums]: https://gitlab.com/kettle-rb/kettle-jem/-/tree/main/checksums
[💎rlts]: https://github.com/rubocop-lts/rubocop-lts
[💎rlts-img]: https://img.shields.io/badge/code_style_&_linting-rubocop--lts-34495e.svg?plastic&logo=ruby&logoColor=white
[💎appraisal2]: https://github.com/appraisal-rb/appraisal2
[💎appraisal2-img]: https://img.shields.io/badge/appraised_by-appraisal2-34495e.svg?plastic&logo=ruby&logoColor=white
[💎d-in-dvcs]: https://railsbling.com/posts/dvcs/put_the_d_in_dvcs/
