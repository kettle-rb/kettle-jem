# frozen_string_literal: true

require "rake"

RSpec.describe "rake kettle:jem:selftest" do # rubocop:disable RSpec/DescribeClass
  include_context "with rake", "selftest"

  describe "task loading" do
    it "defines the task" do
      expect { rake_task }.not_to raise_error
      expect(Rake::Task.task_defined?("kettle:jem:selftest")).to be(true)
    end

    it "delegates to SelfTestTask" do
      expect(Kettle::Jem::Tasks::SelfTestTask).to receive(:run)
      invoke
    end
  end
end
