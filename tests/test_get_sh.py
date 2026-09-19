"""End-to-end runs of get.sh, and of the release resolution in install.sh,
uninstall.sh and restore.sh, against stub `midclt` and `curl` commands on
PATH.

The curl stub serves canned GitHub API pages and release assets. A script
asset is a fake that prints which asset and release it is, the arguments it
got, which release files sit beside it and the image it was handed, so the
tests see exactly what get.sh would run. Tags listed in STUB_LEGACY get an
install.sh without --release, like every release from before per-train
sign-off (v2026.07.15-r5 and older)."""
import json
import os
import re
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

from release_fixtures import release, tag

ROOT = Path(__file__).resolve().parents[1]
GET_SH = ROOT / "get.sh"
SCRIPTS = ROOT / "scripts"
BUILD_YML = ROOT / ".github" / "workflows" / "build.yml"
REPO = "truenas-community-sysexts/prometheus-exporters"
FORK = "someone/prometheus-exporters"

CURL_STUB = textwrap.dedent('''\
    #!/usr/bin/env python3
    import hashlib, json, os, re, sys
    args = sys.argv[1:]
    url = next(a for a in args if a.startswith("http"))
    with open(os.environ["STUB_LOG"], "a") as f:
        f.write("curl " + url + "\\n")
    out = args[args.index("-o") + 1] if "-o" in args else None
    def emit(text):
        if out:
            with open(out, "w") as f:
                f.write(text)
        else:
            sys.stdout.write(text)
    FAKE = """#!/usr/bin/env bash
    %s
    d="$(cd "$(dirname "$0")" && pwd)"
    echo "RAN %s from %s with: $*"
    for s in install.sh uninstall.sh restore.sh prometheus-exporters-lib.sh; do
        if [ -f "$d/$s" ]; then echo "beside: $s"; fi
    done
    for a in "$@"; do
        if [ -f "$a" ]; then echo "image: $(cat "$a")"; fi
    done
    """
    if "api.github.com" in url:
        page = int(re.search(r"[?&]page=(\\d+)", url).group(1))
        pages = json.load(open(os.environ["STUB_PAGES"]))
        print(json.dumps(pages[page - 1] if page <= len(pages) else []))
    elif "/releases/download/" in url:
        tag, asset = url.split("/releases/download/")[1].split("/")
        legacy = tag in os.environ.get("STUB_LEGACY", "").split()
        image = "IMAGE " + tag + "\\n"
        if asset == "prometheus-exporters.raw":
            emit(image)
        elif asset == "prometheus-exporters.raw.sha256":
            data = "tampered" if os.environ.get("STUB_BAD_SHA") else image
            emit(hashlib.sha256(data.encode()).hexdigest() + "  prometheus-exporters.raw\\n")
        elif asset == "prometheus-exporters-lib.sh":
            emit('pe_lib_tag() { echo "' + tag + '"; }\\n')
        elif asset.endswith(".sh"):
            flag = "" if legacy else "# case $arg in --release=*) ;; esac"
            emit(FAKE % (flag, asset, tag))
        else:
            sys.exit(22)
    else:
        sys.exit(22)
    ''')

MIDCLT_STUB = textwrap.dedent("""\
    #!/usr/bin/env bash
    echo "midclt $*" >> "$STUB_LOG"
    [ -n "$STUB_VERSION" ] || exit 1
    echo "{\\"version\\": \\"$STUB_VERSION\\"}"
    """)

R4, R5, R6, R7, R8 = (tag(n) for n in (4, 5, 6, 7, 8))
# r8 untested, r7 approved on 26 only, r6 a full release from before
# per-train sign-off (grandfathered everywhere).
RELEASES = [release(R8, prerelease=True), release(R7, trains=["26"]),
            release(R6), release(R5)]


