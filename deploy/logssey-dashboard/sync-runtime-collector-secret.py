#!/usr/bin/python3
"""Synchronize the runtime collector token without exposing it in process arguments."""

import argparse
import hashlib
import logging
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


TOKEN = re.compile(r"[A-Za-z0-9._~+/=-]{32,512}")


def atomic_write(path, value, uid, gid, mode):
    path.parent.mkdir(mode=0o500, parents=True, exist_ok=True)
    os.chown(path.parent, uid, gid)
    os.chmod(path.parent, 0o500)
    descriptor, temporary = tempfile.mkstemp(prefix="." + path.name + "-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            output.write(value)
            output.flush()
            os.fsync(output.fileno())
            os.fchown(output.fileno(), uid, gid)
            os.fchmod(output.fileno(), mode)
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def synchronize(secret_client, secret_id, destination, stamp, runner, uid=10001, gid=10001,
                compose_directory=Path("/opt/logssey")):
    response = secret_client.get_secret_value(SecretId=secret_id)
    token = response.get("SecretString", "")
    if not isinstance(token, str) or TOKEN.fullmatch(token) is None:
        raise ValueError("Runtime collector secret has an invalid format")

    digest = hashlib.sha256(token.encode("utf-8")).hexdigest()
    current = destination.read_text(encoding="utf-8") if destination.exists() else None
    applied = stamp.read_text(encoding="ascii") if stamp.exists() else None
    if current == token and applied == digest:
        return False

    if current != token:
        atomic_write(destination, token, uid, gid, 0o400)

    runner(["/usr/bin/docker", "compose", "up", "-d", "--force-recreate", "api"],
           cwd=compose_directory, check=True)
    runner(["/usr/bin/docker", "compose", "restart", "frontend"],
           cwd=compose_directory, check=True)
    atomic_write(stamp, digest, 0, 0, 0o600)
    return True


def host_secrets_manager(region):
    for name in (
        "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "AWS_SECURITY_TOKEN",
        "AWS_PROFILE", "AWS_DEFAULT_PROFILE", "AWS_WEB_IDENTITY_TOKEN_FILE", "AWS_ROLE_ARN",
        "AWS_ROLE_SESSION_NAME", "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI",
        "AWS_CONTAINER_CREDENTIALS_FULL_URI", "AWS_CONTAINER_AUTHORIZATION_TOKEN",
        "AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE",
    ):
        os.environ.pop(name, None)
    os.environ["AWS_SHARED_CREDENTIALS_FILE"] = "/dev/null"
    os.environ["AWS_CONFIG_FILE"] = "/dev/null"
    os.environ["BOTO_CONFIG"] = "/dev/null"
    os.environ["AWS_EC2_METADATA_DISABLED"] = "false"
    logging.getLogger("boto3").setLevel(logging.CRITICAL)
    logging.getLogger("botocore").setLevel(logging.CRITICAL)
    import boto3
    from botocore.config import Config

    return boto3.Session(region_name=region).client(
        "secretsmanager", config=Config(connect_timeout=5, read_timeout=15, retries={"max_attempts": 3})
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--region", default="ap-northeast-1")
    parser.add_argument("--secret-id", default="logssey/dashboard/runtime/collector-token")
    parser.add_argument("--destination", default="/opt/logssey/secrets/api/logssey.runtime.collector-token")
    parser.add_argument("--stamp", default="/opt/logssey/secrets/api/.runtime-collector-token.applied")
    args = parser.parse_args()
    try:
        os.umask(0o077)
        changed = synchronize(
            host_secrets_manager(args.region), args.secret_id, Path(args.destination), Path(args.stamp),
            subprocess.run,
        )
        print("Runtime collector configuration applied." if changed else "Runtime collector configuration is current.")
        return 0
    except Exception:
        print("Runtime collector secret synchronization failed.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
