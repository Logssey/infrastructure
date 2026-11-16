#!/usr/bin/python3
"""Publish separate one-hour workload sessions from the host instance role."""

import argparse
import json
import logging
import os
from pathlib import Path
import re
import sys
import tempfile
from datetime import datetime, timedelta, timezone


ROLE_ARN = re.compile(r"^arn:[a-z0-9-]+:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]+$")


def validate_config(config):
    if not isinstance(config, dict) or not re.fullmatch(
        r"[a-z]{2}(?:-[a-z0-9]+){1,3}-[0-9]+", config.get("region", "")
    ):
        raise ValueError("Invalid source credential configuration")
    for component in ("api", "worker"):
        if not ROLE_ARN.fullmatch(config.get(component + "_role_arn", "")):
            raise ValueError("Invalid source credential configuration")
    if config["api_role_arn"] == config["worker_role_arn"]:
        raise ValueError("Source roles must be distinct")
    return config


def session_document(response, now):
    credentials = response.get("Credentials", {})
    for key in ("AccessKeyId", "SecretAccessKey", "SessionToken"):
        if not isinstance(credentials.get(key), str) or not credentials[key].strip():
            raise ValueError("Incomplete temporary session")
    expiration = credentials.get("Expiration")
    if not isinstance(expiration, datetime) or expiration.tzinfo is None:
        raise ValueError("Temporary session expiry is missing")
    if expiration <= now + timedelta(minutes=15):
        raise ValueError("Temporary session expires too soon")
    return {
        "Version": 1,
        "AccessKeyId": credentials["AccessKeyId"],
        "SecretAccessKey": credentials["SecretAccessKey"],
        "SessionToken": credentials["SessionToken"],
        "Expiration": expiration.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
    }


def sync_directory(directory):
    descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def write_session(directory, document):
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chown(directory, 10001, 10001)
    os.chmod(directory, 0o500)
    descriptor, temporary = tempfile.mkstemp(prefix=".credentials-", dir=directory)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            json.dump(document, output, separators=(",", ":"))
            output.flush()
            os.fsync(output.fileno())
            os.fchown(output.fileno(), 10001, 10001)
            os.fchmod(output.fileno(), 0o400)
        os.replace(temporary, directory / "credentials.json")
        sync_directory(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def publish(config, directory, sts):
    validate_config(config)
    now = datetime.now(timezone.utc)
    documents = {}
    # Obtain and validate both sessions before replacing either current file.
    for component in ("api", "worker"):
        response = sts.assume_role(
            RoleArn=config[component + "_role_arn"],
            RoleSessionName="logssey-secret-" + component,
            DurationSeconds=3600,
        )
        documents[component] = session_document(response, now)
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chown(directory, 0, 0)
    os.chmod(directory, 0o700)
    for component, document in documents.items():
        write_session(directory / component, document)


def host_sts(region):
    # A systemd service starts a fresh process. Clear alternative SDK providers so
    # an operator's profile, environment or web identity cannot replace the host role.
    for name in (
        "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN",
        "AWS_SECURITY_TOKEN", "AWS_PROFILE", "AWS_DEFAULT_PROFILE",
        "AWS_WEB_IDENTITY_TOKEN_FILE", "AWS_ROLE_ARN", "AWS_ROLE_SESSION_NAME",
        "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI", "AWS_CONTAINER_CREDENTIALS_FULL_URI",
        "AWS_CONTAINER_AUTHORIZATION_TOKEN", "AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE",
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
        "sts", config=Config(connect_timeout=5, read_timeout=15, retries={"max_attempts": 3})
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default="/opt/logssey/source-credentials.json")
    parser.add_argument("--directory", default="/opt/logssey/aws")
    args = parser.parse_args()
    try:
        import fcntl

        os.umask(0o077)
        directory = Path(args.directory)
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        with (directory / ".publisher.lock").open("w") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            with Path(args.config).open(encoding="utf-8") as source:
                config = validate_config(json.load(source))
            publish(config, directory, host_sts(config["region"]))
        print("Published API and worker role sessions.")
        return 0
    except Exception:
        # SDK errors can contain request context. Operational errors have one safe message.
        print("AWS role credential publication failed.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
