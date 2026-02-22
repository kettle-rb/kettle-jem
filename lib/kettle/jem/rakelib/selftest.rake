# frozen_string_literal: true

namespace :kettle do
  namespace :jem do
    desc "Self-test: template kettle-jem against itself and compare results"
    task :selftest do
      Kettle::Jem::Tasks::SelfTestTask.run
    end
  end
end
