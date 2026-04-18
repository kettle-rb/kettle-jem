# frozen_string_literal: true

RSpec.describe "generic markdown template merge" do
  def merge_generic(template_content, destination_content, relative_path)
    Dir.mktmpdir do |dir|
      path = File.join(dir, relative_path)
      File.write(path, destination_content)
      Kettle::Jem::Tasks::TemplateTask.merge_by_file_type(
        template_content,
        path,
        relative_path,
        Kettle::Jem::TemplateHelpers,
      )
    end
  end

  def converge_generic(template_content, destination_content, relative_path)
    run1 = merge_generic(template_content, destination_content, relative_path)
    run2 = merge_generic(template_content, run1, relative_path)
    [run1, run2]
  end

  def contributing_template_for(gem_name:, gem_name_path:, gh_org:)
    File.read(File.expand_path("../../template/CONTRIBUTING.md.example", __dir__))
      .gsub("{KJ|KETTLE_DEV_GEM}", "kettle-dev")
      .gsub("{KJ|GEM_NAME_PATH}", gem_name_path)
      .gsub("{KJ|GH_ORG}", gh_org)
      .gsub("{KJ|GEM_NAME}", gem_name)
  end

  it "keeps CONTRIBUTING.md stable when kettle-test guidance moves around inside a section" do
    template = contributing_template_for(
      gem_name: "yard-fence",
      gem_name_path: "yard/fence",
      gh_org: "galtzo-floss",
    )
    destination = <<~MARKDOWN
      ## Run Tests

      To run all tests

      ```console
      bundle exec rake test
      ```

      ### Spec organization (required)

      - One spec file per class/module. For each class or module under `lib/`, keep all of its unit tests in a single spec file under `spec/` that mirrors the path and file name exactly: `lib/yard/fence/my_class.rb` -> `spec/yard/fence/my_class_spec.rb`.
      - Exception: Integration specs that intentionally span multiple classes. Place these under `spec/integration/` (or a clearly named integration folder), and do not directly mirror a single class. Name them after the scenario, not a class.

      Run tests via `kettle-test` (provided by `kettle-test`). It runs RSpec, writes the full log to
      `tmp/kettle-test/rspec-TIMESTAMP.log`, and prints a compact highlight block with timing, seed,
      pass/fail count, failing example list, and SimpleCov coverage percentages.

      ```console
      bundle exec kettle-test
      ```

      For targeted runs, disable the hard coverage threshold to avoid false failures:

      ```console
      K_SOUP_COV_MIN_HARD=false bundle exec kettle-test spec/path/to/spec.rb
      ```

      ## Contributors

      Your picture could be here!

      [![Contributors][🖐contributors-img]][🖐contributors]

      Made with [contributors-img][🖐contrib-rocks].

      Also see GitLab Contributors: [https://gitlab.com/galtzo-floss/yard-fence/-/graphs/main][🚎contributors-gl]
    MARKDOWN

    run1, run2 = converge_generic(template, destination, "CONTRIBUTING.md")

    expect(run1.scan("Run tests via `kettle-test`").size).to eq(1)
    expect(run1.scan("[![Contributors][🖐contributors-img]][🖐contributors]").size).to eq(1)
    expect(run2).to eq(run1)
  end

  it "keeps RUBOCOP.md stable across successive merges" do
    template = File.read(File.expand_path("../../template/RUBOCOP.md.example", __dir__))
    destination = <<~MARKDOWN
      ```bash
      bundle exec rake rubocop_gradual:check
      ```

      **Do not use** the standard RuboCop commands like:
      - `bundle exec rubocop`
      - `rubocop`

      ## Understanding the Lock File

      The `.rubocop_gradual.lock` file tracks all current RuboCop violations in the project. This allows the team to:

      1. Prevent new violations while gradually fixing existing ones
      2. Track progress on code style improvements
      3. Ensure CI builds don't fail due to pre-existing violations

      ## Common Commands

      - **Check violations**
          - `bundle exec rake rubocop_gradual`
          - `bundle exec rake rubocop_gradual:check`
      - **(Safe) Autocorrect violations, and update lockfile if no new violations**
        - `bundle exec rake rubocop_gradual:autocorrect`
      - **Force update the lock file (w/o autocorrect) to match violations present in code**
        - `bundle exec rake rubocop_gradual:force_update`

      ## Workflow

      1. Before submitting a PR, run `bundle exec rake rubocop_gradual:autocorrect`
         a. or just the default `bundle exec rake`, as autocorrection is a pre-requisite of the default task.
      2. If there are new violations, either:
         - Fix them in your code
         - Run `bundle exec rake rubocop_gradual:force_update` to update the lock file (only for violations you can't fix immediately)
      3. Commit the updated `.rubocop_gradual.lock` file along with your changes

      ## Never add inline RuboCop disables

      Do not add inline `rubocop:disable` / `rubocop:enable` comments anywhere in the codebase (including specs, except when following the few existing `rubocop:disable` patterns for a rule already being disabled elsewhere in the code). We handle exceptions in two supported ways:

      - Permanent/structural exceptions: prefer adjusting the RuboCop configuration (e.g., in `.rubocop.yml`) to exclude a rule for a path or file pattern when it makes sense project-wide.
      - Temporary exceptions while improving code: record the current violations in `.rubocop_gradual.lock` via the gradual workflow:
        - `bundle exec rake rubocop_gradual:autocorrect` (preferred; will autocorrect what it can and update the lock only if no new violations were introduced)
        - If needed, `bundle exec rake rubocop_gradual:force_update` (as a last resort when you cannot fix the newly reported violations immediately)

      In general, treat the rules as guidance to follow; fix violations rather than ignore them. For example, RSpec conventions in this project expect `described_class` to be used in specs that target a specific class under test.

      ## Benefits of rubocop_gradual

      - Allows incremental adoption of code style rules
      - Prevents CI failures due to pre-existing violations
      - Provides a clear record of code style debt
      - Enables focused efforts on improving code quality over time
    MARKDOWN

    run1, run2 = converge_generic(template, destination, "RUBOCOP.md")

    expect(run1.scan("Force update the lock file").size).to eq(1)
    expect(run1.scan("described_class").size).to eq(1)
    expect(run2).to eq(run1)
  end

  it "keeps CODE_OF_CONDUCT.md stable across successive merges" do
    template = File.read(File.expand_path("../../template/CODE_OF_CONDUCT.md.example", __dir__))
    destination = <<~MARKDOWN
      ## Our Standards

      Examples of behavior that contributes to a positive environment for our
      community include:

      * Demonstrating empathy and kindness toward other people
      * Being respectful of differing opinions, viewpoints, and experiences
      * Giving and gracefully accepting constructive feedback
      * Accepting responsibility and apologizing to those affected by our mistakes,
        and learning from the experience
      * Focusing on what is best not just for us as individuals, but for the overall
        community

      Examples of unacceptable behavior include:

      * The use of sexualized language or imagery, and sexual attention or advances of
        any kind
      * Trolling, insulting or derogatory comments, and personal or political attacks
      * Public or private harassment
      * Publishing others' private information, such as a physical or email address,
        without their explicit permission
      * Other conduct which could reasonably be considered inappropriate in a
        professional setting

      ## Enforcement Responsibilities

      Community leaders are responsible for clarifying and enforcing our standards of
      acceptable behavior and will take appropriate and fair corrective action in
      response to any behavior that they deem inappropriate, threatening, offensive,
      or harmful.
    MARKDOWN

    run1, run2 = converge_generic(template, destination, "CODE_OF_CONDUCT.md")

    expect(run1.scan("Examples of unacceptable behavior include:").size).to eq(1)
    expect(run1.scan("any kind").size).to eq(1)
    expect(run2).to eq(run1)
  end
end
