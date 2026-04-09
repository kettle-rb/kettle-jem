# frozen_string_literal: true

module Kettle
  module Jem
    # Generates framework matrix CI workflow YAML from .kettle-jem.yml config.
    #
    # When `workflows.preset` is "framework", this class reads the
    # `framework_matrix` config and produces a GHA workflow with a
    # `ruby × framework_version` matrix strategy, including the correct
    # gemfile references for each version.
    #
    # @example
    #   generator = FrameworkWorkflowGenerator.new(
    #     template_content: File.read("template/.github/workflows/framework-ci.yml.example"),
    #     helpers: Kettle::Jem::TemplateHelpers,
    #   )
    #   yaml_content = generator.generate
    class FrameworkWorkflowGenerator
      # @param template_content [String] base workflow template YAML
      # @param helpers [Module] TemplateHelpers for config access
      def initialize(template_content:, helpers:)
        @template = template_content
        @helpers = helpers
      end

      # Generate the framework matrix workflow YAML.
      # Returns nil if framework matrix is not configured.
      #
      # @return [String, nil] populated workflow YAML or nil
      def generate
        return unless @helpers.framework_matrix?

        fmc = @helpers.framework_matrix_config
        dimension = fmc["dimension"]
        versions = fmc["versions"]
        pattern = fmc["gemfile_pattern"]

        parsed = Psych.safe_load(@template, permitted_classes: [Symbol])
        return unless parsed.is_a?(Hash)

        # Update workflow name to include dimension
        parsed["name"] = "#{dimension.capitalize} CI"

        # Update the matrix
        jobs = parsed["jobs"]
        return unless jobs.is_a?(Hash)

        job = jobs.values.first
        return unless job.is_a?(Hash)

        strategy = job["strategy"] ||= {}
        matrix = strategy["matrix"] ||= {}

        # Build include entries for framework_version × gemfile mapping
        includes = versions.map do |version|
          gemfile = @helpers.expand_gemfile_pattern(pattern, version)
          {
            "framework_version" => version,
            "gemfile" => gemfile_path(gemfile),
          }
        end

        matrix["include"] = includes

        # Remove placeholder keys
        matrix.delete("framework_version")
        matrix.delete("gemfile")

        # Update job name to use dimension
        job["name"] = "Specs ${{ matrix.ruby }}@${{ matrix.framework_version }}"

        # Update test step name
        update_test_step_name(job, dimension)

        Psych.dump(parsed, line_width: -1).sub(/\A---\n?/, "")
      end

      private

      # Determine the gemfile path format based on the pattern.
      # If pattern doesn't include a directory separator, prepend gemfiles/
      #
      # @param gemfile [String] expanded gemfile name
      # @return [String] full gemfile path for BUNDLE_GEMFILE
      def gemfile_path(gemfile)
        if gemfile.include?("/")
          gemfile
        else
          "gemfiles/#{gemfile}"
        end
      end

      # Update the test step name to include the dimension.
      def update_test_step_name(job, dimension)
        steps = job["steps"]
        return unless steps.is_a?(Array)

        steps.each do |step|
          next unless step.is_a?(Hash)

          if step["name"]&.include?("framework_version")
            step["name"] = step["name"]
              .gsub("framework_version", dimension)
          end
        end
      end
    end
  end
end
