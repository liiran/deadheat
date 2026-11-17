#!/bin/sh
# Runs the gift card race test against Spree at one commit, on PostgreSQL:
#
#   docker compose run --rm dev sh bench/historical/spree/run.sh <commit>
#
# Spree is a monorepo: the code under test is spree/core, and its specs run against a dummy app that
# `rake test_app` generates. bench/apps/spree must hold the commit (git fetch --depth 1 origin <sha>).
set -e
commit=$1
export DB=postgres DB_HOST=${POSTGRES_HOST:-postgres} DB_USERNAME=postgres DB_PASSWORD=postgres
cd /deadheat/bench/apps/spree
git checkout -q -- . && git clean -qfd spree/core/spec/races spree/core/spec/dummy 2>/dev/null || true
git checkout -q "$commit"
printf '\ngem "deadheat", path: "/deadheat"\n' >> spree/common_spree_dependencies.rb
(cd spree && bundle install --quiet)
cd spree/core
mkdir -p spec/races
cp /deadheat/bench/historical/spree/gift_card_race_spec.rb spec/races/
bundle install --quiet
bundle exec rake test_app >/tmp/spree_test_app.log 2>&1 || { tail -20 /tmp/spree_test_app.log; exit 1; }
echo "== spree at $(git log -1 --format='%h %s' | cut -c1-80)"
bundle exec rspec spec/races/gift_card_race_spec.rb 2>&1 | grep -v "^\s*#" | grep -E "Race:|No race|^ *[✗!~✓] |examples?,|Reproduce" || true
