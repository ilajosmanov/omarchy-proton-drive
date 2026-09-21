"""Readiness tests use a private bus, never the desktop's credential store."""
import asyncio
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import shutil
import json
import unittest

try:
    from dbus_next.aio import MessageBus
    from dbus_next.constants import PropertyAccess
    from dbus_next.service import ServiceInterface, method, dbus_property
    from wait_secret_service import wait_ready
    HAS_DBUS = True
except ImportError:
    HAS_DBUS = False


if HAS_DBUS:
    class Secrets(ServiceInterface):
        def __init__(self):
            super().__init__("org.freedesktop.Secret.Service")
            self.collection = "/custom/collection"

        @method()
        def ReadAlias(self, alias: 's') -> 'o':
            assert alias == "default"
            return self.collection

    class Collection(ServiceInterface):
        def __init__(self):
            super().__init__("org.freedesktop.Secret.Collection")
            self.locked = True

        @dbus_property(access=PropertyAccess.READ)
        def Locked(self) -> 'b':
            return self.locked


class PrivateBusTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.bus = await MessageBus().connect()
        self.service = Secrets()
        self.collection = Collection()
        self.bus.export("/org/freedesktop/secrets", self.service)
        self.bus.export("/custom/collection", self.collection)

    async def asyncTearDown(self):
        self.bus.disconnect()
        await self.bus.wait_for_disconnect()

    async def test_delayed_service_and_unlock(self):
        task = asyncio.create_task(wait_ready(timeout=2, interval=0.01))
        await asyncio.sleep(0.05)
        self.assertFalse(task.done())
        await self.bus.request_name("org.freedesktop.secrets")
        await asyncio.sleep(0.05)
        self.assertFalse(task.done())
        self.collection.locked = False
        self.assertTrue(await task)

    async def test_locked_timeout_then_later_retry(self):
        await self.bus.request_name("org.freedesktop.secrets")
        self.assertFalse(await wait_ready(timeout=0.1, interval=0.01))
        self.collection.locked = False
        self.assertTrue(await wait_ready(timeout=0.5, interval=0.01))

    async def test_no_default_collection_allows_first_login(self):
        self.service.collection = "/"
        await self.bus.request_name("org.freedesktop.secrets")
        self.assertTrue(await wait_ready(timeout=0.5, interval=0.01))

    async def test_service_unavailable_is_bounded(self):
        start = asyncio.get_running_loop().time()
        self.assertFalse(await wait_ready(timeout=0.1, interval=0.01))
        self.assertLess(asyncio.get_running_loop().time() - start, 1)

    async def test_unresponsive_service_is_bounded(self):
        # Own the name but swallow calls to emulate a hung provider.
        self.bus.add_message_handler(lambda message: True if message.member == "ReadAlias" else None)
        await self.bus.request_name("org.freedesktop.secrets")
        self.assertFalse(await wait_ready(timeout=0.1, interval=0.01, attempt_timeout=0.03))

    async def test_daemon_waits_then_serves_after_unlock(self):
        root = Path(__file__).resolve().parents[1]
        await self.bus.request_name("org.freedesktop.secrets")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            cli = path / "proton-drive"
            cli.write_text("#!/bin/sh\ncat <<'EOF'\n{\"email\":\"test@example.invalid\",\"usedBytes\":0,\"totalBytes\":1}\nEOF\n")
            cli.chmod(0o755)
            runtime = shutil.which("bun") or str(root / "scripts/node-ts.sh")
            process = await asyncio.create_subprocess_exec(
                runtime, str(root / "daemon/src/main.ts"),
                env={**os.environ, "OMARCHY_DRIVE_PROVIDER": "proton-cli",
                     "OMARCHY_DRIVE_CLI": str(cli), "XDG_RUNTIME_DIR": directory,
                     "XDG_STATE_HOME": str(path / "state"), "XDG_CACHE_HOME": str(path / "cache")},
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
            try:
                # Cross the production 30-second probe deadline: the daemon
                # must survive, retry, and recover without being restarted.
                await asyncio.sleep(31)
                self.assertIsNone(process.returncode)
                self.assertFalse((path / "omarchy-drive.sock").exists())
                self.collection.locked = False
                async def status():
                    while not (path / "omarchy-drive.sock").exists():
                        await asyncio.sleep(0.05)
                    reader, writer = await asyncio.open_unix_connection(str(path / "omarchy-drive.sock"))
                    try:
                        writer.write(b'{"id":"startup","method":"GetStatus"}\n')
                        await writer.drain()
                        return json.loads(await reader.readline())
                    finally:
                        writer.close()
                        await writer.wait_closed()
                result = await asyncio.wait_for(status(), 10)
                self.assertTrue(result["result"]["connected"], result)
            finally:
                if process.returncode is None:
                    process.terminate()
                await asyncio.wait_for(process.communicate(), 5)


@unittest.skipUnless(HAS_DBUS, "requires system python-dbus-next")
class SecretServiceTests(unittest.TestCase):
    def test_private_bus(self):
        result = subprocess.run(["dbus-run-session", "--", sys.executable, __file__, "--private-bus"],
                                capture_output=True, text=True, timeout=50)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_fake_and_unconfigured_do_not_need_bus(self):
        for provider in ("fake", "unconfigured"):
            result = subprocess.run([sys.executable, str(Path(__file__).with_name("wait_secret_service.py"))],
                env={**os.environ, "OMARCHY_DRIVE_PROVIDER": provider,
                     "DBUS_SESSION_BUS_ADDRESS": "unix:path=/nonexistent/omarchy-test-bus"},
                capture_output=True, text=True, timeout=2)
            self.assertEqual(result.returncode, 0, result.stderr)


def load_tests(loader, tests, pattern):
    return loader.loadTestsFromTestCase(SecretServiceTests)


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(
        PrivateBusTests if "--private-bus" in sys.argv else SecretServiceTests)
    sys.exit(not unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful())
