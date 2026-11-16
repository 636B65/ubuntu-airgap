"""Unit tests for the Python helper embedded in ubuntu-airgap.sh.

Run with:  python3 -m unittest discover -s tests -v
"""

import importlib.util
import os
import subprocess
import tempfile
import textwrap
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
_tmp = tempfile.mkdtemp()
_helper_path = os.path.join(_tmp, "airgap_helper.py")
subprocess.run([os.path.join(HERE, "extract-helper.sh"), _helper_path], check=True)
_spec = importlib.util.spec_from_file_location("airgap_helper", _helper_path)
helper = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(helper)


def write(content, suffix):
    fd, path = tempfile.mkstemp(suffix=suffix, dir=_tmp)
    with os.fdopen(fd, "w") as f:
        f.write(textwrap.dedent(content))
    return path


class OneLineFormat(unittest.TestCase):
    def test_options_and_components(self):
        p = write(
            """
            # comment line
            deb [arch=amd64,i386 signed-by=/etc/apt/keyrings/vendor.gpg] https://repo.example.com/apt/1.2 resolute main extra
            #deb-src [signed-by=/etc/apt/keyrings/vendor.gpg] https://repo.example.com/apt/1.2 resolute main
            deb-src https://repo.example.com/apt/1.2 resolute main
            """,
            ".list",
        )
        entries = helper.parse_one_line(p)
        self.assertEqual(len(entries), 1)
        e = entries[0]
        self.assertEqual(e["uris"], ["https://repo.example.com/apt/1.2"])
        self.assertEqual(e["suites"], ["resolute"])
        self.assertEqual(e["comps"], ["main", "extra"])
        self.assertEqual(e["arch"], "amd64,i386")
        self.assertEqual(e["signed_by"], "/etc/apt/keyrings/vendor.gpg")

    def test_without_options(self):
        p = write("deb http://example.org/ubuntu resolute main  # trailing\n", ".list")
        (e,) = helper.parse_one_line(p)
        self.assertEqual(e["uris"], ["http://example.org/ubuntu"])
        self.assertEqual(e["comps"], ["main"])
        self.assertEqual(e["signed_by"], "")


class Deb822Format(unittest.TestCase):
    def test_multiple_paragraphs(self):
        p = write(
            """
            Types: deb deb-src
            URIs: https://a.example.com/ubuntu https://b.example.com/ubuntu
            Suites: resolute resolute-updates
            Components: main contrib
            Architectures: amd64
            Signed-By: /usr/share/keyrings/a.gpg

            # disabled entry
            Types: deb
            URIs: https://disabled.example.com/
            Suites: resolute
            Components: main
            Enabled: no

            Types: deb-src
            URIs: https://src-only.example.com/
            Suites: resolute
            Components: main
            """,
            ".sources",
        )
        entries = helper.parse_deb822(p)
        self.assertEqual(len(entries), 1)
        e = entries[0]
        self.assertEqual(e["uris"], ["https://a.example.com/ubuntu", "https://b.example.com/ubuntu"])
        self.assertEqual(e["suites"], ["resolute", "resolute-updates"])
        self.assertEqual(e["comps"], ["main", "contrib"])
        self.assertEqual(e["arch"], "amd64")
        self.assertEqual(e["signed_by"], "/usr/share/keyrings/a.gpg")

    def test_inline_key(self):
        p = write(
            """
            Types: deb
            URIs: https://inline.example.com/
            Suites: resolute
            Components: main
            Signed-By:
             -----BEGIN PGP PUBLIC KEY BLOCK-----
             .
             mQINBGExampleKeyData
             -----END PGP PUBLIC KEY BLOCK-----
            """,
            ".sources",
        )
        (e,) = helper.parse_deb822(p)
        self.assertIn("-----BEGIN PGP PUBLIC KEY BLOCK-----", e["signed_by"])
        self.assertIn("\n.\n", e["signed_by"])


class Spec(unittest.TestCase):
    def test_spec_format(self):
        self.assertEqual(
            helper.spec(name="x", url="https://e.com", suites="s", components="c", key="/k"),
            "name=x;url=https://e.com;suites=s;components=c;key=/k",
        )


if __name__ == "__main__":
    unittest.main()
