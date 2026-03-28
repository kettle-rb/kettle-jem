# frozen_string_literal: true

# Unit specs for Kettle::Jem::Tasks::InstallTask
# These tests focus on exercising branches documented as missing coverage.
# rubocop:disable RSpec/MultipleExpectations, RSpec/VerifiedDoubles, RSpec/ReceiveMessages

require "rake"

RSpec.describe Kettle::Jem::Tasks::InstallTask do
  let(:helpers) { Kettle::Jem::TemplateHelpers }

  before do
    # Prevent invoking the real rake task; stub it to a no-op
    allow(Rake::Task).to receive(:[]).with("kettle:jem:template").and_return(double(invoke: nil))
    # Bypass funding org requirement during these unit tests unless a test sets it explicitly
    stub_env("FUNDING_ORG" => "false")
  end

  describe "::run" do
    it "trims MRI Ruby badges below gemspec required_ruby_version and removes unused link refs" do
      Dir.mktmpdir do |project_root|
        # Create a gemspec with required_ruby_version >= 2.3
        File.write(File.join(project_root, "demo.gemspec"), <<~G)
          Gem::Specification.new do |spec|
            spec.name = "demo"
            spec.required_ruby_version = ">= 2.3"
            spec.homepage = "https://github.com/acme/demo"
          end
        G
        # Minimal README with MRI rows and refs
        readme = <<~MD
          | Works with MRI Ruby 3   | [![Ruby 3.0 Compat][💎ruby-3.0i]][🚎4-lg-wf] [![Ruby 3.1 Compat][💎ruby-3.1i]][🚎6-s-wf] |
          | Works with MRI Ruby 2   | ![Ruby 2.0 Compat][💎ruby-2.0i] ![Ruby 2.1 Compat][💎ruby-2.1i] [![Ruby 2.3 Compat][💎ruby-2.3i]][🚎1-an-wf] |
          | Works with MRI Ruby 1   | ![Ruby 1.8 Compat][💎ruby-1.8i] ![Ruby 1.9 Compat][💎ruby-1.9i] |

          [💎ruby-1.8i]: https://example/18
          [💎ruby-1.9i]: https://example/19
          [💎ruby-2.0i]: https://example/20
          [💎ruby-2.1i]: https://example/21
          [💎ruby-2.3i]: https://example/23
          [💎ruby-3.0i]: https://example/30
          [💎ruby-3.1i]: https://example/31
          [🚎1-an-wf]: https://example/ancient
          [🚎4-lg-wf]: https://example/legacy
          [🚎6-s-wf]: https://example/supported
        MD
        File.write(File.join(project_root, "README.md"), readme)

        allow(helpers).to receive_messages(
          project_root: project_root,
          modified_by_template?: true, # skip .envrc prompting path
          template_results: {},
        )
        # Stubbing Rake template task already done in before

        described_class.run

        edited = File.read(File.join(project_root, "README.md"))
        table = edited.lines.select { |l| l.start_with?("| Works with MRI") }.join
        # Badges below 2.3 removed from table rows
        expect(table).not_to include("ruby-1.8i")
        expect(table).not_to include("ruby-1.9i")
        expect(table).not_to include("ruby-2.0i")
        expect(table).not_to include("ruby-2.1i")
        # 2.3+ remain in table rows
        expect(table).to include("ruby-2.3i")
        expect(table).to include("ruby-3.0i")
        expect(table).to include("ruby-3.1i")
        # Link reference lines for removed versions are deleted
        expect(edited).not_to match(/^\[💎ruby-1\.8i\]:/)
        expect(edited).not_to match(/^\[💎ruby-1\.9i\]:/)
        expect(edited).not_to match(/^\[💎ruby-2\.0i\]:/)
        expect(edited).not_to match(/^\[💎ruby-2\.1i\]:/)
        # Link refs used by remaining badges and workflows remain
        expect(edited).to match(/^\[💎ruby-2\.3i\]:/)
        expect(edited).to match(/^\[💎ruby-3\.0i\]:/)
        expect(edited).to match(/^\[💎ruby-3\.1i\]:/)
        expect(edited).to match(/^\[🚎6-s-wf\]:/)
      end
    end

    it "trims JRuby and TruffleRuby badges below gemspec required_ruby_version and removes unused compatibility refs" do
      Dir.mktmpdir do |project_root|
        File.write(File.join(project_root, "demo.gemspec"), <<~G)
          Gem::Specification.new do |spec|
            spec.name = "demo"
            spec.required_ruby_version = ">= 3.2"
            spec.homepage = "https://github.com/acme/demo"
          end
        G

        readme = <<~MD
          | Works with JRuby        | ![JRuby 9.1 Compat][💎jruby-9.1i] ![JRuby 9.2 Compat][💎jruby-9.2i] ![JRuby 9.3 Compat][💎jruby-9.3i] <br/> [![JRuby 9.4 Compat][💎jruby-9.4i]][🚎10-j-wf] [![JRuby 10.0 Compat][💎jruby-10.0i]][🚎11-c-wf] [![JRuby current Compat][💎jruby-c-i]][🚎12-j-wf] [![JRuby HEAD Compat][💎jruby-headi]][🚎3-hd-wf] |
          | Works with Truffle Ruby | ![Truffle Ruby 22.3 Compat][💎truby-22.3i] ![Truffle Ruby 23.0 Compat][💎truby-23.0i] ![Truffle Ruby 23.1 Compat][💎truby-23.1i] <br/> [![Truffle Ruby 23.2 Compat][💎truby-23.2i]][🚎9-t-wf] [![Truffle Ruby 24.2 Compat][💎truby-24.2i]][🚎9-t-wf] [![Truffle Ruby 25.0 Compat][💎truby-25.0i]][🚎9-t-wf] [![Truffle Ruby current Compat][💎truby-c-i]][🚎11-c-wf] |
          | Works with MRI Ruby 3   | [![Ruby 3.2 Compat][💎ruby-3.2i]][🚎6-s-wf] [![Ruby 3.3 Compat][💎ruby-3.3i]][🚎6-s-wf] [![Ruby current Compat][💎ruby-c-i]][🚎11-c-wf] [![Ruby HEAD Compat][💎ruby-headi]][🚎3-hd-wf] |

          [💎jruby-9.1i]: https://example/jruby-91
          [💎jruby-9.2i]: https://example/jruby-92
          [💎jruby-9.3i]: https://example/jruby-93
          [💎jruby-9.4i]: https://example/jruby-94
          [💎jruby-10.0i]: https://example/jruby-100
          [💎jruby-c-i]: https://example/jruby-current
          [💎jruby-headi]: https://example/jruby-head
          [💎truby-22.3i]: https://example/truby-223
          [💎truby-23.0i]: https://example/truby-230
          [💎truby-23.1i]: https://example/truby-231
          [💎truby-23.2i]: https://example/truby-232
          [💎truby-24.2i]: https://example/truby-242
          [💎truby-25.0i]: https://example/truby-250
          [💎truby-c-i]: https://example/truby-current
          [💎ruby-3.2i]: https://example/ruby-32
          [💎ruby-3.3i]: https://example/ruby-33
          [💎ruby-c-i]: https://example/ruby-current
          [💎ruby-headi]: https://example/ruby-head
          [🚎3-hd-wf]: https://example/head
          [🚎6-s-wf]: https://example/supported
          [🚎9-t-wf]: https://example/truffle
          [🚎10-j-wf]: https://example/jruby
          [🚎11-c-wf]: https://example/current
          [🚎12-j-wf]: https://example/jruby-current
        MD
        File.write(File.join(project_root, "README.md"), readme)

        allow(helpers).to receive_messages(
          project_root: project_root,
          modified_by_template?: true,
          template_results: {},
        )

        described_class.run

        edited = File.read(File.join(project_root, "README.md"))
        jruby_line = edited.lines.find { |line| line.start_with?("| Works with JRuby") }
        truby_line = edited.lines.find { |line| line.start_with?("| Works with Truffle Ruby") }

        expect(jruby_line).to include("jruby-c-i")
        expect(jruby_line).to include("jruby-headi")
        expect(jruby_line).not_to include("jruby-9.1i")
        expect(jruby_line).not_to include("jruby-9.2i")
        expect(jruby_line).not_to include("jruby-9.3i")
        expect(jruby_line).not_to include("jruby-9.4i")
        expect(jruby_line).to include("jruby-10.0i")

        expect(truby_line).to include("truby-c-i")
        expect(truby_line).not_to include("truby-22.3i")
        expect(truby_line).not_to include("truby-23.0i")
        expect(truby_line).not_to include("truby-23.1i")
        expect(truby_line).to include("truby-23.2i")
        expect(truby_line).to include("truby-24.2i")
        expect(truby_line).to include("truby-25.0i")
        expect(truby_line).not_to match(/\|\s*<br\/>/)

        expect(edited).not_to match(/^\[💎jruby-9\.4i\]:/)
        expect(edited).to match(/^\[💎jruby-10\.0i\]:/)
        expect(edited).not_to match(/^\[💎truby-23\.1i\]:/)
        expect(edited).not_to match(/^\[🚎10-j-wf\]:/)
        expect(edited).to match(/^\[🚎12-j-wf\]:/)
        expect(edited).to match(/^\[🚎9-t-wf\]:/)
        expect(edited).to match(/^\[💎truby-23\.2i\]:/)
        expect(edited).to match(/^\[💎truby-24\.2i\]:/)
        expect(edited).to match(/^\[💎truby-25\.0i\]:/)
        expect(edited).to match(/^\[🚎11-c-wf\]:/)
        expect(edited).to match(/^\[🚎3-hd-wf\]:/)
      end
    end

    it "does not broadly squish intentional double spaces in non-table README prose" do
      Dir.mktmpdir do |project_root|
        File.write(File.join(project_root, "README.md"), "# 🍕 My Library\n\nAlpha  Beta\n")
        gemspec = File.join(project_root, "demo.gemspec")
        File.write(gemspec, <<~G)
          Gem::Specification.new do |spec|
            spec.name = "demo"
            spec.summary = "🍕 A lib"
            spec.description = "🍕 Desc"
            spec.homepage = "https://github.com/acme/demo"
          end
        G

        allow(helpers).to receive_messages(
          project_root: project_root,
          modified_by_template?: true,
          template_results: {},
        )

        described_class.run

        expect(File.read(File.join(project_root, "README.md"))).to include("Alpha  Beta\n")
      end
    end

    it "keeps a fixed JRuby 10.0 badge whose target MRI matches the minimum version" do
      Dir.mktmpdir do |project_root|
        File.write(File.join(project_root, "demo.gemspec"), <<~G)
          Gem::Specification.new do |spec|
            spec.name = "demo"
            spec.required_ruby_version = ">= 3.4"
            spec.homepage = "https://github.com/acme/demo"
          end
        G

        readme = <<~MD
          | Works with JRuby        | ![JRuby 9.4 Compat][💎jruby-9.4i] <br/> [![JRuby 10.0 Compat][💎jruby-10.0i]][🚎11-c-wf] [![JRuby current Compat][💎jruby-c-i]][🚎12-j-wf] |

          [💎jruby-9.4i]: https://example/jruby-94
          [💎jruby-10.0i]: https://example/jruby-100
          [💎jruby-c-i]: https://example/jruby-current
          [🚎11-c-wf]: https://example/current
          [🚎12-j-wf]: https://example/jruby-current
        MD
        File.write(File.join(project_root, "README.md"), readme)

        allow(helpers).to receive_messages(
          project_root: project_root,
          modified_by_template?: true,
          template_results: {},
        )

        described_class.run

        edited = File.read(File.join(project_root, "README.md"))
        jruby_line = edited.lines.find { |line| line.start_with?("| Works with JRuby") }

        expect(jruby_line).not_to include("jruby-9.4i")
        expect(jruby_line).to include("jruby-10.0i")
        expect(jruby_line).to include("jruby-c-i")
        expect(edited).not_to match(/^\[💎jruby-9\.4i\]:/)
        expect(edited).to match(/^\[💎jruby-10\.0i\]:/)
        expect(edited).to match(/^\[🚎11-c-wf\]:/)
        expect(edited).to match(/^\[🚎12-j-wf\]:/)
      end
    end

    it "keeps a fixed TruffleRuby 23.2 badge whose target MRI matches the minimum version" do
      Dir.mktmpdir do |project_root|
        File.write(File.join(project_root, "demo.gemspec"), <<~G)
          Gem::Specification.new do |spec|
            spec.name = "demo"
            spec.required_ruby_version = ">= 3.2"
            spec.homepage = "https://github.com/acme/demo"
          end
        G

        readme = <<~MD
          | Works with Truffle Ruby | ![Truffle Ruby 23.1 Compat][💎truby-23.1i] <br/> [![Truffle Ruby 23.2 Compat][💎truby-23.2i]][🚎9-t-wf] [![Truffle Ruby current Compat][💎truby-c-i]][🚎11-c-wf] |

          [💎truby-23.1i]: https://example/truby-231
          [💎truby-23.2i]: https://example/truby-232
          [💎truby-c-i]: https://example/truby-current
          [🚎9-t-wf]: https://example/truffle
          [🚎11-c-wf]: https://example/current
        MD
        File.write(File.join(project_root, "README.md"), readme)

        allow(helpers).to receive_messages(
          project_root: project_root,
          modified_by_template?: true,
          template_results: {},
        )

        described_class.run

        edited = File.read(File.join(project_root, "README.md"))
        truby_line = edited.lines.find { |line| line.start_with?("| Works with Truffle Ruby") }

        expect(truby_line).not_to include("truby-23.1i")
        expect(truby_line).to include("truby-23.2i")
        expect(truby_line).to include("truby-c-i")
        expect(edited).not_to match(/^\[💎truby-23\.1i\]:/)
        expect(edited).to match(/^\[💎truby-23\.2i\]:/)
        expect(edited).to match(/^\[🚎9-t-wf\]:/)
        expect(edited).to match(/^\[🚎11-c-wf\]:/)
      end
    end

    it "removes JRuby and TruffleRuby rows that end up empty after filtering" do
      Dir.mktmpdir do |project_root|
        File.write(File.join(project_root, "demo.gemspec"), <<~G)
          Gem::Specification.new do |spec|
            spec.name = "demo"
            spec.required_ruby_version = ">= 4.0"
            spec.homepage = "https://github.com/acme/demo"
          end
        G

        readme = <<~MD
          | Works with JRuby        | ![JRuby 9.1 Compat][💎jruby-9.1i] <br/> [![JRuby 9.4 Compat][💎jruby-9.4i]][🚎10-j-wf] |
          | Works with Truffle Ruby | ![Truffle Ruby 22.3 Compat][💎truby-22.3i] <br/> [![Truffle Ruby 23.1 Compat][💎truby-23.1i]][🚎9-t-wf] |

          [💎jruby-9.1i]: https://example/jruby-91
          [💎jruby-9.4i]: https://example/jruby-94
          [💎truby-22.3i]: https://example/truby-223
          [💎truby-23.1i]: https://example/truby-231
          [🚎9-t-wf]: https://example/truffle
          [🚎10-j-wf]: https://example/jruby
        MD
        File.write(File.join(project_root, "README.md"), readme)

        allow(helpers).to receive_messages(
          project_root: project_root,
          modified_by_template?: true,
          template_results: {},
        )

        described_class.run

        edited = File.read(File.join(project_root, "README.md"))
        expect(edited.lines.grep(/^\| Works with JRuby/)).to be_empty
        expect(edited.lines.grep(/^\| Works with Truffle Ruby/)).to be_empty
        expect(edited).not_to match(/^\[💎jruby-9\.1i\]:/)
        expect(edited).not_to match(/^\[💎truby-23\.1i\]:/)
        expect(edited).not_to match(/^\[🚎10-j-wf\]:/)
        expect(edited).not_to match(/^\[🚎9-t-wf\]:/)
      end
    end

    it "cleans a leading <br/> when no badges precede it and keeps the row" do
      Dir.mktmpdir do |project_root|
        File.write(File.join(project_root, "demo.gemspec"), <<~G)
          Gem::Specification.new do |spec|
            spec.name = "demo"
            spec.required_ruby_version = ">= 2.3"
            spec.homepage = "https://github.com/acme/demo"
          end
        G
        readme = <<~MD
          | Works with MRI Ruby 2   |   <br/> [![Ruby 2.3 Compat][💎ruby-2.3i]][🚎1-an-wf] |

          [💎ruby-2.3i]: https://example/23
          [🚎1-an-wf]: https://example/ancient
        MD
        File.write(File.join(project_root, "README.md"), readme)

        allow(helpers).to receive_messages(
          project_root: project_root,
          modified_by_template?: true,
          template_results: {},
        )

        described_class.run

        edited = File.read(File.join(project_root, "README.md"))
        line = edited.lines.find { |l| l.start_with?("| Works with MRI Ruby 2") }
        expect(line).to include("ruby-2.3i")
        expect(line).not_to match(/\|\s*<br\/>/) # no leading br in the badge cell
      end
    end

    it "removes an MRI Ruby row that ends up with only a <br/> and no badges" do
      Dir.mktmpdir do |project_root|
        File.write(File.join(project_root, "demo.gemspec"), <<~G)
          Gem::Specification.new do |spec|
            spec.name = "demo"
            spec.required_ruby_version = ">= 4.0"
            spec.homepage = "https://github.com/acme/demo"
          end
        G
        # Row has only a <br/> in the badge cell which should cause removal
        readme = <<~MD
          | Works with MRI Ruby 2   |   <br/> |

          [💎ruby-2.3i]: https://example/23
        MD
        File.write(File.join(project_root, "README.md"), readme)

        allow(helpers).to receive_messages(
          project_root: project_root,
          modified_by_template?: true,
          template_results: {},
        )

        described_class.run

        edited = File.read(File.join(project_root, "README.md"))
        table_lines = edited.lines.select { |l| l.start_with?("| Works with MRI Ruby") }
        expect(table_lines).to be_empty
      end
    end

    it "removes an MRI Ruby row when all badges in that row are trimmed" do
      Dir.mktmpdir do |project_root|
        # Require Ruby >= 3.5 so MRI 3.0/3.1/3.2/3.3/3.4 badges are also removed from the 3.x row
        File.write(File.join(project_root, "demo.gemspec"), <<~G)
          Gem::Specification.new do |spec|
            spec.name = "demo"
            spec.required_ruby_version = ">= 3.0"
            spec.homepage = "https://github.com/acme/demo"
          end
        G
        readme = <<~MD
          | Works with MRI Ruby 3   | [![Ruby 3.0 Compat][💎ruby-3.0i]][🚎4-lg-wf] [![Ruby 3.1 Compat][💎ruby-3.1i]][🚎6-s-wf] [![Ruby 3.2 Compat][💎ruby-3.2i]][🚎6-s-wf] [![Ruby 3.3 Compat][💎ruby-3.3i]][🚎6-s-wf] [![Ruby current Compat][💎ruby-c-i]][🚎11-c-wf] |
          | Works with MRI Ruby 2   | ![Ruby 2.0 Compat][💎ruby-2.0i] ![Ruby 2.1 Compat][💎ruby-2.1i] [![Ruby 2.3 Compat][💎ruby-2.3i]][🚎1-an-wf] |

          [💎ruby-2.0i]: https://example/20
          [💎ruby-2.1i]: https://example/21
          [💎ruby-2.3i]: https://example/23
          [💎ruby-3.0i]: https://example/30
          [💎ruby-3.1i]: https://example/31
          [💎ruby-3.2i]: https://example/32
          [💎ruby-3.3i]: https://example/33
          [💎ruby-c-i]: https://example/34
          [🚎1-an-wf]: https://example/ancient
          [🚎4-lg-wf]: https://example/legacy
          [🚎6-s-wf]: https://example/supported
          [🚎11-c-wf]: https://example/current
        MD
        File.write(File.join(project_root, "README.md"), readme)

        allow(helpers).to receive_messages(
          project_root: project_root,
          modified_by_template?: true,
          template_results: {},
        )

        described_class.run

        edited = File.read(File.join(project_root, "README.md"))
        table_lines = edited.lines.select { |l| l.start_with?("| Works with MRI Ruby") }
        # The MRI 3 row should remain because it still has badges.
        expect(table_lines.any? { |l| l.include?("Works with MRI Ruby 3") }).to be true
        # The MRI 2 row should be trimmed because it has no badges
        expect(table_lines.any? { |l| l.include?("Works with MRI Ruby 2") }).to be false
      end
    end

    it "prints mise trust notes when .envrc was modified by template", :check_output do
      Dir.mktmpdir do |project_root|
        allow(helpers).to receive_messages(
          project_root: project_root,
          modified_by_template?: true,
          template_results: {},
        )
        allow(described_class).to receive(:mise_installed?).and_return(true)

        expect { described_class.run }
          .to output(/If mise prompts you to trust this repo, run:\n   mise trust\n.*Your \.envrc was created\/updated by kettle:jem:template\./m).to_stdout
      end
    end

    it "recommends installing mise when it is not on PATH", :check_output do
      Dir.mktmpdir do |project_root|
        allow(helpers).to receive_messages(
          project_root: project_root,
          modified_by_template?: true,
          template_results: {},
        )
        allow(described_class).to receive(:mise_installed?).and_return(false)

        expect { described_class.run }
          .to output(/Install mise \(recommended\):\n   https:\/\/mise\.jdx\.dev\/getting-started\.html\n   Then, from the project root, run:\n     mise trust/m).to_stdout
      end
    end

    it "reports that PATH management is handled by mise when .envrc was not created by template" do
      Dir.mktmpdir do |project_root|
        allow(helpers).to receive_messages(
          project_root: project_root,
          modified_by_template?: false,
          template_results: {},
        )

        expect { described_class.run }
          .to output(/PATH management is handled by mise/).to_stdout
      end
    end

    it "adds .env.local to .gitignore (forced) and prints confirmation" do
      Dir.mktmpdir do |project_root|
        allow(helpers).to receive_messages(
          project_root: project_root,
          modified_by_template?: false,
          ask: false, # avoid modifying .envrc in this example
          template_results: {},
        )

        # Force non-interactive add
        stub_env("force" => "true")

        expect { described_class.run }.not_to raise_error
        gi = File.join(project_root, ".gitignore")
        expect(File).to exist(gi)
        txt = File.read(gi)
        expect(txt).to include("# Local environment overrides (KEY=value, loaded by mise via dotenvy)")
        expect(txt).to include(".env.local\n")
      end
    end

    it "skips adding .env.local to .gitignore when declined" do
      Dir.mktmpdir do |project_root|
        allow(helpers).to receive_messages(
          project_root: project_root,
          modified_by_template?: false,
          template_results: {},
        )

        # Decline prompt; stub input adapter for this example only (and ensure force is not set)
        stub_env("force" => nil)
        allow(Kettle::Dev::InputAdapter).to receive(:gets).and_return("n\n")

        expect { described_class.run }.not_to raise_error
        gi = File.join(project_root, ".gitignore")
        expect(File).not_to exist(gi)
      end
    end

    it "notes when no gemspec is present" do
      Dir.mktmpdir do |project_root|
        allow(helpers).to receive_messages(
          project_root: project_root,
          modified_by_template?: false,
          template_results: {},
        )
        allow(helpers).to receive(:ask).and_return(false)
        expect { described_class.run }.not_to raise_error
      end
    end

    it "warns when multiple gemspecs and homepage missing" do
      Dir.mktmpdir do |project_root|
        File.write(File.join(project_root, "a.gemspec"), "Gem::Specification.new do |spec| spec.name='a' end\n")
        File.write(File.join(project_root, "b.gemspec"), "Gem::Specification.new do |spec| spec.name='b' end\n")

        allow(helpers).to receive_messages(
          project_root: project_root,
          modified_by_template?: false,
          template_results: {},
        )
        allow(helpers).to receive(:ask).and_return(false)

        expect { described_class.run }.not_to raise_error
      end
    end

    it "aborts when homepage invalid and no GitHub origin remote is found" do
      Dir.mktmpdir do |project_root|
        gemspec = File.join(project_root, "demo.gemspec")
        File.write(gemspec, <<~G)
          Gem::Specification.new do |spec|
            spec.name = "demo"
            spec.homepage = "http://example.com/demo"
          end
        G

        allow(helpers).to receive_messages(
          project_root: project_root,
          modified_by_template?: false,
          template_results: {},
        )

        # Return non-GitHub url from git remote via GitAdapter
        fake_git = instance_double(Kettle::Dev::GitAdapter, remote_url: "https://gitlab.example.com/acme/demo.git", remotes_with_urls: {"origin" => "https://gitlab.example.com/acme/demo.git"})
        allow(Kettle::Dev::GitAdapter).to receive(:new).and_return(fake_git)

        expect { described_class.run }.to raise_error { |e| expect([SystemExit, Kettle::Dev::Error]).to include(e.class) }
      end
    end

    it "updates homepage using origin when forced" do
      Dir.mktmpdir do |project_root|
        gemspec = File.join(project_root, "demo.gemspec")
        File.write(gemspec, <<~G)
          Gem::Specification.new do |spec|
            spec.name = "demo"
            spec.homepage = "'${ORG}'" # interpolated/invalid on purpose
          end
        G

        allow(helpers).to receive_messages(
          project_root: project_root,
          modified_by_template?: false,
          template_results: {},
        )

        # GitHub origin via GitAdapter
        fake_git = instance_double(Kettle::Dev::GitAdapter, remote_url: "https://github.com/acme/demo.git", remotes_with_urls: {"origin" => "https://github.com/acme/demo.git"})
        allow(Kettle::Dev::GitAdapter).to receive(:new).and_return(fake_git)

        # forced update (no input read under force)
        stub_env("force" => "true", "allowed" => "true")
        described_class.run
        expect(File.read(gemspec)).to match(/spec.homepage\s*=\s*"https:\/\/github.com\/acme\/demo"/)
      end
    end

    it "skips homepage update when declined" do
      Dir.mktmpdir do |project_root|
        gemspec = File.join(project_root, "demo.gemspec")
        File.write(gemspec, <<~G)
          Gem::Specification.new do |spec|
            spec.name = "demo"
            spec.homepage = "http://example.com/demo"
          end
        G

        allow(helpers).to receive_messages(
          project_root: project_root,
          modified_by_template?: false,
          template_results: {},
        )

        # GitHub origin via GitAdapter
        fake_git = instance_double(Kettle::Dev::GitAdapter, remote_url: "https://github.com/acme/demo.git", remotes_with_urls: {"origin" => "https://github.com/acme/demo.git"})
        allow(Kettle::Dev::GitAdapter).to receive(:new).and_return(fake_git)

        # decline (no force, so input is read)
        stub_env("force" => nil)
        allow(Kettle::Dev::InputAdapter).to receive(:gets).and_return("n\n")
        described_class.run
        expect(File.read(gemspec)).to include("http://example.com/demo")
      end
    end

    it "prints summary of templating changes and handles errors in summary" do
      Dir.mktmpdir do |project_root|
        allow(helpers).to receive(:project_root).and_return(project_root)
        allow(helpers).to receive(:modified_by_template?).and_return(false)
        allow(helpers).to receive(:ask).and_return(false)

        # First run: provide meaningful template results across action types
        allow(helpers).to receive(:template_results).and_return({
          File.join(project_root, "a.txt") => {action: :create, timestamp: Time.now},
          File.join(project_root, "b.txt") => {action: :replace, timestamp: Time.now},
          File.join(project_root, "dir1") => {action: :dir_create, timestamp: Time.now},
          File.join(project_root, "dir2") => {action: :dir_replace, timestamp: Time.now},
        })

        expect { described_class.run }.not_to raise_error

        # Second run: force an error when fetching summary
        allow(helpers).to receive(:template_results).and_raise(StandardError, "nope")
        expect { described_class.run }.not_to raise_error
      end
    end

    it "offers to remove .ruby-version and .ruby-gemset when .tool-versions exists and removes them on accept", :check_output do
      Dir.mktmpdir do |project_root|
        File.write(File.join(project_root, ".tool-versions"), "ruby 3.3.0\n")
        rv = File.join(project_root, ".ruby-version")
        rg = File.join(project_root, ".ruby-gemset")
        File.write(rv, "3.3.0\n")
        File.write(rg, "gemset\n")

        allow(helpers).to receive_messages(
          project_root: project_root,
          modified_by_template?: true, # skip .envrc path
          ask: true,
          template_results: {},
        )

        described_class.run
        expect(File).not_to exist(rv)
        expect(File).not_to exist(rg)
      end
    end

    it "rescues read error for .envrc and proceeds" do
      Dir.mktmpdir do |project_root|
        envrc = File.join(project_root, ".envrc")
        File.write(envrc, "whatever")

        allow(helpers).to receive_messages(
          project_root: project_root,
          modified_by_template?: false,
          ask: false, # skip writing
          template_results: {},
        )

        allow(File).to receive(:read).and_wrap_original do |m, path|
          if path == envrc
            raise StandardError, "nope"
          else
            m.call(path)
          end
        end

        expect { described_class.run }.not_to raise_error
      end
    end

    it "rescues read error for .gitignore and still proceeds" do
      Dir.mktmpdir do |project_root|
        gi = File.join(project_root, ".gitignore")
        File.write(gi, "")
        allow(helpers).to receive_messages(
          project_root: project_root,
          modified_by_template?: false,
          template_results: {},
        )
        allow(helpers).to receive(:ask).and_return(false)
        allow(File).to receive(:read).and_wrap_original do |m, path|
          if path == gi
            raise StandardError, "boom"
          else
            m.call(path)
          end
        end
        # Decline prompt so we don't write
        allow(Kettle::Dev::InputAdapter).to receive(:gets).and_return("n\n")
        expect { described_class.run }.not_to raise_error
      end
    end

    it "handles exception when reading git origin and aborts due to missing GitHub" do
      Dir.mktmpdir do |project_root|
        gemspec = File.join(project_root, "demo.gemspec")
        File.write(gemspec, <<~G)
          Gem::Specification.new do |spec|
            spec.name = "demo"
            spec.homepage = "http://example.com/demo"
          end
        G
        allow(helpers).to receive_messages(
          project_root: project_root,
          modified_by_template?: false,
          template_results: {},
        )
        allow(Kettle::Dev::GitAdapter).to receive(:new).and_raise(StandardError, "no git")
        expect { described_class.run }.to raise_error { |e| expect([SystemExit, Kettle::Dev::Error]).to include(e.class) }
      end
    end

    it "rescues unexpected error during gemspec homepage check and warns" do
      Dir.mktmpdir do |project_root|
        allow(helpers).to receive_messages(
          project_root: project_root,
          modified_by_template?: true, # skip envrc
          template_results: {},
        )
        allow(Dir).to receive(:glob).and_raise(StandardError, "kaboom")
        expect { described_class.run }.not_to raise_error
      end
    end

    it "parses quoted literal GitHub homepage without update" do
      Dir.mktmpdir do |project_root|
        gemspec = File.join(project_root, "demo.gemspec")
        File.write(gemspec, <<~G)
          Gem::Specification.new do |spec|
            spec.name = "demo"
            spec.homepage = "'https://github.com/acme/demo'"
          end
        G
        allow(helpers).to receive_messages(
          project_root: project_root,
          modified_by_template?: false,
          template_results: {},
        )
        allow(helpers).to receive(:ask).and_return(false)
        expect { described_class.run }.not_to raise_error
        expect(File.read(gemspec)).to include("'https://github.com/acme/demo'")
      end
    end

    it "rescues when computing relative path during summary" do
      Dir.mktmpdir do |project_root|
        allow(helpers).to receive(:project_root).and_return(project_root)
        allow(helpers).to receive(:modified_by_template?).and_return(true)
        # Include a nil key to trigger NoMethodError in start_with?
        allow(helpers).to receive(:template_results).and_return({
          nil => {action: :create, timestamp: Time.now},
        })
        expect { described_class.run }.not_to raise_error
      end
    end

    # New tests: grapheme synchronization between README H1 and gemspec
    it "replaces mismatched grapheme and enforces single space in README and gemspec" do
      Dir.mktmpdir do |project_root|
        # README with a different emoji
        File.write(File.join(project_root, "README.md"), "# 🍕  My Library\n\nText\n")
        # Gemspec with different leading emoji and extra spaces
        gemspec = File.join(project_root, "demo.gemspec")
        File.write(gemspec, <<~G)
          Gem::Specification.new do |spec|
            spec.name = "demo"
            spec.summary = "🍲  A tasty lib"
            spec.description = "🍲  Delicious things" \
              " and more"
            spec.homepage = "https://github.com/acme/demo"
          end
        G
        allow(helpers).to receive_messages(
          project_root: project_root,
          modified_by_template?: true,
          template_results: {},
        )
        described_class.run
        # README H1 normalized: single 🍕 and single space
        readme = File.read(File.join(project_root, "README.md"))
        expect(readme.lines.first).to eq("# 🍕 My Library\n")
        # Gemspec summary/description start with 🍕 and single space
        txt = File.read(gemspec)
        expect(txt).to match(/spec.summary\s*=\s*"🍕 A tasty lib"/)
        expect(txt).to match(/spec.description\s*=\s*"🍕 Delicious things"/)
      end
    end

    it "inserts user-provided grapheme when README H1 has none" do
      Dir.mktmpdir do |project_root|
        File.write(File.join(project_root, "README.md"), "# My Library\n")
        gemspec = File.join(project_root, "demo.gemspec")
        File.write(gemspec, <<~G)
          Gem::Specification.new do |spec|
            spec.name = "demo"
            spec.summary = "A lib"
            spec.description = "Awesome" \
              " stuff"
            spec.homepage = "https://github.com/acme/demo"
          end
        G
        allow(helpers).to receive_messages(
          project_root: project_root,
          modified_by_template?: true,
          template_results: {},
        )
        # No force set, so input is read and stubbed to 🚀
        stub_env("force" => nil)
        allow(Kettle::Dev::InputAdapter).to receive(:gets).and_return("🚀\n")
        described_class.run
        readme = File.read(File.join(project_root, "README.md"))
        expect(readme.lines.first).to eq("# 🚀 My Library\n")
        txt = File.read(gemspec)
        expect(txt).to match(/spec.summary\s*=\s*"🚀 A lib"/)
        expect(txt).to match(/spec.description\s*=\s*"🚀 Awesome"/)
      end
    end

    it "does nothing when user provides empty grapheme input" do
      Dir.mktmpdir do |project_root|
        File.write(File.join(project_root, "README.md"), "# Title\n")
        gemspec = File.join(project_root, "demo.gemspec")
        File.write(gemspec, <<~G)
          Gem::Specification.new do |spec|
            spec.name = "demo"
            spec.summary = "Sum"
            spec.description = "Desc" \
              " tail"
            spec.homepage = "https://github.com/acme/demo"
          end
        G
        allow(helpers).to receive_messages(
          project_root: project_root,
          modified_by_template?: true,
          template_results: {},
        )
        stub_env("force" => nil)
        allow(Kettle::Dev::InputAdapter).to receive(:gets).and_return("\n")
        described_class.run
        # unchanged
        expect(File.read(File.join(project_root, "README.md"))).to start_with("# Title\n")
        t = File.read(gemspec)
        expect(t).to include('spec.summary = "Sum"')
        expect(t).to include('spec.description = "Desc"')
      end
    end

    it "exits cleanly when templating bootstraps only .kettle-jem.yml" do
      Dir.mktmpdir do |project_root|
        File.write(File.join(project_root, ".tool-versions"), "ruby 3.2.0\n")
        File.write(File.join(project_root, ".ruby-version"), "3.2.0\n")

        fake_task = double("template task")
        allow(fake_task).to receive(:invoke) { helpers.template_run_outcome = :bootstrap_only }
        allow(Rake::Task).to receive(:[]).with("kettle:jem:template").and_return(fake_task)

        allow(helpers).to receive_messages(
          project_root: project_root,
          modified_by_template?: false,
          template_results: {},
        )

        expect { described_class.run }.not_to raise_error
        expect(File).to exist(File.join(project_root, ".ruby-version"))
      end
    end
  end

  describe "::task_abort" do
    it "preserves repeated spaces in README during install while inserting a grapheme" do
      Dir.mktmpdir do |project_root|
        # Minimal gemspec so homepage checks do not abort
        File.write(File.join(project_root, "demo.gemspec"), <<~G)
          Gem::Specification.new do |spec|
            spec.name = "demo"
            spec.homepage = "https://github.com/acme/demo"
          end
        G
        # README with repeated spaces in H1 tail and body
        original = <<~MD
          # Title   with   multiple   spaces

          A  body   line    with     many      spaces.
        MD
        File.write(File.join(project_root, "README.md"), original)

        allow(helpers).to receive_messages(
          project_root: project_root,
          modified_by_template?: false,
          template_results: {},
        )

        # Provide a grapheme non-interactively to avoid prompt unless force is set.
        # With force=true, InputAdapter.gets is not called, so do not stub it in this case.

        stub_env(
          "allowed" => "true",
          "force" => "true",
          "GIT_HOOK_TEMPLATES_CHOICE" => "s",
        )
        described_class.run

        edited = File.read(File.join(project_root, "README.md"))
        first_line = edited.lines.first.chomp
        expect(first_line).to eq("# 🍕 Title   with   multiple   spaces")
        expect(edited).to include("A  body   line    with     many      spaces.")
      end
    end
  end

  # describe "integration via bin/rake" do
  #   # ci_skip because this test is too flaky to run in CI. It seems to fail randomly.
  #   it "runs kettle:jem:install in a mock gem and preserves README table spacing from template", :skip_ci do
  #     repo_root = Kettle::Jem::TemplateHelpers.gem_checkout_root
  #     src_readme = File.join(repo_root, "template", "README.md.example")
  #     template_lines = File.readlines(src_readme)
  #     # Find the 'Support & Community' row dynamically in case table order changes
  #     src_line = template_lines.find { |l| l.start_with?("| Support") }
  #     expect(src_line).not_to be_nil
  #     src_prefix = src_line[/^\|[^|]*\|/]
  #     Dir.mktmpdir do |project_root|
  #       # Minimal gemspec to satisfy homepage/GitHub checks
  #       File.write(File.join(project_root, "demo.gemspec"), <<~G)
  #         Gem::Specification.new do |spec|
  #           spec.name = "demo"
  #           spec.homepage = "https://github.com/acme/demo"
  #         end
  #       G
  #       # Create a minimal Gemfile inside the fixture gem
  #       File.write(File.join(project_root, "Gemfile"), <<~GEMFILE)
  #         # frozen_string_literal: true
  #         source "https://gem.coop"
  #         gem "rake"
  #         gem "kettle-jem", path: "#{repo_root}"
  #       GEMFILE
  #       # Minimal Rakefile that loads kettle-jem tasks from this checkout
  #       File.write(File.join(project_root, "Rakefile"), <<~RAKE)
  #         $LOAD_PATH.unshift(File.expand_path("#{File.join(repo_root, "lib")}"))
  #         require "kettle/jem"
  #         load File.expand_path("#{File.join(repo_root, "lib/kettle/jem/rakelib/template.rake")}")
  #         load File.expand_path("#{File.join(repo_root, "lib/kettle/jem/rakelib/install.rake")}")
  #       RAKE
  #       bin_rake = File.join(repo_root, "bin", "rake")
  #       require "open3"
  #       env = {
  #         "allowed" => "true",
  #         "force" => "true",
  #         "hook_templates" => "l",
  #         # Reduce noise and avoid coverage strictness for a subprocess run
  #         "K_SOUP_COV_MIN_HARD" => "false",
  #       }
  #       # 1) Install dependencies for the fixture gem using an unbundled environment
  #       begin
  #         require "bundler"
  #         bundler_unbundled = Bundler.respond_to?(:with_unbundled_env)
  #       rescue StandardError => e
  #         Kettle::Dev.debug_error(e, __method__)
  #         bundler_unbundled = false
  #       end
  #       if bundler_unbundled
  #         Bundler.with_unbundled_env do
  #           _bout, _berr, _bstatus = Open3.capture3({"BUNDLE_GEMFILE" => File.join(project_root, "Gemfile")}, "bundle", "install", "--quiet", chdir: project_root)
  #         end
  #       else
  #         # Fallback for very old bundler
  #         _bout, _berr, _bstatus = Open3.capture3({"BUNDLE_GEMFILE" => File.join(project_root, "Gemfile")}, "bundle", "install", "--quiet", chdir: project_root)
  #       end
  #       # 2) Ensure the repository Gemfile has its dependencies installed before invoking bin/rake
  #       repo_env = {"BUNDLE_GEMFILE" => File.join(repo_root, "Gemfile")}
  #       bund_out, bund_err, bund_status = Open3.capture3(repo_env, "bundle", "install", "--quiet")
  #       unless bund_status.success?
  #         warn "bundle install failed for repo Gemfile:\n#{bund_out}\n#{bund_err}"
  #       end
  #       # 3) Run the task
  #       stdout, stderr, status = Open3.capture3(env.merge("BUNDLE_GEMFILE" => File.join(project_root, "Gemfile")), bin_rake, "kettle:jem:install", chdir: project_root)
  #       unless status.success?
  #         warn "bin/rake output:\n#{stdout}\n#{stderr}"
  #       end
  #       expect(status.success?).to be true
  #       gen_readme = File.read(File.join(project_root, "README.md"))
  #       line = gen_readme.lines.find { |l| l.start_with?("| Support") }
  #       expect(line).not_to be_nil
  #       gen_prefix = line[/^\|[^|]*\|/]
  #       expect(gen_prefix).to eq(src_prefix)
  #
  #       # ensure .env.local.example is copied during full install
  #       expect(File).to exist(File.join(project_root, ".env.local.example"))
  #     end
  #   end
  # end

  describe "MRI badge cell spacing" do
    it "does not add extra leading spaces at the start of the MRI badge cell" do
      Dir.mktmpdir do |project_root|
        # Keep 2.2 and newer; remove nothing below 2.2 to simulate user's scenario
        File.write(File.join(project_root, "demo.gemspec"), <<~G)
          Gem::Specification.new do |spec|
            spec.name = "demo"
            spec.required_ruby_version = ">= 2.2"
            spec.homepage = "https://github.com/acme/demo"
          end
        G

        # Row mirrors the user's example: a single space before the first badge, then a <br/> and more badges
        readme = <<~MD
          | Works with MRI Ruby 2   | ![Ruby 2.2 Compat][💎ruby-2.2i] <br/> [![Ruby 2.3 Compat][💎ruby-2.3i]][🚎1-an-wf] [![Ruby 2.4 Compat][💎ruby-2.4i]][🚎1-an-wf] [![Ruby 2.5 Compat][💎ruby-2.5i]][🚎1-an-wf] [![Ruby 2.6 Compat][💎ruby-2.6i]][🚎7-us-wf] [![Ruby 2.7 Compat][💎ruby-2.7i]][🚎7-us-wf] |

          [💎ruby-2.2i]: https://example/22
          [💎ruby-2.3i]: https://example/23
          [💎ruby-2.4i]: https://example/24
          [💎ruby-2.5i]: https://example/25
          [💎ruby-2.6i]: https://example/26
          [💎ruby-2.7i]: https://example/27
          [🚎1-an-wf]: https://example/ancient
          [🚎7-us-wf]: https://example/unsupported
        MD
        File.write(File.join(project_root, "README.md"), readme)

        allow(helpers).to receive_messages(
          project_root: project_root,
          modified_by_template?: true,
          template_results: {},
        )

        described_class.run

        edited = File.read(File.join(project_root, "README.md"))
        line = edited.lines.find { |l| l.start_with?("| Works with MRI Ruby 2") }
        expect(line).not_to be_nil
        cells = line.split("|", -1)
        badge_cell = cells[2] || ""
        # Exactly one leading space before the first badge
        expect(badge_cell.start_with?(" ")).to be true
        expect(badge_cell.start_with?("  ")).to be false
      end
    end
  end
end
# rubocop:enable RSpec/MultipleExpectations, RSpec/VerifiedDoubles, RSpec/ReceiveMessages
