#!/usr/bin/python3
"""Add the IaC security worker to the dashboard host in place (IaC security ADR-13).

The host compose.yaml and deploy.sh may hold other solutions' changes that are not in this repository
(the Compliance worker bootstrap patches them in place), so they are never overwritten. This script
only adds the iac-worker service, its deploy case and its health check, keeps a backup of every file it
changes, and checks the result with `bash -n` and `docker compose config`. Running it again changes nothing.

Run once on the host from /opt/logssey as root, after copying the IaC files of this folder there:
    python3 bootstrap-iac-host.py
The same functions produce this folder's compose.yaml and deploy.sh (test_bootstrap_iac_host.py).
"""

import argparse
import datetime as dt
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import tempfile

PLACEHOLDER_IMAGE = "iac-worker-not-configured@sha256:" + "0" * 64

COMPOSE_SERVICE = """\
  # IaC security worker (dashboard-backend iac-worker, Dockerfile --target iac-worker; IaC security ADR-13).
  # No web port. Talks to the DB as logssey_iac (iac-db-role.sh) and, read only, to AWS.
  # Profile "iac": plain `docker compose up -d` and the other services' commands never start or need it,
  # and the default image keeps the file valid before IAC_WORKER_IMAGE is in .env. deploy.sh iac-worker starts it.
  iac-worker:
    profiles: [iac]
    image: ${IAC_WORKER_IMAGE:-iac-worker-not-configured}
    user: "10001:10001"
    read_only: true
    cap_drop: [ALL]
    security_opt: [no-new-privileges:true]
    init: true
    restart: unless-stopped
    stop_grace_period: 30s
    mem_limit: 512m
    pids_limit: 128
    depends_on:
      db: {condition: service_healthy}
    environment:
      AWS_CONFIG_FILE: /run/aws-config/config
    volumes:
      - type: bind
        source: ./iac-worker.properties
        target: /run/config/application.properties
        read_only: true
      - type: bind
        source: ./secrets/iac-worker
        target: /run/secrets
        read_only: true
      - type: bind
        source: ./aws-iac/worker
        target: /run/aws
        read_only: true
      - type: bind
        source: ./iac-worker.aws-config
        target: /run/aws-config/config
        read_only: true
    tmpfs: ["/tmp:rw,noexec,nosuid,size=64m,uid=10001,gid=10001,mode=0700"]
    networks: [backend]
    logging:
      driver: json-file
      options: {max-size: 10m, max-file: "3"}
"""

# Asset graph (IaC security ADR-13). Same image as the former in-cluster graph (gitops iac/graph/neo4j.yaml).
# Only on the internal network, no host port. Bolt only (HTTP off). Data on the data EBS (daily snapshots);
# the graph is collected again every day, so it holds nothing that cannot be rebuilt.
# Read-only root: the entrypoint writes its settings into conf/, so conf/, logs, run and /tmp are tmpfs
# (/tmp needs exec for the JNA native library). The health check is a TCP probe, not a JVM client.
GRAPH_SERVICE = """\
  # IaC security asset graph (Neo4j; IaC security ADR-13). Only iac-worker (and the collector) reach it.
  neo4j:
    profiles: [iac]
    image: neo4j:5.26.30-community@sha256:3388e05ee53c8313d01acdf33e63ad175af95a92226dc8551160564439ce2c8c
    user: "7474:7474"
    read_only: true
    cap_drop: [ALL]
    security_opt: [no-new-privileges:true]
    restart: unless-stopped
    stop_grace_period: 60s
    mem_limit: 1g
    pids_limit: 256
    environment:
      NEO4J_AUTH_FILE: /run/secrets/neo4j-auth
      NEO4J_server_memory_heap_initial__size: 512m
      NEO4J_server_memory_heap_max__size: 512m
      NEO4J_server_memory_pagecache_size: 256m
      NEO4J_server_http_enabled: "false"
      NEO4J_server_https_enabled: "false"
      NEO4J_dbms_usage__report_enabled: "false"
    volumes:
      - /var/lib/logssey/neo4j:/data
      - ./secrets/neo4j:/run/secrets:ro
    tmpfs:
      - "/tmp:rw,exec,nosuid,size=64m,uid=7474,gid=7474"
      - "/logs:rw,noexec,nosuid,size=64m,uid=7474,gid=7474"
      - "/var/lib/neo4j/run:rw,noexec,nosuid,size=8m,uid=7474,gid=7474"
      - "/var/lib/neo4j/conf:rw,noexec,nosuid,size=8m,uid=7474,gid=7474"
    healthcheck:
      test: ["CMD", "bash", "-c", ":> /dev/tcp/127.0.0.1/7687"]
      interval: 30s
      timeout: 5s
      retries: 10
      start_period: 60s
    networks: [backend]
    logging:
      driver: json-file
      options: {max-size: 10m, max-file: "3"}
"""

