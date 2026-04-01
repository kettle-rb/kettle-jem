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

A collection of `Ast::Merge::MergerConfig` presets, YAML-based merge recipes, signature generators, and node typing classifiers for gem templating with the `*-merge` gem family.

### The `*-merge` Gem Family

The `*-merge` gem family provides intelligent, AST-based merging for various file formats. At the foundation is [tree_haver][tree_haver], which provides a unified cross-Ruby parsing API that works seamlessly across MRI, JRuby, and TruffleRuby.

| Gem                                      |                                                         Version / CI                                                         | Language<br>/ Format | Parser Backend(s)                                                                                     | Description                                                                      |
|------------------------------------------|:----------------------------------------------------------------------------------------------------------------------------:|----------------------|-------------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------|
| [tree_haver][tree_haver]                 |                 [![Version][tree_haver-gem-i]][tree_haver-gem] <br/> [![CI][tree_haver-ci-i]][tree_haver-ci]                 | Multi                | Supported Backends: MRI C, Rust, FFI, Java, Prism, Psych, Commonmarker, Markly, Citrus, Parslet       | **Foundation**: Cross-Ruby adapter for parsing libraries (like Faraday for HTTP) |
| [ast-merge][ast-merge]                   |                   [![Version][ast-merge-gem-i]][ast-merge-gem] <br/> [![CI][ast-merge-ci-i]][ast-merge-ci]                   | Text                 | internal                                                                                              | **Infrastructure**: Shared base classes and merge logic for all `*-merge` gems   |
| [bash-merge][bash-merge]                 |                 [![Version][bash-merge-gem-i]][bash-merge-gem] <br/> [![CI][bash-merge-ci-i]][bash-merge-ci]                 | Bash                 | [tree-sitter-bash][ts-bash] (via tree_haver)                                                          | Smart merge for Bash scripts                                                     |
| [commonmarker-merge][commonmarker-merge] | [![Version][commonmarker-merge-gem-i]][commonmarker-merge-gem] <br/> [![CI][commonmarker-merge-ci-i]][commonmarker-merge-ci] | Markdown             | [Commonmarker][commonmarker] (via tree_haver)                                                         | Smart merge for Markdown (CommonMark via comrak Rust)                            |
| [dotenv-merge][dotenv-merge]             |             [![Version][dotenv-merge-gem-i]][dotenv-merge-gem] <br/> [![CI][dotenv-merge-ci-i]][dotenv-merge-ci]             | Dotenv               | internal                                                                                              | Smart merge for `.env` files                                                     |
| [json-merge][json-merge]                 |                 [![Version][json-merge-gem-i]][json-merge-gem] <br/> [![CI][json-merge-ci-i]][json-merge-ci]                 | JSON                 | [tree-sitter-json][ts-json] (via tree_haver)                                                          | Smart merge for JSON files                                                       |
| [jsonc-merge][jsonc-merge]               |               [![Version][jsonc-merge-gem-i]][jsonc-merge-gem] <br/> [![CI][jsonc-merge-ci-i]][jsonc-merge-ci]               | JSONC                | [tree-sitter-jsonc][ts-jsonc] (via tree_haver)                                                        | ⚠️ Proof of concept; Smart merge for JSON with Comments                          |
| [markdown-merge][markdown-merge]         |         [![Version][markdown-merge-gem-i]][markdown-merge-gem] <br/> [![CI][markdown-merge-ci-i]][markdown-merge-ci]         | Markdown             | [Commonmarker][commonmarker] / [Markly][markly] (via tree_haver), [Parslet][parslet]                  | **Foundation**: Shared base for Markdown mergers with inner code block merging   |
| [markly-merge][markly-merge]             |             [![Version][markly-merge-gem-i]][markly-merge-gem] <br/> [![CI][markly-merge-ci-i]][markly-merge-ci]             | Markdown             | [Markly][markly] (via tree_haver)                                                                     | Smart merge for Markdown (CommonMark via cmark-gfm C)                            |
| [prism-merge][prism-merge]               |               [![Version][prism-merge-gem-i]][prism-merge-gem] <br/> [![CI][prism-merge-ci-i]][prism-merge-ci]               | Ruby                 | [Prism][prism] (`prism` std lib gem)                                                                  | Smart merge for Ruby source files                                                |
| [psych-merge][psych-merge]               |               [![Version][psych-merge-gem-i]][psych-merge-gem] <br/> [![CI][psych-merge-ci-i]][psych-merge-ci]               | YAML                 | [Psych][psych] (`psych` std lib gem)                                                                  | Smart merge for YAML files                                                       |
| [rbs-merge][rbs-merge]                   |                   [![Version][rbs-merge-gem-i]][rbs-merge-gem] <br/> [![CI][rbs-merge-ci-i]][rbs-merge-ci]                   | RBS                  | [tree-sitter-rbs][ts-rbs] (via tree_haver), [RBS][rbs] (`rbs` std lib gem)                            | Smart merge for Ruby type signatures                                             |
| [toml-merge][toml-merge]                 |                 [![Version][toml-merge-gem-i]][toml-merge-gem] <br/> [![CI][toml-merge-ci-i]][toml-merge-ci]                 | TOML                 | [Parslet + toml][toml], [Citrus + toml-rb][toml-rb], [tree-sitter-toml][ts-toml] (all via tree_haver) | Smart merge for TOML files                                                       |

