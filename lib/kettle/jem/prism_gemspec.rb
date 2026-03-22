# frozen_string_literal: true

module Kettle
  module Jem
    # Prism helpers for gemspec manipulation.
    module PrismGemspec
      autoload :DependencyEntryPolicy, "kettle/jem/prism_gemspec/dependency_entry_policy"
      autoload :DependencyRemovalPolicy, "kettle/jem/prism_gemspec/dependency_removal_policy"
      autoload :DependencySectionPolicy, "kettle/jem/prism_gemspec/dependency_section_policy"
      autoload :DevelopmentDependencySyncPolicy, "kettle/jem/prism_gemspec/development_dependency_sync_policy"
      autoload :EmojiPolicy, "kettle/jem/prism_gemspec/emoji_policy"
      autoload :FieldAssignmentPolicy, "kettle/jem/prism_gemspec/field_assignment_policy"
      autoload :GemspecContextPolicy, "kettle/jem/prism_gemspec/gemspec_context_policy"
      autoload :HarmonizationPolicy, "kettle/jem/prism_gemspec/harmonization_policy"
      autoload :LiteralDirAssignmentPolicy, "kettle/jem/prism_gemspec/literal_dir_assignment_policy"
      autoload :MergeRuntimePolicy, "kettle/jem/prism_gemspec/merge_runtime_policy"
      autoload :StructuralEditPolicy, "kettle/jem/prism_gemspec/structural_edit_policy"
      autoload :VersionLoaderPolicy, "kettle/jem/prism_gemspec/version_loader_policy"

      module_function
      extend DependencyEntryPolicy
      extend DependencyRemovalPolicy
      extend GemspecContextPolicy
      extend DevelopmentDependencySyncPolicy
      extend EmojiPolicy
      extend FieldAssignmentPolicy
      extend HarmonizationPolicy
      extend LiteralDirAssignmentPolicy
      extend MergeRuntimePolicy
      extend StructuralEditPolicy
      extend VersionLoaderPolicy
    end
  end
end
