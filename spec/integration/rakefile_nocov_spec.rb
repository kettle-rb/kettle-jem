# frozen_string_literal: true

# Integration regression spec for :nocov: wrapper preservation in Rakefile merging.
#
# Exercises the full Kettle::Jem::TemplateHelpers.apply_strategy code path —
# the same path that runs during `rake kettle:jem:template` — against the exact
# fixture files derived from turbo_tests2/Rakefile.
#
# The fixture destination wraps task-block and rescue-LoadError bodies in
# `# :nocov:` pairs; the fixture template has no such wrappers.  Before the fix
# the merge produced duplicated bodies, misplaced markers, and false stderr
# warnings.
RSpec.describe "Rakefile :nocov: wrapper preservation via TemplateHelpers.apply_strategy" do
  let(:helpers) { Kettle::Jem::TemplateHelpers }

  FIXTURE_DIR = "spec/fixtures/rakefile_nocov"

  let(:template_content) { File.read("#{FIXTURE_DIR}/template.rb") }
  let(:dest_content)     { File.read("#{FIXTURE_DIR}/destination.rb") }

  # Reset TemplateHelpers global state between every example.
  after do
    helpers.send(:class_variable_set, :@@template_results, {})
    helpers.send(:class_variable_set, :@@output_dir, nil)
    helpers.send(:class_variable_set, :@@project_root_override, nil)
    helpers.send(:class_variable_set, :@@template_warnings, [])
    helpers.send(:class_variable_set, :@@manifestation, nil)
    helpers.send(:class_variable_set, :@@kettle_config, nil)
    helpers.send(:class_variable_set, :@@token_replacements, nil)
  end

  # apply_strategy(content, dest_path) reads dest_path from disk and computes
  # rel_path(dest_path) relative to project_root.  We set up a tmpdir with the
  # real destination content and stub project_root so rel_path works correctly.
  def with_rakefile_dest(dest_content)
    Dir.mktmpdir do |dir|
      rakefile_path = File.join(dir, "Rakefile")
      File.write(rakefile_path, dest_content)
      allow(helpers).to receive(:project_root).and_return(dir)
      yield rakefile_path
    end
  end

  # ── isolated rescue clause ─────────────────────────────────────────────────

  describe "rescue clause where destination wraps body in :nocov:" do
    let(:template) do
      <<~RUBY
        begin
          require "kettle/jem"
        rescue LoadError
          desc("(stub) kettle:jem:selftest is unavailable")
          task("kettle:jem:selftest") do
            warn("NOTE: not installed")
          end
        end
      RUBY
    end

    let(:dest) do
      <<~RUBY
        begin
          require "kettle/jem"
        rescue LoadError
          # :nocov:
          desc("(stub) kettle:jem:selftest is unavailable")
          task("kettle:jem:selftest") do
            warn("NOTE: not installed")
          end
          # :nocov:
        end
      RUBY
    end

    it "preserves the :nocov: wrapper without corruption" do
      with_rakefile_dest(dest) do |path|
        result = helpers.apply_strategy(template, path)
        expect(result).to eq(dest)
      end
    end

    it "does not duplicate the rescue body" do
      with_rakefile_dest(dest) do |path|
        result = helpers.apply_strategy(template, path)
        expect(result.scan("desc(").size).to eq(1)
        expect(result.scan("task(").size).to eq(1)
      end
    end

    it "does not emit warnings about unclosed :nocov:" do
      with_rakefile_dest(dest) do |path|
        expect { helpers.apply_strategy(template, path) }.not_to output(/unclosed.*nocov/i).to_stderr
      end
    end
  end

  # ── isolated task block ────────────────────────────────────────────────────

  describe "task block where destination wraps body in :nocov:" do
    let(:template) do
      <<~RUBY
        task :default do
          puts "Default task complete."
        end
      RUBY
    end

    let(:dest) do
      <<~RUBY
        task :default do
          # :nocov:
          puts "Default task complete."
          # :nocov:
        end
      RUBY
    end

    it "preserves the :nocov: wrapper without corruption" do
      with_rakefile_dest(dest) do |path|
        result = helpers.apply_strategy(template, path)
        expect(result).to eq(dest)
      end
    end

    it "does not duplicate puts" do
      with_rakefile_dest(dest) do |path|
        result = helpers.apply_strategy(template, path)
        expect(result.scan("puts").size).to eq(1)
      end
    end

    it "does not emit warnings about unclosed :nocov:" do
      with_rakefile_dest(dest) do |path|
        expect { helpers.apply_strategy(template, path) }.not_to output(/unclosed.*nocov/i).to_stderr
      end
    end
  end

  # ── full Rakefile fixture ──────────────────────────────────────────────────

  describe "full turbo_tests2 Rakefile fixture via apply_strategy" do
    it "produces output identical to destination" do
      with_rakefile_dest(dest_content) do |path|
        result = helpers.apply_strategy(template_content, path)
        expect(result).to eq(dest_content)
      end
    end

    it "has exactly 8 :nocov: markers (4 pairs)" do
      with_rakefile_dest(dest_content) do |path|
        result = helpers.apply_strategy(template_content, path)
        expect(result.scan("# :nocov:").size).to eq(8)
      end
    end

    it "does not duplicate any rescue body" do
      with_rakefile_dest(dest_content) do |path|
        result = helpers.apply_strategy(template_content, path)
        expect(result.scan("desc(\"(stub) kettle:jem:selftest").size).to eq(1)
        expect(result.scan("desc(\"(stub) build:generate_checksums").size).to eq(1)
      end
    end

    it "does not emit any warnings about unclosed :nocov:" do
      with_rakefile_dest(dest_content) do |path|
        expect { helpers.apply_strategy(template_content, path) }.not_to output(/unclosed.*nocov/i).to_stderr
      end
    end
  end
end
