#!/bin/bash
# Daily IaC asset graph collection (IaC security ADR-13). Run as root by logssey-iac-collector.service.
# 1. Cartography (compose service cartography) refreshes the graph with the collector role session.
# 2. The result is recorded through the dashboard on this host (frontend :8088 -> API) with the collector
#    token. A successful collection queues one graph enrichment (open paths) and one State check.
# The token never appears in a process argument: curl reads the header from a private file.
set -uo pipefail

cd "${LOGSSEY_DIR:-/opt/logssey}" || exit 1
api="${LOGSSEY_IAC_COLLECTOR_API:-http://127.0.0.1:8088}"
token_file=secrets/iac-collector/api-token
[ -s "$token_file" ] || { echo "missing $token_file (run bootstrap-iac-host.py)" >&2; exit 1; }

started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
start_seconds=$(date +%s)
if docker compose --profile iac --profile iac-collect run --rm -T cartography; then
  status=SUCCEEDED
else
  status=FAILED
fi
finished=$(date -u +%Y-%m-%dT%H:%M:%SZ)
seconds=$(( $(date +%s) - start_seconds ))

header=$(mktemp)
trap 'rm -f "$header"' EXIT
printf 'X-IaC-Collector-Token: %s\n' "$(cat "$token_file")" > "$header"
body=$(printf '{"status":"%s","startedAt":"%s","finishedAt":"%s","stats":{"durationSeconds":%d}}' \
  "$status" "$started" "$finished" "$seconds")
if ! curl -fsS --max-time 30 -o /dev/null -H @"$header" -H 'Content-Type: application/json' \
    --data "$body" "$api/api/v1/iac/jobs/collect-graph/runs"; then
  echo "collection $status in ${seconds}s, but recording it failed" >&2
  exit 1
fi
echo "collection $status in ${seconds}s, recorded"
[ "$status" = SUCCEEDED ]
