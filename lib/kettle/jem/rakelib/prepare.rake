# frozen_string_literal: true

namespace :kettle do
  namespace :jem do
    desc "Prepare .kettle-jem.yml for templating by seeding, backfilling, and validating token values"
    task :prepare do
      Kettle::Jem::Tasks::PrepareTask.run
    end
  end
end
