# frozen_string_literal: true

RSpec.describe "CONTRIBUTING.md list duplication bug" do
  # Reproduce the scenario where the template has a 7-item contribution list under
  # "## Help out!" and the destination has a different 9-item list under "## You can help!".
  # Previously, each merge run appended another copy of the 7-item list because:
  #   1. The two lists had different item counts -> no signature match
  #   2. The template list was added as template-only content
  #   3. Adjacent ordered lists get merged by the Markly/CommonMark parser into one
  #      bigger list, changing the item count each run
  #   4. Next run: still no signature match -> another copy added, ad infinitum

  let(:template) do
    <<~MD
      # Contributing

      ## Help out!

      Take a look at the reek list.

      Follow these instructions:

      1. Fork the repository
      2. Create a feature branch (`git checkout -b my-new-feature`)
      3. Make some fixes.
      4. Commit changes (`git commit -am 'Added some feature'`)
      5. Push to the branch (`git push origin my-new-feature`)
      6. Make sure to add tests for it. This is important, so it doesn't break in a future release.
      7. Create new Pull Request.
    MD
  end

  let(:destination) do
    <<~MD
      # Contributing

      ## You can help!

      Follow these instructions:

      1. Join the Discord server.
      2. Fork the repository
      3. Create your feature branch (`git checkout -b my-new-feature`)
      4. Make some fixes.
      5. Commit your changes (`git commit -am 'Added some feature'`)
      6. Push to the branch (`git push origin my-new-feature`)
      7. Make sure to add tests for it. This is important, so it doesn't break in a future release.
      8. Create new Pull Request.
      9. Announce it in the Discord channel!
    MD
  end

  def do_merge(src, dest)
    Markdown::Merge::SmartMerger.new(
      src,
      dest,
      backend: :markly,
      preference: {default: :template, markdown_list: :destination},
      add_template_only_nodes: true,
      match_refiner: Kettle::Jem::Tasks::TemplateTask::MARKDOWN_PARAGRAPH_MATCH_REFINER,
      node_typing: Kettle::Jem::Tasks::TemplateTask::MARKDOWN_LIST_NODE_TYPING,
    ).merge
  end

  it "does not duplicate the ordered list across multiple merge runs" do
    result1 = do_merge(template, destination)
    result2 = do_merge(template, result1)
    result3 = do_merge(template, result2)

    # Count how many times the first item of the template list appears.
    # Before the fix this count grew by 1 on each run.
    list_start_count = result3.scan(/^1\. /).count
    expect(list_start_count).to eq(1),
      "Expected exactly 1 ordered list in result after 3 runs, got #{list_start_count}.\n\nResult:\n#{result3}"
  end

  it "is idempotent: result of run 2 equals result of run 3" do
    result1 = do_merge(template, destination)
    result2 = do_merge(template, result1)
    result3 = do_merge(template, result2)

    expect(result3).to eq(result2),
      "Merge is not idempotent!\n\nRun 2:\n#{result2}\n\nRun 3:\n#{result3}"
  end
end