#### Backend Platform Compatibility

tree_haver supports multiple parsing backends, but not all backends work on all Ruby platforms:

| Platform 👉️<br> TreeHaver Backend 👇️          | MRI | JRuby | TruffleRuby | Notes                                                                      |
|-------------------------------------------------|:---:|:-----:|:-----------:|----------------------------------------------------------------------------|
| **MRI** ([ruby_tree_sitter][ruby_tree_sitter])  |  ✅  |   ❌   |      ❌      | C extension, MRI only                                                      |
| **Rust** ([tree_stump][tree_stump])             |  ✅  |   ❌   |      ❌      | Rust extension via magnus/rb-sys, MRI only                                 |
| **FFI** ([ffi][ffi])                            |  ✅  |   ✅   |      ❌      | TruffleRuby's FFI doesn't support `STRUCT_BY_VALUE`                        |
| **Java** ([jtreesitter][jtreesitter])           |  ❌  |   ✅   |      ❌      | JRuby only, requires grammar JARs                                          |
| **Prism** ([prism][prism])                      |  ✅  |   ✅   |      ✅      | Ruby parsing, stdlib in Ruby 3.4+                                          |
| **Psych** ([psych][psych])                      |  ✅  |   ✅   |      ✅      | YAML parsing, stdlib                                                       |
| **Citrus** ([citrus][citrus])                   |  ✅  |   ✅   |      ✅      | Pure Ruby PEG parser, no native dependencies                               |
| **Parslet** ([parslet][parslet])                |  ✅  |   ✅   |      ✅      | Pure Ruby PEG parser, no native dependencies                               |
| **Commonmarker** ([commonmarker][commonmarker]) |  ✅  |   ❌   |      ❓      | Rust extension for Markdown (via [commonmarker-merge][commonmarker-merge]) |
| **Markly** ([markly][markly])                   |  ✅  |   ❌   |      ❓      | C extension for Markdown  (via [markly-merge][markly-merge])               |

**Legend**: ✅ = Works, ❌ = Does not work, ❓ = Untested

**Why some backends don't work on certain platforms**:

- **JRuby**: Runs on the JVM; cannot load native C/Rust extensions (`.so` files)
- **TruffleRuby**: Has C API emulation via Sulong/LLVM, but it doesn't expose all MRI internals that native extensions require (e.g., `RBasic.flags`, `rb_gc_writebarrier`)
- **FFI on TruffleRuby**: TruffleRuby's FFI implementation doesn't support returning structs by value, which tree-sitter's C API requires

**Example implementations** for the gem templating use case:

| Gem                      | Purpose         | Description                                   |
|--------------------------|-----------------|-----------------------------------------------|
| [kettle-dev][kettle-dev] | Gem Development  | Development tooling, CI automation, and release workflows |
| [kettle-jem][kettle-jem] | Gem Templating  | Gem template library with smart merge support |

