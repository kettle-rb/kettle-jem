# frozen_string_literal: true

RSpec.describe Kettle::Jem::GemRubyFloor::Resolver do
  subject(:resolver) { described_class.new }

  describe "#parse_min_ruby" do
    it "returns nil for blank or invalid requirements" do
      expect(resolver.parse_min_ruby(nil)).to be_nil
      expect(resolver.parse_min_ruby("")).to be_nil
      expect(resolver.parse_min_ruby("not a requirement")).to be_nil
    end

    it "prefers >= floors over other operators" do
      expect(resolver.parse_min_ruby(">= 2.7")).to eq(Gem::Version.new("2.7"))
    end

    it "falls back to pessimistic floors" do
      expect(resolver.parse_min_ruby("~> 3.1")).to eq(Gem::Version.new("3.1"))
    end
  end

  describe "#fetch_versions" do
    it "sorts results oldest-to-newest and caches the response" do
      response = instance_double(Net::HTTPOK, body: <<~JSON)
        [{"number":"2.0.0"},{"number":"1.5.0"},{"number":"1.10.0"}]
      JSON
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(Net::HTTP).to receive(:get_response).once.and_return(response)

      versions = resolver.fetch_versions("demo")

      expect(versions.map { |entry| entry["number"] }).to eq(%w[1.5.0 1.10.0 2.0.0])
      expect(resolver.fetch_versions("demo")).to equal(versions)
    end

    it "raises when RubyGems returns a non-success response" do
      response = instance_double(Net::HTTPNotFound, code: "404")
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
      allow(Net::HTTP).to receive(:get_response).and_return(response)

      expect { resolver.fetch_versions("missing") }.to raise_error("RubyGems API error for missing: 404")
    end
  end

  describe "#min_ruby_version" do
    it "extracts the floor from the matching version entry" do
      response = instance_double(Net::HTTPOK, body: <<~JSON)
        [{"number":"0.9.0","ruby_version":">= 2.6"},{"number":"1.0.0","ruby_version":"~> 3.1"}]
      JSON
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(Net::HTTP).to receive(:get_response).and_return(response)

      expect(resolver.min_ruby_version("demo", "1.0.0")).to eq(Gem::Version.new("3.1"))
      expect(resolver.min_ruby_version("demo", "2.0.0")).to be_nil
    end
  end

  describe "#fetch_gem_info" do
    it "returns nil for non-success responses" do
      response = instance_double(Net::HTTPNotFound)
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
      allow(Net::HTTP).to receive(:get_response).and_return(response)

      expect(resolver.fetch_gem_info("demo", "1.0.0")).to be_nil
    end

    it "parses and caches successful responses" do
      response = instance_double(Net::HTTPOK, body: '{"ruby_version":">= 3.0"}')
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(Net::HTTP).to receive(:get_response).once.and_return(response)

      info = resolver.fetch_gem_info("demo", "1.0.0")

      expect(info).to eq({"ruby_version" => ">= 3.0"})
      expect(resolver.fetch_gem_info("demo", "1.0.0")).to equal(info)
    end
  end
end
