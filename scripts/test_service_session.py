"""Check enablement migration and optionally exercise a real user manager.

OMARCHY_DRIVE_TEST_SESSION=1 enables the runtime test. It uses uniquely named
units with dummy processes, never the real desktop target or Proton services.
"""
import configparser
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
SERVICES = ["omarchy-drive.service", "omarchy-drive-dbus.service", "omarchy-drive-mount.service"]


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True, timeout=20).stdout.strip()


@unittest.skipUnless(shutil.which("systemctl"), "systemctl unavailable")
class SessionTests(unittest.TestCase):
    def test_reenable_migrates_old_default_target_links(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            units = root / "usr/lib/systemd/user"
            config = root / "etc/systemd/user"
            units.mkdir(parents=True)
            old = config / "default.target.wants"
            old.mkdir(parents=True)
            for name in SERVICES:
                shutil.copy(ROOT / "systemd" / name, units / name)
                (old / name).symlink_to("/usr/lib/systemd/user/" + name)
            (units / "graphical-session.target").write_text("[Unit]\nDescription=Test session\n")
            run("systemctl", "--root=" + directory, "--global", "reenable", *SERVICES)
            for name in SERVICES:
                self.assertFalse((old / name).is_symlink())
                self.assertTrue((config / "graphical-session.target.wants" / name).is_symlink())

    @unittest.skipUnless(os.environ.get("OMARCHY_DRIVE_TEST_SESSION") == "1",
                         "set OMARCHY_DRIVE_TEST_SESSION=1 for isolated runtime units")
    def test_services_return_after_session_restart(self):
        prefix = "omarchy-drive-test-" + uuid.uuid4().hex
        names = {name: prefix + "-" + name for name in SERVICES}
        names.update({"graphical-session.target": prefix + "-session.target",
                      "default.target": prefix + "-default.target"})
        session, default = names["graphical-session.target"], names["default.target"]
        services = [names[name] for name in SERVICES]
        all_units = [session, default, *services]
        with tempfile.TemporaryDirectory() as directory:
            stage = Path(directory)
            for target in (session, default):
                (stage / target).write_text("[Unit]\nDescription=Isolated session test\n")
            for name in SERVICES:
                source = configparser.ConfigParser(interpolation=None)
                source.optionxform = str
                source.read(ROOT / "systemd" / name)
                # Preserve packaged dependency/enablement semantics, substitute
                # only names and the payload (no FUSE, credentials or network).
                text = "[Unit]\n" + "\n".join(f"{k}={v}" for k, v in source["Unit"].items())
                text += "\n[Service]\nType=oneshot\nExecStart=/usr/bin/true\nRemainAfterExit=yes\n"
                text += "[Install]\n" + "\n".join(f"{k}={v}" for k, v in source["Install"].items()) + "\n"
                for original, replacement in names.items():
                    text = text.replace(original, replacement)
                (stage / names[name]).write_text(text)
            try:
                run("systemctl", "--user", "--runtime", "link", *(str(stage / n) for n in all_units))
                run("systemctl", "--user", "--runtime", "enable", *services)
                run("systemctl", "--user", "start", default, session)
                for unit in services:
                    self.assertEqual(run("systemctl", "--user", "is-active", unit), "active")
                first = [run("systemctl", "--user", "show", u, "-p", "InvocationID", "--value") for u in services]
                run("systemctl", "--user", "stop", session)
                for unit in services:
                    self.assertEqual(run("systemctl", "--user", "show", unit, "-p", "ActiveState", "--value"), "inactive")
                self.assertEqual(run("systemctl", "--user", "is-active", default), "active")
                run("systemctl", "--user", "start", session)
                for unit, invocation in zip(services, first):
                    self.assertEqual(run("systemctl", "--user", "is-active", unit), "active")
                    self.assertNotEqual(run("systemctl", "--user", "show", unit, "-p", "InvocationID", "--value"), invocation)
            finally:
                run("systemctl", "--user", "stop", *all_units)
                run("systemctl", "--user", "--runtime", "disable", *all_units)


if __name__ == "__main__":
    unittest.main()
