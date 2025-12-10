# frozen_string_literal: true

module Kettle
  module Jem
    # Classifier helpers for AST-aware section typing.
    #
    # These classifiers work with `Ast::Merge::SectionTyping` to identify
    # logical sections within parsed AST nodes.
    #
    # @example Creating an Appraisals block classifier
    #   classifier = Classifiers::AppraisalBlock.new
    #   sections = classifier.classify_all(prism_tree.statements.body)
    #
    # @see Ast::Merge::SectionTyping
    module Classifiers
      autoload :AppraisalBlock, "kettle/jem/classifiers/appraisal_block"
      autoload :GemGroup, "kettle/jem/classifiers/gem_group"
      autoload :GemCall, "kettle/jem/classifiers/gem_call"
      autoload :SourceCall, "kettle/jem/classifiers/source_call"
      autoload :MethodDef, "kettle/jem/classifiers/method_def"
    end
  end
end
