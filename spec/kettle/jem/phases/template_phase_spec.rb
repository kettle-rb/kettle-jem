# frozen_string_literal: true

require "tmpdir"

require "kettle/jem/phases/template_phase"

RSpec.describe Kettle::Jem::Phases::TemplatePhase do
  let(:phase_class) do
    klass = Class.new(described_class) do
      def perform; end
    end
    klass.const_set(:PHASE_EMOJI, "🧪")
    klass.const_set(:PHASE_NAME, "Test phase")
    stub_const("TemplatePhaseSpecActor", klass)
  end

  it "advances the templating progress after emitting the phase summary" do
    helpers = double("helpers", template_results: {})
    out = double("out", phase: nil, warning: nil)
    progress = double("progress", advance!: nil)

    Dir.mktmpdir do |project_root|
      context = Kettle::Jem::Phases::PhaseContext.new(
        helpers: helpers,
        out: out,
        progress: progress,
        project_root: project_root,
        template_root: project_root,
        gem_name: "demo",
        namespace: "Demo",
        namespace_shield: "Demo",
        gem_shield: "demo",
        forge_org: "acme",
        funding_org: nil,
        min_ruby: "3.2",
        entrypoint_require: "demo",
        meta: {},
      )

      phase_class.call(context: context)
    end

    expect(out).to have_received(:phase).with("🧪", "Test phase", detail: nil)
    expect(progress).to have_received(:advance!).once
  end
end
