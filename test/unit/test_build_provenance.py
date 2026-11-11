import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
VERSION = "1.2.3.r4.gabc"
REVISION = "a123" * 10


class BuildProvenanceTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="iso-provenance-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.bin = self.root / "stubs"
        self.bin.mkdir()
        self.trace = self.root / "trace.jsonl"
        self.env = dict(os.environ, PATH=f"{self.bin}:/usr/bin:/bin",
                        HOME=str(self.root), FIXTURE=str(self.root))
        for name in ("MONARCH_LOCAL_PKGVER", "MONARCH_LOCAL_REVISION", "BASH_ENV", "ENV"):
            self.env.pop(name, None)
        self.stub("git", """
if 'describe' in args:
    print(os.environ.get('DERIVED_VERSION', 'v1.2.3-4-gabc'))
elif 'rev-parse' in args:
    print(os.environ.get('DERIVED_REVISION', 'a123' * 10))
    sys.exit(int(os.environ.get('REVISION_FAILURE', '0')))
elif args[0] == 'clone':
    Path(args[-1]).mkdir(parents=True)
""")
        for name in ("pacman", "pacman-key", "useradd", "chown", "chmod"):
            self.stub(name, "")
        self.stub("id", """
if args == ['-u']:
    print(os.getuid())
elif args == ['-g']:
    print(os.getgid())
else:
    sys.exit(1)
""")
        self.stub("rm", "")
        self.stub("sudo", "sys.exit(96)")
        self.stub("container", "sys.exit(75)")

    def stub(self, name, body):
        path = self.bin / name
        path.write_text("#!/usr/bin/python3\n"
                        "import json, os, subprocess, sys, tarfile, io\n"
                        "from pathlib import Path\n"
                        f"root = Path({str(self.root)!r})\n"
                        "args = sys.argv[1:]\n"
                        f"with (root / 'trace.jsonl').open('a') as stream:\n"
                        f"    stream.write(json.dumps([{name!r}, args]) + '\\n')\n" + body)
        path.chmod(0o755)

    def calls(self, name):
        rows = [json.loads(line) for line in self.trace.read_text().splitlines()] if self.trace.exists() else []
        return [args for command, args in rows if command == name]

    def run_script(self, script, *args, env=None):
        return subprocess.run(["/bin/bash", str(script), *map(str, args)],
                              env=env or self.env, text=True, capture_output=True, timeout=10)

    def host_script(self):
        for name in ("bin/monarch-iso-make", "builder/source-package-version.sh"):
            target = self.root / name
            target.parent.mkdir(exist_ok=True)
            shutil.copy2(ROOT / name, target)
        source = self.root / "runtime source with spaces"
        packages = self.root / "package recipes with spaces"
        source.mkdir()
        packages.mkdir()
        self.env["BUILDER_CMD"] = str(self.bin / "container")
        return self.root / "bin/monarch-iso-make", source, packages

    def container_script(self, name):
        # Rebase only fixed container locations; execute the production control flow.
        text = (ROOT / name).read_text()
        locations = dict((("/tmp/monarch-pkg-build", "work"),
                         ("/tmp/monarch-local-source", "local"),
                         ("/etc/sudoers.d", "sudoers"), ("/monarch-source", "source"),
                         ("/monarch-pkgs", "packages"), ("/builder", "builder"),
                         ("/configs", "configs"), ("/archiso", "archiso"),
                         ("/var/cache", "cache")))
        pattern = r"(?<![\w/.-])(" + "|".join(map(re.escape, locations)) + r")"
        text = re.sub(pattern, lambda match: str(self.root / locations[match[0]]), text)
        script = self.root / Path(name).name
        script.write_text(text)
        return script

    def package_fixture(self):
        for directory in ("source", "packages/pkgbuilds/monarch", "sudoers", "builder"):
            (self.root / directory).mkdir(parents=True)
        (self.root / "packages/pkgbuilds/monarch/PKGBUILD").write_text("fixture\n")
        shutil.copy2(ROOT / "builder/package-name.sh", self.root / "builder/package-name.sh")
        self.stub("su", """
assert args[:2] == ['builder', '-c']
# Model su discarding arbitrary inherited variables.
environment = {'PATH': str(root / 'stubs') + ':/usr/bin:/bin', 'HOME': str(root)}
sys.exit(subprocess.run(['/bin/bash', '-c', args[2]], env=environment).returncode)
""")
        self.stub("makepkg", """
values = {key: os.environ.get(key) for key in
          ('MONARCH_LOCAL_PKGVER', 'MONARCH_LOCAL_REVISION', 'MONARCH_SRC', 'PKGDEST')}
(root / 'makepkg.json').write_text(json.dumps(values))
assert (Path(values['MONARCH_SRC']) / 'version').read_text().strip() == values['MONARCH_LOCAL_PKGVER']
data = b'pkgname = monarch\\n'
with tarfile.open(Path(values['PKGDEST']) / 'monarch-fixture.pkg.tar.gz', 'w:gz') as archive:
    entry = tarfile.TarInfo('.PKGINFO')
    entry.size = len(data)
    archive.addfile(entry, io.BytesIO(data))
""")
        return self.container_script("builder/build-monarch-package.sh")

    def test_host_derives_and_passes_pair_with_space_containing_paths(self):
        script, source, packages = self.host_script()
        result = self.run_script(script, "--local-source", source, packages,
                                 "--keep-pkg-cache", "--no-boot-offer", "--no-cache")
        self.assertEqual(result.returncode, 75, result.stderr)
        args = self.calls("container")[0]
        self.assertIn(f"MONARCH_LOCAL_PKGVER={VERSION}", args)
        self.assertIn(f"MONARCH_LOCAL_REVISION={REVISION}", args)
        self.assertIn(f"{source}:/monarch-source:ro", args)
        self.assertIn(f"{packages}:/monarch-pkgs:ro", args)
        self.assertIn(["-C", str(source), "rev-parse", "--verify", "HEAD"], self.calls("git"))

    def test_host_rejects_bad_or_failed_revision_before_side_effects(self):
        script, source, packages = self.host_script()
        for revision, failure in (("", "0"), ("abc", "0"), ("a" * 40 + "';touch injected", "0"),
                                  (REVISION, "1")):
            with self.subTest(revision=revision, failure=failure):
                self.trace.unlink(missing_ok=True)
                self.env.update(DERIVED_REVISION=revision, REVISION_FAILURE=failure)
                result = self.run_script(script, "--local-source", source, packages)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.calls("container"))
                self.assertFalse(self.calls("sudo"))
                self.assertFalse(any("submodule" in args for args in self.calls("git")))

    def test_host_rejects_injected_derived_version_before_side_effects(self):
        script, source, packages = self.host_script()
        self.env["DERIVED_VERSION"] = "v1';touch injected;#"
        result = self.run_script(script, "--local-source", source, packages)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Invalid package version derived", result.stderr)
        self.assertFalse(self.calls("sudo"))
        self.assertFalse(self.calls("container"))
        self.assertFalse(any("submodule" in args for args in self.calls("git")))

    def test_package_pair_survives_clean_su_for_sha1_and_sha256(self):
        script = self.package_fixture()
        for revision in (REVISION, "B234" * 16):
            with self.subTest(revision=revision):
                self.env.update(MONARCH_LOCAL_PKGVER=VERSION, MONARCH_LOCAL_REVISION=revision)
                mirror = self.root / "offline mirror with spaces"
                result = self.run_script(script, mirror)
                self.assertEqual(result.returncode, 0, result.stderr)
                values = json.loads((self.root / "makepkg.json").read_text())
                self.assertEqual(values["MONARCH_LOCAL_PKGVER"], VERSION)
                self.assertEqual(values["MONARCH_LOCAL_REVISION"], revision)
                self.assertTrue((mirror / "monarch-fixture.pkg.tar.gz").exists())

    def test_package_rejects_missing_malformed_and_injected_pair_before_mutation(self):
        script = self.package_fixture()
        for version, revision in ((None, REVISION), (VERSION, None), ("", REVISION),
                                  (VERSION, ""), (VERSION, "abc"), (VERSION, "a" * 41),
                                  (VERSION, "z" * 40), ("1';touch injected;#", REVISION),
                                  (VERSION, REVISION + "';touch injected;#"),
                                  ("$(touch injected)", REVISION)):
            with self.subTest(version=version, revision=revision):
                self.trace.unlink(missing_ok=True)
                env = dict(self.env)
                if version is not None:
                    env["MONARCH_LOCAL_PKGVER"] = version
                if revision is not None:
                    env["MONARCH_LOCAL_REVISION"] = revision
                result = self.run_script(script, self.root / "mirror", env=env)
                self.assertNotEqual(result.returncode, 0)
                for command in ("rm", "useradd", "pacman", "su", "makepkg"):
                    self.assertFalse(self.calls(command), command)
                self.assertFalse((self.root / "work").exists())
                self.assertFalse((self.root / "sudoers/99-monarch-pkg-builder").exists())

    def test_clone_derives_and_exports_both_values_to_package_builder(self):
        releng = self.root / "archiso/configs/releng/airootfs"
        (releng / "root").mkdir(parents=True)
        (releng / "etc").mkdir()
        (releng / "etc/motd").touch()
        (self.root / "configs").mkdir()
        (self.root / "configs/pacman-online.conf").touch()
        (self.root / "builder").mkdir()
        shutil.copy2(ROOT / "builder/source-package-version.sh", self.root / "builder/source-package-version.sh")
        self.stub("bash", """
if args[0].endswith('/bootstrap-monarch-keyring.sh'):
    sys.exit(0)
if args[0].endswith('/build-monarch-package.sh'):
    (root / 'clone-pair.json').write_text(json.dumps({key: os.environ.get(key) for key in
        ('MONARCH_LOCAL_PKGVER', 'MONARCH_LOCAL_REVISION')}))
    sys.exit(77)
sys.exit(subprocess.run(['/bin/bash', *args]).returncode)
""")
        result = self.run_script(self.container_script("builder/build-iso.sh"))
        self.assertEqual(result.returncode, 77, result.stderr)
        values = json.loads((self.root / "clone-pair.json").read_text())
        self.assertEqual(values, {"MONARCH_LOCAL_PKGVER": VERSION, "MONARCH_LOCAL_REVISION": REVISION})
        self.assertIn(["-C", str(self.root / "source"), "rev-parse", "--verify", "HEAD"], self.calls("git"))


if __name__ == "__main__":
    unittest.main()