class Stubbed(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)
        self.bin = self.dir / "bin"
        self.bin.mkdir()
        for name, text in (("curl", CURL_STUB), ("midclt", MIDCLT_STUB)):
            path = self.bin / name
            path.write_text(text)
            path.chmod(0o755)
        self.log = self.dir / "log"
        self.log.write_text("")

    def tearDown(self):
        self._tmp.cleanup()

    def run_bash(self, args, version, releases=RELEASES, legacy=(), bad_sha=False,
                 stdin=None, cwd=None):
        pages = self.dir / "pages.json"
        pages.write_text(json.dumps([releases]))
        env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                   STUB_LOG=str(self.log), STUB_PAGES=str(pages),
                   STUB_VERSION=version, STUB_LEGACY=" ".join(legacy),
                   TMPDIR=str(self.dir))
        env.pop("PROMETHEUS_EXPORTERS_REPO", None)
        if bad_sha:
            env["STUB_BAD_SHA"] = "1"
        return subprocess.run(["bash", *args], capture_output=True, text=True,
                              env=env, input=stdin, cwd=cwd)

    def calls(self):
        return self.log.read_text().splitlines()

    def downloads(self):
        """(repo, tag, asset) of every release asset download."""
        out = []
        for c in self.calls():
            m = re.search(r"github\.com/([^/]+/[^/]+)/releases/download/([^/]+)/(\S+)$", c)
            if m:
                out.append(m.groups())
        return out

    def assert_no_selection(self):
        self.assertFalse(any(c.startswith("midclt") or "api.github.com" in c
                             for c in self.calls()), self.calls())


class GetShRun(Stubbed):
    def get(self, *args, version="25.10.7", **kw):
        return self.run_bash([str(GET_SH), *args], version, **kw)

    def ran(self, p):
        self.assertEqual(p.returncode, 0, p.stderr)
        return p.stdout.splitlines()


class GetSh(GetShRun):
    def test_runs_the_approved_releases_installer_pinned_to_it(self):
        out = self.ran(self.get())
        self.assertEqual(out[0], f"RAN install.sh from {R6} with: --release={R6}")
        self.assertIn("beside: prometheus-exporters-lib.sh", out)
        self.assertEqual(self.downloads(), [(REPO, R6, "install.sh"),
                                            (REPO, R6, "prometheus-exporters-lib.sh")])

    def test_each_train_gets_its_own_approved_release(self):
        out = self.ran(self.get(version="26.0.0-BETA.3"))
        self.assertEqual(out[0], f"RAN install.sh from {R7} with: --release={R7}")

    def test_enable_and_other_flags_pass_through(self):
        out = self.ran(self.get("--enable=node_exporter,smartctl_exporter", "--pool=fast"))
        self.assertEqual(out[0], f"RAN install.sh from {R6} with: "
                                 f"--enable=node_exporter,smartctl_exporter --pool=fast --release={R6}")

    def test_uninstall_runs_the_approved_releases_uninstaller_with_its_siblings(self):
        out = self.ran(self.get("--uninstall"))
        self.assertEqual(out[0], f"RAN uninstall.sh from {R6} with: ")
        self.assertIn("beside: restore.sh", out)
        self.assertIn("beside: prometheus-exporters-lib.sh", out)
        self.assertEqual(sorted(a for _, t, a in self.downloads() if t == R6),
                         ["prometheus-exporters-lib.sh", "restore.sh", "uninstall.sh"])

    def test_pinned_release_skips_selection(self):
        out = self.ran(self.get(f"--release={R8}", "--check"))
        self.assertEqual(out[0], f"RAN install.sh from {R8} with: --check --release={R8}")
        self.assert_no_selection()

    def test_pinned_uninstall(self):
        out = self.ran(self.get("--uninstall", f"--release={R8}"))
        self.assertEqual(out[0], f"RAN uninstall.sh from {R8} with: ")
        self.assert_no_selection()

    def test_no_approved_release_stops_before_any_download(self):
        p = self.get(version="26.0.0-BETA.3", releases=[release(R8, prerelease=True)])
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("No release is approved for TrueNAS train 26 yet", p.stderr)
        self.assertEqual(self.downloads(), [])

    def test_unreadable_truenas_version_is_an_error(self):
        p = self.get(version="")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("could not read the TrueNAS version", p.stderr)
        self.assertEqual(self.downloads(), [])

    def test_empty_release_flag_is_refused(self):
        self.assertEqual(self.get("--release=").returncode, 2)

    def test_temp_dir_is_removed(self):
        self.ran(self.get())
        self.assertEqual(list(self.dir.glob("pe-get.*")), [])

    def test_repo_selects_and_downloads_from_the_fork(self):
        out = self.ran(self.get(f"--repo={FORK}", "--enable=all"))
        self.assertEqual(out[0], f"RAN install.sh from {R6} with: "
                                 f"--enable=all --repo={FORK} --release={R6}")
        self.assertIn(f"api.github.com/repos/{FORK}/releases", "\n".join(self.calls()))
        self.assertEqual({r for r, _, _ in self.downloads()}, {FORK})

    def test_repo_is_not_passed_to_the_uninstaller(self):
        # restore.sh rejects options it does not know.
        out = self.ran(self.get("--uninstall", f"--repo={FORK}"))
        self.assertEqual(out[0], f"RAN uninstall.sh from {R6} with: ")
        self.assertEqual({r for r, _, _ in self.downloads()}, {FORK})


