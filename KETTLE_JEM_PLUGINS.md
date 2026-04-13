# Kettle::Jem Plugin Authoring

This guide documents the public plugin seam used by gems such as `kettle-drift`.

## Overview

`kettle-jem` plugins are regular gems that hook into the templating phase pipeline.
They are loaded from the destination project's `.kettle-jem.yml` `plugins:` list,
then given a registrar object to attach callbacks before or after named phases.

## Plugin naming and loading

Given this config:

```yaml
plugins:
  - kettle-drift
  - your-plugin
```

`kettle-jem` will:

1. `require` the plugin using the gem name with `-` converted to `/`
   - `kettle-drift` -> `require "kettle/drift"`
   - `your-plugin` -> `require "your/plugin"`
2. Resolve the plugin constant by camelizing each segment
   - `kettle-drift` -> `Kettle::Drift`
   - `your-plugin` -> `Your::Plugin`
3. Call:

```ruby
Your::Plugin.register_kettle_jem_plugin(registrar)
```

If the listed plugin is not the host gem itself, `kettle-jem` also adds it as a
development dependency during setup/template bootstrap.

## Minimal plugin

```ruby
module Your
  module Plugin
    module_function

    def register_kettle_jem_plugin(registrar)
      registrar.after_phase(:remaining_files) do |context:, **|
        context.out.report_detail("[your-plugin] hook ran")
      end
    end
  end
end
```

## Registrar API

The registrar exposes three entrypoints:

```ruby
registrar.before_phase(:phase_name) { |context:, actor:, phase:, phase_stats:, plugin_name:| ... }
registrar.after_phase(:phase_name)  { |context:, actor:, phase:, phase_stats:, plugin_name:| ... }
registrar.on_phase(:phase_name, timing: :before) { |...| ... }
```

- `phase_name` is normalized to a lowercase symbol
- valid timings are `:before` and `:after`
- a callback block is required

## Available phases

Current phase keys, in execution order:

1. `:config_sync`
2. `:dev_container`
3. `:github_workflows`
4. `:quality_config`
5. `:modular_gemfiles`
6. `:spec_helper`
7. `:environment_templates`
8. `:remaining_files`
9. `:git_hooks`
10. `:license_files`
11. `:duplicate_check`

## Callback arguments

Every callback receives:

- `context:` immutable `Kettle::Jem::Phases::PhaseContext`
- `actor:` the current phase actor instance
- `phase:` normalized phase symbol
- `phase_stats:` current phase stats object
- `plugin_name:` plugin name string from config

Useful `context` readers include:

- `context.project_root`
- `context.template_root`
- `context.helpers`
- `context.out`
- `context.gem_name`
- `context.namespace`
- `context.meta`

## Common plugin pattern

The most common plugin pattern is:

1. hook `after_phase(:remaining_files)`
2. read or patch generated files under `context.project_root`
3. record modified template-managed files with:

```ruby
context.helpers.record_template_result(path, :replace)
```

4. emit detail/warning output through `context.out`

See `kettle-drift` for a concrete example that injects Rake tasks into the
destination `Rakefile`.

## Failure behavior

Plugin hook failures are caught by `kettle-jem` at phase-run time and surfaced as
warnings in the templating output:

- the phase continues
- the warning includes the phase name, exception class, and message

Plugins should still fail loudly on real corruption or invalid assumptions rather
than silently swallowing errors.

## Recommendations

- Prefer phase hooks over monkey-patching `kettle-jem`
- Keep hooks idempotent
- Limit writes to files owned by your plugin's concern
- Use `context.helpers.record_template_result` when you mutate managed output
- Prefer `after_phase(:remaining_files)` for post-processing generated files
- Prefer `before_phase(...)` only when you truly need to prepare phase inputs
