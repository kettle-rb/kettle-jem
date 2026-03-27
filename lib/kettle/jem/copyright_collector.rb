# frozen_string_literal: true

module Kettle
  module Jem
    # Collects copyright information from a git repository by running
    # `git blame --porcelain` across every tracked file and aggregating
    # unique human contributors with the years in which their still-present
    # lines were last touched.
    #
    # Each unique author is identified by their commit email address. Names
    # are taken from the first occurrence seen in blame output. Bot-authored
    # commits (GitHub Actions, Dependabot, etc.) are filtered out.
    #
    # @example
    #   ga = Kettle::Dev::GitAdapter.new
    #   collector = CopyrightCollector.new(git_adapter: ga, project_root: Dir.pwd)
    #   collector.copyright_lines
    #   # => ["Copyright (c) 2024-2026 Peter H. Boling",
    #   #     "Copyright (c) 2025 Jane Contributor"]
    class CopyrightCollector
      # Emails matching this pattern are GitHub/GitLab bot no-reply addresses
      # with a numeric user-ID prefix, e.g. "49699333+dependabot[bot]@users.noreply.github.com".
      BOT_EMAIL_PATTERN = /\A\d+\+[^@]+\[bot\]@/i

      # Names that end with "[bot]" (case-insensitive) are also treated as bots.
      BOT_NAME_SUFFIX = /\[bot\]\z/i

      # Email sentinel used by git blame for lines not yet committed.
      NOT_COMMITTED_EMAIL = "not.committed.yet"

      # @param git_adapter [Kettle::Dev::GitAdapter]
      # @param project_root [String] absolute path to the repository root
      def initialize(git_adapter:, project_root:)
        @git_adapter  = git_adapter
        @project_root = project_root.to_s
      end

      # Return one formatted copyright string per unique human contributor,
      # sorted by earliest year ascending, then by name ascending.
      #
      # @return [Array<String>] e.g. ["Copyright (c) 2024-2026 Peter H. Boling"]
      def copyright_lines
        raw = collect_raw_authors
        return [] if raw.empty?

        raw
          .values
          .reject { |entry| bot_entry?(entry) }
          .sort_by { |entry| [entry[:years].map(&:to_i).min, entry[:name].to_s.downcase] }
          .map { |entry| "Copyright (c) #{format_years(entry[:years])} #{entry[:name]}" }
      end

      private

      attr_reader :git_adapter, :project_root

      # @return [Hash{String => {name: String, years: Set<String>, email: String}}]
      def collect_raw_authors
        files = git_adapter.ls_files
        author_map = Hash.new { |h, k| h[k] = {name: nil, years: Set.new, email: k} }

        files.each do |rel_path|
          abs_path = File.join(project_root, rel_path)
          next unless File.exist?(abs_path)

          output = git_adapter.blame_porcelain(rel_path)
          next if output.nil? || output.empty?

          parse_blame_porcelain(output, author_map)
        rescue StandardError => e
          Kettle::Dev.debug_error(e, __method__)
          # skip this file and continue
        end

        resolve_uncommitted_author!(author_map)
        author_map
      end

      # Parse a single file's `git blame --porcelain` output into the shared map.
      #
      # Porcelain format: for each blamed source line there is a group of header
      # lines followed by the content line (prefixed with a tab). The first time
      # a commit SHA appears all header fields are present; on subsequent
      # appearances only the commit hash line and `filename` appear before the
      # content line. We track already-seen SHAs to avoid double-counting.
      #
      # @param output [String]
      # @param author_map [Hash]
      def parse_blame_porcelain(output, author_map)
        # Accumulate per-commit metadata keyed by SHA
        commit_meta = {}

        # State for the current group being parsed
        current_sha   = nil
        current_name  = nil
        current_email = nil
        current_time  = nil

        output.each_line do |raw_line|
          line = raw_line.chomp

          if line.match?(/\A[0-9a-f]{40}\s/)
            # Start of a new blame group
            current_sha = line[0, 40]
            if commit_meta.key?(current_sha)
              # Repeat occurrence — no header stanza follows (except filename)
              current_name  = commit_meta[current_sha][:name]
              current_email = commit_meta[current_sha][:email]
              current_time  = commit_meta[current_sha][:time]
            else
              current_name  = nil
              current_email = nil
              current_time  = nil
            end
          elsif line.start_with?("author ") && !commit_meta.key?(current_sha.to_s)
            current_name = line[7..].strip
          elsif line.start_with?("author-mail ") && !commit_meta.key?(current_sha.to_s)
            current_email = line[12..].strip.gsub(/[<>]/, "")
          elsif line.start_with?("author-time ") && !commit_meta.key?(current_sha.to_s)
            current_time = line[12..].strip.to_i
          elsif line.start_with?("filename ")
            # Last header line before the content line — stanza complete.
            next unless current_sha && current_email

            unless commit_meta.key?(current_sha)
              commit_meta[current_sha] = {
                name:  current_name,
                email: current_email,
                time:  current_time,
              }
            end

            year = current_time ? Time.at(current_time).utc.year.to_s : nil
            author_map[current_email][:name] ||= current_name
            author_map[current_email][:years] << year if year
          end
        end
      end

      # Replace any "Not Committed Yet" blame entries with the real git user identity.
      #
      # `git blame --porcelain` uses the sentinel email "not.committed.yet" for
      # lines that exist in the working tree but have not been committed. Since
      # `kettle-jem` always runs templating as an automated commit step, we know
      # exactly who the committer will be: whoever `git config user.name/email`
      # reports. We merge the accumulated years from the sentinel into that
      # person's existing entry (creating one if needed), then remove the sentinel.
      #
      # @param author_map [Hash] mutated in place
      def resolve_uncommitted_author!(author_map)
        uncommitted = author_map.delete(NOT_COMMITTED_EMAIL)
        return unless uncommitted && uncommitted[:years].any?

        real_name, name_ok   = git_adapter.capture(["config", "user.name"])
        real_email, email_ok = git_adapter.capture(["config", "user.email"])

        # If git config isn't available, discard the uncommitted years rather
        # than attributing them to an unknown author.
        return unless name_ok && email_ok && real_email && !real_email.strip.empty?

        real_name  = real_name.strip
        real_email = real_email.strip

        author_map[real_email][:name] ||= real_name
        author_map[real_email][:years].merge(uncommitted[:years])
      rescue StandardError => e
        Kettle::Dev.debug_error(e, __method__)
      end

      # Fetch the configured git user identity via `git config`.
      # Exposed separately for ease of testing.
      #
      # @return [Array<(String, String)>] [name, email], empty strings on failure
      def git_config_user
        name,  = git_adapter.capture(["config", "user.name"])
        email, = git_adapter.capture(["config", "user.email"])
        [name.to_s.strip, email.to_s.strip]
      rescue StandardError => e
        Kettle::Dev.debug_error(e, __method__)
        ["", ""]
      end

      # @param entry [Hash]
      def bot_entry?(entry)
        name  = entry[:name].to_s
        email = entry[:email].to_s
        name.match?(BOT_NAME_SUFFIX) || email.match?(BOT_EMAIL_PATTERN)
      end

      # Collapse a set/array of year strings into a compact human-readable string.
      #
      # @param year_set [Set<String>, Array<String>]
      # @return [String]
      def format_years(year_set)
        years = year_set.map(&:to_i).sort.uniq
        return "" if years.empty?
        return years.first.to_s if years.size == 1

        # Build contiguous runs
        runs  = []
        run   = [years.first]
        years[1..].each do |y|
          if y == run.last + 1
            run << y
          else
            runs << run
            run = [y]
          end
        end
        runs << run

        runs.map { |r| r.size == 1 ? r.first.to_s : "#{r.first}-#{r.last}" }.join(", ")
      end
    end
  end
end
