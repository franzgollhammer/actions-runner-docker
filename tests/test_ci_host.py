"""Lifecycle safety regressions; no Docker, root privileges or network required."""
import importlib.util
import json
import pathlib
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location("ci_host", pathlib.Path(__file__).parents[1] / "host/ci_host.py")
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)
OLD = "ghcr.io/example/runner@sha256:" + "a" * 64
NEW = "ghcr.io/example/runner@sha256:" + "b" * 64


class Lifecycle(unittest.TestCase):
    def setUp(self):
        self.c = host.Controller.__new__(host.Controller)
        self.c.state = {"phase": "active", "image": OLD}
        self.c.name, self.c.route, self.c.repo = "ucsl-hetzner-1", "hetzner-ci", "owner/repo"
        self.c.uid, self.c.volume = 1001, "ci-ucsl-work"
        self.c.workspace = pathlib.Path("/srv/ci-runner/workspace")
        self.c.save = Mock(side_effect=lambda **kw: self.c.state.update(kw))
        self.now = 0
        self.c.clock = lambda: self.now
        self.c.sleep = lambda seconds: setattr(self, "now", self.now + seconds)

    def runner(self, busy=False, route=False):
        return {"id": 7, "name": self.c.name, "busy": busy, "status": "online",
                "labels": [{"name": "ucsl"}] + ([{"name": "hetzner-ci"}] if route else [])}

    def test_drain_resets_idle_when_an_assigned_job_starts_late(self):
        self.c.runner = lambda: self.runner(busy=30 <= self.now < 95, route=self.now == 0)
        self.c.remove_route, self.c.workers = Mock(), Mock(return_value=False)
        self.c.drain()
        self.assertEqual(self.now, 160)  # 65 uninterrupted seconds after the job

    def test_local_worker_blocks_drain_even_when_api_says_idle(self):
        self.c.runner = lambda: self.runner()
        self.c.remove_route = Mock()
        self.c.workers = lambda: self.now < 100
        self.c.drain()
        self.assertEqual(self.now, 165)

    def test_route_must_really_disappear_before_drain_finishes(self):
        self.c.runner = lambda: self.runner(route=self.now < 20)
        self.c.remove_route, self.c.workers = Mock(), Mock(return_value=False)
        self.c.drain()
        self.assertEqual(self.now, 85)

    def test_registry_failure_does_not_drain_or_delete(self):
        self.c.resolve = Mock(side_effect=host.Error("registry unavailable"))
        self.c.drain, self.c.purge = Mock(), Mock()
        with self.assertRaises(host.Error):
            self.c.refresh()
        self.c.drain.assert_not_called()
        self.c.purge.assert_not_called()

    def test_api_failure_does_not_delete_or_change_state(self):
        self.c.resolve = Mock(return_value=NEW)
        self.c.runner = Mock(side_effect=host.Error("401"))
        self.c.purge = Mock()
        with self.assertRaises(host.Error):
            self.c.refresh()
        self.c.purge.assert_not_called()
        self.c.save.assert_not_called()

    def test_failed_new_image_repulls_previous_digest(self):
        self.c.resolve = Mock(return_value=NEW)
        self.c.runner, self.c.drain, self.c.purge = Mock(), Mock(), Mock()
        self.c.launch = Mock(side_effect=[host.Error("bad image"), None])
        self.c.refresh()
        self.assertEqual([c.args[0] for c in self.c.launch.call_args_list], [NEW, OLD])
        self.assertEqual(self.c.purge.call_count, 2)
        self.assertTrue(self.c.state["rollback"])

    def test_recovery_uses_recorded_digest_and_drains_again(self):
        self.c.state.update(phase="purging", target=NEW, previous=OLD)
        self.c.resolve = Mock(side_effect=AssertionError("must not resolve a moved tag"))
        self.c.runner, self.c.drain, self.c.purge, self.c.launch = Mock(), Mock(), Mock(), Mock()
        self.c.start()
        self.c.drain.assert_called_once()
        self.c.launch.assert_called_once_with(NEW)

    def test_recovery_has_ten_minute_backoff(self):
        self.c.state["next_retry"] = 2000
        self.c.start = Mock()
        with patch.object(host.time, "time", return_value=1500):
            self.c.recover()
        self.c.start.assert_not_called()
        with patch.object(host.time, "time", return_value=2000):
            self.c.recover()
        self.c.start.assert_called_once()

    def test_busy_worker_prevents_every_cleanup_action(self):
        self.c.workers = Mock(return_value=True)
        self.c.docker = Mock()
        with self.assertRaises(host.Error):
            self.c.purge()
        self.c.docker.assert_not_called()

    def test_purge_clears_both_engines_but_preserves_other_volumes(self):
        self.c.workers, self.c.container = Mock(return_value=False), Mock(return_value=None)
        self.c.archive, self.c.deregister, self.c.command = Mock(), Mock(), Mock()
        self.c.mounted = Mock(return_value=True)
        self.c.inventory = Mock(return_value={x: {"containers": [], "images": []} for x in ("host", "jobs")})
        def docker(engine, *args, **kwargs):
            out = "id1\nid2" if args == ("ps", "-aq") else ""
            if args[:2] == ("volume", "ls"):
                out = "database\nci-ucsl-work\nbuildx_buildkit_test_state\n"
            return subprocess.CompletedProcess([], 0, out, "")
        self.c.docker = Mock(side_effect=docker)
        self.c.purge()
        deleted = [c.args for c in self.c.docker.call_args_list if c.args[1:3] == ("volume", "rm")]
        self.assertEqual(deleted, [("jobs", "volume", "rm", "buildx_buildkit_test_state"),
                                  ("host", "volume", "rm", "buildx_buildkit_test_state"),
                                  ("host", "volume", "rm", "ci-ucsl-work")])
        for engine in ("jobs", "host"):
            self.c.docker.assert_any_call(engine, "image", "prune", "--all", "--force", timeout=600)
            self.c.docker.assert_any_call(engine, "builder", "prune", "--all", "--force", timeout=600)

    def test_bootstrap_refuses_existing_old_runner(self):
        self.c.container = Mock(return_value=None)
        self.c.docker = Mock(return_value=subprocess.CompletedProcess([], 0, "old-id", ""))
        self.c.launch = Mock()
        with self.assertRaises(host.Error):
            self.c.start()
        self.c.launch.assert_not_called()

    def test_lost_registration_recreates_container_after_drain(self):
        self.c.container = Mock(return_value={"State": {"Running": False}})
        self.c.runner = Mock(return_value=None)
        self.c.refresh, self.c.docker = Mock(), Mock()
        self.c.start()
        self.c.refresh.assert_called_once()
        self.c.docker.assert_not_called()
        self.assertEqual(self.c.state["target"], OLD)

    def test_stale_rootless_socket_recreates_instead_of_restarting_forever(self):
        self.c.container = Mock(return_value={"State": {"Running": True}})
        self.c.runner = Mock(return_value=self.runner())
        self.c.mount_workspace = Mock()
        self.c.wait_online = Mock(side_effect=host.Error("stale socket"))
        self.c.refresh = Mock()
        self.c.start()
        self.c.refresh.assert_called_once()
        self.assertEqual(self.c.state["target"], OLD)

    def test_launch_only_passes_registration_token_and_rootless_socket(self):
        self.c.api = Mock(return_value={"token": "short-lived"})
        self.c.docker, self.c.mount_workspace, self.c.wait_online = Mock(), Mock(), Mock()
        self.c.launch(NEW)
        call = next(c for c in self.c.docker.call_args_list if c.args[1] == "run")
        self.assertIn("--cgroup-parent=ci-runner.slice", call.args)
        self.assertIn("type=bind,src=/run/user/1001/docker.sock,dst=/var/run/docker.sock", call.args)
        self.assertNotIn("short-lived", " ".join(call.args))
        self.assertNotIn("ACCESS_TOKEN", call.kwargs["input_text"])
        self.assertIn("RUNNER_TOKEN=short-lived", call.kwargs["input_text"])
        self.assertIn("NO_DEFAULT_LABELS=true", call.kwargs["input_text"])
        self.assertNotIn("src=/var/run/docker.sock", " ".join(call.args))

    def test_default_self_hosted_label_is_rejected_before_exposing_route(self):
        runner = self.runner()
        runner["labels"].append({"name": "self-hosted"})
        self.c.runner = Mock(return_value=runner)
        self.c.container = Mock(return_value={"State": {"Running": True}})
        self.c.api = Mock()
        with self.assertRaises(host.Error):
            self.c.wait_online()
        self.c.api.assert_not_called()

    def test_dry_run_never_calls_a_lifecycle_mutation(self):
        self.c.guard, self.c.inventory = Mock(), Mock(return_value={})
        self.c.refresh = Mock()
        with patch("builtins.print"):
            self.c.execute("refresh", dry_run=True)
        self.c.refresh.assert_not_called()
        self.c.save.assert_not_called()

    def test_resolves_amd64_instead_of_first_platform(self):
        manifest = {"manifests": [
            {"platform": {"os": "linux", "architecture": "arm64"}, "digest": "sha256:" + "a" * 64},
            {"platform": {"os": "linux", "architecture": "amd64"}, "digest": "sha256:" + "b" * 64}]}
        self.assertEqual(host.image_digest(manifest, "ghcr.io/example/runner:latest"), NEW)

    def test_subordinate_ids_exclude_other_users_and_real_accounts(self):
        host.validate_subids("fg:100000:65536\nci-ucsl:165536:65536", [0, 1000, 1001], "ci-ucsl")
        for text, ids in [("fg:100000:65536\nci-ucsl:100000:65536", [0, 1000, 1001]),
                          ("ci-ucsl:165536:65536", [0, 1001, 165600]),
                          ("ci-ucsl:1000:65536", [0, 1001])]:
            with self.subTest(text=text, ids=ids), self.assertRaises(host.Error):
                host.validate_subids(text, ids, "ci-ucsl")

    def test_state_is_atomically_written_private(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory, "state.json")
            host.atomic_json(path, {"phase": "purging", "target": NEW})
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(json.loads(path.read_text())["target"], NEW)
            self.assertFalse(path.with_suffix(".tmp").exists())


if __name__ == "__main__":
    unittest.main()
