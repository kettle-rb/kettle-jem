# frozen_string_literal: true

require "rake"

RSpec.describe "rake kettle:jem:prepare" do # rubocop:disable RSpec/DescribeClass
  include_context "with rake", "prepare"

  describe "task loading" do
    it "defines the task" do
      expect { rake_task }.not_to raise_error
      expect(Rake::Task.task_defined?("kettle:jem:prepare")).to be(true)
    end

    it "delegates to PrepareTask" do
      expect(Kettle::Jem::Tasks::PrepareTask).to receive(:run)
      invoke
    end
  end
end
