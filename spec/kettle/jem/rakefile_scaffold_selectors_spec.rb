# frozen_string_literal: true

require "spec_helper"

RSpec.describe Kettle::Jem::RakefileScaffoldSelectors do
  describe ".remove" do
    it "removes a bare bundler scaffold require" do
      content = <<~RUBY
        # frozen_string_literal: true

        require "bundler/gem_tasks"

        task :build do
          puts "building"
        end
      RUBY

      result = described_class.remove(content, Prism::Merge::ScaffoldChunkRemover::BUNDLER_GEM_TASKS_SPEC)

      expect(result).not_to include('require "bundler/gem_tasks"')
      expect(result).to include("task :build")
      expect(result).not_to match(/\n{3,}/)
    end

    it "does not remove a guarded bundler scaffold require" do
      content = <<~RUBY
        # frozen_string_literal: true

        if defined?(Bundler)
          require "bundler/gem_tasks"
        end
      RUBY

      result = described_class.remove(content, Prism::Merge::ScaffoldChunkRemover::BUNDLER_GEM_TASKS_SPEC)

      expect(result).to include('require "bundler/gem_tasks"')
    end

    it "removes rspec scaffold nodes while preserving unrelated custom tasks" do
      content = <<~RUBY
        # frozen_string_literal: true

        require "rspec/core/rake_task"

        desc "Custom task one"
        task :custom_one do
          puts "one"
        end

        desc "Custom task two"
        task :custom_two do
          puts "two"
        end

        RSpec::Core::RakeTask.new(:spec)
      RUBY

      result = described_class.remove(content, Prism::Merge::ScaffoldChunkRemover::RSPEC_SPEC)

      expect(result).not_to include('require "rspec/core/rake_task"')
      expect(result).not_to include("RSpec::Core::RakeTask.new")
      expect(result).to include("task :custom_one")
      expect(result).to include("task :custom_two")
    end
  end
end
