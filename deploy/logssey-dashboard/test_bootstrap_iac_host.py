import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
import unittest.mock

HERE = Path(__file__).parent


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


iac = load("bootstrap_iac", HERE / "bootstrap-iac-host.py")
# The Compliance bootstrap patches the same host files in place (dashboard-backend repository, if checked out next to this one)
COMPLIANCE = HERE.parents[2] / "dashboard-backend" / "deploy" / "bootstrap-compliance-host.py"


class BootstrapIacHostTest(unittest.TestCase):
    def setUp(self):
        self.compose = (HERE / "compose.yaml").read_text(encoding="utf-8")
        self.deploy = (HERE / "deploy.sh").read_text(encoding="utf-8")

    def test_repository_files_already_hold_the_iac_additions(self):
        # this folder's compose.yaml and deploy.sh are what the bootstrap produces on a fresh host
        self.assertEqual(iac.patch_compose(self.compose), self.compose)
        self.assertEqual(iac.patch_deploy_script(self.deploy), self.deploy)

    def test_patches_only_add_lines_and_run_once(self):
        for patch, text in ((iac.patch_compose, self.compose), (iac.patch_deploy_script, self.deploy)):
            original = strip_iac(text)
            patched = patch(original)
            self.assertEqual(patch(patched), patched, "running again changes nothing")
            removed = set(original.splitlines()) - set(patched.splitlines())
            self.assertEqual(removed, set(), "no existing line is removed or changed")

    @unittest.skipUnless(COMPLIANCE.is_file(), "dashboard-backend is not checked out next to this repository")
    def test_works_on_a_host_already_patched_for_compliance(self):
        compliance = load("bootstrap_compliance", COMPLIANCE)
        host_compose = compliance.patch_compose(strip_iac(self.compose))
        host_deploy = compliance.patch_deploy_script(strip_iac(self.deploy))
        compose = iac.patch_compose(host_compose)
        deploy = iac.patch_deploy_script(host_deploy)
        self.assertIn("  compliance-worker:\n", compose)
        self.assertIn("compliance-worker) var=COMPLIANCE_WORKER_IMAGE", deploy)
        self.assertIn(iac.DEPLOY_CASE, deploy)
        with tempfile.NamedTemporaryFile("w", suffix=".sh") as script:
            script.write(deploy)
            script.flush()
            subprocess.run(["bash", "-n", script.name], check=True)

    def test_session_directory_is_created_for_the_credentials_service(self):
        with tempfile.TemporaryDirectory() as folder, \
                unittest.mock.patch.object(iac.os, "chown") as chown:
            directory = iac.ensure_session_directory(Path(folder))
            self.assertTrue(directory.is_dir())
            self.assertEqual(directory.stat().st_mode & 0o777, 0o700)
            chown.assert_called_once_with(directory, 0, 0)
            iac.ensure_session_directory(Path(folder))  # already there: no error

    def test_env_keeps_an_existing_image(self):
        self.assertEqual(iac.set_env("A=1\nIAC_WORKER_IMAGE=x@sha256:1\n", "IAC_WORKER_IMAGE", "y"),
                         "A=1\nIAC_WORKER_IMAGE=x@sha256:1\n")
        self.assertEqual(iac.set_env("A=1\n", "IAC_WORKER_IMAGE", "y"), "A=1\nIAC_WORKER_IMAGE=y\n")


def strip_iac(text):
    """The file as it was before the IaC additions."""
    for block in (iac.COMPOSE_SERVICE + "\n", iac.DEPLOY_SETTLE, iac.DEPLOY_CASE, iac.DEPLOY_HEALTH,
                  iac.DEPLOY_FIRST_ROLLBACK):
        text = text.replace(block, "", 1)
    return text


if __name__ == "__main__":
    unittest.main()
