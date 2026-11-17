#!/bin/bash
# IaC security worker DB role (IaC security ADR-13). Run once on the dashboard host from /opt/logssey as root,
# after the API has applied the IaC migrations (V11, V12) and before the iac-worker starts:
#   ./iac-db-role.sh
# Creates logssey_iac (login, not the schema owner) with only the table rights the worker uses.
# The password is read from secrets/iac-worker/spring.datasource.password (create it first, 0400, owner 10001).
# Safe to run again: it updates the password and re-applies the same grants.
# New IaC tables in later migrations need a matching GRANT here (and a re-run).
set -euo pipefail
cd "${LOGSSEY_DIR:-/opt/logssey}"
pw_file=secrets/iac-worker/spring.datasource.password
[ -s "$pw_file" ] || { echo "missing $pw_file" >&2; exit 1; }
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U postgres -d logssey --set=pw="$(cat "$pw_file")" <<'SQL'
SELECT format('CREATE ROLE logssey_iac LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT PASSWORD %L', :'pw')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'logssey_iac') \gexec
ALTER ROLE logssey_iac LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT PASSWORD :'pw';

GRANT CONNECT ON DATABASE logssey TO logssey_iac;
GRANT USAGE ON SCHEMA public TO logssey_iac;

-- Reference data: read only
GRANT SELECT ON iac_rules, iac_repos, iac_data_assets TO logssey_iac;
-- Job queue and runs: the API inserts, the worker leases and finishes them
GRANT SELECT, UPDATE ON iac_jobs, iac_runs TO logssey_iac;
-- Redacted plans: the worker reads and deletes them after analysis (SR-5)
GRANT SELECT, DELETE ON iac_plan_payloads TO logssey_iac;
-- Results
GRANT SELECT, INSERT, UPDATE ON iac_findings, iac_attack_paths TO logssey_iac;
GRANT SELECT, INSERT, DELETE ON iac_run_path_changes TO logssey_iac;
-- Audit: append only
GRANT INSERT ON iac_audit_events TO logssey_iac;
-- Identity columns of the tables the worker inserts into
GRANT USAGE ON SEQUENCE iac_findings_finding_id_seq, iac_attack_paths_path_id_seq,
                       iac_run_path_changes_change_id_seq, iac_audit_events_audit_id_seq TO logssey_iac;
SQL
echo "logssey_iac ready"
