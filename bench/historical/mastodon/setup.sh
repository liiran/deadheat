# Run by bench/historical/run.sh inside the app after checkout: Mastodon reads these.
export DB_HOST=${POSTGRES_HOST:-postgres} DB_USER=postgres DB_PASS=postgres REDIS_URL=redis://redis:6379/0 DISABLE_SIMPLECOV=true
