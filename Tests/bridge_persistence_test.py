"""Offline IPC regressions. Only a disposable SUIXING_DATA directory is used."""
import ctypes
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from contextlib import contextmanager


@contextmanager
def deny_replace(path):
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.CreateFileW.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32,
                                  ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p]
    kernel.CreateFileW.restype = ctypes.c_void_p
    kernel.CloseHandle.argtypes = [ctypes.c_void_p]
    handle = kernel.CreateFileW(str(path), 0x80000000, 1, None, 3, 0x80, None)
    if handle == ctypes.c_void_p(-1).value:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        yield
    finally:
        kernel.CloseHandle(handle)


def run(executable, assembly=None):
    with tempfile.TemporaryDirectory(prefix="sxloc-ipc-") as data:
        env = dict(os.environ, SUIXING_DATA=data)
        command = [executable] + ([assembly] if assembly else [])
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True, encoding="utf-8", env=env)
        sequence = 0

        def call(method, args=None):
            nonlocal sequence
            sequence += 1
            process.stdin.write(json.dumps(dict(id=sequence, method=method, args=args or {})) + "\n")
            process.stdin.flush()
            response = json.loads(process.stdout.readline())
            assert response.get("id") == sequence, response
            return response

        try:
            before = call("init")["result"]
            assert before["applyBlockedReason"] == "请先连接 iPhone，再应用定位。"
            path = Path(data, "desktop.json")
            existed = path.exists()
            failure = call("apply", dict(latitude=31.2, longitude=121.4))
            assert failure.get("error") == before["applyBlockedReason"], failure
            assert path.exists() == existed, "Disconnected apply created settings"
            assert call("snapshot")["result"]["target"] == before["target"]
            assert "result" in call("settings.save", dict(searchCity=""))
            before = call("snapshot")["result"]
            saved = path.read_bytes()
            with deny_replace(path):
                failure = call("apply", dict(latitude=40, longitude=116))
                assert failure.get("error") == before["applyBlockedReason"], failure
                after = call("snapshot")["result"]
                assert after["target"] == before["target"], "Failed apply changed live target/revision"
                failure = call("settings.save", dict(searchCity="不应保存"))
                assert "error" in failure
                assert call("snapshot")["result"]["settings"] == before["settings"]
                found = call("search.places", dict(query="31.23,121.47", searchId=1))["result"]
                assert found["places"] and "历史未能保存" in found["notice"], found
                assert call("snapshot")["result"]["settings"]["searchHistory"] == []
            assert path.read_bytes() == saved
            assert "error" in call("apply", dict(latitude=91))
            assert path.read_bytes() == saved
            assert call("apply", dict(latitude=40, longitude=116)).get("error") == before["applyBlockedReason"]
            assert call("snapshot")["result"]["target"] == before["target"]
            assert path.read_bytes() == saved
            assert "result" in call("favorites.add", dict(name="原收藏", latitude=0, longitude=0))
            config = Path(data, "iap2loc.json")
            with deny_replace(config):
                assert "error" in call("favorites.add", dict(name="失败收藏", latitude=31, longitude=121))
                assert len(call("snapshot")["result"]["favorites"]) == 1
            assert "error" in call("favorites.add", dict(name="非法", latitude=100, longitude=0))
            assert "result" in call("search.places", dict(query="31.23,121.47", searchId=2))
            assert call("snapshot")["result"]["settings"]["searchHistory"] == ["31.23,121.47"]
            print("PASS: Bridge IPC rejects disconnected apply without changing target/disk; settings/favorites roll back; search results survive history failure")
        finally:
            process.stdin.close()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
                raise


if __name__ == "__main__":
    run(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None)