[tree_haver]: https://github.com/kettle-rb/tree_haver
[ast-merge]: https://github.com/kettle-rb/ast-merge
[prism-merge]: https://github.com/kettle-rb/prism-merge
[psych-merge]: https://github.com/kettle-rb/psych-merge
[json-merge]: https://github.com/kettle-rb/json-merge
[jsonc-merge]: https://github.com/kettle-rb/jsonc-merge
[bash-merge]: https://github.com/kettle-rb/bash-merge
[rbs-merge]: https://github.com/kettle-rb/rbs-merge
[dotenv-merge]: https://github.com/kettle-rb/dotenv-merge
[toml-merge]: https://github.com/kettle-rb/toml-merge
[markdown-merge]: https://github.com/kettle-rb/markdown-merge
[markly-merge]: https://github.com/kettle-rb/markly-merge
[commonmarker-merge]: https://github.com/kettle-rb/commonmarker-merge
[kettle-dev]: https://github.com/kettle-rb/kettle-dev
[kettle-jem]: https://github.com/kettle-rb/kettle-jem
[tree_haver-gem]: https://bestgems.org/gems/tree_haver
[ast-merge-gem]: https://bestgems.org/gems/ast-merge
[prism-merge-gem]: https://bestgems.org/gems/prism-merge
[psych-merge-gem]: https://bestgems.org/gems/psych-merge
[json-merge-gem]: https://bestgems.org/gems/json-merge
[jsonc-merge-gem]: https://bestgems.org/gems/jsonc-merge
[bash-merge-gem]: https://bestgems.org/gems/bash-merge
[rbs-merge-gem]: https://bestgems.org/gems/rbs-merge
[dotenv-merge-gem]: https://bestgems.org/gems/dotenv-merge
[toml-merge-gem]: https://bestgems.org/gems/toml-merge
[markdown-merge-gem]: https://bestgems.org/gems/markdown-merge
[markly-merge-gem]: https://bestgems.org/gems/markly-merge
[commonmarker-merge-gem]: https://bestgems.org/gems/commonmarker-merge
[kettle-dev-gem]: https://bestgems.org/gems/kettle-dev
[kettle-jem-gem]: https://bestgems.org/gems/kettle-jem
[tree_haver-gem-i]: https://img.shields.io/gem/v/tree_haver.svg
[ast-merge-gem-i]: https://img.shields.io/gem/v/ast-merge.svg
[prism-merge-gem-i]: https://img.shields.io/gem/v/prism-merge.svg
[psych-merge-gem-i]: https://img.shields.io/gem/v/psych-merge.svg
[json-merge-gem-i]: https://img.shields.io/gem/v/json-merge.svg
[jsonc-merge-gem-i]: https://img.shields.io/gem/v/jsonc-merge.svg
[bash-merge-gem-i]: https://img.shields.io/gem/v/bash-merge.svg
[rbs-merge-gem-i]: https://img.shields.io/gem/v/rbs-merge.svg
[dotenv-merge-gem-i]: https://img.shields.io/gem/v/dotenv-merge.svg
[toml-merge-gem-i]: https://img.shields.io/gem/v/toml-merge.svg
[markdown-merge-gem-i]: https://img.shields.io/gem/v/markdown-merge.svg
[markly-merge-gem-i]: https://img.shields.io/gem/v/markly-merge.svg
[commonmarker-merge-gem-i]: https://img.shields.io/gem/v/commonmarker-merge.svg
[kettle-dev-gem-i]: https://img.shields.io/gem/v/kettle-dev.svg
[kettle-jem-gem-i]: https://img.shields.io/gem/v/kettle-jem.svg
[tree_haver-ci-i]: https://github.com/kettle-rb/tree_haver/actions/workflows/current.yml/badge.svg
[ast-merge-ci-i]: https://github.com/kettle-rb/ast-merge/actions/workflows/current.yml/badge.svg
[prism-merge-ci-i]: https://github.com/kettle-rb/prism-merge/actions/workflows/current.yml/badge.svg
[psych-merge-ci-i]: https://github.com/kettle-rb/psych-merge/actions/workflows/current.yml/badge.svg
[json-merge-ci-i]: https://github.com/kettle-rb/json-merge/actions/workflows/current.yml/badge.svg
[jsonc-merge-ci-i]: https://github.com/kettle-rb/jsonc-merge/actions/workflows/current.yml/badge.svg
[bash-merge-ci-i]: https://github.com/kettle-rb/bash-merge/actions/workflows/current.yml/badge.svg
[rbs-merge-ci-i]: https://github.com/kettle-rb/rbs-merge/actions/workflows/current.yml/badge.svg
[dotenv-merge-ci-i]: https://github.com/kettle-rb/dotenv-merge/actions/workflows/current.yml/badge.svg
[toml-merge-ci-i]: https://github.com/kettle-rb/toml-merge/actions/workflows/current.yml/badge.svg
[markdown-merge-ci-i]: https://github.com/kettle-rb/markdown-merge/actions/workflows/current.yml/badge.svg
[markly-merge-ci-i]: https://github.com/kettle-rb/markly-merge/actions/workflows/current.yml/badge.svg
[commonmarker-merge-ci-i]: https://github.com/kettle-rb/commonmarker-merge/actions/workflows/current.yml/badge.svg
[kettle-dev-ci-i]: https://github.com/kettle-rb/kettle-dev/actions/workflows/current.yml/badge.svg
[kettle-jem-ci-i]: https://github.com/kettle-rb/kettle-jem/actions/workflows/current.yml/badge.svg
[tree_haver-ci]: https://github.com/kettle-rb/tree_haver/actions/workflows/current.yml
[ast-merge-ci]: https://github.com/kettle-rb/ast-merge/actions/workflows/current.yml
[prism-merge-ci]: https://github.com/kettle-rb/prism-merge/actions/workflows/current.yml
[psych-merge-ci]: https://github.com/kettle-rb/psych-merge/actions/workflows/current.yml
[json-merge-ci]: https://github.com/kettle-rb/json-merge/actions/workflows/current.yml
[jsonc-merge-ci]: https://github.com/kettle-rb/jsonc-merge/actions/workflows/current.yml
[bash-merge-ci]: https://github.com/kettle-rb/bash-merge/actions/workflows/current.yml
[rbs-merge-ci]: https://github.com/kettle-rb/rbs-merge/actions/workflows/current.yml
[dotenv-merge-ci]: https://github.com/kettle-rb/dotenv-merge/actions/workflows/current.yml
[toml-merge-ci]: https://github.com/kettle-rb/toml-merge/actions/workflows/current.yml
[markdown-merge-ci]: https://github.com/kettle-rb/markdown-merge/actions/workflows/current.yml
[markly-merge-ci]: https://github.com/kettle-rb/markly-merge/actions/workflows/current.yml
[commonmarker-merge-ci]: https://github.com/kettle-rb/commonmarker-merge/actions/workflows/current.yml
[kettle-dev-ci]: https://github.com/kettle-rb/kettle-dev/actions/workflows/current.yml
[kettle-jem-ci]: https://github.com/kettle-rb/kettle-jem/actions/workflows/current.yml
[prism]: https://github.com/ruby/prism
[psych]: https://github.com/ruby/psych
[ffi]: https://github.com/ffi/ffi
[ts-json]: https://github.com/tree-sitter/tree-sitter-json
[ts-jsonc]: https://gitlab.com/WhyNotHugo/tree-sitter-jsonc
[ts-bash]: https://github.com/tree-sitter/tree-sitter-bash
[ts-rbs]: https://github.com/joker1007/tree-sitter-rbs
[ts-toml]: https://github.com/tree-sitter-grammars/tree-sitter-toml
[dotenv]: https://github.com/bkeepers/dotenv
[rbs]: https://github.com/ruby/rbs
[toml-rb]: https://github.com/emancu/toml-rb
[toml]: https://github.com/jm/toml
[markly]: https://github.com/ioquatix/markly
[commonmarker]: https://github.com/gjtorikian/commonmarker
[ruby_tree_sitter]: https://github.com/Faveod/ruby-tree-sitter
[tree_stump]: https://github.com/joker1007/tree_stump
[jtreesitter]: https://central.sonatype.com/artifact/io.github.tree-sitter/jtreesitter
[citrus]: https://github.com/mjackson/citrus
[parslet]: https://github.com/kschiess/parslet

