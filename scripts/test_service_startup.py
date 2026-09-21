"""Exercise packaged Python entry points with a conflicting PATH interpreter."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ServiceInterpreterTests(unittest.TestCase):
    def test_services_ignore_path_python(self):
        with tempfile.TemporaryDirectory() as directory:
            trap = Path(directory) / "python3"
            trap.write_text("#!/bin/sh\necho WRONG_PYTHON >&2\nexit 97\n")
            trap.chmod(0o755)
            for service in ("mount", "dbus"):
                unit = (ROOT / "systemd" / f"omarchy-drive-{service}.service").read_text()
                command = shlex.split(next(line.removeprefix("ExecStart=")
                    for line in unit.splitlines() if line.startswith("ExecStart=")))
                self.assertEqual(command[0], "/usr/bin/python3")
                source = ROOT / command[1].removeprefix("/usr/lib/omarchy-drive/")
                # Import the actual entry point without starting a mount/bridge.
                # This checks its dependencies and interpreter selection together.
                result = subprocess.run([command[0], "-B", "-c",
                    "import runpy,sys; runpy.run_path(sys.argv[1])", str(source)],
                    env={**os.environ, "PATH": directory + os.pathsep + os.environ["PATH"]},
                    capture_output=True, text=True, timeout=10)
                if "No module named 'pyfuse3'" in result.stderr or "No module named 'trio'" in result.stderr:
                    # Ubuntu CI does not install the optional FUSE runtime.
                    continue
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("WRONG_PYTHON", result.stderr)


if __name__ == "__main__":
    unittest.main()
