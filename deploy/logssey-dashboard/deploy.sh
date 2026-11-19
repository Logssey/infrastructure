#!/bin/bash
# Deploy one dashboard image by digest. Runs as root on the dashboard host from /opt/logssey/deploy.sh.
# GitHub Actions calls it through the SSM document logssey-dashboard-deploy (terraform deploy.tf):
#   deploy.sh api|frontend|worker sha256:<64 hex>
# Steps: lock -> (api) database dump -> new digest in .env -> pull and recreate -> health check.
# Health: api and frontend - the page and the API answer; worker (no port) - it keeps running without a restart.
# If the new image is not healthy, the previous digest goes back into .env and the script fails.
# A new image that already applied a migration may keep the old one from starting; then restore the dump.
set -euo pipefail
umask 077

DIR=${LOGSSEY_DIR:-/opt/logssey}
BACKUPS=${LOGSSEY_BACKUP_DIR:-/var/lib/logssey/backups}
KEEP_BACKUPS=${LOGSSEY_KEEP_BACKUPS:-5}
BASE_URL=${LOGSSEY_BASE_URL:-http://127.0.0.1:8088}
HEALTH_TIMEOUT=${LOGSSEY_HEALTH_TIMEOUT:-300}
WORKER_SETTLE=${LOGSSEY_WORKER_SETTLE:-60}
IAC_WORKER_SETTLE=${LOGSSEY_IAC_WORKER_SETTLE:-60}
# SSM runs without HOME; the ECR credential helper is configured in /root/.docker (host-init.sh.tftpl)
export DOCKER_CONFIG=${DOCKER_CONFIG:-/root/.docker}

service=${1:-} digest=${2:-}
# var: the .env line, container: the compose service
case $service in
  api) var=API_IMAGE container=api ;;
  frontend) var=FRONTEND_IMAGE container=frontend ;;
  worker) var=WORKER_IMAGE container=secret-worker ;;
  iac-worker) var=IAC_WORKER_IMAGE container=iac-worker ;;
  *) echo "usage: deploy.sh api|frontend|worker sha256:<digest>" >&2; exit 2 ;;
esac
[[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "invalid digest: $digest" >&2; exit 2; }

cd "$DIR"
exec 9> .deploy.lock
flock -w 900 9 || { echo "another deploy is still running" >&2; exit 1; }

current=$(sed -n "s/^$var=//p" .env)
[[ $current =~ ^[^@[:space:]]+@sha256:[0-9a-f]{64}$ ]] || { echo "$var in .env is not pinned by digest: $current" >&2; exit 1; }
new="${current%@*}@$digest"
if [ "$current" = "$new" ]; then
  echo "$service already runs $digest"
  exit 0
fi

record() { printf '%s %s %s %s\n' "$(date -u +%FT%TZ)" "$service" "$digest" "$1" >> deploy.log; }

healthy() {
  if [ "$service" = worker ]; then worker_healthy; return; fi
  if [ "$service" = iac-worker ]; then
    sleep "$IAC_WORKER_SETTLE"
    local id state
    id=$(docker compose ps -q "$container") && [ -n "$id" ] || return 1
    state=$(docker inspect -f '{{.State.Running}} {{.RestartCount}}' "$id") || return 1
    echo "iac worker after ${IAC_WORKER_SETTLE}s: running/restarts = $state"
    [ "$state" = "true 0" ]
    return
  fi
  # the page and the API (through nginx) both answer
  local deadline=$((SECONDS + HEALTH_TIMEOUT))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if curl -fsS -o /dev/null --max-time 5 "$BASE_URL/" &&
       curl -fsS -o /dev/null --max-time 5 "$BASE_URL/api/v1/auth/options"; then
      return 0
    fi
    sleep 5
  done
  return 1
}

# The worker has no port. It is healthy when, after WORKER_SETTLE seconds, it still runs without a restart
# (a bad setting stops it and Docker restarts it) and it has written a heartbeat to the DB since it started
# (without the DB it keeps running and only logs errors). Heartbeats: Secret operations, secret_worker_heartbeats.
worker_healthy() {
  sleep "$WORKER_SETTLE"
  local id state started beats
  id=$(docker compose ps -q "$container") && [ -n "$id" ] || return 1
  state=$(docker inspect -f '{{.State.Running}} {{.RestartCount}}' "$id") || return 1
  started=$(docker inspect -f '{{.State.StartedAt}}' "$id") || return 1
  beats=$(docker compose exec -T db psql -U postgres -d logssey -tAc \
    "SELECT count(*) FROM secret_worker_heartbeats WHERE last_heartbeat_at >= '$started'::timestamptz") || beats=0
  echo "worker after ${WORKER_SETTLE}s: running/restarts = $state, heartbeats since start = $beats"
  [ "$state" = "true 0" ] && [ "${beats:-0}" -gt 0 ]
}

recreate() {
  docker compose up -d "$container" || return 1
  # nginx resolves "api" once at startup (proxy_pass http://api:8080); restart it to reach the new container
  if [ "$service" = api ]; then docker compose restart frontend || return 1; fi
}

dump=
if [ "$service" = api ]; then
  install -d -m 0700 "$BACKUPS"
  dump="$BACKUPS/logssey-$(date -u +%Y%m%dT%H%M%SZ).dump"
  docker compose exec -T db pg_dump -U postgres -d logssey -Fc > "$dump.part"
  mv "$dump.part" "$dump"
  echo "database dump: $dump ($(du -h "$dump" | cut -f1))"
  ls -1t "$BACKUPS"/logssey-*.dump | tail -n +"$((KEEP_BACKUPS + 1))" | xargs -r rm -f --
fi

sed -i "s|^$var=.*|$var=$new|" .env
echo "$var: $current -> $new"
if docker compose pull --quiet "$container" && recreate && healthy; then
  record deployed
  echo "deployed $service $digest"
  exit 0
fi

echo "new $service is not healthy; last log lines:" >&2
docker compose logs --no-color --tail 60 "$container" >&2 || true
sed -i "s|^$var=.*|$var=$current|" .env
if [ "$service" = iac-worker ] && [[ "$current" =~ @sha256:0{64}$ ]]; then
  docker compose rm -sf "$container" >/dev/null 2>&1 || true
  record rolled-back
  echo "removed failed initial iac worker; existing services were not changed" >&2
  exit 1
fi
if recreate && healthy; then
  record rolled-back
  echo "rolled back to $current" >&2
else
  record rollback-failed
  echo "rollback did not become healthy either." >&2
  [ -n "$dump" ] && echo "if a migration was applied, restore the database from $dump (README)" >&2
fi
exit 1
