# frozen_string_literal: true

RSpec.describe Kettle::Jem::LicenseTxtMigrator do
  subject(:migrator) { described_class.new(content) }

  describe "#mit_license?" do
    context "when content is a standard MIT license" do
      let(:content) do
        <<~LICENSE
          MIT License

          Copyright (c) 2024 Someone

          Permission is hereby granted, free of charge, to any person obtaining a copy
          of this software and associated documentation files (the "Software"), to deal
          in the Software without restriction, including without limitation the rights
          to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
          copies of the Software.

          THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
          IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
          FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
        LICENSE
      end

      it "returns true" do
        expect(migrator.mit_license?).to be(true)
      end
    end

    context "when content is not an MIT license" do
      let(:content) do
        <<~LICENSE
          Apache License 2.0

          Licensed under the Apache License, Version 2.0 (the "License");
          you may not use this file except in compliance with the License.
        LICENSE
      end

      it "returns false" do
        expect(migrator.mit_license?).to be(false)
      end
    end

    context "when content has only one MIT phrase" do
      let(:content) { "permission is hereby granted but nothing else" }

      it "returns false (requires both phrases)" do
        expect(migrator.mit_license?).to be(false)
      end
    end

    context "when content is empty string" do
      let(:content) { "" }

      it "returns false" do
        expect(migrator.mit_license?).to be(false)
      end
    end

    context "when content is nil" do
      let(:content) { nil }

      it "returns false (nil coerced to empty string)" do
        expect(migrator.mit_license?).to be(false)
      end
    end

    context "when phrases appear across broken lines" do
      let(:content) do
        # searchable_text collapses whitespace so multi-line phrases still match
        <<~LICENSE
          Permission is hereby
          granted, free of charge, to any person obtaining a copy
          of this software without restriction.
        LICENSE
      end

      it "returns true due to whitespace collapsing" do
        expect(migrator.mit_license?).to be(true)
      end
    end
  end

  describe "#copyright_lines" do
    context "when content has copyright in preamble" do
      let(:content) do
        <<~LICENSE
          Copyright (c) 2024 Jane Doe
          All rights reserved.

          Permission is hereby granted, free of charge, to any person obtaining a copy
          of this software without restriction.
        LICENSE
      end

      it "returns lines matching /copyright/i" do
        lines = migrator.copyright_lines
        expect(lines).to be_an(Array)
        expect(lines.length).to eq(1)
        expect(lines.first).to include("Copyright")
      end
    end

    context "when content has multiple copyright lines" do
      let(:content) do
        <<~LICENSE
          Copyright (c) 2020 Original Author
          Copyright (c) 2024 New Contributor

          Permission is hereby granted, free of charge, to any person
          without restriction.
        LICENSE
      end

      it "returns all copyright lines from the preamble" do
        expect(migrator.copyright_lines.length).to eq(2)
      end
    end

    context "when content has no 'Permission is hereby granted' boundary" do
      let(:content) do
        <<~LICENSE
          Copyright (c) 2024 Jane Doe
          Some other license text without the permission grant phrase.
          More text here.
        LICENSE
      end

      it "treats all lines as preamble and returns copyright lines" do
        lines = migrator.copyright_lines
        expect(lines.length).to eq(1)
        expect(lines.first).to include("Copyright")
      end
    end

    context "when there are no copyright lines in the preamble" do
      let(:content) do
        <<~LICENSE
          MIT License

          Permission is hereby granted, free of charge, to any person obtaining a copy
          without restriction.
        LICENSE
      end

      it "returns an empty array" do
        expect(migrator.copyright_lines).to eq([])
      end
    end

    context "when copyright lines appear after the permission grant" do
      let(:content) do
        <<~LICENSE
          Permission is hereby granted, free of charge, to any person
          without restriction.
          Copyright (c) 2024 in license body
        LICENSE
      end

      it "excludes copyright lines that appear after the boundary" do
        expect(migrator.copyright_lines).to eq([])
      end
    end

    context "when content is empty" do
      let(:content) { "" }

      it "returns an empty array" do
        expect(migrator.copyright_lines).to eq([])
      end
    end
  end
end
