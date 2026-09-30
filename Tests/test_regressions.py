"""Run simulated transitions against the current helper source (no disk access)."""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
SOURCE = HERE.parent / "Source/VolumeBridge.swift"
CASES = [
    "fuse_to_readonly", "unmounted_empty_to_readonly", "unmounted_missing_to_readonly",
    "native_to_readonly", "native_to_readwrite", "unmounted_empty_to_readwrite",
    "concurrent_unmount_success", "failed_readonly_state_detected",
    "fuse_to_readwrite", "unmount_busy_stops_driver", "permission_denial_restores_readonly",
    "driver_failure_restores_readonly", "mount_timeout_restores_readonly", "changed_uuid_stops_driver",
    "internal_disk_rejected", "wrong_uuid_rejected", "non_ntfs_rejected", "non_admin_rejected",
    "fuse_eject", "permission_error_mapping",
]

def production_function(text, name):
    """Keep function bodies verbatim, selecting top-level declarations."""
    start = re.search(r"^func " + re.escape(name) + r"\(", text, re.M)
    if not start:
        raise RuntimeError(f"Production function {name} is missing; update test adapter")
    following = re.search(r"^(?:func |struct |@MainActor|@main)", text[start.end():], re.M)
    end = start.end() + following.start() if following else len(text)
    return text[start.start():end]

class MountRegressionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # subprocess.run is used only for the Swift compiler and this harness.
        # Production Process/run/info/raw-open functions are never included.
        cls.temp = tempfile.TemporaryDirectory(prefix="volumebridge-test-build-")
        cls.addClassCleanup(cls.temp.cleanup)
        text = SOURCE.read_text()
        names = ["validID", "diskAccessHint", "driverFailure"]
        # These helpers are part of the mount-state fix in the main thread.
        names += [name for name in ["nativeMountPath", "verifiedInfo", "unmountNativeIfMounted"]
                  if re.search(r"^func " + name + r"\(", text, re.M)]
        bodies = "\n".join(production_function(text, name) for name in names + ["helper"])
        harness = (HERE / "RegressionHarness.swift").read_text()
        main = Path(cls.temp.name) / "main.swift"
        main.write_text(harness.replace("// PRODUCTION_FUNCTIONS", bodies))
        cls.binary = Path(cls.temp.name) / "regressions"
        result = subprocess.run(["swiftc", str(main), "-o", str(cls.binary)],
                                text=True, capture_output=True, timeout=90)
        if result.returncode:
            raise RuntimeError("Harness compilation failed:\n" + result.stderr)

    def check_case(self, name):
        result = subprocess.run([str(self.binary), name], text=True,
                                capture_output=True, timeout=15, env={**__import__("os").environ, "VOLUMEBRIDGE_TEST_LOCALIZATIONS": str(HERE.parent / "Source/Localizations/zh-Hans.lproj/Localizable.strings")})
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)

for case in CASES:
    def method(self, name=case):
        self.check_case(name)
    setattr(MountRegressionTests, "test_" + case, method)

if __name__ == "__main__":
    unittest.main(verbosity=2)