## 💡 Info you can shake a stick at

| Tokens to Remember      | [![Gem name][⛳️name-img]][⛳️gem-name] [![Gem namespace][⛳️namespace-img]][⛳️gem-namespace]                                                                                                                                                                                                                                                                          |
|-------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Works with JRuby        | [![JRuby current Compat][💎jruby-c-i]][🚎10-j-wf] [![JRuby HEAD Compat][💎jruby-headi]][🚎3-hd-wf]|
| Works with Truffle Ruby | [![Truffle Ruby 23.2 Compat][💎truby-23.2i]][🚎truby-23.2-wf] [![Truffle Ruby 24.2 Compat][💎truby-24.2i]][🚎truby-24.2-wf] [![Truffle Ruby 25.0 Compat][💎truby-25.0i]][🚎truby-25.0-wf] [![Truffle Ruby current Compat][💎truby-c-i]][🚎9-t-wf]|
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

Kettle::Jem provides two complementary systems for merge configuration:

1. **Presets** (Ruby classes) — Programmatic API with factory methods for in-process use
2. **Recipes** (YAML files) — Distributable, declarative merge configurations that any project can ship and any `*-merge` consumer can load without additional Ruby instrumentation

### Presets

Presets are Ruby classes under `Kettle::Jem::Presets::*` that provide factory methods for creating `Ast::Merge::MergerConfig` objects. Each preset bundles a signature generator, node typing configuration, and freeze token appropriate for its file type. [kettle-dev][kettle-dev] uses presets internally to power its gem templating workflow.

#### Available Presets

| Preset                | File Types             | Merger       | Signature Matching                                                                                          | Node Typing                                                          |
|-----------------------|------------------------|--------------|-------------------------------------------------------------------------------------------------------------|----------------------------------------------------------------------|
| `Presets::Gemfile`    | `Gemfile`, `*.gemfile` | prism-merge  | `gem()` by name, `source()` singleton, `eval_gemfile()` by path, `git_source()` by name, `ruby()` singleton | Gem categorization (lint/test/doc/dev)                               |
| `Presets::Appraisals` | `Appraisals`           | prism-merge  | Extends Gemfile + `appraise()` by name                                                                      | Appraisal categorization (ruby_version/deps/feature/runtime)         |
| `Presets::Gemspec`    | `*.gemspec`            | prism-merge  | `spec.*=` by attribute, `add_dependency` by gem name, `Gem::Specification.new` singleton                    | Attribute categorization (identity/metadata/files/deps/requirements) |
| `Presets::Rakefile`   | `Rakefile`, `*.rake`   | prism-merge  | `task()` by name, `namespace()` by name, `desc()` singleton                                                 | Task categorization (build/test/release/lint/doc)                    |
| `Presets::Markdown`   | `*.md`                 | markly-merge | Headings by level+text, tables by header, code blocks by language                                           | —                                                                    |
| `Presets::Yaml`       | `*.yml`, `*.yaml`      | psych-merge  | Key-based (internal to psych-merge)                                                                         | —                                                                    |
| `Presets::Json`       | `*.json`               | json-merge   | Key-based (internal to json-merge)                                                                          | —                                                                    |
| `Presets::Rbs`        | `*.rbs`                | rbs-merge    | Declaration-based (internal to rbs-merge)                                                                   | —                                                                    |
| `Presets::Dotenv`     | `.env*`                | dotenv-merge | Variable name matching (internal to dotenv-merge)                                                           | —                                                                    |

