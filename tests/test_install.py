import pathlib
import shutil
import subprocess
import tempfile
import unittest


REPO = pathlib.Path(__file__).resolve().parents[1]


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.clone = self.root / "clone with spaces"
        self.clone.mkdir()
        for name in ("taskbar", "install.sh"):
            source = REPO / name
            if source.exists():
                shutil.copy2(source, self.clone / name)
        # Exercise command dispatch without building, launching or stopping a real app.
        for name in ("restart", "kill", "open-settings"):
            script = self.clone / f"{name}.sh"
            script.write_text(f"#!/bin/bash\nprintf '{name}\\n'\n")
            script.chmod(0o755)
        self.bin = self.root / "bin with spaces"

    def install(self):
        return subprocess.run(
            ["bash", str(self.clone / "install.sh"), str(self.bin)],
            cwd=self.root,
            capture_output=True,
            text=True,
        )

    def test_installed_symlink_dispatches_from_an_unrelated_directory(self):
        for _ in range(2):
            result = self.install()
            self.assertEqual(result.returncode, 0, result.stderr)
        launcher = self.bin / "taskbar"
        self.assertTrue(launcher.is_symlink())
        self.assertEqual(launcher.resolve(), (self.clone / "taskbar").resolve())
        for command, expected in (("start", "restart"), ("settings", "open-settings"), ("stop", "kill")):
            result = subprocess.run(
                [str(launcher), command], cwd=self.root, capture_output=True, text=True
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), expected)

    def test_installer_preserves_an_existing_regular_file(self):
        self.bin.mkdir()
        destination = self.bin / "taskbar"
        destination.write_text("another command\n")
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(destination.read_text(), "another command\n")

    def test_installer_help_does_not_create_a_launcher(self):
        result = subprocess.run(
            ["bash", str(self.clone / "install.sh"), "--help"],
            cwd=self.root, capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Usage:", result.stdout)
        self.assertFalse(self.bin.exists())


if __name__ == "__main__":
    unittest.main()
