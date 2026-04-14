# frozen_string_literal: true

require "stringio"

require "kettle/jem/template_output"

RSpec.describe Kettle::Jem::TemplateOutput::Formatter do
  it "writes phase output to the configured CLI stream" do
    cli_io = StringIO.new

    formatter = described_class.new(cli_io: cli_io)
    formatter.phase("⚙️", "Config sync", detail: ".kettle-jem.yml")

    expect(cli_io.string).to include("[kettle-jem] ⚙️  Config sync - .kettle-jem.yml")
  end
end
