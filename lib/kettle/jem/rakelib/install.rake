# frozen_string_literal: true

namespace :kettle do
  namespace :jem do
    desc "Run kettle:jem:template, then perform install-time checks and setup guidance for the current project"
    task :install do
      Kettle::Jem::Tasks::InstallTask.run
    end
  end
end
