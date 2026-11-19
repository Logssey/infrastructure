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

    def test_a_host_bootstrapped_before_the_graph_step_gets_only_the_graph(self):
        without_graph = self.compose.replace(iac.GRAPH_SERVICE + "\n", "", 1)
        self.assertIn("\n  iac-worker:\n", without_graph)
        self.assertNotIn("\n  neo4j:\n", without_graph)
        patched = iac.patch_compose(without_graph)
        self.assertEqual(patched.count("\n  iac-worker:\n"), 1)
        self.assertEqual(patched.count("\n  neo4j:\n"), 1)

    def test_graph_password_is_shared_and_kept(self):
        with tempfile.TemporaryDirectory() as folder, \
                unittest.mock.patch.object(iac.os, "chown"), unittest.mock.patch.object(iac.os, "fchmod"), \
                unittest.mock.patch.object(iac.os, "chmod"):  # root on the host; here keep folders writable
            root, data = Path(folder), Path(folder) / "neo4j-data"
            iac.ensure_graph_files(root, data)
            auth = (root / "secrets/neo4j/neo4j-auth").read_text()
            worker = (root / "secrets/iac-worker/logssey.iac.graph.password").read_text()
            self.assertEqual(auth, "neo4j/" + worker)
            self.assertGreaterEqual(len(worker), 40)
            self.assertTrue(data.is_dir())
            (root / "secrets/iac-worker/logssey.iac.graph.password").unlink()
            iac.ensure_graph_files(root, data)  # again: the existing password stays
            self.assertEqual((root / "secrets/neo4j/neo4j-auth").read_text(), auth)
            self.assertEqual((root / "secrets/iac-worker/logssey.iac.graph.password").read_text(), worker)

    def test_a_host_bootstrapped_before_the_collection_step_gets_only_the_collector(self):
        without_collector = self.compose.replace(iac.COLLECTOR_SERVICE + "\n", "", 1)
        self.assertNotIn("\n  cartography:\n", without_collector)
        patched = iac.patch_compose(without_collector)
        for name in ("iac-worker", "neo4j", "cartography"):
            self.assertEqual(patched.count(f"\n  {name}:\n"), 1)

    def test_collector_gets_the_graph_password_and_one_kept_token_for_the_api(self):
        with tempfile.TemporaryDirectory() as folder, \
                unittest.mock.patch.object(iac.os, "chown") as chown, unittest.mock.patch.object(iac.os, "fchmod"), \
                unittest.mock.patch.object(iac.os, "chmod"):
            root = Path(folder)
            (root / "secrets/api").mkdir(parents=True)
            iac.ensure_collector_files(root, "graph-password")
            self.assertEqual((root / "secrets/cartography/neo4j-password").read_text(), "graph-password")
            token = (root / "secrets/iac-collector/api-token").read_text()
            self.assertGreaterEqual(len(token), 32)  # the API rejects shorter tokens
            self.assertEqual((root / "secrets/api/logssey.iac.collector-token").read_text(), token)
            chown.assert_any_call(root / "secrets/iac-collector/api-token", 0, 0)
            chown.assert_any_call(root / "secrets/api/logssey.iac.collector-token", 10001, 10001)
            iac.ensure_collector_files(root, "graph-password")  # again: the token stays
            self.assertEqual((root / "secrets/api/logssey.iac.collector-token").read_text(), token)

    def test_collector_needs_the_existing_api_secrets_folder(self):
        with tempfile.TemporaryDirectory() as folder, \
                unittest.mock.patch.object(iac.os, "chown"), unittest.mock.patch.object(iac.os, "fchmod"), \
                unittest.mock.patch.object(iac.os, "chmod"):
            with self.assertRaises(SystemExit):
                iac.ensure_collector_files(Path(folder), "graph-password")
            self.assertFalse((Path(folder) / "secrets/api").exists(), "the API folder is never created here")

    def test_placeholder_names_the_real_repository_so_deploy_sh_can_pull(self):
        registry = "123456789012.dkr.ecr.ap-northeast-1.amazonaws.com"
        env = f"API_IMAGE={registry}/logssey/dashboard-api@sha256:{'a' * 64}\n"
        expected = f"IAC_WORKER_IMAGE={registry}/logssey/dashboard-iac-worker@sha256:{'0' * 64}"
        self.assertIn(expected, iac.set_iac_image(env))
        # the unpullable value from the first bootstrap is corrected
        old = env + "IAC_WORKER_IMAGE=" + iac.OLD_PLACEHOLDER + "\n"
        self.assertEqual(iac.set_iac_image(old), env + expected + "\n")
        # a deployed image is never touched
        deployed = env + f"IAC_WORKER_IMAGE={registry}/logssey/dashboard-iac-worker@sha256:{'b' * 64}\n"
        self.assertEqual(iac.set_iac_image(deployed), deployed)
        with self.assertRaises(RuntimeError):
            iac.set_iac_image("FRONTEND_IMAGE=x\n")

    def test_env_keeps_an_existing_image(self):
        self.assertEqual(iac.set_env("A=1\nIAC_WORKER_IMAGE=x@sha256:1\n", "IAC_WORKER_IMAGE", "y"),
                         "A=1\nIAC_WORKER_IMAGE=x@sha256:1\n")
        self.assertEqual(iac.set_env("A=1\n", "IAC_WORKER_IMAGE", "y"), "A=1\nIAC_WORKER_IMAGE=y\n")


def strip_iac(text):
    """The file as it was before the IaC additions."""
    for block in (iac.COMPOSE_SERVICE + "\n", iac.GRAPH_SERVICE + "\n", iac.COLLECTOR_SERVICE + "\n", iac.DEPLOY_SETTLE, iac.DEPLOY_CASE, iac.DEPLOY_HEALTH,
                  iac.DEPLOY_FIRST_ROLLBACK):
        text = text.replace(block, "", 1)
    return text


if __name__ == "__main__":
    unittest.main()
