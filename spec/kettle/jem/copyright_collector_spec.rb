# frozen_string_literal: true

RSpec.describe Kettle::Jem::CopyrightCollector do
  # ─── Porcelain fixture helpers ─────────────────────────────────────────────
  #
  # Build minimal but valid `git blame --porcelain` output snippets.
  # The format per blamed line is:
  #   <40-char-sha> <orig-line> <final-line> [<group-size>]
  #   author <name>          ← only on first occurrence of this commit
  #   author-mail <<email>>  ← only on first occurrence
  #   author-time <unix-ts>  ← only on first occurrence
  #   author-tz <offset>     ← only on first occurrence
  #   committer <name>       ← only on first occurrence
  #   committer-mail <email> ← only on first occurrence
  #   committer-time <ts>    ← only on first occurrence
  #   committer-tz <offset>  ← only on first occurrence
  #   summary <msg>          ← only on first occurrence
  #   filename <path>        ← always present (last header line)
  #   \t<source line>        ← the blamed source line
  #
  # We omit committer/summary lines for brevity — they are not parsed.

  def blame_stanza(sha:, name:, email:, timestamp:, filename: "lib/foo.rb", line_num: 1, group_size: 1, content: "code")
    <<~PORCELAIN
      #{sha} #{line_num} #{line_num} #{group_size}
      author #{name}
      author-mail <#{email}>
      author-time #{timestamp}
      author-tz +0000
      filename #{filename}
      \t#{content}
    PORCELAIN
  end

  # A repeat occurrence of a commit (no header stanza except filename)
  def blame_repeat(sha:, filename: "lib/foo.rb", line_num: 2, content: "more code")
    <<~PORCELAIN
      #{sha} #{line_num} #{line_num}
      filename #{filename}
      \t#{content}
    PORCELAIN
  end

  # ─── Shared setup ──────────────────────────────────────────────────────────

  subject(:collector) { described_class.new(git_adapter: git_adapter, project_root: project_root) }

  let(:git_adapter) { instance_double(Kettle::Dev::GitAdapter) }
  let(:project_root) { Dir.mktmpdir }

  # Named timestamp helpers (UTC year in parentheses)
  # rubocop:disable RSpec/IndexedLet
  let(:ts_2023) { 1690000000 } # => 2023
  let(:ts_2024) { 1720000000 } # => 2024
  let(:ts_2025) { 1750000000 } # => 2025
  # rubocop:enable RSpec/IndexedLet

  let(:sha_a) { "a" * 40 }
  let(:sha_b) { "b" * 40 }
  let(:sha_c) { "c" * 40 }

  after { FileUtils.remove_entry(project_root) }

  # Safe default: git config returns a real identity so uncommitted sentinel
  # entries are resolved without breaking unrelated examples.
  before do
    allow(git_adapter).to receive(:capture).with(["config", "user.name"]).and_return(["Test User", true])
    allow(git_adapter).to receive(:capture).with(["config", "user.email"]).and_return(["test@example.com", true])
  end

  # Create a real file at the given relative path so existence checks pass.
  def touch_file(rel)
    abs = File.join(project_root, rel)
    FileUtils.mkdir_p(File.dirname(abs))
    FileUtils.touch(abs)
    rel
  end

  # ─── #copyright_lines ──────────────────────────────────────────────────────

  describe "#copyright_lines" do
    context "when there are no tracked files" do
      before { allow(git_adapter).to receive(:ls_files).and_return([]) }

      it "returns an empty array" do
        expect(collector.copyright_lines).to eq([])
      end
    end

    context "when all blame calls return empty output" do
      let(:file) { touch_file("lib/foo.rb") }

      before do
        allow(git_adapter).to receive(:ls_files).and_return([file])
        allow(git_adapter).to receive(:blame_porcelain).with(file).and_return("")
      end

      it "returns an empty array" do
        expect(collector.copyright_lines).to eq([])
      end
    end

    context "with a single author and a single year" do
      let(:file) { touch_file("lib/foo.rb") }
      let(:output) { blame_stanza(sha: sha_a, name: "Alice", email: "alice@example.com", timestamp: ts_2025) }

      before do
        allow(git_adapter).to receive(:ls_files).and_return([file])
        allow(git_adapter).to receive(:blame_porcelain).with(file).and_return(output)
      end

      it "returns one copyright line with the single year" do
        expect(collector.copyright_lines).to eq(["Copyright (c) 2025 Alice"])
      end
    end

    context "with a single author across two contiguous years" do
      let(:file_a) { touch_file("lib/a.rb") }
      let(:file_b) { touch_file("lib/b.rb") }

      before do
        allow(git_adapter).to receive(:ls_files).and_return([file_a, file_b])
        allow(git_adapter).to receive(:blame_porcelain).with(file_a)
          .and_return(blame_stanza(sha: sha_a, name: "Alice", email: "alice@example.com", timestamp: ts_2024))
        allow(git_adapter).to receive(:blame_porcelain).with(file_b)
          .and_return(blame_stanza(sha: sha_b, name: "Alice", email: "alice@example.com", timestamp: ts_2025))
      end

      it "collapses the years into a range" do
        expect(collector.copyright_lines).to eq(["Copyright (c) 2024-2025 Alice"])
      end
    end

    context "with a single author across three contiguous years" do
      let(:file) { touch_file("lib/foo.rb") }
      let(:output) do
        blame_stanza(sha: sha_a, name: "Alice", email: "alice@example.com", timestamp: ts_2023) +
          blame_stanza(sha: sha_b, name: "Alice", email: "alice@example.com", timestamp: ts_2024, line_num: 2) +
          blame_stanza(sha: sha_c, name: "Alice", email: "alice@example.com", timestamp: ts_2025, line_num: 3)
      end

      before do
        allow(git_adapter).to receive(:ls_files).and_return([file])
        allow(git_adapter).to receive(:blame_porcelain).with(file).and_return(output)
      end

      it "collapses to a three-year range" do
        expect(collector.copyright_lines).to eq(["Copyright (c) 2023-2025 Alice"])
      end
    end

    context "with a single author having non-contiguous years" do
      let(:file_a) { touch_file("lib/a.rb") }
      let(:file_b) { touch_file("lib/b.rb") }

      before do
        allow(git_adapter).to receive(:ls_files).and_return([file_a, file_b])
        allow(git_adapter).to receive(:blame_porcelain).with(file_a)
          .and_return(blame_stanza(sha: sha_a, name: "Alice", email: "alice@example.com", timestamp: ts_2023))
        allow(git_adapter).to receive(:blame_porcelain).with(file_b)
          .and_return(blame_stanza(sha: sha_b, name: "Alice", email: "alice@example.com", timestamp: ts_2025))
      end

      it "lists the non-contiguous years comma-separated" do
        expect(collector.copyright_lines).to eq(["Copyright (c) 2023, 2025 Alice"])
      end
    end

    context "with multiple authors sorted by earliest year" do
      let(:file_a) { touch_file("lib/a.rb") }
      let(:file_b) { touch_file("lib/b.rb") }

      before do
        allow(git_adapter).to receive(:ls_files).and_return([file_a, file_b])
        # Bob committed in 2025, Alice in 2023 — Alice should appear first
        allow(git_adapter).to receive(:blame_porcelain).with(file_a)
          .and_return(blame_stanza(sha: sha_a, name: "Bob", email: "bob@example.com", timestamp: ts_2025))
        allow(git_adapter).to receive(:blame_porcelain).with(file_b)
          .and_return(blame_stanza(sha: sha_b, name: "Alice", email: "alice@example.com", timestamp: ts_2023))
      end

      it "sorts by earliest year ascending" do
        lines = collector.copyright_lines
        expect(lines.first).to start_with("Copyright (c) 2023 Alice")
        expect(lines.last).to start_with("Copyright (c) 2025 Bob")
      end
    end

    context "with multiple authors sharing the same earliest year, sorted by name" do
      let(:file_a) { touch_file("lib/a.rb") }
      let(:file_b) { touch_file("lib/b.rb") }

      before do
        allow(git_adapter).to receive(:ls_files).and_return([file_a, file_b])
        allow(git_adapter).to receive(:blame_porcelain).with(file_a)
          .and_return(blame_stanza(sha: sha_a, name: "Zelda", email: "zelda@example.com", timestamp: ts_2024))
        allow(git_adapter).to receive(:blame_porcelain).with(file_b)
          .and_return(blame_stanza(sha: sha_b, name: "Alice", email: "alice@example.com", timestamp: ts_2024))
      end

      it "sorts alphabetically by name within the same year" do
        lines = collector.copyright_lines
        expect(lines.first).to start_with("Copyright (c) 2024 Alice")
        expect(lines.last).to start_with("Copyright (c) 2024 Zelda")
      end
    end

    context "when the only author is a bot (name ends in [bot])" do
      let(:file) { touch_file("lib/foo.rb") }

      before do
        allow(git_adapter).to receive(:ls_files).and_return([file])
        allow(git_adapter).to receive(:blame_porcelain).with(file)
          .and_return(blame_stanza(
            sha: sha_a,
            name: "dependabot[bot]",
            email: "49699333+dependabot[bot]@users.noreply.github.com",
            timestamp: ts_2025,
          ))
      end

      it "filters out the bot and returns an empty array" do
        expect(collector.copyright_lines).to eq([])
      end
    end

    context "when an author email matches the GitHub Actions no-reply bot pattern" do
      let(:file) { touch_file("lib/foo.rb") }

      before do
        allow(git_adapter).to receive(:ls_files).and_return([file])
        allow(git_adapter).to receive(:blame_porcelain).with(file)
          .and_return(blame_stanza(
            sha: sha_a,
            name: "github-actions[bot]",
            email: "41898282+github-actions[bot]@users.noreply.github.com",
            timestamp: ts_2025,
          ))
      end

      it "filters out the GitHub Actions bot" do
        expect(collector.copyright_lines).to eq([])
      end
    end

    context "with a mix of human and bot authors" do
      let(:file) { touch_file("lib/foo.rb") }
      let(:output) do
        blame_stanza(sha: sha_a, name: "Alice", email: "alice@example.com", timestamp: ts_2024) +
          blame_stanza(
            sha: sha_b,
            name: "dependabot[bot]",
            email: "49699333+dependabot[bot]@users.noreply.github.com",
            timestamp: ts_2025,
            line_num: 2,
          )
      end

      before do
        allow(git_adapter).to receive(:ls_files).and_return([file])
        allow(git_adapter).to receive(:blame_porcelain).with(file).and_return(output)
      end

      it "returns only the human author" do
        expect(collector.copyright_lines).to eq(["Copyright (c) 2024 Alice"])
      end
    end

    context "when blame_porcelain raises an error for one file" do
      let(:file_a) { touch_file("lib/a.rb") }
      let(:file_b) { touch_file("lib/b.rb") }

      before do
        allow(git_adapter).to receive(:ls_files).and_return([file_a, file_b])
        allow(git_adapter).to receive(:blame_porcelain).with(file_a).and_raise(StandardError, "git exploded")
        allow(git_adapter).to receive(:blame_porcelain).with(file_b)
          .and_return(blame_stanza(sha: sha_b, name: "Alice", email: "alice@example.com", timestamp: ts_2025))
      end

      it "skips the failing file and processes the others" do
        expect(collector.copyright_lines).to eq(["Copyright (c) 2025 Alice"])
      end
    end

    context "when a file listed by ls_files does not exist on disk" do
      let(:tracked_but_deleted) { "lib/ghost.rb" } # NOT touched — does not exist on disk

      before do
        allow(git_adapter).to receive(:ls_files).and_return([tracked_but_deleted])
      end

      it "skips the missing file gracefully" do
        expect(collector.copyright_lines).to eq([])
      end
    end

    context "when the same author appears in multiple files (year deduplication)" do
      let(:file_a) { touch_file("lib/a.rb") }
      let(:file_b) { touch_file("lib/b.rb") }

      before do
        allow(git_adapter).to receive(:ls_files).and_return([file_a, file_b])
        allow(git_adapter).to receive(:blame_porcelain).with(file_a)
          .and_return(blame_stanza(sha: sha_a, name: "Alice", email: "alice@example.com", timestamp: ts_2025))
        allow(git_adapter).to receive(:blame_porcelain).with(file_b)
          .and_return(blame_stanza(sha: sha_b, name: "Alice", email: "alice@example.com", timestamp: ts_2025))
      end

      it "deduplicates years and emits one entry" do
        expect(collector.copyright_lines).to eq(["Copyright (c) 2025 Alice"])
      end
    end

    context "when the same commit SHA appears on multiple lines in one file" do
      let(:file) { touch_file("lib/foo.rb") }
      # First occurrence has full stanza; second is a repeat (no headers)
      let(:output) do
        blame_stanza(
          sha: sha_a,
          name: "Alice",
          email: "alice@example.com",
          timestamp: ts_2025,
          line_num: 1,
          group_size: 2,
        ) +
          blame_repeat(sha: sha_a, line_num: 2)
      end

      before do
        allow(git_adapter).to receive(:ls_files).and_return([file])
        allow(git_adapter).to receive(:blame_porcelain).with(file).and_return(output)
      end

      it "counts the year only once per commit" do
        expect(collector.copyright_lines).to eq(["Copyright (c) 2025 Alice"])
      end
    end

    context "when the same author has two different email addresses" do
      let(:file_a) { touch_file("lib/a.rb") }
      let(:file_b) { touch_file("lib/b.rb") }

      before do
        allow(git_adapter).to receive(:ls_files).and_return([file_a, file_b])
        allow(git_adapter).to receive(:blame_porcelain).with(file_a)
          .and_return(blame_stanza(sha: sha_a, name: "Alice", email: "alice@work.com", timestamp: ts_2024))
        allow(git_adapter).to receive(:blame_porcelain).with(file_b)
          .and_return(blame_stanza(sha: sha_b, name: "Alice", email: "alice@personal.com", timestamp: ts_2025))
      end

      it "produces two separate copyright entries (one per email)" do
        lines = collector.copyright_lines
        expect(lines.size).to eq(2)
        expect(lines).to include("Copyright (c) 2024 Alice")
        expect(lines).to include("Copyright (c) 2025 Alice")
      end
    end

    # ── Uncommitted changes ("Not Committed Yet") ────────────────────────────

    context "when some lines are uncommitted (not.committed.yet sentinel)" do
      let(:not_committed_sha) { "0" * 40 }
      let(:file) { touch_file("lib/foo.rb") }
      let(:uncommitted_output) do
        blame_stanza(
          sha: not_committed_sha,
          name: "Not Committed Yet",
          email: "not.committed.yet",
          timestamp: ts_2025,
        )
      end

      before do
        allow(git_adapter).to receive(:ls_files).and_return([file])
        allow(git_adapter).to receive(:blame_porcelain).with(file).and_return(uncommitted_output)
      end

      it "replaces the sentinel with the git config user" do
        lines = collector.copyright_lines
        expect(lines).to eq(["Copyright (c) 2025 Test User"])
      end

      it "does not include a 'Not Committed Yet' line" do
        expect(collector.copyright_lines).not_to include(match(/Not Committed Yet/))
      end
    end

    context "when uncommitted lines exist alongside committed lines from the same user" do
      let(:not_committed_sha) { "0" * 40 }
      let(:file) { touch_file("lib/foo.rb") }
      # Alice has committed lines in 2024 AND uncommitted lines (would resolve to test@example.com)
      # The git config resolves to test@example.com / "Test User", distinct from Alice
      let(:output) do
        blame_stanza(sha: sha_a, name: "Alice", email: "alice@example.com", timestamp: ts_2024) +
          blame_stanza(
            sha: not_committed_sha,
            name: "Not Committed Yet",
            email: "not.committed.yet",
            timestamp: ts_2025,
            line_num: 2,
          )
      end

      before do
        allow(git_adapter).to receive(:ls_files).and_return([file])
        allow(git_adapter).to receive(:blame_porcelain).with(file).and_return(output)
      end

      it "merges uncommitted year into the git config user's entry" do
        lines = collector.copyright_lines
        expect(lines).to include("Copyright (c) 2024 Alice")
        expect(lines).to include("Copyright (c) 2025 Test User")
        expect(lines).not_to include(match(/Not Committed Yet/))
      end
    end

    context "when uncommitted lines belong to the same email as the git config user" do
      let(:not_committed_sha) { "0" * 40 }
      let(:file) { touch_file("lib/foo.rb") }
      let(:output) do
        # Committed line by the same person who is in git config
        blame_stanza(sha: sha_a, name: "Test User", email: "test@example.com", timestamp: ts_2024) +
          blame_stanza(
            sha: not_committed_sha,
            name: "Not Committed Yet",
            email: "not.committed.yet",
            timestamp: ts_2025,
            line_num: 2,
          )
      end

      before do
        allow(git_adapter).to receive(:ls_files).and_return([file])
        allow(git_adapter).to receive(:blame_porcelain).with(file).and_return(output)
      end

      it "merges both years into one entry for that author" do
        expect(collector.copyright_lines).to eq(["Copyright (c) 2024-2025 Test User"])
      end
    end

    context "when git config user.email is unavailable for uncommitted lines" do
      let(:not_committed_sha) { "0" * 40 }
      let(:file) { touch_file("lib/foo.rb") }

      before do
        allow(git_adapter).to receive(:ls_files).and_return([file])
        allow(git_adapter).to receive(:blame_porcelain).with(file)
          .and_return(blame_stanza(
            sha: not_committed_sha,
            name: "Not Committed Yet",
            email: "not.committed.yet",
            timestamp: ts_2025,
          ))
        # Override default capture stubs to simulate git config failure
        allow(git_adapter).to receive(:capture).with(["config", "user.name"]).and_return(["", false])
        allow(git_adapter).to receive(:capture).with(["config", "user.email"]).and_return(["", false])
      end

      it "discards the uncommitted years and returns an empty array" do
        expect(collector.copyright_lines).to eq([])
      end
    end
  end

  # ─── machine_users exclusion ───────────────────────────────────────────────

  describe "#copyright_lines with machine_users:" do
    subject(:collector) do
      described_class.new(
        git_adapter: git_adapter,
        project_root: project_root,
        machine_users: machine_users,
      )
    end

    let(:file) { touch_file("lib/foo.rb") }

    context "when an author name exactly matches a machine user (case-insensitive)" do
      let(:machine_users) { ["autobolt"] }
      let(:output) do
        blame_stanza(sha: sha_a, name: "Alice", email: "alice@example.com", timestamp: ts_2025) +
          blame_stanza(
            sha: sha_b,
            name: "Autobolt",
            email: "autobolt@ci.example.com",
            timestamp: ts_2025,
            line_num: 2,
          )
      end

      before do
        allow(git_adapter).to receive(:ls_files).and_return([file])
        allow(git_adapter).to receive(:blame_porcelain).with(file).and_return(output)
      end

      it "excludes the machine user by name" do
        lines = collector.copyright_lines
        expect(lines).to eq(["Copyright (c) 2025 Alice"])
        expect(lines.join).not_to include("Autobolt")
      end
    end

    context "when an author email exactly matches a machine user entry" do
      let(:machine_users) { ["autobolt@ci.example.com"] }
      let(:output) do
        blame_stanza(sha: sha_a, name: "Alice", email: "alice@example.com", timestamp: ts_2025) +
          blame_stanza(
            sha: sha_b,
            name: "AutoBolt CI",
            email: "autobolt@ci.example.com",
            timestamp: ts_2025,
            line_num: 2,
          )
      end

      before do
        allow(git_adapter).to receive(:ls_files).and_return([file])
        allow(git_adapter).to receive(:blame_porcelain).with(file).and_return(output)
      end

      it "excludes the machine user by email" do
        lines = collector.copyright_lines
        expect(lines).to eq(["Copyright (c) 2025 Alice"])
        expect(lines.join).not_to include("AutoBolt CI")
      end
    end

    context "when machine_users contains mixed case entries" do
      let(:machine_users) { ["AUTOBOLT"] }
      let(:output) do
        blame_stanza(sha: sha_a, name: "autobolt", email: "bot@example.com", timestamp: ts_2025)
      end

      before do
        allow(git_adapter).to receive(:ls_files).and_return([file])
        allow(git_adapter).to receive(:blame_porcelain).with(file).and_return(output)
      end

      it "matches case-insensitively and excludes the user" do
        expect(collector.copyright_lines).to eq([])
      end
    end

    context "when machine_users is empty" do
      let(:machine_users) { [] }
      let(:output) do
        blame_stanza(sha: sha_a, name: "autobolt", email: "autobolt@ci.example.com", timestamp: ts_2025)
      end

      before do
        allow(git_adapter).to receive(:ls_files).and_return([file])
        allow(git_adapter).to receive(:blame_porcelain).with(file).and_return(output)
      end

      it "does not exclude any users" do
        expect(collector.copyright_lines).to eq(["Copyright (c) 2025 autobolt"])
      end
    end

    context "when the machine user is the only author" do
      let(:machine_users) { ["autobolt"] }
      let(:output) do
        blame_stanza(sha: sha_a, name: "autobolt", email: "autobolt@ci.example.com", timestamp: ts_2025)
      end

      before do
        allow(git_adapter).to receive(:ls_files).and_return([file])
        allow(git_adapter).to receive(:blame_porcelain).with(file).and_return(output)
      end

      it "returns an empty array" do
        expect(collector.copyright_lines).to eq([])
      end
    end

    context "when multiple machine users are listed" do
      let(:machine_users) { ["autobolt", "release-bot@example.com"] }
      let(:output) do
        blame_stanza(sha: sha_a, name: "Alice", email: "alice@example.com", timestamp: ts_2024) +
          blame_stanza(
            sha: sha_b,
            name: "autobolt",
            email: "autobolt@ci.example.com",
            timestamp: ts_2025,
            line_num: 2,
          ) +
          blame_stanza(
            sha: sha_c,
            name: "Release Bot",
            email: "release-bot@example.com",
            timestamp: ts_2025,
            line_num: 3,
          )
      end

      before do
        allow(git_adapter).to receive(:ls_files).and_return([file])
        allow(git_adapter).to receive(:blame_porcelain).with(file).and_return(output)
      end

      it "excludes all listed machine users and keeps humans" do
        lines = collector.copyright_lines
        expect(lines).to eq(["Copyright (c) 2024 Alice"])
      end
    end
  end

  # ─── #format_years (private) ───────────────────────────────────────────────

  describe "#format_years" do
    subject(:format) { collector.send(:format_years, input) }

    context "with a single year" do
      let(:input) { Set["2026"] }

      it { is_expected.to eq("2026") }
    end

    context "with two contiguous years" do
      let(:input) { Set["2025", "2026"] }

      it { is_expected.to eq("2025-2026") }
    end

    context "with three contiguous years" do
      let(:input) { Set["2024", "2025", "2026"] }

      it { is_expected.to eq("2024-2026") }
    end

    context "with two non-contiguous years" do
      let(:input) { Set["2023", "2026"] }

      it { is_expected.to eq("2023, 2026") }
    end

    context "with a gap followed by a contiguous pair" do
      let(:input) { Set["2023", "2025", "2026"] }

      it { is_expected.to eq("2023, 2025-2026") }
    end

    context "with multiple runs and gaps" do
      let(:input) { Set["2021", "2023", "2025", "2026"] }

      it { is_expected.to eq("2021, 2023, 2025-2026") }
    end

    context "with unsorted input" do
      let(:input) { ["2026", "2024", "2025"] }

      it "sorts before collapsing" do
        expect(subject).to eq("2024-2026")
      end
    end

    context "with an empty collection" do
      let(:input) { [] }

      it { is_expected.to eq("") }
    end
  end
end
