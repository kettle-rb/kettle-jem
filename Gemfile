# frozen_string_literal: true

source "https://gem.coop"

git_source(:codeberg) { |repo_name| "https://codeberg.org/#{repo_name}" }
git_source(:gitlab) { |repo_name| "https://gitlab.com/#{repo_name}" }

# Specify your gem's dependencies in kettle-jem.gemspec
gemspec

# Templating (env-switched: KETTLE_RB_DEV=true for local paths)
eval_gemfile "gemfiles/modular/templating.gemfile"

eval_gemfile "gemfiles/modular/debug.gemfile"

# Code Coverage (env-switched: KETTLE_RB_DEV=true for local paths)
eval_gemfile "gemfiles/modular/coverage.gemfile"

eval_gemfile "gemfiles/modular/style.gemfile"
eval_gemfile "gemfiles/modular/documentation.gemfile"
eval_gemfile "gemfiles/modular/optional.gemfile"
eval_gemfile "gemfiles/modular/x_std_libs.gemfile"