Each preset provides three factory methods:

- **`destination_wins`** — Preserve destination customizations; template-only content is skipped
- **`template_wins`** — Apply template updates; template-only content is added
- **`custom`** — Full control over preference, add_template_only, freeze_token, and node_typing

### Recipes

Recipes are self-contained YAML files designed to be **distributable units of merge knowledge**. A project can ship a recipe alongside its templates, allowing any consumer of the `*-merge` gem family to perform intelligent merges without writing Ruby merge logic.

A simple recipe is just a YAML file — no companion folder or Ruby scripts required:

```yaml
name: my_config
description: Merge YAML config files with destination preference
parser: psych
merge:
  preference: destination
  add_missing: true
freeze_token: my-project
```

For advanced recipes that need custom signature matching or node categorization, a companion folder can optionally contain small Ruby scripts (signature generators, node typing lambdas) that are loaded on demand. The consumer only needs `ast-merge` to load and use them.

#### Available Recipes

| Recipe        | YAML File                | Parser   | Description                                                                               |
|---------------|--------------------------|----------|-------------------------------------------------------------------------------------------|
| `:gemfile`    | `recipes/gemfile.yml`    | `prism`  | Gemfile merging with gem-name-aware signature matching and gem categorization node typing |
| `:gemspec`    | `recipes/gemspec.yml`    | `prism`  | Gemspec merging with attribute assignment and dependency matching                         |
| `:rakefile`   | `recipes/rakefile.yml`   | `prism`  | Rakefile merging with task/namespace/require matching                                     |
| `:appraisals` | `recipes/appraisals.yml` | `prism`  | Appraisals merging extending Gemfile signatures with `appraise()` block matching          |
| `:markdown`   | `recipes/markdown.yml`   | `markly` | Markdown merging with heading, table, and code block matching                             |

#### Recipe YAML Schema

Each recipe YAML defines:

- **`name`** — Recipe identifier
- **`description`** — Human-readable description
- **`parser`** — Which `*-merge` parser to use (`prism`, `markly`, etc.)
- **`merge.preference`** — Default merge preference (`:template` or `:destination`)
- **`merge.add_missing`** — Whether to add template-only nodes to the result
- **`merge.signature_generator`** — Path to companion Ruby script (relative to recipe folder)
- **`merge.node_typing`** — Hash mapping node class names to companion Ruby scripts
- **`freeze_token`** — Token for freeze block preservation

#### Shipping Your Own Recipes

Any project can create and distribute recipes. A minimal recipe is a single YAML file:

```
my - project /
  recipes /
  my_format.yml
```

For recipes that need custom signature matching or node categorization, add a companion folder with Ruby scripts. The folder name must match the recipe name (without the `.yml` extension):

```
my - project /
  recipes /
  my_format.yml
    my_format/                     # Optional companion folder
      signature_generator.rb       # Returns a lambda for node matching
      typing /
        call_node.rb               # Returns a lambda for node categorization
```

Then consumers load it directly:

```ruby
preset = Ast::Merge::Recipe::Preset.load("path/to/my_format.yml")
merger = Prism::Merge::SmartMerger.new(template, destination, **preset.to_h)
result = merger.merge
```

No dependency on kettle-jem is required — only `ast-merge` and the appropriate `*-merge` gem for parsing.

### Freeze Token

The default freeze token for kettle-jem is `kettle-jem`. This means freeze markers look like:

```ruby
# kettle-jem:freeze
# ... content to preserve ...
# kettle-jem:unfreeze
```

### Freeze Blocks in Ruby Files

When using kettle-jem's merge configurations with Ruby files (gemspecs, Gemfiles, etc.), you can protect sections from being overwritten by the template using freeze markers.

#### Block-Style Freeze (with matching markers)

```ruby
# kettle-jem:freeze
gem "my-custom-gem", path: "../local-fork"
gem "another-local-gem", git: "https://github.com/my-org/gem.git"
# kettle-jem:unfreeze
```

#### Inline Freeze Comments

You can also freeze a **single Ruby statement** by placing a freeze comment immediately before it:

```ruby
# kettle-jem:freeze
gem "my-custom-gem", "~> 1.0"
```

**⚠️ Important:** When a freeze comment precedes a block-based statement (like a class, module, method definition, or DSL block), the **entire block is frozen**, preventing any template updates to that section:

