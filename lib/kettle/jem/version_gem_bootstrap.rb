# frozen_string_literal: true

module Kettle
  module Jem
    module VersionGemBootstrap
      module_function

      def bootstrap!(helpers:, project_root:, entrypoint_require:, namespace:, version:)
        return false if blank_string?(entrypoint_require) || blank_string?(namespace)

        version_changed = ensure_version_file!(helpers: helpers, project_root: project_root, entrypoint_require: entrypoint_require, namespace: namespace, version: version)
        entrypoint_changed = ensure_entrypoint_file!(helpers: helpers, project_root: project_root, entrypoint_require: entrypoint_require, namespace: namespace)
        version_changed || entrypoint_changed
      end

      def ensure_version_file!(helpers:, project_root:, entrypoint_require:, namespace:, version:)
        dest = File.join(project_root, "lib", entrypoint_require, "version.rb")
        # Read from dest (source path), not output_path(dest). When writes are redirected
        # to an output_dir (e.g. during selftest), the output path may not exist yet even
        # though the file exists at the source path. Writing still goes through write_file
        # which applies the output_dir redirect correctly.
        existed_before = File.file?(dest)
        current = existed_before ? File.read(dest) : ""
        resolved_version = extract_version_string(current) || version.to_s.strip
        resolved_version = "0.0.1.pre" if resolved_version.empty?
        desired = render_version_file(namespace: namespace, version: resolved_version)
        return false if current == desired

        helpers.write_file(dest, desired)
        helpers.record_template_result(dest, existed_before ? :replace : :create)
        true
      end

      def ensure_entrypoint_file!(helpers:, project_root:, entrypoint_require:, namespace:)
        dest = File.join(project_root, "lib", "#{entrypoint_require}.rb")
        # Read from dest (source path), not output_path(dest). When writes are redirected
        # to an output_dir (e.g. during selftest), the output path may not exist yet even
        # though the source file does. Writing still goes through write_file.
        existed_before = File.file?(dest)
        current = existed_before ? File.read(dest) : ""
        desired = if existed_before
          bootstrap_entrypoint_content(current, entrypoint_require: entrypoint_require, namespace: namespace)
        else
          render_entrypoint_file(namespace: namespace, require_relative_path: relative_version_require(entrypoint_require))
        end
        return false if current == desired

        helpers.write_file(dest, desired)
        helpers.record_template_result(dest, existed_before ? :replace : :create)
        true
      end

      def bootstrap_entrypoint_content(content, entrypoint_require:, namespace:)
        merged = Kettle::Jem::SourceMerger.apply(
          strategy: :merge,
          src: render_entrypoint_merge_template(namespace: namespace, require_relative_path: relative_version_require(entrypoint_require)),
          dest: content,
          path: File.join("lib", "#{entrypoint_require}.rb"),
          file_type: :ruby,
          force: false,
        )
        normalize_entrypoint_content(merged, entrypoint_require: entrypoint_require)
      rescue StandardError => e
        Kettle::Dev.debug_error(e, __method__)
        manually_bootstrap_entrypoint_content(content, entrypoint_require: entrypoint_require, namespace: namespace)
      end

      def manually_bootstrap_entrypoint_content(content, entrypoint_require:, namespace:)
        current = content.to_s
        return render_entrypoint_file(namespace: namespace, require_relative_path: relative_version_require(entrypoint_require)) if current.empty?

        lines = current.lines
        insert_lines = []
        insert_lines << "require \"version_gem\"\n" unless current.match?(/^\s*require\s+["']version_gem["']\s*$/)

        relative_path = relative_version_require(entrypoint_require)
        require_relative_pattern = /^\s*require_relative\s+["']#{Regexp.escape(relative_path)}["']\s*$/
        insert_lines << %(require_relative "#{relative_path}"\n) unless current.match?(require_relative_pattern)

        if insert_lines.any?
          insertion_index = entrypoint_require_insertion_index(lines)
          lines.insert(insertion_index, *insert_lines, "\n")
        end

        updated = lines.join
        class_eval_block = <<~RUBY
          #{namespace}::Version.class_eval do
            extend VersionGem::Basic
          end
        RUBY
        unless updated.include?("#{namespace}::Version.class_eval do")
          updated += "\n" unless updated.end_with?("\n")
          updated += "\n#{class_eval_block}"
        end

        normalize_entrypoint_content(updated, entrypoint_require: entrypoint_require)
      end

      def entrypoint_require_insertion_index(lines)
        index = 0
        while index < lines.length && lines[index].match?(/\A#(?:!|\s*(?:frozen_string_literal|coding|encoding))/)
          index += 1
        end
        index += 1 while index < lines.length && lines[index].strip.empty?
        index
      end

      def normalize_entrypoint_content(content, entrypoint_require:)
        version_autoload_pattern = /^\s*autoload\s+:VERSION,\s*["']#{Regexp.escape(File.join(entrypoint_require, "version"))}["']\s*\n?/
        normalized = content.to_s.gsub(version_autoload_pattern, "")
        normalized.gsub(/\n{3,}/, "\n\n")
      end

      def render_entrypoint_merge_template(namespace:, require_relative_path:)
        <<~RUBY
          # frozen_string_literal: true

          require "version_gem"
          require_relative "#{require_relative_path}"

          #{namespace}::Version.class_eval do
            extend VersionGem::Basic
          end
        RUBY
      end

      def render_entrypoint_file(namespace:, require_relative_path:)
        <<~RUBY
          # frozen_string_literal: true

          require "version_gem"
          require_relative "#{require_relative_path}"

          #{render_namespace_shell(namespace)}

          #{namespace}::Version.class_eval do
            extend VersionGem::Basic
          end
        RUBY
      end

      def render_version_file(namespace:, version:)
        body_lines = [
          "module Version",
          "  VERSION = #{version.dump}",
          "end",
          "VERSION = Version::VERSION # Traditional Constant Location",
        ]

        <<~RUBY
          # frozen_string_literal: true

          #{wrap_namespace(namespace, body_lines).join("\n")}
        RUBY
      end

      def render_namespace_shell(namespace)
        wrap_namespace(namespace, []).join("\n")
      end

      def wrap_namespace(namespace, body_lines)
        segments = namespace.to_s.split("::").reject(&:empty?)
        return body_lines if segments.empty?

        lines = []
        segments.each_with_index do |segment, index|
          lines << ("  " * index) + "module #{segment}"
        end
        body_lines.each do |line|
          lines << ("  " * segments.length) + line unless line.empty?
        end
        (segments.length - 1).downto(0) do |index|
          lines << ("  " * index) + "end"
        end
        lines
      end

      def relative_version_require(entrypoint_require)
        File.join(File.basename(entrypoint_require.to_s), "version")
      end

      def extract_version_string(content)
        content.to_s[/^\s*VERSION\s*=\s*["']([^"']+)["']/, 1]
      end

      def blank_string?(value)
        value.to_s.strip.empty?
      end
    end
  end
end
