import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch
from datetime import datetime, timedelta, timezone


SPEC = importlib.util.spec_from_file_location(
    "iac_publisher", Path(__file__).with_name("publish-iac-credentials.py")
)
iac = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(iac)


class IacCredentialPublisherTest(unittest.TestCase):
    def setUp(self):
        self.config = {
            "region": "ap-northeast-1",
            "worker_role_arn": "arn:aws:iam::123456789012:role/example-iac-worker",
        }
        self.expiration = datetime.now(timezone.utc) + timedelta(hours=1)
        # write_session (shared helper) changes ownership to the container user 10001
        self.chown = self.enterContext(patch.object(iac.os, "chown", create=True))
        self.enterContext(patch.object(iac.os, "fchown", create=True))
        self.enterContext(patch.object(iac.os, "chmod"))
        self.fchmod = self.enterContext(patch.object(iac.os, "fchmod", create=True))

    def response(self):
        return {"Credentials": {
            "AccessKeyId": "iac-access",
            "SecretAccessKey": "iac-credential",
            "SessionToken": "iac-session",
            "Expiration": self.expiration,
        }}

    def test_worker_session_is_named_for_iac_and_readable_by_the_container_only(self):
        sts = Mock()
        sts.assume_role.return_value = self.response()
        with tempfile.TemporaryDirectory() as folder:
            with patch.object(iac.publisher, "sync_directory"):
                iac.publish(self.config, Path(folder), sts)
            value = json.loads((Path(folder) / "worker" / "credentials.json").read_text())
            self.assertEqual(value["Version"], 1)
            self.assertEqual(value["AccessKeyId"], "iac-access")
            self.chown.assert_any_call(Path(folder) / "worker", 10001, 10001)
            self.assertTrue(all(call.args[1] == 0o400 for call in self.fchmod.call_args_list))
        sts.assume_role.assert_called_once_with(
            RoleArn=self.config["worker_role_arn"], RoleSessionName="logssey-iac-worker", DurationSeconds=3600
        )

    def test_failure_keeps_the_previous_file(self):
        sts = Mock()
        sts.assume_role.side_effect = RuntimeError("unavailable")
        with tempfile.TemporaryDirectory() as folder:
            directory = Path(folder) / "worker"
            directory.mkdir()
            (directory / "credentials.json").write_text("previous")
            with self.assertRaises(RuntimeError):
                iac.publish(self.config, Path(folder), sts)
            self.assertEqual((directory / "credentials.json").read_text(), "previous")

    def test_rejects_missing_or_malformed_role(self):
        for config in ({"region": "ap-northeast-1"},
                       {"region": "ap-northeast-1", "worker_role_arn": "not-an-arn"},
                       {"region": "nowhere", "worker_role_arn": self.config["worker_role_arn"]}):
            with self.assertRaises(ValueError):
                iac.validate_config(config)


if __name__ == "__main__":
    unittest.main()
