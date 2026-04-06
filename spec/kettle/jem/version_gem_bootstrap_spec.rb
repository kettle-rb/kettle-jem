# frozen_string_literal: true

RSpec.describe Kettle::Jem::VersionGemBootstrap do
  subject(:mod) { described_class }

  describe ".manually_bootstrap_entrypoint_content" do
    let(:namespace) { "MyGem" }
    let(:entrypoint_require) { "my_gem" }

    context "when content is empty" do
      it "renders a fresh entrypoint file" do
        result = mod.manually_bootstrap_entrypoint_content(
          "",
          entrypoint_require: entrypoint_require,
          namespace: namespace,
        )
        expect(result).to include("require \"version_gem\"")
        expect(result).to include("require_relative \"my_gem/version\"")
        expect(result).to include("module MyGem")
        expect(result).to include("MyGem::Version.class_eval do")
      end
    end

    context "when content is nil" do
      it "treats nil as empty and renders a fresh file" do
        result = mod.manually_bootstrap_entrypoint_content(
          nil,
          entrypoint_require: entrypoint_require,
          namespace: namespace,
        )
        expect(result).to include("require \"version_gem\"")
        expect(result).to include("MyGem::Version.class_eval do")
      end
    end

    context "when content already has version_gem and require_relative" do
      let(:content) do
        <<~RUBY
          # frozen_string_literal: true

          require "version_gem"
          require_relative "my_gem/version"

          module MyGem
          end

          MyGem::Version.class_eval do
            extend VersionGem::Basic
          end
        RUBY
      end

      it "does not duplicate requires" do
        result = mod.manually_bootstrap_entrypoint_content(
          content,
          entrypoint_require: entrypoint_require,
          namespace: namespace,
        )
        expect(result.scan("require \"version_gem\"").length).to eq(1)
        expect(result.scan("require_relative \"my_gem/version\"").length).to eq(1)
        expect(result.scan("MyGem::Version.class_eval do").length).to eq(1)
      end
    end

    context "when content is missing version_gem and require_relative" do
      let(:content) do
        <<~RUBY
          # frozen_string_literal: true

          module MyGem
            STUFF = true
          end
        RUBY
      end

      it "inserts missing requires after the frozen_string_literal comment" do
        result = mod.manually_bootstrap_entrypoint_content(
          content,
          entrypoint_require: entrypoint_require,
          namespace: namespace,
        )
        expect(result).to include("require \"version_gem\"")
        expect(result).to include("require_relative \"my_gem/version\"")
        expect(result).to include("MyGem::Version.class_eval do")
      end
    end

    context "when content is missing the class_eval block" do
      let(:content) do
        <<~RUBY
          require "version_gem"
          require_relative "my_gem/version"

          module MyGem
          end
        RUBY
      end

      it "appends the class_eval block" do
        result = mod.manually_bootstrap_entrypoint_content(
          content,
          entrypoint_require: entrypoint_require,
          namespace: namespace,
        )
        expect(result).to include("MyGem::Version.class_eval do")
        expect(result).to include("extend VersionGem::Basic")
      end
    end

    context "when content already ends without trailing newline" do
      let(:content) { "module MyGem; end" }

      it "adds a newline before the class_eval block" do
        result = mod.manually_bootstrap_entrypoint_content(
          content,
          entrypoint_require: entrypoint_require,
          namespace: namespace,
        )
        expect(result).to include("MyGem::Version.class_eval do")
      end
    end

    context "with content that has a shebang line" do
      let(:content) do
        <<~RUBY
          #!/usr/bin/env ruby
          # frozen_string_literal: true

          module MyGem
          end
        RUBY
      end

      it "inserts requires after the shebang and magic comments" do
        result = mod.manually_bootstrap_entrypoint_content(
          content,
          entrypoint_require: entrypoint_require,
          namespace: namespace,
        )
        lines = result.lines
        shebang_index = lines.index { |l| l.start_with?("#!") }
        require_index = lines.index { |l| l.include?("require \"version_gem\"") }
        expect(require_index).to be > shebang_index
      end
    end
  end

  describe ".entrypoint_require_insertion_index" do
    context "with only frozen_string_literal comment" do
      let(:lines) { ["# frozen_string_literal: true\n", "\n", "module MyGem\n"] }

      it "skips the magic comment and blank line" do
        index = mod.entrypoint_require_insertion_index(lines)
        expect(index).to eq(2)
      end
    end

    context "with shebang and encoding comment" do
      let(:lines) { ["#!/usr/bin/env ruby\n", "# encoding: utf-8\n", "\n", "module MyGem\n"] }

      it "skips both magic comments and blank line" do
        index = mod.entrypoint_require_insertion_index(lines)
        expect(index).to eq(3)
      end
    end

    context "with no magic comments" do
      let(:lines) { ["module MyGem\n"] }

      it "returns 0" do
        index = mod.entrypoint_require_insertion_index(lines)
        expect(index).to eq(0)
      end
    end

    context "with empty lines array" do
      let(:lines) { [] }

      it "returns 0" do
        expect(mod.entrypoint_require_insertion_index(lines)).to eq(0)
      end
    end
  end

  describe ".blank_string?" do
    it "returns true for nil" do
      expect(mod.blank_string?(nil)).to be(true)
    end

    it "returns true for empty string" do
      expect(mod.blank_string?("")).to be(true)
    end

    it "returns true for whitespace-only string" do
      expect(mod.blank_string?("   \t\n")).to be(true)
    end

    it "returns false for non-blank string" do
      expect(mod.blank_string?("hello")).to be(false)
    end
  end

  describe ".extract_version_string" do
    it "returns nil when no VERSION constant present" do
      expect(mod.extract_version_string("module Foo; end")).to be_nil
    end

    it "returns the version string when present" do
      content = 'VERSION = "1.2.3"'
      expect(mod.extract_version_string(content)).to eq("1.2.3")
    end

    it "returns nil for empty content" do
      expect(mod.extract_version_string("")).to be_nil
    end
  end

  describe ".bootstrap!" do
    context "when entrypoint_require is blank" do
      it "returns false" do
        result = mod.bootstrap!(
          helpers: double("helpers"),
          project_root: "/tmp",
          entrypoint_require: "",
          namespace: "MyGem",
          version: "1.0.0",
        )
        expect(result).to be(false)
      end
    end

    context "when namespace is blank" do
      it "returns false" do
        result = mod.bootstrap!(
          helpers: double("helpers"),
          project_root: "/tmp",
          entrypoint_require: "my_gem",
          namespace: "  ",
          version: "1.0.0",
        )
        expect(result).to be(false)
      end
    end
  end

  describe ".wrap_namespace" do
    context "when namespace is empty" do
      it "returns body_lines unchanged" do
        result = mod.wrap_namespace("", ["some_line"])
        expect(result).to eq(["some_line"])
      end
    end

    context "when namespace is nil" do
      it "returns body_lines unchanged" do
        result = mod.wrap_namespace(nil, ["some_line"])
        expect(result).to eq(["some_line"])
      end
    end

    context "when body_lines has empty strings" do
      it "skips empty lines in the output" do
        result = mod.wrap_namespace("MyGem", ["", "CONTENT = true"])
        joined = result.join("\n")
        expect(joined).to include("CONTENT = true")
        # empty body_lines should not produce a line with only spaces
        expect(result.none? { |l| l.strip.empty? }).to be(true)
      end
    end

    context "with nested namespace" do
      it "wraps body with indentation" do
        result = mod.wrap_namespace("Foo::Bar", ["VALUE = 1"])
        joined = result.join("\n")
        expect(joined).to include("module Foo")
        expect(joined).to include("  module Bar")
        expect(joined).to include("    VALUE = 1")
        expect(joined).to include("  end")
        expect(joined).to include("end")
      end
    end
  end

  describe ".bootstrap_entrypoint_content" do
    it "falls back to manually_bootstrap_entrypoint_content when normalize_entrypoint_content raises" do
      allow(mod).to receive(:normalize_entrypoint_content).and_raise(StandardError, "normalize error")
      allow(mod).to receive(:manually_bootstrap_entrypoint_content).and_return("fallback content")
      result = mod.bootstrap_entrypoint_content(
        "original",
        entrypoint_require: "my_gem",
        namespace: "MyGem",
      )
      expect(result).to eq("fallback content")
    end
  end
end
