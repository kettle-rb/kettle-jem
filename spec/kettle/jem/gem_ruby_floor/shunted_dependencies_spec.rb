# frozen_string_literal: true

RSpec.describe Kettle::Jem::GemRubyFloor::ShuntedDependencies do
  describe ".compute" do
    it "classifies dependencies by their resolved Ruby floor" do
      resolver = instance_double(Kettle::Jem::GemRubyFloor::Resolver)
      allow(resolver).to receive(:min_ruby_version).with("rubocop", "1.0.0").and_return(Gem::Version.new("3.1"))
      allow(resolver).to receive(:min_ruby_version).with("rake", "13.0.0").and_return(Gem::Version.new("2.2"))
      allow(resolver).to receive(:min_ruby_version).with("mystery", "0.1.0").and_raise(StandardError, "boom")

      result = described_class.compute(
        dev_deps: [
          {name: "rubocop", version: "1.0.0", constraint: "~> 1.0"},
          {name: "rake", version: "13.0.0", constraint: "~> 13.0"},
          {name: "mystery", version: "0.1.0", constraint: "~> 0.1"},
          {name: "", version: "1.0.0"},
          {name: "skip-me", version: nil},
        ],
        gemspec_min_ruby: Gem::Version.new("2.7"),
        resolver: resolver,
      )

      expect(result[:effective_floor]).to eq(Gem::Version.new("2.7"))
      expect(result[:to_shunt]).to contain_exactly(
        include(name: "rubocop", version: "1.0.0", constraint: "~> 1.0", min_ruby: Gem::Version.new("3.1")),
      )
      expect(result[:to_keep]).to contain_exactly(
        include(name: "rake", version: "13.0.0", constraint: "~> 13.0", min_ruby: Gem::Version.new("2.2")),
        include(name: "mystery", version: "0.1.0", constraint: "~> 0.1", min_ruby: nil),
      )
    end
  end

  describe ".compute_from_gemspec" do
    it "returns a fallback payload when the gemspec cannot be loaded" do
      allow(Gem::Specification).to receive(:load).with("/tmp/demo.gemspec").and_return(nil)

      expect(described_class.compute_from_gemspec(gemspec_path: "/tmp/demo.gemspec", resolver: double("resolver"))).to eq(
        to_shunt: [],
        to_keep: [],
        effective_floor: Kettle::Jem::GemRubyFloor::MINIMUM_RUBY_FLOOR,
        gemspec_min_ruby: nil,
      )
    end

    it "uses the latest matching dependency versions from the gemspec" do
      spec = Gem::Specification.new do |gemspec|
        gemspec.name = "demo"
        gemspec.version = "0.1.0"
        gemspec.required_ruby_version = Gem::Requirement.new(">= 2.6")
        gemspec.add_development_dependency("rubocop", "~> 1.0")
        gemspec.add_development_dependency("rake", "~> 13.0")
      end
      resolver = instance_double(Kettle::Jem::GemRubyFloor::Resolver)

      allow(Gem::Specification).to receive(:load).with("/tmp/demo.gemspec").and_return(spec)
      allow(resolver).to receive(:fetch_versions).with("rubocop").and_return(
        [{"number" => "0.9.0"}, {"number" => "1.0.0"}, {"number" => "1.1.0"}],
      )
      allow(resolver).to receive(:fetch_versions).with("rake").and_return(
        [{"number" => "12.3.0"}, {"number" => "13.0.1"}],
      )
      allow(resolver).to receive(:min_ruby_version).with("rubocop", "1.1.0").and_return(Gem::Version.new("3.0"))
      allow(resolver).to receive(:min_ruby_version).with("rake", "13.0.1").and_return(Gem::Version.new("2.0"))

      result = described_class.compute_from_gemspec(gemspec_path: "/tmp/demo.gemspec", resolver: resolver)

      expect(result[:gemspec_min_ruby]).to eq(Gem::Version.new("2.6"))
      expect(result[:effective_floor]).to eq(Gem::Version.new("2.6"))
      expect(result[:to_shunt]).to contain_exactly(include(name: "rubocop", version: "1.1.0", min_ruby: Gem::Version.new("3.0")))
      expect(result[:to_keep]).to contain_exactly(include(name: "rake", version: "13.0.1", min_ruby: Gem::Version.new("2.0")))
    end

    it "falls back cleanly when gemspec processing raises" do
      allow(Gem::Specification).to receive(:load).and_raise(StandardError, "boom")

      expect(described_class.compute_from_gemspec(gemspec_path: "/tmp/demo.gemspec", resolver: double("resolver"))).to eq(
        to_shunt: [],
        to_keep: [],
        effective_floor: Kettle::Jem::GemRubyFloor::MINIMUM_RUBY_FLOOR,
        gemspec_min_ruby: nil,
      )
    end
  end

  describe ".effective_dev_floor" do
    it "clamps nil and invalid values to the minimum floor" do
      expect(described_class.effective_dev_floor(nil)).to eq(Gem::Version.new("2.3"))
      expect(described_class.effective_dev_floor("not-a-version")).to eq(Gem::Version.new("2.3"))
    end

    it "returns the max of the gemspec floor and the CI floor" do
      expect(described_class.effective_dev_floor("2.2")).to eq(Gem::Version.new("2.3"))
      expect(described_class.effective_dev_floor("3.0")).to eq(Gem::Version.new("3.0"))
    end
  end
end
