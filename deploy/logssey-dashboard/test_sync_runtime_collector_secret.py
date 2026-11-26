import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock


MODULE_PATH = Path(__file__).with_name("sync-runtime-collector-secret.py")
SPEC = importlib.util.spec_from_file_location("runtime_secret", MODULE_PATH)
runtime_secret = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runtime_secret)


class SecretClient:
    def __init__(self, token):
        self.token = token

    def get_secret_value(self, **kwargs):
        return {"SecretString": self.token}


class RuntimeCollectorSecretTest(unittest.TestCase):
    def test_applies_once_and_does_not_restart_when_unchanged(self):
        token = "a" * 64
        calls = []
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            destination = root / "logssey.runtime.collector-token"
            stamp = root / ".applied"
            runner = lambda *args, **kwargs: calls.append((args, kwargs))
            uid, gid = os.getuid(), os.getgid()

            with mock.patch.object(runtime_secret.os, "chown"), \
                    mock.patch.object(runtime_secret.os, "fchown"), \
                    mock.patch.object(runtime_secret.os, "chmod"):
                self.assertTrue(runtime_secret.synchronize(
                    SecretClient(token), "secret", destination, stamp, runner,
                    uid=uid, gid=gid, compose_directory=root,
                ))
                self.assertFalse(runtime_secret.synchronize(
                    SecretClient(token), "secret", destination, stamp, runner,
                    uid=uid, gid=gid, compose_directory=root,
                ))

            self.assertEqual(token, destination.read_text())
            self.assertEqual(2, len(calls))
            self.assertEqual(0o400, destination.stat().st_mode & 0o777)

    def test_rejects_unsafe_token(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaises(ValueError):
                runtime_secret.synchronize(
                    SecretClient("short\nheader"), "secret", root / "token", root / "stamp",
                    lambda *args, **kwargs: None, uid=os.getuid(), gid=os.getgid(),
                    compose_directory=root,
                )


if __name__ == "__main__":
    unittest.main()
