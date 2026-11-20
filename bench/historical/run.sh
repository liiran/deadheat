#!/bin/sh
# Runs one of Dead Heat's race tests against a real app at one commit, inside the dev container:
#
#   docker compose run --rm -e MYSQL_HOST=mariadb dev sh bench/historical/run.sh lobsters 7cc3c14ed spec/races/origin_race_spec.rb
#
# With "sweep" in place of the race test, it sweeps the whole app instead:
#
#   docker compose run --rm -e MYSQL_HOST=mariadb dev sh bench/historical/run.sh lobsters 7cc3c14ed sweep
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
if [ -f /deadheat/bench/historical/"$app"/setup.sh ]; then . /deadheat/bench/historical/"$app"/setup.sh; fi
printf '\ngroup :test do\n  gem "deadheat", path: "/deadheat"\nend\n' >> Gemfile
mkdir -p "$(dirname "$spec")"
cp /deadheat/bench/historical/"$app"/*_race_spec.rb "$(dirname "$spec")"/ 2>/dev/null || true
cp /deadheat/bench/historical/"$app"/*_race_test.rb "$(dirname "$spec")"/ 2>/dev/null || true
bundle install --quiet
# A fresh test database. Some commits have a second database with no schema file yet; for those,
# only the main schema is loaded.
RAILS_ENV=test bin/rails db:drop >/dev/null 2>&1 || true
RAILS_ENV=test bin/rails db:create >/dev/null 2>&1
RAILS_ENV=test bin/rails db:schema:load >/dev/null 2>&1 || {
  RAILS_ENV=test bin/rails db:drop db:create >/dev/null 2>&1
  RAILS_ENV=test bin/rails db:schema:load:primary >/dev/null
}
# A commit whose schema file lags behind its newest migration: bring the test database up to date.
RAILS_ENV=test bin/rails db:migrate >/dev/null 2>&1 || true
echo "== $app at $(git log -1 --format='%h %s' | cut -c1-80)"
rm -rf tmp/deadheat/runs
if [ "$spec" = "sweep" ]; then
  # The whole app, with no race test: every write request its request specs make, sent twice.
  bundle exec deadheat sweep --no-tests 2>&1 | grep -E "^Found|^Checked|races? found|No races found" || true
  exit 0
fi
case "$spec" in
  spec/*) bundle exec rspec "$spec" 2>&1 | grep -v "^\s*#" | grep -E "Race:|^  [✗!~✓]|examples?,|Reproduce" || true ;;
  *) bin/rails test "$spec" 2>&1 | grep -E "Race:|^  [✗!~✓]|runs?,|Reproduce" || true ;;
esac
# A passing race test prints nothing, so say what every try did, from the result it saved.
ruby /deadheat/bench/historical/summary.rb tmp/deadheat
