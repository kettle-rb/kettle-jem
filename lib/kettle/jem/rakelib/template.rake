# frozen_string_literal: true

namespace :kettle do
  namespace :jem do
    desc "Smart-merge kettle-jem template files using .kettle-jem.yml (seed the config and exit early if it is missing)"
    task :template do
      Kettle::Jem::Tasks::TemplateTask.run
    end
  end
end
