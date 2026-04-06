# frozen_string_literal: true

RSpec.describe Kettle::Jem do
  it "has a version number" do
    expect(Kettle::Jem::VERSION).not_to be_nil
  end

  describe ".available_recipes" do
    it "returns an array of available recipe names" do
      expect(described_class.available_recipes).to be_an(Array)
    end
  end

  describe ".install_tasks" do
    it "loads kettle/jem/tasks.rb without error" do
      expect { described_class.install_tasks }.not_to raise_error
    end
  end
end
