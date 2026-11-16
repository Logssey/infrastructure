import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
from datetime import datetime, timedelta, timezone


SPEC = importlib.util.spec_from_file_location(
    "publisher", Path(__file__).with_name("publish-aws-credentials.py")
)
publisher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(publisher)


class CredentialPublisherTest(unittest.TestCase):
    def setUp(self):
        self.config = {
            "region": "ap-northeast-1",
            "api_role_arn": "arn:aws:iam::123456789012:role/example-api",
            "worker_role_arn": "arn:aws:iam::123456789012:role/example-worker",
        }
        self.expiration = datetime.now(timezone.utc) + timedelta(hours=1)
        self.chown = self.enterContext(patch.object(publisher.os, "chown", create=True))
        self.enterContext(patch.object(publisher.os, "fchown", create=True))
        self.chmod = self.enterContext(patch.object(publisher.os, "chmod"))
        self.fchmod = self.enterContext(patch.object(publisher.os, "fchmod", create=True))

    def response(self, component):
        return {"Credentials": {
            "AccessKeyId": component + "-access",
            "SecretAccessKey": component + "-credential",
            "SessionToken": component + "-session",
            "Expiration": self.expiration,
        }}

    def test_api_and_worker_have_distinct_sessions(self):
        sts = Mock()
        sts.assume_role.side_effect = [self.response("api"), self.response("worker")]
        with tempfile.TemporaryDirectory() as folder:
            with patch.object(publisher, "sync_directory"):
                publisher.publish(self.config, Path(folder), sts)
            for component in ("api", "worker"):
                value = json.loads((Path(folder) / component / "credentials.json").read_text())
                self.assertEqual(value["Version"], 1)
                self.assertEqual(value["AccessKeyId"], component + "-access")
                self.assertTrue(value["Expiration"].endswith("Z"))
                self.chown.assert_any_call(Path(folder) / component, 10001, 10001)
                self.chmod.assert_any_call(Path(folder) / component, 0o500)
            self.assertEqual(sts.assume_role.call_count, 2)
            self.assertEqual(sts.assume_role.call_args.kwargs["DurationSeconds"], 3600)
            self.assertEqual(self.fchmod.call_count, 2)
            self.assertTrue(all(call.args[1] == 0o400 for call in self.fchmod.call_args_list))

    def test_assumption_failure_keeps_both_previous_files(self):
        sts = Mock()
        sts.assume_role.side_effect = [self.response("api"), RuntimeError("unavailable")]
        with tempfile.TemporaryDirectory() as folder:
            for component in ("api", "worker"):
                directory = Path(folder) / component
                directory.mkdir()
                (directory / "credentials.json").write_text("previous")
            with self.assertRaises(RuntimeError):
                publisher.publish(self.config, Path(folder), sts)
            for component in ("api", "worker"):
                self.assertEqual(
                    (Path(folder) / component / "credentials.json").read_text(), "previous"
                )

    def test_rejects_expired_or_long_term_credentials(self):
        now = datetime.now(timezone.utc)
        response = self.response("api")
        response["Credentials"]["Expiration"] = now - timedelta(seconds=1)
        with self.assertRaises(ValueError):
            publisher.session_document(response, now)
        response = self.response("api")
        del response["Credentials"]["SessionToken"]
        with self.assertRaises(ValueError):
            publisher.session_document(response, now)

    def test_failed_atomic_replace_keeps_previous_file_and_cleans_temporary(self):
        with tempfile.TemporaryDirectory() as folder:
            directory = Path(folder)
            current = directory / "credentials.json"
            current.write_text("previous")
            with patch.object(publisher.os, "replace", side_effect=OSError("unavailable")) as replace:
                with self.assertRaises(OSError):
                    publisher.write_session(directory, {"Version": 1})
                replace.assert_called_once()
            self.assertEqual(current.read_text(), "previous")
            self.assertEqual(list(directory.glob(".credentials-*")), [])

    def test_rejects_using_one_role_for_both_components(self):
        self.config["worker_role_arn"] = self.config["api_role_arn"]
        with self.assertRaises(ValueError):
            publisher.validate_config(self.config)

    def test_host_session_does_not_inherit_operator_credentials(self):
        session = Mock()
        boto3 = SimpleNamespace(Session=Mock(return_value=session))
        config = SimpleNamespace(Config=Mock(return_value="configuration"))
        with patch.dict(publisher.os.environ, {
            "AWS_ACCESS_KEY_ID": "operator-access",
            "AWS_SECRET_ACCESS_KEY": "operator-credential",
            "AWS_PROFILE": "operator",
            "AWS_WEB_IDENTITY_TOKEN_FILE": "/operator/token",
            "AWS_CONTAINER_CREDENTIALS_FULL_URI": "http://localhost/operator",
        }), patch.dict(publisher.sys.modules, {"boto3": boto3, "botocore.config": config}):
            publisher.host_sts("ap-northeast-1")
            for key in (
                "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_PROFILE",
                "AWS_WEB_IDENTITY_TOKEN_FILE", "AWS_CONTAINER_CREDENTIALS_FULL_URI",
            ):
                self.assertNotIn(key, publisher.os.environ)
            self.assertEqual(publisher.os.environ["AWS_CONFIG_FILE"], "/dev/null")
            self.assertEqual(publisher.os.environ["AWS_SHARED_CREDENTIALS_FILE"], "/dev/null")
            boto3.Session.assert_called_once_with(region_name="ap-northeast-1")


if __name__ == "__main__":
    unittest.main()