DEPLOY_CASE = "  iac-worker) var=IAC_WORKER_IMAGE container=iac-worker ;;\n"
DEPLOY_SETTLE = "IAC_WORKER_SETTLE=${LOGSSEY_IAC_WORKER_SETTLE:-60}\n"
# No heartbeat table: healthy when it keeps running without a restart (a bad setting or DB login stops it)
DEPLOY_HEALTH = (
    "  if [ \"$service\" = iac-worker ]; then\n"
    "    sleep \"$IAC_WORKER_SETTLE\"\n"
    "    local id state\n"
    "    id=$(docker compose ps -q \"$container\") && [ -n \"$id\" ] || return 1\n"
    "    state=$(docker inspect -f '{{.State.Running}} {{.RestartCount}}' \"$id\") || return 1\n"
    "    echo \"iac worker after ${IAC_WORKER_SETTLE}s: running/restarts = $state\"\n"
    "    [ \"$state\" = \"true 0\" ]\n"
    "    return\n"
    "  fi\n"
)
# The first deploy has no previous image to go back to: stop the new container and leave the rest as it was
DEPLOY_FIRST_ROLLBACK = (
    "if [ \"$service\" = iac-worker ] && [[ \"$current\" =~ @sha256:0{64}$ ]]; then\n"
    "  docker compose rm -sf \"$container\" >/dev/null 2>&1 || true\n"
    "  record rolled-back\n"
    "  echo \"removed failed initial iac worker; existing services were not changed\" >&2\n"
    "  exit 1\n"
    "fi\n"
)


def replace_once(text, old, new, what):
    if text.count(old) != 1:
        raise RuntimeError(f"deploy.sh: {what} was not found exactly once")
    return text.replace(old, new)


def patch_compose(text):
    """Add each IaC service that is not there yet (a host bootstrapped before the graph step gets only neo4j)."""
    marker = "\nnetworks:\n"
    for name, block in (("iac-worker", COMPOSE_SERVICE), ("neo4j", GRAPH_SERVICE)):
        if f"\n  {name}:\n" in text:
            continue
        if text.count(marker) != 1:
            raise RuntimeError("compose: top-level networks section was not found exactly once")
        text = text.replace(marker, "\n" + block + marker)
    return text


def patch_deploy_script(text):
    if DEPLOY_CASE in text:
        return text
    text = replace_once(text, "WORKER_SETTLE=${LOGSSEY_WORKER_SETTLE:-60}\n",
                        "WORKER_SETTLE=${LOGSSEY_WORKER_SETTLE:-60}\n" + DEPLOY_SETTLE, "settle settings")
    text = replace_once(text, "  worker) var=WORKER_IMAGE container=secret-worker ;;\n",
                        "  worker) var=WORKER_IMAGE container=secret-worker ;;\n" + DEPLOY_CASE, "service case")
    text = replace_once(text, "  if [ \"$service\" = worker ]; then worker_healthy; return; fi\n",
                        "  if [ \"$service\" = worker ]; then worker_healthy; return; fi\n" + DEPLOY_HEALTH,
                        "health function")
    # up, pull and ps name the service, which starts a profile-gated service without --profile
    text = replace_once(text, "if recreate && healthy; then\n  record rolled-back\n",
                        DEPLOY_FIRST_ROLLBACK + "if recreate && healthy; then\n  record rolled-back\n", "rollback")
    return text


