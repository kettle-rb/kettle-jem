# frozen_string_literal: true

require "spec_helper"

RSpec.describe Kettle::Jem::SnippetInjector do
  let(:snippet) do
    <<~RUBY
      ### MANAGED SNIPPET
      puts "managed"
    RUBY
  end

  let(:anchor) { Struct.new(:start_line, :end_line, :node).new(2, 2, nil) }
  let(:injection_point) { Struct.new(:anchor).new(anchor) }

  it "inserts after the located anchor" do
    content = <<~RUBY
      # frozen_string_literal: true
      require "kettle/dev"

      ### TEMPLATING TASKS
    RUBY

    result = described_class.inject(
      content: content,
      snippet: snippet,
      anchor_finder: ->(_content) { injection_point },
    )

    expect(result.changed).to be(true)
    expect(result.relocated).to be(false)
    expect(result.content.index('require "kettle/dev"')).to be < result.content.index("### MANAGED SNIPPET")
    expect(result.content.index("### MANAGED SNIPPET")).to be < result.content.index("### TEMPLATING TASKS")
  end

  it "appends to the end of file when no anchor is found" do
    content = <<~RUBY
      # frozen_string_literal: true

      task :default do
        puts "ok"
      end
    RUBY

    result = described_class.inject(
      content: content,
      snippet: snippet,
      anchor_finder: ->(_content) { nil },
    )

    expect(result.content.rstrip).to end_with(<<~RUBY.rstrip)
      ### MANAGED SNIPPET
      puts "managed"
    RUBY
  end

  it "relocates a single existing snippet when replacement is enabled" do
    content = <<~RUBY
      ### MANAGED SNIPPET
      puts "managed"

      # frozen_string_literal: true
      require "kettle/dev"

      ### TEMPLATING TASKS
    RUBY

    result = described_class.inject(
      content: content,
      snippet: snippet,
      anchor_finder: ->(_content) { injection_point },
      replace_existing: true,
    )

    expect(result.changed).to be(true)
    expect(result.relocated).to be(true)
    expect(result.match_count).to eq(1)
    expect(result.content.scan("### MANAGED SNIPPET").size).to eq(1)
    expect(result.content.index('require "kettle/dev"')).to be < result.content.index("### MANAGED SNIPPET")
    expect(result.content.index("### MANAGED SNIPPET")).to be < result.content.index("### TEMPLATING TASKS")
  end

  it "skips replacement and warns when multiple managed snippets are found" do
    content = <<~RUBY
      ### MANAGED SNIPPET
      puts "managed"

      # frozen_string_literal: true

      ### MANAGED SNIPPET
      puts "managed"
    RUBY

    result = described_class.inject(
      content: content,
      snippet: snippet,
      anchor_finder: ->(_content) { nil },
      replace_existing: true,
    )

    expect(result.changed).to be(false)
    expect(result.warning).to include("found 2 matches")
    expect(result.content).to eq(content)
  end

  it "replaces a marker-matched snippet even when the managed block shape changed" do
    content = <<~RUBY
      ### MANAGED SNIPPET
      puts "old"
      task("legacy")

      # frozen_string_literal: true
      require "kettle/dev"

      ### TEMPLATING TASKS
    RUBY

    result = described_class.inject(
      content: content,
      snippet: snippet,
      anchor_finder: ->(_content) { nil },
      replace_existing: true,
    )

    expect(result.changed).to be(true)
    expect(result.relocated).to be(true)
    expect(result.match_count).to eq(1)
    expect(result.content.scan("### MANAGED SNIPPET").size).to eq(1)
    expect(result.content).not_to include('task("legacy")')
  end

  it "deduplicates multiple marker-matched managed blocks into a single injected block" do
    content = <<~RUBY
      ### MANAGED SNIPPET
      puts "old"

      ### MANAGED SNIPPET
      puts "managed"

      # frozen_string_literal: true
      require "kettle/dev"

      ### TEMPLATING TASKS
    RUBY

    result = described_class.inject(
      content: content,
      snippet: snippet,
      anchor_finder: ->(_content) { nil },
      replace_existing: true,
    )

    expect(result.changed).to be(true)
    expect(result.relocated).to be(true)
    expect(result.match_count).to eq(2)
    expect(result.content.scan("### MANAGED SNIPPET").size).to eq(1)
    expect(result.content).not_to include('puts "old"')
  end
end
