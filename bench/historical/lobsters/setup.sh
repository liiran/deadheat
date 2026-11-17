# Run by bench/historical/run.sh inside the app after checkout. Lobsters' sample config is MariaDB
# (until 2026, when it moved to SQLite); point it at the compose service.
sed "s/host: 127.0.0.1/host: ${MYSQL_HOST:-mariadb}/; s/password: localdev/password: root/" config/database.yml.sample > config/database.yml
