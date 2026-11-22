#!/usr/bin/env python3
"""Install or update Wine-Fx from its file releases, without building anything.

    python3 wine-fx-install.py [--list] [--release NAME] [--dest DIR] [--undo DIR] [--yes]

In an unpacked release archive (Wine-Fx-<version>-<letter>.tar.xz: this script, manifest.json,
files/) it installs that release from those files and downloads only the base. On its own it
reads the list of releases from GitHub and downloads both.

A release of Wine-Fx (releases.json lists them) is two archives:
- the base: a ready Wine <version> as released (Kron4ek's build, from its own GitHub
  releases), not made by Wine-Fx;
- Wine-Fx-<version>-<letter>.tar.xz: only the files the patches change (and add), with
  manifest.json. Small: a new release of the patches is only this.

The script asks which Wine version (Enter: the newest) and where (Enter:
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
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path

RELEASES = os.environ.get("WINEFX_RELEASES", "https://github.com/fly4xy/Wine-fx/releases/latest/download/releases.json")
HERE = Path(__file__).resolve().parent
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
    for path, info in state.get("files", {}).items():
        target, orig = dest / path, dest / (path + ORIG)
        if orig.exists() or orig.is_symlink():
            os.replace(orig, target)
        elif info.get("new") and (target.exists() or target.is_symlink()):
            target.unlink()
        done.append(path)
    # the Wine version stays known (a base from elsewhere has no version.txt of ours)
    (dest / STATE).write_text(json.dumps({"wine": state["wine"]}))
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


def install(release: dict, dest: Path, progress=None, log=print, overlay: Path | None = None) -> dict:
    """Install a release into dest: the base first if dest has no Wine of that version. overlay:
    the release already unpacked (the archive this script came in), else it is downloaded."""
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
        if overlay is None:
            log(f"downloading {release['overlay']['file']}")
            overlay = _extract(download(release["overlay"], tmp, progress), tmp / "overlay")
        return apply(dest, overlay)


def local_release() -> dict | None:
    """The release of the archive this script is in (manifest.json and files/ next to it)."""
    try:
        m = json.loads((HERE / "manifest.json").read_text())
    except (OSError, ValueError):
        return None
    return m if (HERE / "files").is_dir() and "base" in m else None


TERMINALS = (("konsole", "-e"), ("gnome-terminal", "--"), ("kgx", "--"), ("xfce4-terminal", "-x"),
             ("mate-terminal", "-x"), ("kitty", None), ("alacritty", "-e"), ("foot", None),
             ("x-terminal-emulator", "-e"), ("xterm", "-e"))


def in_terminal() -> None:
    """Started from the file manager (no terminal, no arguments): run again in a terminal window,
    which stays open at the end."""
    if len(sys.argv) > 1 or sys.stdin.isatty() or not (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")):
        return
    run = f'"{sys.executable}" "{Path(__file__).resolve()}"; echo; read -rp "Press Enter to close this window. "'
    for name, flag in TERMINALS:
        if shutil.which(name):
            os.execvp(name, [name, *([flag] if flag else []), "bash", "-c", run])
    subprocess.run(["notify-send", "Wine-Fx", "No terminal found: run python3 wine-fx-install.py in one"], check=False)
    sys.exit(1)


def main() -> int:
    ap = argparse.ArgumentParser(description="Install or update Wine-Fx from its file releases.")
    ap.add_argument("--list", action="store_true", help="list the releases and exit")
    ap.add_argument("--release", help="the release to install, e.g. Wine-Fx-11.22-a (default: asked)")
    ap.add_argument("--dest", help="where (default: asked, ~/.local/share/wine-fx/Wine-Fx-<version>)")
    ap.add_argument("--undo", metavar="DIR", help="put back the files the installed release replaced")
    ap.add_argument("--yes", action="store_true", help="do not ask: the newest release, the default folder")
    a = ap.parse_args()
    in_terminal()
    try:
        if a.undo:
            print(f"{len(undo(Path(a.undo).expanduser()))} file(s) put back")
            return 0
        local = None if (a.list or a.release) else local_release()
        try:
            items = releases()
        except (OSError, ValueError, KeyError):
            if not local:
                raise
            items = []   # offline: this archive's release only
        if local:   # this archive's release first; its files are here
            items = [local] + [r for r in items if r["release"] != local["release"]]
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
        else:   # the Wine version, with the newest release of the patches for it
            newest = list({r["wine"]: r for r in reversed(items)}.values())[::-1]
            if local:   # this archive's Wine first, whatever its version
                newest.sort(key=lambda r: r is not local)
            for i, r in enumerate(newest, 1):
                here = ", files in this archive" if r is local else ""
                print(f"  {i}) Wine {r['wine']}  ({r['release']}{here})")
            answer = input("Which Wine? [1] ").strip() or "1"
            release = newest[int(answer) - 1]
        default = Path.home() / ".local/share/wine-fx" / f"Wine-Fx-{release['wine']}"
        dest = Path(a.dest).expanduser() if a.dest else default
        if not a.dest and not a.yes and sys.stdin.isatty():
            dest = Path(input(f"Install into [{default}] ").strip() or default).expanduser()
        have = installed(dest).get("release")
        print(f"{release['release']} -> {dest}" + (f" (now {have})" if have else ""))

        def progress(done, total):
            print(f"\r    {done * 100 // total if total else 0}%", end="", flush=True)
        state = install(release, dest.resolve(), progress, log=lambda m: print(f"\n>>> {m}"),
                        overlay=HERE if release is local else None)
        print(f"\ndone: {dest}/bin/wine, {state['release']} ({len(state['files'])} file(s) of the release)")
        return 0
    except (FxError, OSError, ValueError, KeyError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