def set_env(text, key, value):
    lines = text.splitlines()
    if any(line.startswith(key + "=") for line in lines):
        return text
    return text.rstrip("\n") + f"\n{key}={value}\n"


def ensure_session_directory(root):
    """aws-iac/ must exist before logssey-iac-credentials.service starts: its ReadWritePaths fails otherwise (226/NAMESPACE)."""
    directory = root / "aws-iac"
    directory.mkdir(mode=0o700, exist_ok=True)
    os.chown(directory, 0, 0)
    os.chmod(directory, 0o700)
    return directory


def ensure_graph_files(root, data):
    """Neo4j data folder and one generated password, written for Neo4j (7474) and for the worker (10001).

    An existing password is kept: Neo4j sets it only when the data folder is first initialised.
    """
    data.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chown(data, 7474, 7474)
    os.chmod(data, 0o700)
    graph_secrets = root / "secrets" / "neo4j"
    worker_secrets = root / "secrets" / "iac-worker"
    for directory, uid in ((graph_secrets, 7474), (worker_secrets, 10001)):
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chown(directory, uid, uid)
        os.chmod(directory, 0o500)
    auth = graph_secrets / "neo4j-auth"
    if auth.exists():
        password = auth.read_text(encoding="utf-8").split("/", 1)[1]
    else:
        password = secrets.token_urlsafe(32)
        write_secret(auth, "neo4j/" + password, 7474)
    write_secret(worker_secrets / "logssey.iac.graph.password", password, 10001)


def write_secret(path, value, uid):
    atomic_write(path, value, 0o400)
    os.chown(path, uid, uid)


def atomic_write(path, text, mode):
    descriptor, temporary = tempfile.mkstemp(prefix="." + path.name + "-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            output.write(text)
            output.flush()
            os.fsync(output.fileno())
            os.fchmod(output.fileno(), mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=os.environ.get("LOGSSEY_DIR", "/opt/logssey"))
    parser.add_argument("--graph-data", default="/var/lib/logssey/neo4j", help="Neo4j data folder (data EBS)")
    args = parser.parse_args()
    if os.geteuid() != 0:
        raise SystemExit("run as root")
    root = Path(args.root).resolve()
    compose, deploy, env_file = root / "compose.yaml", root / "deploy.sh", root / ".env"
    for path in (compose, deploy, env_file, root / "iac-worker.properties", root / "iac-worker.aws-config"):
        if not path.is_file():
            raise SystemExit(f"missing required file: {path}")

    stamp = dt.datetime.now(dt.UTC).strftime("%Y%m%dT%H%M%SZ")
    for path in (compose, deploy, env_file):
        shutil.copy2(path, path.with_name(f"{path.name}.bak-{stamp}"))

    ensure_session_directory(root)
    ensure_graph_files(root, Path(args.graph_data))
    atomic_write(env_file, set_env(env_file.read_text(encoding="utf-8"), "IAC_WORKER_IMAGE", PLACEHOLDER_IMAGE), 0o600)
    atomic_write(compose, patch_compose(compose.read_text(encoding="utf-8")), 0o644)
    atomic_write(deploy, patch_deploy_script(deploy.read_text(encoding="utf-8")), 0o755)

    subprocess.run(["bash", "-n", str(deploy)], check=True)
    subprocess.run(["docker", "compose", "--profile", "iac", "-f", str(compose), "config", "--quiet"], cwd=root, check=True)
    print(f"IaC worker host configuration prepared (backups *.bak-{stamp}); the worker and the graph are not started.")


if __name__ == "__main__":
    main()