class GetShLegacyInstaller(GetShRun):
    """A release from before per-train sign-off has an install.sh with no
    --release flag, which downloads GitHub's Latest image unless it is given
    a local one. get.sh hands it the image of the selected release."""

    def test_legacy_installer_gets_the_releases_image_not_release_flag(self):
        out = self.ran(self.get("--enable=all", legacy=[R6]))
        self.assertTrue(out[0].startswith(f"RAN install.sh from {R6} with: --enable=all /"), out[0])
        self.assertTrue(out[0].endswith("/prometheus-exporters.raw"), out[0])
        self.assertNotIn("--release", out[0])
        self.assertIn(f"image: IMAGE {R6}", out)
        self.assertIn("beside: prometheus-exporters-lib.sh", out)
        self.assertEqual(sorted(a for _, t, a in self.downloads() if t == R6),
                         ["install.sh", "prometheus-exporters-lib.sh",
                          "prometheus-exporters.raw", "prometheus-exporters.raw.sha256"])

    def test_todays_releases_install_r5_on_both_trains(self):
        # The live shape at the cutover: r5 is the newest full release (no
        # markers), r4 an untested prerelease.
        rels = [release(R5), release(R4, prerelease=True)]
        for version in ("25.10.4", "26.0.0-BETA.1"):
            self.log.write_text("")
            out = self.ran(self.get("--enable=node_exporter", version=version,
                                    releases=rels, legacy=[R5, R4]))
            self.assertTrue(out[0].startswith(f"RAN install.sh from {R5} with: --enable=node_exporter /"))
            self.assertIn(f"image: IMAGE {R5}", out)

    def test_bad_checksum_stops_before_the_installer_runs(self):
        p = self.get("--enable=all", legacy=[R6], bad_sha=True)
        self.assertNotEqual(p.returncode, 0)
        self.assertNotIn("RAN", p.stdout)
        self.assertIn("failed its checksum", p.stderr)

    def test_check_list_and_help_need_no_image(self):
        for flag in ("--check", "--list", "--help"):
            self.log.write_text("")
            out = self.ran(self.get(flag, legacy=[R6]))
            self.assertEqual(out[0], f"RAN install.sh from {R6} with: {flag}")
            self.assertNotIn("prometheus-exporters.raw", [a for _, _, a in self.downloads()])

    def test_a_users_own_image_is_left_alone(self):
        image = self.dir / "mine.raw"
        image.write_text("MY IMAGE\n")
        out = self.ran(self.get(str(image), legacy=[R6]))
        self.assertEqual(out[0], f"RAN install.sh from {R6} with: {image}")
        self.assertNotIn("prometheus-exporters.raw", [a for _, _, a in self.downloads()])

    def test_legacy_uninstaller_is_run_the_same_way(self):
        out = self.ran(self.get("--uninstall", legacy=[R6]))
        self.assertEqual(out[0], f"RAN uninstall.sh from {R6} with: ")


