#!/usr/bin/env python3
"""Install or update Wine-Fx from its file releases, without building anything.

    python3 wine-fx-install.py [--list] [--release NAME] [--dest DIR] [--undo DIR] [--yes]

Wine-Fx releases two kinds of archives (releases.json lists them):
- Wine-<version>-base.tar.xz: Wine <version> as released, built by build.sh --vanilla. Once
  per Wine version.
- Wine-Fx-<version>-<letter>.tar.xz: only the files the patches change (and add), with
  manifest.json. Small: a new release of the patches is only this.

The script asks which release to install (Enter: the newest) and where (Enter:
~/.local/share/wine-fx/Wine-Fx-<version>). It downloads the base when that folder has no Wine
<version> yet, checks the SHA-256 of what it downloads, then puts the release's files in. The
files they replace are kept next to them as <file>.wfx-orig, and share/wine-fx/overlay.json
lists what the release changed: installing another release (an update) first puts the kept
files back, then puts the new ones in; --undo DIR only puts them back.

Only the standard library: python3 is all it needs. WINEFX_RELEASES sets where releases.json
is (an https:// or file:// URL, or a path).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path

RELEASES = os.environ.get("WINEFX_RELEASES", "https://downloads.lis-carter.site/wine-fx/releases.json")
STATE = "share/wine-fx/overlay.json"
ORIG = ".wfx-orig"


class FxError(Exception):
    pass


def _open(url: str):
    if "://" not in url:
        url = Path(url).resolve().as_uri()
    return urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "wine-fx"}), timeout=60)


def releases(url: str = RELEASES) -> list[dict]:
    """The releases, newest first."""
    with _open(url) as r:
        data = json.loads(r.read(1 << 20))
    items = data["releases"]
    base = url.rsplit("/", 1)[0] if "://" in url else Path(url).resolve().parent.as_uri()
    for item in items:   # relative file names are next to releases.json
        for part in ("base", "overlay"):
            item[part].setdefault("url", f"{base}/{item[part]['file']}")
    return sorted(items, key=lambda r: (_key(r["wine"]), r["fx"]), reverse=True)


def _key(version: str) -> list:
    return [int(x) if x.isdigit() else x for x in version.replace("-", ".").split(".")]


def download(part: dict, dest: Path, progress=None) -> Path:
    """Download a part of a release (base or overlay) into dest, checking its size and SHA-256."""
    out = dest / part["file"]
    digest, done = hashlib.sha256(), 0
    with _open(part["url"]) as r, open(out, "wb") as f:
        while chunk := r.read(1 << 20):
            f.write(chunk)
            digest.update(chunk)
            done += len(chunk)
            if progress:
                progress(done, part["size"])
    if done != part["size"] or digest.hexdigest() != part["sha256"]:
        out.unlink(missing_ok=True)
        raise FxError(f"{part['file']} is damaged (size or checksum)")
    return out


def _extract(archive: Path, into: Path) -> Path:
    """Unpack an archive whose files are under one top folder; returns that folder."""
    with tarfile.open(archive) as t:
        names = t.getnames()
        top = names[0].split("/", 1)[0]
        if any(n != top and not n.startswith(top + "/") for n in names) or ".." in Path(top).parts:
            raise FxError(f"{archive.name}: unexpected layout")
        t.extractall(into, filter="tar") if hasattr(tarfile, "tar_filter") else t.extractall(into)
    return into / top


def installed(dest: Path) -> dict:
    """What a Wine-Fx folder has: wine (version), release (overlay.json), or {} for no Wine."""
    try:
        return json.loads((dest / STATE).read_text())
    except (OSError, ValueError):
        pass
    try:
        lines = (dest / "share/wine-fx/version.txt").read_text().splitlines()
        return {"wine": lines[1].split()[-1], "release": lines[0]}
    except (OSError, IndexError):
        return {}


def undo(dest: Path) -> list[str]:
    """Put back the files the installed release replaced; remove the ones it added."""
    try:
        state = json.loads((dest / STATE).read_text())
    except (OSError, ValueError):
        return []
    done = []
    for path, info in state["files"].items():
        target, orig = dest / path, dest / (path + ORIG)
        if orig.exists() or orig.is_symlink():
            os.replace(orig, target)
        elif info.get("new") and (target.exists() or target.is_symlink()):
            target.unlink()
        done.append(path)
    (dest / STATE).unlink()
    return done


def apply(dest: Path, overlay: Path) -> dict:
    """Put an unpacked release (manifest.json, files/) into dest, after undoing the one there."""
    manifest = json.loads((overlay / "manifest.json").read_text())
    undo(dest)
    files = {}
    for path, info in manifest["files"].items():
        src, target = overlay / "files" / path, dest / path
        new = not (target.exists() or target.is_symlink())
        if not new:
            os.replace(target, dest / (path + ORIG))      # a new file over it: the running Wine keeps the old one
        target.parent.mkdir(parents=True, exist_ok=True)
        if src.is_symlink():
            os.symlink(os.readlink(src), target)
        else:
            shutil.copy2(src, target)
        files[path] = {"sha256": info["sha256"], "new": new}
    state = {"release": manifest["release"], "wine": manifest["wine"], "fx": manifest["fx"], "files": files}
    (dest / STATE).parent.mkdir(parents=True, exist_ok=True)
    (dest / STATE).write_text(json.dumps(state, indent=1))
    return state


def install(release: dict, dest: Path, progress=None, log=print) -> dict:
    """Install a release into dest: the base first if dest has no Wine of that version."""
    have = installed(dest)
    with tempfile.TemporaryDirectory(prefix="wine-fx-", dir=dest.parent if dest.parent.is_dir() else None) as tmp:
        tmp = Path(tmp)
        if have.get("wine") != release["wine"]:
            if dest.exists() and any(dest.iterdir()):
                raise FxError(f"{dest} is not empty and has no Wine {release['wine']}: choose another folder")
            log(f"downloading {release['base']['file']}")
            base = _extract(download(release["base"], tmp, progress), tmp / "base")
            dest.parent.mkdir(parents=True, exist_ok=True)
            if dest.exists():
                dest.rmdir()
            shutil.move(str(base), dest)
        log(f"downloading {release['overlay']['file']}")
        overlay = _extract(download(release["overlay"], tmp, progress), tmp / "overlay")
        return apply(dest, overlay)


def main() -> int:
    ap = argparse.ArgumentParser(description="Install or update Wine-Fx from its file releases.")
    ap.add_argument("--list", action="store_true", help="list the releases and exit")
    ap.add_argument("--release", help="the release to install, e.g. Wine-Fx-11.22-a (default: asked)")
    ap.add_argument("--dest", help="where (default: asked, ~/.local/share/wine-fx/Wine-Fx-<version>)")
    ap.add_argument("--undo", metavar="DIR", help="put back the files the installed release replaced")
    ap.add_argument("--yes", action="store_true", help="do not ask: the newest release, the default folder")
    a = ap.parse_args()
    try:
        if a.undo:
            print(f"{len(undo(Path(a.undo).expanduser()))} file(s) put back")
            return 0
        items = releases()
        if a.list:
            for r in items:
                print(f"{r['release']}  (Wine {r['wine']})")
            return 0
        if a.release:
            release = next((r for r in items if r["release"] == a.release), None)
            if not release:
                raise FxError(f"no release {a.release} (--list)")
        elif a.yes or not sys.stdin.isatty():
            release = items[0]
        else:
            for i, r in enumerate(items, 1):
                print(f"  {i}) {r['release']}  (Wine {r['wine']})")
            answer = input("Which release? [1] ").strip() or "1"
            release = items[int(answer) - 1]
        default = Path.home() / ".local/share/wine-fx" / f"Wine-Fx-{release['wine']}"
        dest = Path(a.dest).expanduser() if a.dest else default
        if not a.dest and not a.yes and sys.stdin.isatty():
            dest = Path(input(f"Install into [{default}] ").strip() or default).expanduser()
        have = installed(dest).get("release")
        print(f"{release['release']} -> {dest}" + (f" (now {have})" if have else ""))

        def progress(done, total):
            print(f"\r    {done * 100 // total if total else 0}%", end="", flush=True)
        state = install(release, dest.resolve(), progress, log=lambda m: print(f"\n>>> {m}"))
        print(f"\ndone: {dest}/bin/wine, {state['release']} ({len(state['files'])} file(s) of the release)")
        return 0
    except (FxError, OSError, ValueError, KeyError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
