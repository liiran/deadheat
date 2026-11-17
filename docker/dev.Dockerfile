# The environment Dead Heat is developed and tested in: Ruby plus the client libraries for
# PostgreSQL, MySQL and SQLite. The databases themselves run as their own services (compose.yaml).
FROM ruby:3.4-slim

RUN apt-get update -qq \
 && apt-get install -y --no-install-recommends \
      build-essential git curl pkg-config \
      libpq-dev postgresql-client \
      default-libmysqlclient-dev libssl-dev \
      libsqlite3-dev sqlite3 \
      libyaml-dev zlib1g-dev \
 && rm -rf /var/lib/apt/lists/*

ENV BUNDLE_JOBS=8 \
    BUNDLE_RETRY=3 \
    LANG=C.UTF-8

WORKDIR /deadheat