def function(text, name):
    return re.search(rf"^{name}\(\) \{{\n.*?^\}}\n", text, re.S | re.M).group(0)


def block(text):
    return text[text.index("# BEGIN approved-release"):text.index("# END approved-release")]


class InstallerResolve(Stubbed):
    """install.sh run without get.sh (a raw download, or the script alone)
    takes its lib and image from --release, else from the release approved
    for the box's train, resolved once."""

    def resolve(self, version, release_tag="", lib_beside=False):
        text = (SCRIPTS / "install.sh").read_text()
        work = self.dir / "work"
        work.mkdir()
        if lib_beside:
            (self.dir / "prometheus-exporters-lib.sh").write_text('pe_lib_tag() { echo beside; }\n')
        script = self.dir / "resolve.sh"
        script.write_text(
            f'set -euo pipefail\nREPO="{REPO}"\nRELEASE_TAG="{release_tag}"\n'
            f'RESOLVED_TAG=""\nRELEASE_DL_BASE=""\nWORK_DIR="{work}"\n{block(text)}\n'
            + "".join(function(text, n) for n in ("resolve_release", "download_image", "_source_pe_lib"))
            + '_source_pe_lib || { echo "lib failed" >&2; exit 1; }\n'
              'echo "lib=$(pe_lib_tag)"\ndownload_image\n'
              'echo "image=$(cat "$WORK_DIR/prometheus-exporters.raw")"\n')
        return self.run_bash([str(script)], version)

    def test_auto_resolve_takes_the_approved_release_once(self):
        p = self.resolve("26.1.0")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn(f"lib={R7}", p.stdout)
        self.assertIn(f"image=IMAGE {R7}", p.stdout)
        self.assertEqual(sum(c.startswith("midclt") for c in self.calls()), 1)
        self.assertEqual({t for _, t, _ in self.downloads()}, {R7})

    def test_no_approved_release_stops_instead_of_using_latest(self):
        pages = [release(R8, prerelease=True)]
        text = (SCRIPTS / "install.sh").read_text()
        self.assertNotIn("releases/latest", text)
        p = self.run_bash(["-c", f'REPO="{REPO}"\nRELEASE_TAG=""\nRESOLVED_TAG=""\n{block(text)}\n'
                           + function(text, "resolve_release")
                           + 'resolve_release\necho "tag=$RESOLVED_TAG"\n'],
                          "26.1.0", releases=pages)
        self.assertNotEqual(p.returncode, 0)
        self.assertNotIn("tag=", p.stdout)
        self.assertIn("No release is approved for TrueNAS train 26 yet", p.stderr)
        self.assertEqual(self.downloads(), [])

    def test_explicit_release_is_trusted(self):
        p = self.resolve("", release_tag=R8)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn(f"lib={R8}", p.stdout)
        self.assertIn(f"image=IMAGE {R8}", p.stdout)
        self.assert_no_selection()

    def test_lib_beside_the_script_is_used(self):
        # What get.sh sets up: the lib comes with install.sh, not the network.
        p = self.resolve("", release_tag=R6, lib_beside=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("lib=beside", p.stdout)
        self.assertEqual([a for _, _, a in self.downloads()],
                         ["prometheus-exporters.raw", "prometheus-exporters.raw.sha256"])

    def test_release_flag_is_accepted(self):
        text = (SCRIPTS / "install.sh").read_text()
        self.assertRegex(text, r"(?m)^\s+--release=\*\)\s+RELEASE_TAG=")
        # get.sh detects an installer that takes --release by this string.
        self.assertIn("--release=*)", text)
        self.assertIn("grep -qF -- '--release=*)'", GET_SH.read_text())


class UninstallerResolve(Stubbed):
    """uninstall.sh piped to bash (no restore.sh beside it) fetches restore.sh
    and the lib from the pinned or approved release, never Latest."""

    def uninstall(self, *args, version="25.10.7", beside=False):
        cwd = self.dir / "cwd"
        cwd.mkdir()
        if beside:
            script = cwd / "uninstall.sh"
            script.write_text((SCRIPTS / "uninstall.sh").read_text())
            (cwd / "restore.sh").write_text('echo "RAN local restore.sh with: $*"\n')
            return self.run_bash([str(script), *args], version)
        # curl | sudo bash -s -- ARGS
        return self.run_bash(["-s", "--", *args], version, cwd=str(cwd),
                             stdin=(SCRIPTS / "uninstall.sh").read_text())

    def test_piped_uninstall_uses_the_approved_release(self):
        p = self.uninstall(version="26.0.0-BETA.3")
        self.assertEqual(p.returncode, 0, p.stderr)
        out = p.stdout.splitlines()
        self.assertEqual(out[0], f"RAN restore.sh from {R7} with: ")
        self.assertIn("beside: prometheus-exporters-lib.sh", out)
        self.assertEqual(sorted(a for _, t, a in self.downloads() if t == R7),
                         ["prometheus-exporters-lib.sh", "restore.sh"])

    def test_pinned_release_is_used_and_not_passed_on(self):
        p = self.uninstall(f"--release={R8}")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout.splitlines()[0], f"RAN restore.sh from {R8} with: ")
        self.assert_no_selection()

    def test_no_approved_release_stops(self):
        pages_rel = [release(R8, prerelease=True)]
        cwd = self.dir / "cwd"
        cwd.mkdir()
        p = self.run_bash(["-s"], "26.0.0-BETA.3", releases=pages_rel, cwd=str(cwd),
                          stdin=(SCRIPTS / "uninstall.sh").read_text())
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("No release is approved", p.stderr)
        self.assertEqual(self.downloads(), [])

    def test_restore_beside_it_runs_without_the_network(self):
        p = self.uninstall(f"--release={R8}", beside=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout.strip(), "RAN local restore.sh with:")
        self.assertEqual(self.calls(), [])