```ruby
# kettle-jem:freeze
class MyCustomClass
  # EVERYTHING inside this class is frozen!
  # Template changes to this class will be ignored.
  def custom_method
    # ...
  end
end

# kettle-jem:freeze
Gem::Specification.new do |spec|
  # The entire gemspec block is frozen
  # Use this carefully - it prevents ALL template updates!
end
```

#### Matching Behavior

Frozen statements are matched by their **structural identity**, not their content:

- A frozen `gem "example"` matches `gem "example"` in the template (by gem name)
- A frozen `spec.add_dependency "foo"` matches the same dependency in the template
- A frozen `class Foo` matches `class Foo` in the template (by class name)
  The destination's frozen version is always preserved, regardless of changes in the template.

### Template Manifest and AST Strategies

`kettle:jem:template` looks at `.kettle-jem.yml` to determine how each file should be updated. The config supports a hybrid format: a list of ordered glob `patterns` used as fallbacks and a `files` nested map for per-file configurations. Each entry ultimately exposes a `strategy` (and optional merge options for Ruby files).

The config also includes a small README-specific section for the top logo strip. Set `readme.top_logo_mode` to one of:

- `org` — include only the GitHub org logo
- `project` — include only the project logo
- `org_and_project` — include both org and project logos after the shared Galtzo and ruby-lang logos

If the key is omitted, `org_and_project` is used.

| Strategy  | Behavior                                                                                                          |
|-----------|-------------------------------------------------------------------------------------------------------------------|
| `skip`    | Legacy behavior: template content is copied with token replacements and any bespoke merge logic already in place. |
| `replace` | Template AST replaces the destination outside of `kettle-jem:freeze` sections.                                    |
| `append`  | Only missing AST nodes (e.g., `gem` or `task` declarations) are appended; existing nodes remain untouched.        |
| `merge`   | Destination nodes are updated in-place using the template AST (used for `Gemfile`, `*.gemspec`, and `Rakefile`).  |

All Ruby files receive this reminder (inserted after shebang/frozen-string-literal lines):

    # To force retention during kettle-jem templating:
    #     kettle-jem:freeze
    #     # ... your code
    #     kettle-jem:unfreeze

Wrap any code you never want rewritten between `kettle-jem:freeze` / `kettle-jem:unfreeze` comments. When an AST merge fails, the task emits an error asking you to file an issue at https://github.com/kettle-rb/kettle-jem/issues and then aborts—there is no regex fallback.

### Template .example files are preferred

- The templating step dynamically prefers any `*.example` file present in this gem's templates. When a `*.example` exists alongside the non-example template, the `.example` content is used, and the destination file is written without the `.example` suffix.
- This applies across all templated files, including:
    - Root files like `.gitlab-ci.yml` (copied from `.gitlab-ci.yml.example` when present).
    - Nested files like `.github/workflows/coverage.yml` (copied from `.github/workflows/coverage.yml.example` when present).
- This behavior is automatic for any future `*.example` files added to the templates.
- Exception: `.env.local` is handled specially for safety. Regardless of whether the template provides `.env.local` or `.env.local.example`, the installer copies it to `.env.local.example` in your project, and will never create or overwrite `.env.local`.

### Template Config Example

Here is an example `.kettle-jem.yml` (hybrid format):

```yaml
# Fail `rake kettle:jem:selftest` once divergence reaches or exceeds this percent.
# Leave blank to report only.
min_divergence_threshold:

# Defaults applied to per-file merge options when strategy: merge
defaults:
  preference: "template"
  add_template_only_nodes: true

# README header logo behavior
readme:
  top_logo_mode: org_and_project

# Ordered glob patterns (first match wins)
patterns:
  - path: "*.gemspec"
    strategy: merge
  - path: "gemfiles/modular/erb/**"
    strategy: merge
  - path: ".github/**/*.yml"
    strategy: skip

# Per-file nested configuration (overrides patterns)
files:
  "Gemfile":
    strategy: merge
    add_template_only_nodes: true

  "Rakefile":
    strategy: merge

  "README.md":
    strategy: replace

  ".env.local":
    strategy: skip
```

## 🔧 Basic Usage

### The `kettle-jem` command

`kettle-jem` is the primary user-facing entry point. Run it from inside the target gem repository.

Its behavior depends on whether the project already has a `.kettle-jem.yml` file:

1. **No `.kettle-jem.yml` yet** — `kettle-jem` seeds that file from `template/.kettle-jem.yml.example`, fills whatever token values it can derive safely from the gemspec, and then **stops before templating the rest of the project**.
2. **`.kettle-jem.yml` already present** — `kettle-jem` performs the full bootstrap/update workflow and finishes by invoking `rake kettle:jem:install`.

That first-run stop is intentional: `.kettle-jem.yml` is the seam between “install kettle-jem into this repo” and “apply the template to this repo.” It is the place where you decide merge strategies and provide any token values that cannot be derived automatically.

