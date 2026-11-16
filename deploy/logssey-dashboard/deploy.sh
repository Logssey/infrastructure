#!/bin/bash
# Deploy one dashboard image by digest. Runs as root on the dashboard host from /opt/logssey/deploy.sh.
# GitHub Actions calls it through the SSM document logssey-dashboard-deploy (terraform deploy.tf):
#   deploy.sh api|frontend sha256:<64 hex>
# Steps: lock -> (api) database dump -> new digest in .env -> pull and recreate -> health check.
# If the site does not become healthy, the previous digest goes back into .env and the script fails.
# A new image that already applied a migration may keep the old one from starting; then restore the dump.
set -euo pipefail
umask 077

DIR=${LOGSSEY_DIR:-/opt/logssey}
BACKUPS=${LOGSSEY_BACKUP_DIR:-/var/lib/logssey/backups}
KEEP_BACKUPS=${LOGSSEY_KEEP_BACKUPS:-5}
BASE_URL=${LOGSSEY_BASE_URL:-http://127.0.0.1:8088}
HEALTH_TIMEOUT=${LOGSSEY_HEALTH_TIMEOUT:-300}
# SSM runs without HOME; the ECR credential helper is configured in /root/.docker (host-init.sh.tftpl)
export DOCKER_CONFIG=${DOCKER_CONFIG:-/root/.docker}

service=${1:-} digest=${2:-}
case $service in
  api) var=API_IMAGE ;;
  frontend) var=FRONTEND_IMAGE ;;
  *) echo "usage: deploy.sh api|frontend sha256:<digest>" >&2; exit 2 ;;
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

healthy() {   # the page and the API (through nginx) both answer
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

recreate() {
  docker compose up -d "$service" || return 1
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
if docker compose pull --quiet "$service" && recreate && healthy; then
  record deployed
  echo "deployed $service $digest"
  exit 0
fi

echo "new $service did not become healthy within ${HEALTH_TIMEOUT}s; last log lines:" >&2
docker compose logs --no-color --tail 60 "$service" >&2 || true
sed -i "s|^$var=.*|$var=$current|" .env
if recreate && healthy; then
  record rolled-back
  echo "rolled back to $current" >&2
else
  record rollback-failed
  echo "rollback did not become healthy either." >&2
  [ -n "$dump" ] && echo "if a migration was applied, restore the database from $dump (README)" >&2
fi
exit 1