class RestoreLib(Stubbed):
    """restore.sh without the lib beside it fetches it from the pinned or
    approved release."""

    def source(self, version, release_tag=""):
        text = (SCRIPTS / "restore.sh").read_text()
        self.assertNotIn("releases/latest", text)
        script = self.dir / "restore-lib.sh"
        script.write_text(f'REPO="{REPO}"\nRELEASE_TAG="{release_tag}"\n{block(text)}\n'
                          + function(text, "_source_pe_lib")
                          + '_source_pe_lib || exit 1\necho "lib=$(pe_lib_tag)"\n')
        return self.run_bash([str(script)], version)

    def test_approved_release(self):
        p = self.source("25.10.7")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout.strip(), f"lib={R6}")

    def test_pinned_release(self):
        p = self.source("", release_tag=R8)
        self.assertEqual(p.stdout.strip(), f"lib={R8}")
        self.assert_no_selection()


class BuildUploadsWhatGetShNeeds(Stubbed):
    """Every release asset get.sh downloads (new and legacy installers,
    install and uninstall) is one build.yml attaches to the release."""

    def uploaded(self):
        lines = BUILD_YML.read_text().splitlines()
        start = next(i for i, ln in enumerate(lines) if ln.strip() == "files: |")
        indent = len(lines[start]) - len(lines[start].lstrip())
        names = set()
        for ln in lines[start + 1:]:
            if ln.strip() and len(ln) - len(ln.lstrip()) <= indent:
                break
            if ln.strip() and not ln.strip().startswith("#"):
                names.add(ln.strip().rsplit("/", 1)[-1])
        return names

    def test_every_downloaded_asset_is_uploaded(self):
        runs = [([], ()), (["--enable=all"], (R6,)), (["--uninstall"], ())]
        for args, legacy in runs:
            p = self.run_bash([str(GET_SH), *args], "25.10.7", legacy=legacy)
            self.assertEqual(p.returncode, 0, p.stderr)
        fetched = {a for _, _, a in self.downloads()}
        self.assertEqual(fetched, {"install.sh", "uninstall.sh", "restore.sh",
                                   "prometheus-exporters-lib.sh", "prometheus-exporters.raw",
                                   "prometheus-exporters.raw.sha256"})
        self.assertLessEqual(fetched, self.uploaded())


if __name__ == "__main__":
    unittest.main()