```console
kettle-jem [options]
# e.g., kettle-jem --allowed=true --force --quiet
```

#### How the entry points fit together

| Entry point | Purpose | What happens when `.kettle-jem.yml` is missing? | Typical use |
|-------------|---------|--------------------------------------------------|-------------|
| `kettle-jem` | Preferred top-level bootstrap command | Writes `.kettle-jem.yml` and exits early | First adoption of kettle-jem in a repo |
| `rake kettle:jem:template` | Low-level templating engine | Writes `.kettle-jem.yml` and exits early | Re-run templating after config changes, or when you only want file merges |
| `rake kettle:jem:install` | Wrapper around `template` plus post-template checks/prompts | Exits cleanly after the config bootstrap | Templating plus install-time guidance like `.envrc`, `.gitignore`, and post-merge checks |

Both `kettle-jem` and `rake kettle:jem:install` are already gated by the same template preflight. In other words, you do **not** need to guess whether to run “install” or “template” first: if the config is missing, the shared preflight seeds it and stops before broader changes are made.

#### What it does

When `.kettle-jem.yml` already exists, the `kettle-jem` command performs the following steps in order:

1. **Prechecks** — Verifies you're inside a git repo with a clean working tree, a gemspec, and a Gemfile
2. **Sync dev dependencies** — Updates your gemspec's `add_development_dependency` entries to match the kettle-jem template
3. **Sync Gemfile** — Ensures your Gemfile contains required `source`, `git_source`, `gemspec`, and `eval_gemfile` directives from the template
4. **Sync modular gemfiles** — Ensures the bootstrap modular gemfiles are present; with `--force`, refreshes `gemfiles/modular/templating.gemfile` from the template while preserving `templating_local.gemfile`
5. **Ensure bin/setup** — Ensures `bin/setup` matches the template bootstrap script; with `--force`, refreshes it from the template even if already present
6. **Ensure Rakefile** — Replaces your Rakefile with the kettle-jem template Rakefile
7. **Run bin/setup** — Executes `bin/setup` to install dependencies
8. **Generate binstubs** — Runs `bundle binstubs --all`
9. **Commit bootstrap changes** — Commits any changes from the above steps
10. **Run kettle:jem:install** — Invokes the full template merge via `rake kettle:jem:install`, which performs AST-based smart merging of all template files according to `.kettle-jem.yml`

Step 2 is intentionally best-effort during bootstrap. In the normal case `kettle-jem` edits a well-formed `Gem::Specification` structurally, but if the target gemspec exists and is still temporarily incomplete (for example empty content, a missing final `end`, or another in-progress edit that Prism cannot parse yet), `kettle-jem` falls back to a conservative line-oriented dependency sync so bootstrap can continue instead of failing immediately. That resilience is for early setup/recovery flows; it is not a promise that arbitrary malformed gemspecs are a first-class public edit format.

#### Options

All options are passed through to the underlying `rake kettle:jem:install` task:

| Option | Description |
|--------|-------------|
| `--allowed=VAL` | Acknowledge prior review of environment-file changes (for example after `.envrc` updates). Passed as `allowed=VAL` to the rake task. |
| `--force` | Accept all prompts non-interactively (sets `force=true`). Also refreshes tool-owned bootstrap files such as `bin/setup` and `gemfiles/modular/templating.gemfile`, while preserving project config and local override wiring such as `.kettle-jem.yml` and `templating_local.gemfile`. Useful for CI or scripted setups. |
| `--quiet` | Passes `--quiet` into `bin/setup` so each setup-time `bundle install` stays quiet, suppresses extra setup progress banners and direct `bundle binstubs` chatter, and preserves `--quiet` for the final `rake kettle:jem:install` invocation. |
| `--hook_templates=VAL` | Control git hook templating. Values: `local` (install to `.git/hooks`), `global` (install to `~/.git-templates`), `skip` (do not install hooks). |
| `--only=VAL` | Restrict install scope to a specific subset of files. |
| `--include=VAL` | Include optional files by glob pattern. |
| `-h`, `--help` | Show help and exit. |

#### Environment variables

| Variable | Description |
|----------|-------------|
| `DEBUG=true` | Print full backtraces on errors |
| `FUNDING_ORG=org_name` | Override the GitHub org used for FUNDING.yml generation. Auto-derived from git remote `origin` when not set. Set to `false` to disable. |

#### Examples

First run in a repository that has not been configured yet:

```console
cd my-gem
kettle-jem
```

That first run writes `.kettle-jem.yml` and exits. Review it, fill in any missing token values, commit it, then re-run `kettle-jem`.

Complete the bootstrap after reviewing the config:

```console
$EDITOR .kettle-jem.yml
git add .kettle-jem.yml
git commit -m "Configure kettle-jem"
kettle-jem
```

Non-interactive setup for CI:

```console
kettle-jem --force --quiet
```

Only install git hooks locally:

