"""Private JSON-lines worker. Importing this module never contacts a device."""
import asyncio
import contextlib
import json
import math
import sys
import threading
import subprocess
from pathlib import Path
from datetime import datetime, timezone

# Third-party progress/log output must never enter the protocol pipe.
for stream in (sys.stdin, sys.stdout, sys.stderr):
    if hasattr(stream, "reconfigure"):
        stream.reconfigure(encoding="utf-8", errors="replace")
PROTOCOL = sys.stdout
sys.stdout = sys.stderr

from packaging.version import Version
from pymobiledevice3.exceptions import AlreadyMountedError, InvalidServiceError, StartServiceError
from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.remote.userspace_tunnel import UserspaceRsdTunnel
from pymobiledevice3.remote.remote_service_discovery import RemoteServiceDiscoveryService
from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation
from pymobiledevice3.services.mobile_image_mounter import (
    auto_mount, uses_cryptex_image, DeveloperDiskImageMounter, PersonalizedImageMounter,
)
from pymobiledevice3.services.simulate_location import DtSimulateLocation
from pymobiledevice3.services.amfi import AmfiService
from pymobiledevice3.usbmux import list_devices


def emit(value):
    PROTOCOL.write(json.dumps(value, ensure_ascii=False, allow_nan=False) + "\n")
    PROTOCOL.flush()


def compatibility(version):
    v = Version(version)
    if v < Version("17.0"):
        return "legacy", "传统开发者定位 · USB"
    if v < Version("17.4"):
        return "remote", "DVT 定位 · USB 配对，需手机与电脑同一局域网"
    return "usb", "DVT 定位 · USB 隧道"


def chinese_error(error):
    name = type(error).__name__
    if isinstance(error, UserError):
        return str(error)
    if isinstance(error, (TimeoutError, asyncio.TimeoutError)):
        return "设备响应超时，请检查连接、解锁与信任状态后重试。"
    if "Pairing" in name or "NotPaired" in name or "Password" in name or "Locked" in name:
        return "请解锁手机，在手机上选择“信任此电脑”，然后重新连接。"
    if "DeveloperMode" in name:
        return "请在手机“设置 → 隐私与安全性”中开启开发者模式，按手机提示完成后重新连接。"
    if "Device" in name or isinstance(error, (ConnectionError, OSError, EOFError)):
        return "无法与 Apple 设备通信，请检查 USB 数据线及 Apple Devices／iTunes 设备服务。"
    if "Tunnel" in name or "Bonjour" in name:
        return "开发者隧道连接失败。iOS 17.0–17.3 还需手机与电脑处于同一局域网。"
    if "Image" in name or "Mount" in name or "Download" in name or "HTTP" in name:
        return "开发者镜像准备失败，请检查网络及该 iOS 版本的镜像支持后重试。"
    if isinstance(error, (InvalidServiceError, StartServiceError)):
        return "开发者定位服务不可用，请确认已开启开发者模式，且系统版本有对应开发者镜像。"
    return f"开发者定位操作失败（{name}），请重新连接；该系统版本可能需要更新兼容组件。"


class UserError(Exception):
    pass


