# frozen_string_literal: true

RSpec.describe "Rakefile scaffold cleanup via recipe" do
  let(:scaffold_rakefile) do
    <<~RUBY
      # frozen_string_literal: true

      require "bundler/gem_tasks"
      require "rspec/core/rake_task"

      RSpec::Core::RakeTask.new(:spec)

      require "rubocop/rake_task"

      RuboCop::RakeTask.new

      task default: %i[spec rubocop]
    RUBY
  end

  it "removes all scaffold chunks via the rakefile recipe steps" do
    recipe = Kettle::Jem.recipe(:rakefile)
    runner = Ast::Merge::Recipe::Runner.new(recipe)

    # Use a minimal template (just the frozen string comment)
    template_content = "# frozen_string_literal: true\n"

    result = runner.run_content(
      template_content: template_content,
      destination_content: scaffold_rakefile,
    )

    # After cleanup, scaffold boilerplate should be gone
    expect(result.content).not_to include("bundler/gem_tasks")
    expect(result.content).not_to include("rspec/core/rake_task")
    expect(result.content).not_to include("RSpec::Core::RakeTask")
    expect(result.content).not_to include("rubocop/rake_task")
    expect(result.content).not_to include("RuboCop::RakeTask")
    expect(result.content).not_to include("task default:")
  end

  it "preserves user-added custom rake tasks" do
    custom_rakefile = scaffold_rakefile + "\ntask :custom do\n  puts 'custom'\nend\n"

    recipe = Kettle::Jem.recipe(:rakefile)
    runner = Ast::Merge::Recipe::Runner.new(recipe)
    template_content = "# frozen_string_literal: true\n"

    result = runner.run_content(
      template_content: template_content,
      destination_content: custom_rakefile,
    )

    expect(result.content).to include(":custom")
    expect(result.content).not_to include("bundler/gem_tasks")
  end
end
