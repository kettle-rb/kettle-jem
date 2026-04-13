# frozen_string_literal: true

require "json"
require "tmpdir"
require "set"

require "kettle/jem/phases/duplicate_check"
require "kettle/jem/phases/phase_context"

RSpec.describe Kettle::Jem::Phases::DuplicateCheck do
  def build_context(helpers:, out:, project_root:, template_root: project_root)
    Kettle::Jem::Phases::PhaseContext.new(
      helpers: helpers,
      out: out,
      project_root: project_root,
      template_root: template_root,
      gem_name: "demo",
      namespace: "Demo",
      namespace_shield: "Demo",
      gem_shield: "demo",
      forge_org: "acme",
      funding_org: nil,
      min_ruby: "3.1",
      entrypoint_require: "demo",
      meta: {},
    )
  end

  def drift_outcome(project_root:, results:, warning_count:, diff_state:, lock_path:, json_path: nil, exit_code: 0, new_entries: nil, fixed_entries: nil, unchanged_entries: nil)
    diff = Kettle::Drift::Diff.new(
      state: diff_state,
      new_entries: new_entries || [],
      fixed_entries: fixed_entries || [],
      unchanged_entries: unchanged_entries || [],
    )

    Kettle::Drift::Outcome.new(
      project_root: project_root,
      files: [],
      template_dir: nil,
      baseline_set: Set.new,
      results: results,
      warning_count: warning_count,
      json_path: json_path,
      lock_path: lock_path,
      mode: :update,
      diff: diff,
      exit_code: exit_code,
    )
  end

  let(:helpers) do
    double(
      "helpers",
      template_results: {},
      add_warning: nil,
      print_warnings_summary: nil,
    )
  end
  let(:out) { double("out", phase: nil, report_detail: nil, warning: nil) }

  before do
    allow(Kettle::Jem::Tasks::TemplateTask).to receive(:unresolved_written_tokens).and_return({})
  end

  it "ignores .kettle-jem.lock and uses only .kettle-drift.lock" do
    Dir.mktmpdir do |project_root|
      legacy_lock = File.join(project_root, ".kettle-jem.lock")
      current_lock = File.join(project_root, ".kettle-drift.lock")
      File.write(legacy_lock, "{\"legacy\":[]}\n")

      captured = nil
      allow(Kettle::Drift).to receive(:run) do |**kwargs|
        captured = kwargs
        drift_outcome(
          project_root: project_root,
          results: {},
          warning_count: 0,
          diff_state: :no_changes,
          lock_path: kwargs.fetch(:lock_path),
        )
      end

      described_class.call(context: build_context(helpers: helpers, out: out, project_root: project_root))

      expect(File).to exist(legacy_lock)
      expect(File).not_to exist(current_lock)
      expect(captured.fetch(:lock_path)).to eq(current_lock)
    end
  end

  it "does not abort when drift is establishing the first baseline without any lockfile" do
    Dir.mktmpdir do |project_root|
      current_lock = File.join(project_root, ".kettle-drift.lock")

      allow(Kettle::Drift).to receive(:run).and_return(
        drift_outcome(
          project_root: project_root,
          results: {"alpha\nbeta" => [{file: File.join(project_root, "lib/demo.rb"), lines: [1, 2]}]},
          warning_count: 1,
          diff_state: :new,
          lock_path: current_lock,
          new_entries: [{chunk: "alpha\nbeta", file: File.join(project_root, "lib/demo.rb"), lines: [1, 2]}],
        ),
      )

      expect {
        described_class.call(context: build_context(helpers: helpers, out: out, project_root: project_root))
      }.not_to raise_error

      expect(out).to have_received(:phase).with("⚠️", "Duplicate check", detail: a_string_including("first baseline"))
    end
  end

  it "writes a duplicate report payload that highlights drift changes relative to the lockfile" do
    Dir.mktmpdir do |project_root|
      report_path = File.join(project_root, "tmp", "kettle-jem", "templating-report-123.md")
      json_path = report_path.sub(/\.md\z/, "-duplicates.json")
      current_lock = File.join(project_root, ".kettle-drift.lock")
      results = {
        "alpha\nbeta" => [{file: File.join(project_root, "lib/new.rb"), lines: [3, 7]}],
        "same\nchunk" => [{file: File.join(project_root, "lib/keep.rb"), lines: [9, 10]}],
      }

      allow(Kettle::Drift).to receive(:run).and_return(
        drift_outcome(
          project_root: project_root,
          results: results,
          warning_count: 2,
          diff_state: :worse,
          lock_path: current_lock,
          json_path: json_path,
          exit_code: 1,
          new_entries: [{chunk: "alpha\nbeta", file: File.join(project_root, "lib/new.rb"), lines: [3, 7]}],
          fixed_entries: [{chunk: "old\nchunk", file: File.join(project_root, "lib/old.rb"), lines: [1, 4]}],
          unchanged_entries: [{chunk: "same\nchunk", file: File.join(project_root, "lib/keep.rb"), lines: [9, 10]}],
        ),
      )

      expect {
        described_class.call(
          context: build_context(helpers: helpers, out: out, project_root: project_root),
          templating_report_path: report_path,
        )
      }.to raise_error(Kettle::Dev::Error, a_string_including(".kettle-drift.lock"))

      parsed = JSON.parse(File.read(json_path))
      expect(parsed.fetch("state")).to eq("worse")
      expect(parsed.fetch("lockfile")).to eq(File.join(project_root, ".kettle-drift.lock"))
      expect(parsed.dig("diff", "new_entries")).to include(
        a_hash_including("file" => "lib/new.rb", "lines" => [3, 7], "chunk" => "alpha\nbeta"),
      )
      expect(parsed.dig("diff", "fixed_entries")).to include(
        a_hash_including("file" => "lib/old.rb", "lines" => [1, 4], "chunk" => "old\nchunk"),
      )
      expect(parsed.dig("summary", "new_entries")).to eq(1)
      expect(parsed.dig("summary", "fixed_entries")).to eq(1)
      expect(parsed.dig("current_results", "alpha\nbeta")).to include(
        a_hash_including("file" => "lib/new.rb", "lines" => [3, 7]),
      )
      expect(out).to have_received(:report_detail).with(a_string_including("New since lockfile: 1"))
    end
  end
end
