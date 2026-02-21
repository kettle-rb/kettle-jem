# frozen_string_literal: true

namespace :kettle do
  namespace :jem do
    desc "Install kettle-jem GitHub automation and setup hints into the current project"
    task :install do
      Kettle::Jem::Tasks::InstallTask.run
    end
  end
end