class Worker:
    def __init__(self):
        self.state = dict(phase="idle", status="尚未连接", error=None, label="", ios="",
                          udid="", transport="", lastRevision=None, updatedAt=None,
                          updates=0, restoreWarning=None, clearRequested=False)
        self.target = None
        self.wake = asyncio.Event()
        self.session = None
        self.cleaning = False
        self.cancel_issued = False

    def publish(self, **values):
        self.state.update(values)
        emit(dict(event="state", state=self.state))

    async def devices(self):
        devices = await asyncio.wait_for(list_devices(), 8)
        result = []
        for device in devices[:16]:
            if not device.is_usb:
                continue
            entry = dict(udid=device.serial, name="Apple 设备", ios="", detail="连接后读取系统版本")
            lockdown = None
            try:
                # Listing may read existing pairing, but must not trigger a trust dialog.
                lockdown = await asyncio.wait_for(create_using_usbmux(
                    serial=device.serial, connection_type="USB", autopair=False), 4)
                entry.update(name=lockdown.all_values.get("DeviceName", "Apple 设备"),
                             ios=lockdown.product_version,
                             detail=compatibility(lockdown.product_version)[1])
            except Exception:
                entry["detail"] = "请解锁并信任此电脑，再点击连接"
            finally:
                if lockdown is not None:
                    with contextlib.suppress(Exception):
                        await asyncio.wait_for(lockdown.close(), 2)
            result.append(entry)
        return result

    def set_target(self, target):
        lat, lon = float(target["latitude"]), float(target["longitude"])
        revision = int(target["revision"])
        if not math.isfinite(lat) or not math.isfinite(lon) or abs(lat) > 90 or abs(lon) > 180:
            raise UserError("目标经纬度无效。")
        if self.target is None or revision >= self.target["revision"]:
            self.target = dict(latitude=lat, longitude=lon, revision=revision)
            self.wake.set()
        return True

    async def connect(self, udid):
        if self.session is not None and not self.session.done():
            raise UserError("USB 开发者模式一次连接一台设备，请先停止当前连接。")
        if not udid or self.target is None:
            raise UserError("请先选择设备并保存目标位置。")
        self.publish(phase="connecting", status="正在连接，请解锁手机并信任此电脑…",
                     error=None, udid=udid, label="Apple 设备", ios="", transport="",
                     lastRevision=None, updatedAt=None, updates=0, clearRequested=False)
        self.cleaning = False
        self.cancel_issued = False
        self.session = asyncio.create_task(self.run_session(udid))
        return True

    async def reveal_developer_mode(self, udid):
        if self.session is not None and not self.session.done():
            raise UserError("请先停止当前 USB 连接，再显示开发者模式入口。")
        if not udid:
            raise UserError("请先刷新并选择 USB 设备。")
        lockdown = None
        try:
            async with asyncio.timeout(18):
                devices = await list_devices()
                if not any(d.is_usb and d.serial == udid for d in devices):
                    raise UserError("所选设备已断开，请插入 USB 数据线并刷新设备。")
                lockdown = await create_using_usbmux(
                    serial=udid, connection_type="USB", autopair=True, pair_timeout=10)
                if Version(lockdown.product_version) < Version("16.0"):
                    return dict(message="该系统无需开启开发者模式，可以直接连接定位。")
                if await lockdown.get_developer_mode_status():
                    return dict(message="手机已开启开发者模式，可以直接连接定位。")
                # Only the REVEAL action. Never enable, reboot or accept on behalf of the user.
                try:
                    await AmfiService(lockdown).reveal_developer_mode_option_in_ui()
                except (InvalidServiceError, StartServiceError) as error:
                    raise UserError("当前系统未提供显示入口服务，请检查手机限制或设备管理策略。") from error
                except Exception as error:
                    raise UserError("手机未确认显示开发者模式入口，请检查手机限制后重试。") from error
                return dict(message="手机已确认显示入口。请重新打开“设置 → 隐私与安全性”，滑到底部开启“开发者模式”，按手机提示重启并确认后再连接。")
        finally:
            if lockdown is not None:
                with contextlib.suppress(Exception):
                    await asyncio.wait_for(lockdown.close(), 2)

    async def mount(self, provider):
        self.publish(status="正在准备匹配系统版本的开发者镜像，首次可能需要联网下载…")
        version = provider.product_version
        legacy = Version(version) < Version("17.0")
        mounter = DeveloperDiskImageMounter(provider) if legacy else PersonalizedImageMounter(provider)
        async with mounter:
            if await asyncio.wait_for(mounter.is_image_mounted(
                    "Developer" if legacy else PersonalizedImageMounter.IMAGE_TYPE), 10):
                return
        kind = "legacy" if legacy else "cryptex" if uses_cryptex_image(provider) else "personalized"
        # Upstream image fetches are synchronous. A separate, killable process keeps
        # this event loop serving the tunnel and the Cancel/Stop command throughout.
        downloader = await asyncio.create_subprocess_exec(
            sys.executable, "-X", "utf8", str(Path(__file__).with_name("prepare_image.py")), kind, version,
            stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
            creationflags=subprocess.CREATE_NO_WINDOW if sys.platform == "win32" else 0)
        try:
            if await asyncio.wait_for(downloader.wait(), 600) != 0:
                raise UserError(f"iOS {version} 开发者镜像下载失败或暂未提供，请检查网络后重试。")
        finally:
            if downloader.returncode is None:
                downloader.kill()
                await downloader.wait()
        try:
            await asyncio.wait_for(auto_mount(provider), 120)
        except AlreadyMountedError:
            pass  # Never replace another application's mounted image.

    async def run_session(self, udid):
        stack = contextlib.AsyncExitStack()
        location = None
        attempted = False
        failure = None
        try:
            # Re-check USB identity: never silently select another phone on the LAN.
            devices = await asyncio.wait_for(list_devices(), 8)
            if not any(d.is_usb and d.serial == udid for d in devices):
                raise UserError("所选设备已断开，请插入 USB 数据线并刷新设备。")
            lockdown = await asyncio.wait_for(create_using_usbmux(
                serial=udid, connection_type="USB", autopair=True, pair_timeout=90), 100)
            stack.push_async_callback(lockdown.close)
            version = lockdown.product_version
            mode, transport = compatibility(version)
            self.publish(label=lockdown.all_values.get("DeviceName", "Apple 设备"),
                         ios=version, transport=transport, status="正在检查开发者定位服务…")
            if Version(version) >= Version("16.0"):
                if not await asyncio.wait_for(lockdown.get_developer_mode_status(), 8):
                    raise UserError("请在手机“设置 → 隐私与安全性”中开启开发者模式；找不到时，点击“显示开发者模式入口”。按手机提示完成后重新连接。")
            if mode == "legacy":
                location = DtSimulateLocation(lockdown)
            else:
                self.publish(status="正在建立开发者隧道…" if mode == "usb" else
                             "正在寻找同一局域网的已配对设备（iOS 17.0–17.3）…")
                provider = await asyncio.wait_for(stack.enter_async_context(
                    UserspaceRsdTunnel(serial=udid, autopair=False,
                                       remotepairing_fallback=mode == "remote")), 100)
                try:
                    dvt = await asyncio.wait_for(stack.enter_async_context(DvtProvider(provider)), 25)
                except (InvalidServiceError, StartServiceError):
                    # iOS 27+ Cryptex image mounting must use RSD, never legacy lockdown.
                    await self.mount(provider)
                    provider = await asyncio.wait_for(stack.enter_async_context(
                        RemoteServiceDiscoveryService(provider.service.address,
                            open_connection=provider.open_connection,
                            auxiliary_metadata=provider.auxiliary_metadata)), 25)
                    dvt = await asyncio.wait_for(stack.enter_async_context(DvtProvider(provider)), 25)
                location = await asyncio.wait_for(stack.enter_async_context(LocationSimulation(dvt)), 25)

            self.publish(status="通道已连接，正在提交目标…")
            while True:
                self.wake.clear()
                target = self.target.copy()
                attempted = True  # A timed-out write may still have changed the phone.
                try:
                    await asyncio.wait_for(location.set(target["latitude"], target["longitude"]), 15)
                except (InvalidServiceError, StartServiceError):
                    if mode != "legacy":
                        raise
                    await self.mount(lockdown)
                    await asyncio.wait_for(location.set(target["latitude"], target["longitude"]), 15)
                self.publish(phase="simulating", lastRevision=target["revision"],
                             updatedAt=datetime.now(timezone.utc).isoformat(),
                             updates=self.state["updates"] + 1,
                             status="本次目标已提交 · 手机结果待确认")
                # Keep the event loop and DVT session alive between edits. Periodic sends
                # detect a broken connection; a new revision wakes immediately.
                try:
                    await asyncio.wait_for(self.wake.wait(), 5)
                except TimeoutError:
                    pass
        except asyncio.CancelledError:
            pass
        except Exception as error:
            failure = chinese_error(error)
        finally:
            self.cleaning = True
            clear_requested = False
            warning = self.state.get("restoreWarning")
            if attempted and location is not None:
                try:
                    await asyncio.wait_for(location.clear(), 4)
                    clear_requested = True
                    warning = None
                except Exception:
                    warning = "停止模拟指令未能发送，手机可能仍保留模拟位置；请重新连接后再停止模拟。"
            try:
                await asyncio.wait_for(stack.aclose(), 4)
            except Exception:
                failure = failure or "开发者通道释放超时，请重新连接设备。"
            self.publish(phase="error" if failure or warning else "idle",
                         status=("连接已结束" if failure else "已发送停止模拟指令 · 手机结果待确认"
                                 if clear_requested else "连接已取消"),
                         error=failure, clearRequested=clear_requested, restoreWarning=warning)

    async def stop(self):
        if self.session is not None and not self.session.done():
            self.publish(phase="stopping", status="正在停止模拟并释放连接…")
            if not self.cleaning and not self.cancel_issued:
                self.cancel_issued = True
                self.session.cancel()
            # The session owns cleanup; do not cancel it a second time during clear().
            try:
                await asyncio.shield(self.session)
            except asyncio.CancelledError:
                if not self.session.cancelled():
                    raise
            if self.state["phase"] == "stopping":
                self.publish(phase="idle", status="连接已取消")
        return self.state

    async def dispatch(self, method, args):
        if method == "devices":
            return await self.devices()
        if method == "target":
            return self.set_target(args)
        if method == "connect":
            return await self.connect(args.get("udid", ""))
        if method == "revealDeveloperMode":
            return await self.reveal_developer_mode(args.get("udid", ""))
        if method in ("stop", "shutdown"):
            return await self.stop()
        if method == "clearError":
            if self.session is None or self.session.done():
                self.publish(phase="idle", error=None, status="尚未连接",
                             label="", ios="", udid="", lastRevision=None,
                             clearRequested=False, transport="", updates=0, updatedAt=None)
            return True
        raise UserError("不支持的 USB 操作。")


