"""Exercise libalpm's required/trusted-only package policy without installation."""

import ctypes
import ctypes.util
import io
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path


@unittest.skipUnless(ctypes.util.find_library("alpm") and shutil.which("gpg"), "libalpm and GnuPG required")
class PackageSignaturesTest(unittest.TestCase):
    def test_trusted_signature_required_and_foreign_signer_rejected(self):
        with tempfile.TemporaryDirectory(prefix="monarch-signatures-") as temporary:
            root = Path(temporary)
            trusted, foreign = root / "trusted", root / "foreign"
            trusted.mkdir(mode=0o700)
            foreign.mkdir(mode=0o700)

            def gpg(home, *arguments, data=None):
                return subprocess.run(["gpg", "--homedir", str(home), "--batch", "--pinentry-mode", "loopback", *arguments],
                                      input=data, capture_output=True, check=True, timeout=20).stdout

            try:
                for home in (trusted, foreign):
                    gpg(home, "--passphrase", "", "--quick-generate-key", "Fixture <fixture@example.invalid>", "ed25519", "sign", "1d")
                gpg(trusted, "--import", data=gpg(foreign, "--export"))
                package = root / "fixture-1-1-any.pkg.tar"
                metadata = b"pkgname = fixture\npkgver = 1-1\npkgdesc = Signature fixture\narch = any\nsize = 0\n"
                with tarfile.open(package, "w") as archive:
                    entry = tarfile.TarInfo(".PKGINFO")
                    entry.size = len(metadata)
                    archive.addfile(entry, io.BytesIO(metadata))

                lib = ctypes.CDLL(ctypes.util.find_library("alpm"))
                pointer = ctypes.c_void_p
                lib.alpm_initialize.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.POINTER(ctypes.c_int)]
                lib.alpm_initialize.restype = pointer
                lib.alpm_option_set_gpgdir.argtypes = [pointer, ctypes.c_char_p]
                lib.alpm_pkg_load.argtypes = [pointer, ctypes.c_char_p, ctypes.c_int, ctypes.c_int, ctypes.POINTER(pointer)]
                lib.alpm_pkg_free.argtypes = [pointer]
                lib.alpm_release.argtypes = [pointer]
                (root / "db").mkdir()
                error = ctypes.c_int()
                handle = lib.alpm_initialize(str(root).encode(), str(root / "db").encode(), ctypes.byref(error))
                self.assertTrue(handle, f"alpm_initialize failed: {error.value}")
                try:
                    self.assertEqual(lib.alpm_option_set_gpgdir(handle, str(trusted).encode()), 0)

                    def load():
                        result = pointer()
                        # ALPM_SIG_PACKAGE without OPTIONAL/MARGINAL_OK/UNKNOWN_OK.
                        status = lib.alpm_pkg_load(handle, str(package).encode(), 1, 1, ctypes.byref(result))
                        if result.value:
                            lib.alpm_pkg_free(result)
                        return status

                    self.assertNotEqual(load(), 0, "unsigned package accepted")
                    gpg(trusted, "--yes", "--detach-sign", str(package))
                    self.assertEqual(load(), 0, "trusted package rejected")
                    gpg(foreign, "--yes", "--detach-sign", str(package))
                    self.assertNotEqual(load(), 0, "untrusted signer accepted")
                finally:
                    lib.alpm_release(handle)
            finally:
                for home in (trusted, foreign):
                    subprocess.run(["gpgconf", "--homedir", str(home), "--kill", "gpg-agent"], capture_output=True, timeout=10)


if __name__ == "__main__":
    unittest.main()
