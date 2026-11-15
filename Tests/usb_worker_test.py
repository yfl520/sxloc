"""Offline protocol/lifecycle tests. Every device API is replaced before execution."""
import asyncio
import importlib.util
import io
import sys
import unittest
from contextlib import ExitStack
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock, patch

worker_path = Path(__file__).resolve().parents[1] / "Bridge/UsbWorker/worker.py"
spec = importlib.util.spec_from_file_location("usb_worker", worker_path)
module = importlib.util.module_from_spec(spec)
original_stdout = sys.stdout
spec.loader.exec_module(module)
sys.stdout = original_stdout
module.PROTOCOL = io.StringIO()


class Context:
    def __init__(self, value=None):
        self.value = value if value is not None else self
        self.closed = False

    async def __aenter__(self):
        return self.value

    async def __aexit__(self, *args):
        self.closed = True


class WorkerTests(unittest.IsolatedAsyncioTestCase):
    def fixture(self, version="27.0", developer=True):
        self.patches = ExitStack()
        self.addCleanup(self.patches.close)
        lockdown = SimpleNamespace(
            product_version=version, all_values={"DeviceName": "离线测试手机"},
            close=AsyncMock(), get_developer_mode_status=AsyncMock(return_value=developer))
        location = SimpleNamespace(set=AsyncMock(), clear=AsyncMock())
        provider = SimpleNamespace(service=SimpleNamespace(address=("::1", 123)),
                                   open_connection=None, auxiliary_metadata={})
        tunnel = Context(provider)
        for name, value in {
            "list_devices": AsyncMock(return_value=[SimpleNamespace(is_usb=True, serial="test-phone")]),
            "create_using_usbmux": AsyncMock(return_value=lockdown),
            "UserspaceRsdTunnel": Mock(return_value=tunnel),
            "DvtProvider": Mock(side_effect=lambda _: Context()),
            "LocationSimulation": Mock(side_effect=lambda _: Context(location)),
            "DtSimulateLocation": Mock(return_value=location),
            "RemoteServiceDiscoveryService": Mock(side_effect=lambda *a, **k: Context(provider)),
        }.items():
            self.patches.enter_context(patch.object(module, name, value))
        worker = module.Worker()
        worker.set_target(dict(latitude=31.2, longitude=121.4, revision=1))
        return worker, lockdown, location, tunnel

    async def until(self, predicate):
        async with asyncio.timeout(2):
            while not predicate():
                await asyncio.sleep(0)

    def test_version_boundaries(self):
        for version, expected in [("12.5.7", "legacy"), ("15.8", "legacy"),
                                  ("16.7.12", "legacy"), ("17.0", "remote"),
                                  ("17.3.1", "remote"), ("17.4", "usb"),
                                  ("18.7", "usb"), ("26.1", "usb"), ("27.0", "usb")]:
            with self.subTest(version=version):
                self.assertEqual(module.compatibility(version)[0], expected)

    async def test_reuses_session_and_stops_for_each_version(self):
        for version in ("15.8", "16.7", "17.2", "17.4", "18.7", "26.1", "27.0"):
            with self.subTest(version=version):
                worker, lockdown, location, tunnel = self.fixture(version)
                await worker.connect("test-phone")
                await self.until(lambda: worker.state["lastRevision"] == 1)
                worker.set_target(dict(latitude=39.9, longitude=116.4, revision=2))
                await self.until(lambda: worker.state["lastRevision"] == 2)
                self.assertEqual(location.set.await_args.args, (39.9, 116.4))
                if module.compatibility(version)[0] != "legacy":
                    module.UserspaceRsdTunnel.assert_called_once_with(
                        serial="test-phone", autopair=False,
                        remotepairing_fallback=version == "17.2")
                await worker.stop()
                self.assertEqual(worker.state["phase"], "idle")
                self.assertTrue(worker.state["clearRequested"])
                location.clear.assert_awaited_once()
                lockdown.close.assert_awaited_once()
                count = location.set.await_count
                worker.set_target(dict(latitude=1, longitude=2, revision=3))
                await asyncio.sleep(0)
                self.assertEqual(location.set.await_count, count)
                self.patches.close()

    async def test_immediate_cancel_never_connects(self):
        worker, _, location, _ = self.fixture()
        await worker.connect("test-phone")
        await worker.stop()
        self.assertEqual(worker.state["phase"], "idle")
        location.set.assert_not_awaited()

    async def test_cancel_while_pairing_releases_session(self):
        worker, _, location, _ = self.fixture()
        entered = asyncio.Event()

        async def pairing(**kwargs):
            entered.set()
            await asyncio.Event().wait()

        module.create_using_usbmux.side_effect = pairing
        await worker.connect("test-phone")
        await entered.wait()
        await worker.stop()
        self.assertEqual(worker.state["phase"], "idle")
        location.set.assert_not_awaited()

    async def test_cancel_during_write_still_requests_clear(self):
        worker, _, location, _ = self.fixture()
        entered = asyncio.Event()

        async def blocked_set(*args):
            entered.set()
            await asyncio.Event().wait()

        location.set.side_effect = blocked_set
        await worker.connect("test-phone")
        await entered.wait()
        await worker.stop()
        location.clear.assert_awaited_once()
        self.assertTrue(worker.state["clearRequested"])

    async def test_clear_failure_remains_visible_after_dismiss(self):
        worker, _, location, _ = self.fixture()
        await worker.connect("test-phone")
        await self.until(lambda: worker.state["lastRevision"] == 1)
        location.clear.side_effect = ConnectionError()
        await worker.stop()
        self.assertFalse(worker.state["clearRequested"])
        self.assertIsNotNone(worker.state["restoreWarning"])
        await worker.dispatch("clearError", {})
        self.assertIsNotNone(worker.state["restoreWarning"])

    async def test_stop_during_error_cleanup_does_not_cancel_clear(self):
        worker, lockdown, location, _ = self.fixture()
        entered = asyncio.Event()
        released = asyncio.Event()

        async def slow_clear():
            entered.set()
            await released.wait()

        location.set.side_effect = ConnectionError()
        location.clear.side_effect = slow_clear
        await worker.connect("test-phone")
        await entered.wait()
        stopping = asyncio.create_task(worker.stop())
        await asyncio.sleep(0)
        released.set()
        await stopping
        self.assertTrue(worker.state["clearRequested"])
        lockdown.close.assert_awaited_once()

    async def test_developer_mode_required_only_since_16(self):
        worker, lockdown, location, _ = self.fixture("16.7", developer=False)
        await worker.connect("test-phone")
        await worker.session
        self.assertEqual(worker.state["phase"], "error")
        self.assertIn("开发者模式", worker.state["error"])
        location.set.assert_not_awaited()
        lockdown.close.assert_awaited_once()

    async def test_stale_target_cannot_replace_latest_revision(self):
        worker, _, _, _ = self.fixture()
        worker.set_target(dict(latitude=1, longitude=2, revision=3))
        worker.set_target(dict(latitude=4, longitude=5, revision=2))
        self.assertEqual(worker.target, dict(latitude=1, longitude=2, revision=3))

    async def test_dismiss_stopped_record_clears_completion_fields(self):
        worker, _, _, _ = self.fixture()
        await worker.connect("test-phone")
        await self.until(lambda: worker.state["lastRevision"] == 1)
        await worker.stop()
        await worker.dispatch("clearError", {})
        self.assertFalse(worker.state["clearRequested"])
        self.assertIsNone(worker.state["lastRevision"])
        self.assertEqual(worker.state["label"], "")

    async def test_never_selects_network_only_or_other_device(self):
        worker, _, location, _ = self.fixture()
        module.list_devices.return_value = [SimpleNamespace(is_usb=False, serial="test-phone"),
                                           SimpleNamespace(is_usb=True, serial="other-phone")]
        await worker.connect("test-phone")
        await worker.session
        self.assertEqual(worker.state["phase"], "error")
        module.create_using_usbmux.assert_not_awaited()
        location.set.assert_not_awaited()

    async def test_reveal_only_sends_reveal_action_and_closes_connection(self):
        worker, lockdown, location, _ = self.fixture("27.0", developer=False)
        amfi = Mock()
        amfi.reveal_developer_mode_option_in_ui = AsyncMock()
        with patch.object(module, "AmfiService", return_value=amfi):
            result = await worker.dispatch("revealDeveloperMode", {"udid": "test-phone"})
        self.assertIn("手机已确认显示入口", result["message"])
        amfi.reveal_developer_mode_option_in_ui.assert_awaited_once()
        amfi.enable_developer_mode.assert_not_called()
        amfi.enable_developer_mode_post_restart.assert_not_called()
        lockdown.close.assert_awaited_once()
        self.assertIsNone(worker.session)
        location.set.assert_not_awaited()

    async def test_reveal_not_needed_when_old_system_or_already_enabled(self):
        for version, developer in [("15.8", False), ("16.7", True), ("27.0", True)]:
            with self.subTest(version=version):
                worker, lockdown, _, _ = self.fixture(version, developer)
                with patch.object(module, "AmfiService") as amfi:
                    result = await worker.reveal_developer_mode("test-phone")
                self.assertIn("直接连接", result["message"])
                amfi.assert_not_called()
                lockdown.close.assert_awaited_once()
                self.patches.close()

    async def test_reveal_rejected_by_phone_reports_failure_and_closes(self):
        worker, lockdown, _, _ = self.fixture("27.0", developer=False)
        amfi = SimpleNamespace(reveal_developer_mode_option_in_ui=AsyncMock(side_effect=RuntimeError()))
        with patch.object(module, "AmfiService", return_value=amfi):
            with self.assertRaisesRegex(module.UserError, "未确认"):
                await worker.reveal_developer_mode("test-phone")
        lockdown.close.assert_awaited_once()

    async def test_reveal_rejects_missing_usb_or_active_session(self):
        worker, _, _, _ = self.fixture()
        module.list_devices.return_value = [SimpleNamespace(is_usb=False, serial="test-phone")]
        with patch.object(module, "AmfiService") as amfi:
            with self.assertRaisesRegex(module.UserError, "已断开"):
                await worker.reveal_developer_mode("test-phone")
            module.create_using_usbmux.assert_not_awaited()
            worker.session = asyncio.create_task(asyncio.sleep(5))
            try:
                with self.assertRaisesRegex(module.UserError, "先停止"):
                    await worker.reveal_developer_mode("test-phone")
            finally:
                worker.session.cancel()
                await asyncio.gather(worker.session, return_exceptions=True)
            amfi.assert_not_called()

    async def test_legacy_missing_image_prepares_before_retry(self):
        worker, lockdown, location, _ = self.fixture("15.8")
        location.set.side_effect = [module.InvalidServiceError("missing", "test-phone", "15.8"), None]
        worker.mount = AsyncMock()
        await worker.connect("test-phone")
        await self.until(lambda: worker.state["lastRevision"] == 1)
        worker.mount.assert_awaited_once_with(lockdown)
        await worker.stop()

    async def test_modern_mount_uses_rsd_and_refreshes_services(self):
        worker, lockdown, _, tunnel = self.fixture()

        class MissingService(Context):
            async def __aenter__(self):
                raise module.InvalidServiceError("missing", "test-phone", "27.0")

        module.DvtProvider.side_effect = [MissingService(), Context()]
        worker.mount = AsyncMock()
        await worker.connect("test-phone")
        await self.until(lambda: worker.state["lastRevision"] == 1)
        worker.mount.assert_awaited_once_with(tunnel.value)
        self.assertIsNot(worker.mount.await_args.args[0], lockdown)
        module.RemoteServiceDiscoveryService.assert_called_once()
        await worker.stop()


if __name__ == "__main__":
    unittest.main(verbosity=2)
