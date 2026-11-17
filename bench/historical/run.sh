#!/bin/sh
# Runs one of Dead Heat's race tests against a real app at one commit, inside the dev container:
#
#   docker compose run --rm -e MYSQL_HOST=mariadb dev sh bench/historical/run.sh lobsters 7cc3c14ed spec/races/origin_race_spec.rb
#
# It checks the app out at that commit (bench/apps/<app>, cloned earlier), adds the deadheat gem,
# copies the race test(s) from bench/historical/<app>/ into the app, installs gems, loads the schema
# into the test database, runs the race test and prints its last lines.
set -e
app=$1
commit=$2
spec=$3
dir=/deadheat/bench/apps/$app
cd "$dir"
git checkout -q -- . && git clean -qfd spec/races test/races 2>/dev/null || true
git checkout -q "$commit"
printf '\ngroup :test do\n  gem "deadheat", path: "/deadheat"\nend\n' >> Gemfile
mkdir -p "$(dirname "$spec")"
cp /deadheat/bench/historical/"$app"/*_race_spec.rb "$(dirname "$spec")"/ 2>/dev/null || true
cp /deadheat/bench/historical/"$app"/*_race_test.rb "$(dirname "$spec")"/ 2>/dev/null || true
bundle install --quiet
RAILS_ENV=test bin/rails db:drop db:create db:schema:load >/dev/null 2>&1 || RAILS_ENV=test bin/rails db:create db:schema:load >/dev/null
echo "== $app at $(git log -1 --format='%h %s' | cut -c1-80)"
case "$spec" in
  spec/*) bundle exec rspec "$spec" 2>&1 | grep -v "^\s*#" | grep -E "Race:|No race|^  [✗!~✓]|examples?,|Reproduce" || true ;;
  *) bin/rails test "$spec" 2>&1 | grep -E "Race:|No race|^  [✗!~✓]|runs?,|Reproduce" || true ;;
esac