```console
kettle-jem --hook_templates=local
```

Run only the templating layer after changing `.kettle-jem.yml`:

```console
bundle exec rake kettle:jem:template allowed=true
```

Run templating plus install-time follow-up checks and prompts:

```console
bundle exec rake kettle:jem:install allowed=true
```

#### Rake tasks

After initial setup, the following rake tasks are available for ongoing use:

| Task | Description |
|------|-------------|
| `rake kettle:jem:install` | Runs `kettle:jem:template`, then performs install-time follow-up work such as summarizing changed files, checking `.envrc`, and offering `.gitignore` updates |
| `rake kettle:jem:template` | Smart-merges template files according to `.kettle-jem.yml`; if the config file is missing, it writes `.kettle-jem.yml` and exits before templating the rest of the project |
| `rake kettle:jem:selftest` | Run a divergence-from-template check: template the current gem into a sandbox, compare the result against the current tree, and report how much drift remains |

#### Divergence-from-template self-test

`rake kettle:jem:selftest` is not an exact byte-for-byte identity check. It is a **divergence-from-template** test that answers: _if I template this gem again right now, how much of the produced output would still change?_

The task copies the current project into `tmp/template_test/destination/`, runs templating into `tmp/template_test/output/`, and compares the two file manifests. It classifies produced files as `matched`, `changed`, or `added`, writes diffs for changed files, and generates `tmp/template_test/report/summary.md`.

- **Score** = percentage of produced files that were unchanged after templating
- **Divergence** = `100 - score`, i.e. the percentage of produced files that would change or be added

This means some divergence can be expected and is not automatically a bug. Common causes include token replacement, smart-merge normalization, and files that are source-only and intentionally not emitted by the template task.

To make CI fail on too much drift, set `min_divergence_threshold` in `.kettle-jem.yml`.

```yaml
min_divergence_threshold: 15
```

That setting fails the task once divergence reaches or exceeds the configured percentage. For ad hoc runs, `KJ_SELFTEST_THRESHOLD` still takes precedence and is interpreted as a minimum unchanged-score threshold:

```console
KJ_SELFTEST_THRESHOLD=85 bundle exec rake kettle:jem:selftest
```

### Using Presets

Presets are the programmatic Ruby API, used by [kettle-dev][kettle-dev] for in-process gem templating:

```ruby
require "kettle/jem"

# Merge a Gemfile with template preference
config = Kettle::Jem::Presets::Gemfile.template_wins
merger = Prism::Merge::SmartMerger.new(template_content, destination_content, **config.to_h)
result = merger.merge

# Merge a gemspec preserving destination customizations
config = Kettle::Jem::Presets::Gemspec.destination_wins(freeze_token: "my-project")
merger = Prism::Merge::SmartMerger.new(template_content, destination_content, **config.to_h)
result = merger.merge

# Merge Markdown with template priority
config = Kettle::Jem::Presets::Markdown.template_wins
merger = Markly::Merge::SmartMerger.new(template_content, destination_content, **config.to_h)
result = merger.merge

# Custom merge with per-type preferences
config = Kettle::Jem::Presets::Gemspec.custom(
  preference: {
    default: :destination,
    spec_metadata: :template,  # Update metadata from template
  },
  add_template_only: true,
  freeze_token: "kettle-dev",
)
merger = Prism::Merge::SmartMerger.new(template_content, destination_content, **config.to_h)
result = merger.merge
```

### Using Recipes

Recipes provide a declarative, distributable approach to merge configuration. A project ships a recipe YAML (and companion scripts), and consumers load it without needing to write merge instrumentation in Ruby:

```ruby
require "kettle/jem"

# Load a built-in recipe by name
preset = Kettle::Jem.recipe(:gemfile)

# Use it with a SmartMerger
merger = Prism::Merge::SmartMerger.new(
  template_content,
  destination_content,
  **preset.to_h,
)
result = merger.merge

# List available built-in recipes
Kettle::Jem.available_recipes  # => [:appraisals, :gemfile, :gemspec, :markdown, :rakefile]

# Load a recipe from any path (no kettle-jem dependency needed — only ast-merge)
preset = Ast::Merge::Recipe::Preset.load("/path/to/third-party/recipe.yml")
merger = Prism::Merge::SmartMerger.new(template, destination, **preset.to_h)
result = merger.merge
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

The gem is available as open source under the terms of
the [MIT](MIT.md) [![License: MIT][📄license-img]][📄license-ref].

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
[🚎truby-23.2-wf]: https://github.com/kettle-rb/kettle-jem/actions/workflows/truffleruby-23.2.yml
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
[💎truby-23.2i]: https://img.shields.io/badge/Truffle_Ruby-23.2-34BCB1?style=for-the-badge&logo=ruby&logoColor=pink
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
[📄license-ref]: https://opensource.org/licenses/MIT
[📄license-img]: https://img.shields.io/badge/License-MIT-259D6C.svg
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
