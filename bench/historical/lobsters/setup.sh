# Run by bench/historical/run.sh inside the app after checkout. Lobsters' sample config is MariaDB
# (until 2026, when it moved to SQLite); point it at the compose service. Older samples have a
# password filled in; later ones name no user at all, so one is added.
if grep -q "password: localdev" config/database.yml.sample; then
  sed -e "s/host: 127.0.0.1/host: ${MYSQL_HOST:-mariadb}/" -e "s/password: localdev/password: root/" config/database.yml.sample > config/database.yml
else
  sed -e "s/host: 127.0.0.1/host: ${MYSQL_HOST:-mariadb}/" -e "s/^  adapter: trilogy$/  adapter: trilogy\n  username: root\n  password: root/" \
      -e "s/^    username: *$//" -e "s/^    password: *$//" config/database.yml.sample > config/database.yml
fi