async def main():
    worker = Worker()
    queue = asyncio.Queue()
    loop = asyncio.get_running_loop()

    def read_input():
        # A daemon reader does not block asyncio or prevent interpreter shutdown on EOF.
        try:
            for line in sys.stdin:
                loop.call_soon_threadsafe(queue.put_nowait, line)
        finally:
            with contextlib.suppress(RuntimeError):
                loop.call_soon_threadsafe(queue.put_nowait, None)

    threading.Thread(target=read_input, daemon=True).start()
    worker.publish()
    queries = set()

    async def query(request):
        try:
            result = await asyncio.wait_for(worker.devices(), 20)
            emit(dict(id=request["id"], result=result))
        except Exception as error:
            emit(dict(id=request["id"], error=chinese_error(error)))

    try:
        while (line := await queue.get()) is not None:
            request_id = None
            try:
                request = json.loads(line)
                request_id = request["id"]
                if request["method"] == "devices":
                    task = asyncio.create_task(query(request))
                    queries.add(task)
                    task.add_done_callback(queries.discard)
                    continue
                result = await worker.dispatch(request["method"], request.get("args") or {})
                emit(dict(id=request_id, result=result))
                if request["method"] == "shutdown":
                    break
            except Exception as error:
                emit(dict(id=request_id, error=chinese_error(error)))
    finally:
        for task in queries:
            task.cancel()
        await asyncio.gather(*queries, return_exceptions=True)
        await worker.stop()


if __name__ == "__main__":
    asyncio.run(main())
