# frozen_string_literal: true

namespace :kettle do
  namespace :jem do
    desc "Template kettle-jem files into the current project"
    task :template do
      Kettle::Jem::Tasks::TemplateTask.run
    end
  end
end
