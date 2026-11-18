#!/usr/bin/python3
"""Publish one-hour sessions for the IaC security containers from the host instance role.

IaC security ADR-13. Reuses the checked helpers of publish-aws-credentials.py (session validation,
atomic file replacement, host-role-only STS client) without changing that file. Only the role list
and the session names are IaC's own, so CloudTrail shows logssey-iac-<component>.
The session file is the credential_process format (Version 1) that the containers read through
AWS_CONFIG_FILE (compose.yaml).
"""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import sys
from datetime import datetime, timezone

_SPEC = importlib.util.spec_from_file_location(
    "publisher", Path(__file__).with_name("publish-aws-credentials.py")
)
publisher = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(publisher)

# Containers that receive a session: the IaC worker and the daily Cartography collector.
COMPONENTS = ("worker", "collector")


def validate_config(config):
    if not isinstance(config, dict) or not publisher.re.fullmatch(
        r"[a-z]{2}(?:-[a-z0-9]+){1,3}-[0-9]+", config.get("region", "")
    ):
        raise ValueError("Invalid IaC credential configuration")
    for component in COMPONENTS:
        if not publisher.ROLE_ARN.fullmatch(config.get(component + "_role_arn", "")):
            raise ValueError("Invalid IaC credential configuration")
    return config


def publish(config, directory, sts):
    validate_config(config)
    now = datetime.now(timezone.utc)
    documents = {}
    # Obtain and validate every session before replacing any current file.
    for component in COMPONENTS:
        response = sts.assume_role(
            RoleArn=config[component + "_role_arn"],
            RoleSessionName="logssey-iac-" + component,
            DurationSeconds=3600,
        )
        documents[component] = publisher.session_document(response, now)
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chown(directory, 0, 0)
    os.chmod(directory, 0o700)
    for component, document in documents.items():
        publisher.write_session(directory / component, document)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default="/opt/logssey/iac-credentials.json")
    parser.add_argument("--directory", default="/opt/logssey/aws-iac")
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
            publish(config, directory, publisher.host_sts(config["region"]))
        print("Published IaC role sessions.")
        return 0
    except Exception:
        # SDK errors can contain request context. Operational errors have one safe message.
        print("IaC role credential publication failed.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
