#!/bin/bash
# Runs once when the data directory is empty. Creates the schema-owner role (not a superuser) and the database.
set -euo pipefail
pw="$(cat /run/secrets/logssey-password)"
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --set=pw="$pw" <<'SQL'
CREATE ROLE logssey LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD :'pw';
CREATE DATABASE logssey OWNER logssey;
SQL