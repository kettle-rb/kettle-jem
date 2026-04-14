# frozen_string_literal: true

require "stringio"

require "kettle/jem/template_progress"

RSpec.describe Kettle::Jem::TemplateProgress do
  let(:cli_io) { StringIO.new }

  it "prints an initial persistent progress line when started" do
    progress = described_class.new(total_steps: 3, cli_io: cli_io, enabled: true)

    progress.start!

    expect(cli_io.string).to include("[kettle-jem] ⏳  Progress -")
    expect(cli_io.string).to include("0/3")
  end

  it "prints updated progress lines as phases complete" do
    progress = described_class.new(total_steps: 3, cli_io: cli_io, enabled: true)

    progress.start!
    progress.advance!(label: "Config sync")

    lines = cli_io.string.lines.map(&:chomp)
    expect(lines.length).to eq(2)
    expect(lines.last).to include("1/3")
    expect(lines.last).to include("Config sync")
  end

  it "uses ruby-progress fill styles to draw the bar" do
    progress = described_class.new(total_steps: 4, cli_io: cli_io, enabled: true, style: :squares)

    progress.start!
    2.times { progress.advance! }

    expect(cli_io.string).to include("■■□□ 2/4")
  end

  it "does nothing when disabled" do
    progress = described_class.new(total_steps: 3, cli_io: cli_io, enabled: false)

    progress.start!
    progress.advance!(label: "Config sync")
    progress.stop!

    expect(cli_io.string).to eq("")
  end
end
