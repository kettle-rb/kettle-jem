# frozen_string_literal: true

RSpec.describe Kettle::Jem::TemplatingReport do
  describe ".snapshot" do
    it "captures merge gem versions and local-path status" do
      loaded_specs = {
        "kettle-jem" => instance_double(
          Gem::Specification,
          version: Gem::Version.new("1.0.0"),
          full_gem_path: "/workspace/kettle-jem",
        ),
        "ast-merge" => instance_double(
          Gem::Specification,
          version: Gem::Version.new("4.0.6"),
          full_gem_path: "/workspace/ast-merge",
        ),
        "prism-merge" => instance_double(
          Gem::Specification,
          version: Gem::Version.new("2.0.4"),
          full_gem_path: "/gems/prism-merge-2.0.4",
        ),
      }

      snapshot = described_class.snapshot(loaded_specs: loaded_specs, workspace_root: "/workspace")

      expect(snapshot[:workspace_root]).to eq("/workspace")
      expect(snapshot.dig(:kettle_jem, :version)).to eq("1.0.0")
      expect(snapshot[:merge_gems]).to include(
        hash_including(name: "ast-merge", version: "4.0.6", local_path: true, loaded: true),
      )
      expect(snapshot[:merge_gems]).to include(
        hash_including(name: "prism-merge", version: "2.0.4", local_path: false, loaded: true),
      )
    end
  end

  describe ".markdown_section" do
    it "renders a markdown table with source and path details" do
      snapshot = {
        workspace_root: "/workspace",
        merge_gems: [
          {
            name: "ast-merge",
            version: "4.0.6",
            path: "/workspace/ast-merge",
            local_path: true,
            loaded: true,
          },
        ],
      }

      result = described_class.markdown_section(snapshot: snapshot)

      expect(result).to include("## Merge Gem Environment")
      expect(result).to include("**Workspace root**: `/workspace`")
      expect(result).to include("| ast-merge | 4.0.6 | local path | `/workspace/ast-merge` |")
    end
  end

  describe ".report_path" do
    it "places per-run reports under tmp/kettle-jem for the active output root" do
      started_at = Time.utc(2026, 3, 16, 12, 34, 56)

      result = described_class.report_path(
        project_root: "/project",
        output_dir: "/redirected-output",
        run_started_at: started_at,
        pid: 4321,
      )

      expect(result).to eq(
        "/redirected-output/tmp/kettle-jem/templating-report-20260316-123456-000000-4321.md",
      )
    end
  end

  describe ".write" do
    it "writes a markdown run report with status, warnings, and error details" do
      snapshot = {
        kettle_jem: {
          name: "kettle-jem",
          version: "1.0.0",
          path: "/workspace/kettle-jem",
          local_path: true,
          loaded: true,
        },
        workspace_root: "/workspace",
        merge_gems: [
          {
            name: "ast-merge",
            version: "4.0.6",
            path: "/workspace/ast-merge",
            local_path: true,
            loaded: true,
          },
        ],
      }
      started_at = Time.utc(2026, 3, 16, 12, 34, 56)
      finished_at = Time.utc(2026, 3, 16, 12, 35, 1)
      error = RuntimeError.new("boom")

      Dir.mktmpdir do |dir|
        report_path = described_class.write(
          project_root: dir,
          snapshot: snapshot,
          run_started_at: started_at,
          finished_at: finished_at,
          status: :failed,
          warnings: ["Heads up"],
          error: error,
        )

        expect(File).to exist(report_path)
        expect(report_path).to start_with(File.join(dir, "tmp", "kettle-jem", "templating-report-20260316-123456-000000-"))

        content = File.read(report_path)
        expect(content).to include("# kettle-jem Templating Run Report")
        expect(content).to include("**Status**: `failed`")
        expect(content).to include("**Project root**: `#{dir}`")
        expect(content).to include("**kettle-jem**: 1.0.0 (local path) `#{snapshot.dig(:kettle_jem, :path)}`")
        expect(content).to include("## Merge Gem Environment")
        expect(content).to include("- Heads up")
        expect(content).to include("RuntimeError: boom")
      end
    end
  end

  describe ".default_workspace_root" do
    it "treats KETTLE_RB_DEV=true as the default sibling workspace root" do
      stub_env("KETTLE_RB_DEV" => "true")

      result = described_class.default_workspace_root

      expect(result).to end_with("/src/kettle-rb")
      expect(result).not_to end_with("/true")
    end
  end

  describe ".local_path?" do
    it "treats symlinked workspace paths as local" do
      Dir.mktmpdir do |dir|
        real_root = File.join(dir, "real")
        local_gem = File.join(real_root, "ast-merge")
        link_root = File.join(dir, "link")

        FileUtils.mkdir_p(local_gem)
        File.symlink(real_root, link_root)

        expect(described_class.local_path?(local_gem, workspace_root: link_root)).to be(true)
      end
    end
  end
end
