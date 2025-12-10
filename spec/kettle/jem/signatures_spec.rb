# frozen_string_literal: true

RSpec.describe Kettle::Jem::Signatures do
  describe ".gemfile" do
    let(:generator) { described_class.gemfile }

    context "with source() call" do
      let(:node) { parse_call("source 'https://rubygems.org'") }

      it "returns [:source] signature" do
        expect(generator.call(node)).to eq([:source])
      end
    end

    context "with gem() call" do
      let(:node) { parse_call('gem "rspec"') }

      it "returns [:gem, gem_name] signature" do
        expect(generator.call(node)).to eq([:gem, "rspec"])
      end
    end

    context "with gem() call with version" do
      let(:node) { parse_call('gem "rspec", "~> 3.0"') }

      it "returns [:gem, gem_name] signature (ignores version)" do
        expect(generator.call(node)).to eq([:gem, "rspec"])
      end
    end

    context "with eval_gemfile() call" do
      let(:node) { parse_call('eval_gemfile "modular/test.gemfile"') }

      it "returns [:eval_gemfile, path] signature" do
        expect(generator.call(node)).to eq([:eval_gemfile, "modular/test.gemfile"])
      end
    end

    context "with ruby() call" do
      let(:node) { parse_call('ruby "3.2.0"') }

      it "returns [:ruby] signature" do
        expect(generator.call(node)).to eq([:ruby])
      end
    end

    context "with git_source() call" do
      let(:node) { parse_call('git_source(:github) { |repo| "https://github.com/#{repo}" }') }

      it "returns [:git_source, source_name] signature" do
        expect(generator.call(node)).to eq([:git_source, "github"])
      end
    end

    context "with assignment method" do
      let(:node) { parse_call('spec.name = "test"') }

      it "returns [:call, method, receiver] signature" do
        expect(generator.call(node)).to eq([:call, :name=, "spec"])
      end
    end

    context "with method call with first argument" do
      let(:node) { parse_call('add_dependency("test")') }

      it "returns [method, first_arg] signature" do
        expect(generator.call(node)).to eq([:add_dependency, "test"])
      end
    end

    context "with non-CallNode" do
      let(:node) { parse_statement("x = 1") }

      it "returns the node unchanged" do
        expect(generator.call(node)).to eq(node)
      end
    end

    def parse_call(code)
      result = Prism.parse(code)
      result.value.statements.body.first
    end

    def parse_statement(code)
      result = Prism.parse(code)
      result.value.statements.body.first
    end
  end

  describe ".appraisals" do
    let(:generator) { described_class.appraisals }

    context "with appraise() call" do
      let(:node) do
        code = <<~RUBY
          appraise "ruby-3-3" do
            gem "test"
          end
        RUBY
        result = Prism.parse(code)
        result.value.statements.body.first
      end

      it "returns [:appraise, appraisal_name] signature" do
        expect(generator.call(node)).to eq([:appraise, "ruby-3-3"])
      end
    end

    context "with gem() call (delegated to gemfile)" do
      let(:node) do
        result = Prism.parse('gem "rspec"')
        result.value.statements.body.first
      end

      it "returns [:gem, gem_name] signature" do
        expect(generator.call(node)).to eq([:gem, "rspec"])
      end
    end
  end

  describe ".gemspec" do
    let(:generator) { described_class.gemspec }

    context "with spec.name = assignment" do
      let(:node) { parse_call('spec.name = "test"') }

      it "returns [:spec_attr, :name=] signature" do
        expect(generator.call(node)).to eq([:spec_attr, :name=])
      end
    end

    context "with spec.add_dependency call" do
      let(:node) { parse_call('spec.add_dependency("test", "~> 1.0")') }

      it "returns [:add_dependency, gem_name] signature" do
        expect(generator.call(node)).to eq([:add_dependency, "test"])
      end
    end

    context "with spec.add_development_dependency call" do
      let(:node) { parse_call('spec.add_development_dependency("rspec")') }

      it "returns [:add_development_dependency, gem_name] signature" do
        expect(generator.call(node)).to eq([:add_development_dependency, "rspec"])
      end
    end

    def parse_call(code)
      result = Prism.parse(code)
      result.value.statements.body.first
    end
  end

  describe ".rakefile" do
    let(:generator) { described_class.rakefile }

    context "with task :name" do
      let(:node) { parse_call("task :test") }

      it "returns [:task, task_name] signature" do
        expect(generator.call(node)).to eq([:task, "test"])
      end
    end

    context "with namespace :name" do
      let(:node) do
        code = <<~RUBY
          namespace :db do
            task :migrate
          end
        RUBY
        result = Prism.parse(code)
        result.value.statements.body.first
      end

      it "returns [:namespace, namespace_name] signature" do
        expect(generator.call(node)).to eq([:namespace, "db"])
      end
    end

    context "with desc call" do
      let(:node) { parse_call('desc "Run tests"') }

      it "returns [:desc] signature" do
        expect(generator.call(node)).to eq([:desc])
      end
    end

    def parse_call(code)
      result = Prism.parse(code)
      result.value.statements.body.first
    end
  end
end
