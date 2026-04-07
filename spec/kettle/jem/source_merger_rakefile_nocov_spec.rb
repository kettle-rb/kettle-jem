# frozen_string_literal: true

# Unit regression specs for :nocov: wrapper preservation in Rakefile merging.
#
# Exercises Kettle::Jem::SourceMerger.apply directly (no file I/O, no token
# substitution, no TemplateHelpers wiring).  Uses the exact fixture files
# derived from turbo_tests2/Rakefile (destination) and the kettle-jem
# Rakefile.example template with {KJ|...} tokens already substituted.
#
# The dest wraps task-block and rescue-LoadError bodies in `# :nocov:` pairs;
# the template has no such wrappers.  Before the fix the merge produced:
#   - duplicated rescue bodies
#   - misplaced / missing `# :nocov:` markers
#   - stray bare `end` lines
#   - false "unclosed :nocov:" warnings on stderr
RSpec.describe Kettle::Jem::SourceMerger, ".apply — Rakefile :nocov: preservation" do
  FIXTURE_DIR = "spec/fixtures/rakefile_nocov"

  let(:template_content) { File.read("#{FIXTURE_DIR}/template.rb") }
  let(:dest_content)     { File.read("#{FIXTURE_DIR}/destination.rb") }

  def rakefile_merge(src, dest)
    described_class.apply(strategy: :merge, src: src, dest: dest, path: "Rakefile")
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
      expect(rakefile_merge(template, dest)).to eq(dest)
    end

    it "does not duplicate the rescue body" do
      result = rakefile_merge(template, dest)
      expect(result.scan("desc(").size).to eq(1)
      expect(result.scan("task(").size).to eq(1)
    end

    it "does not emit warnings about unclosed :nocov:" do
      expect { rakefile_merge(template, dest) }.not_to output(/unclosed.*nocov/i).to_stderr
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
      expect(rakefile_merge(template, dest)).to eq(dest)
    end

    it "does not duplicate puts" do
      result = rakefile_merge(template, dest)
      expect(result.scan("puts").size).to eq(1)
    end

    it "does not emit warnings about unclosed :nocov:" do
      expect { rakefile_merge(template, dest) }.not_to output(/unclosed.*nocov/i).to_stderr
    end
  end

  # ── full Rakefile fixture ──────────────────────────────────────────────────

  describe "full turbo_tests2 Rakefile fixture via SourceMerger.apply" do
    it "produces output identical to destination" do
      result = rakefile_merge(template_content, dest_content)
      expect(result).to eq(dest_content)
    end

    it "has exactly 8 :nocov: markers (4 pairs)" do
      result = rakefile_merge(template_content, dest_content)
      expect(result.scan("# :nocov:").size).to eq(8)
    end

    it "does not duplicate any rescue body" do
      result = rakefile_merge(template_content, dest_content)
      expect(result.scan("desc(\"(stub) kettle:jem:selftest").size).to eq(1)
      expect(result.scan("desc(\"(stub) build:generate_checksums").size).to eq(1)
    end

    it "does not emit warnings about unclosed :nocov:" do
      expect { rakefile_merge(template_content, dest_content) }.not_to output(/unclosed.*nocov/i).to_stderr
    end
  end
end
