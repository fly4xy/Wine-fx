#!/bin/bash
# Makes the file releases of Wine-Fx (what wine-fx-install.py and Wine Fox install), into dist/:
#
#   bash make-release.sh [version] [--jobs N]
#
#   Wine-<version>-base.tar.xz     Wine as released, built by build.sh --vanilla: made once per
#                                  Wine version (kept in dist/ and reused)
#   Wine-Fx-<version>-<fx>.tar.xz  the files the patches change or add, with manifest.json
#                                  (fx: FX_RELEASE of versions/<version>/wine.conf)
#   releases.json                  every release in dist/, for the installers
#
# Upload the new files of dist/ to the server ($RELEASES_BASE) with releases.json last. Both
# builds are made here, with the same compilers and options: the release's files fit the base
# exactly. Raise FX_RELEASE in wine.conf before releasing changed patches.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
VERSION="" JOBS=()
while [ $# -gt 0 ]; do
    case $1 in
        --jobs) JOBS=(--jobs "$2"); shift ;;
        -h|--help) sed -n '2,/^set -e/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) VERSION=$1 ;;
    esac
    shift
done
[ -n "$VERSION" ] || VERSION=$(ls "$HERE/versions" | sort -V | tail -1)
. "$HERE/versions/$VERSION/wine.conf"
FX=${FX_RELEASE:-a}
RELEASES_BASE=${RELEASES_BASE:-https://downloads.lis-carter.site/wine-fx}
DIST=$HERE/dist
BASE=Wine-$WINE_VERSION-base
NAME=Wine-Fx-$VERSION-$FX
mkdir -p "$DIST"

if [ ! -f "$DIST/$BASE.tar.xz" ]; then
    echo ">>> $BASE: Wine $WINE_VERSION as released"
    WORK=$HERE/work/$VERSION-vanilla bash "$HERE/build.sh" "$VERSION" --vanilla --yes --no-deps \
        --prefix "$HERE/wine_dist/$BASE" "${JOBS[@]}"
    tar -C "$HERE/wine_dist" -cJf "$DIST/$BASE.tar.xz" "$BASE"
fi
[ -d "$HERE/wine_dist/$BASE" ] || tar -C "$HERE/wine_dist" -xJf "$DIST/$BASE.tar.xz"

echo ">>> $NAME: with all the patches"
bash "$HERE/build.sh" "$VERSION" --all --yes --no-deps --prefix "$HERE/wine_dist/Wine-Fx-$VERSION" "${JOBS[@]}"

echo ">>> $NAME.tar.xz: what differs from the base"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
python3 - "$HERE/wine_dist/$BASE" "$HERE/wine_dist/Wine-Fx-$VERSION" "$STAGE/$NAME" "$NAME" "$WINE_VERSION" "$FX" <<'EOF'
import hashlib, json, os, shutil, sys
from pathlib import Path
base, fx, out, name, wine, letter = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3]), *sys.argv[4:]
def content(p):
    return ("link:" + os.readlink(p)).encode() if p.is_symlink() else p.read_bytes()
files, removed = {}, []
for p in sorted(fx.rglob("*")):
    rel = p.relative_to(fx).as_posix()
    if p.is_dir() and not p.is_symlink() or rel == "share/wine-fx/overlay.json":
        continue
    b = base / rel
    if (b.exists() or b.is_symlink()) and content(b) == content(p):
        continue
    dst = out / "files" / rel
    dst.parent.mkdir(parents=True, exist_ok=True)
    if p.is_symlink():
        os.symlink(os.readlink(p), dst)
    else:
        shutil.copy2(p, dst)
    files[rel] = {"sha256": hashlib.sha256(content(p)).hexdigest()}
for p in base.rglob("*"):
    rel = p.relative_to(base).as_posix()
    if not (fx / rel).exists() and not (fx / rel).is_symlink():
        removed.append(rel)
if removed:
    print("warning: files of the base that the build does not have stay:", *removed[:10], sep="\n  ")
(out / "manifest.json").write_text(json.dumps({"release": name, "wine": wine, "fx": letter, "files": files}, indent=1))
print(f"    {len(files)} file(s)")
EOF
tar -C "$STAGE" -cJf "$DIST/$NAME.tar.xz" "$NAME"

echo ">>> releases.json"
python3 - "$DIST" "$NAME" "$BASE" "$WINE_VERSION" "$FX" "$HERE/versions/$VERSION/patches" <<'EOF'
import hashlib, json, re, sys, time
from pathlib import Path
dist, name, base, wine, letter, patches = Path(sys.argv[1]), *sys.argv[2:6], Path(sys.argv[6])
def part(f):
    p = dist / f
    return {"file": f, "size": p.stat().st_size, "sha256": hashlib.sha256(p.read_bytes()).hexdigest()}
subjects = []
for p in sorted(patches.glob("*.patch")):
    m = re.search(r"^Subject: \[PATCH\] (.*)$", p.read_text(), re.M)
    subjects.append(f"{p.name[:4]} {m.group(1) if m else p.stem}")
path = dist / "releases.json"
data = json.loads(path.read_text()) if path.exists() else {"releases": []}
data["releases"] = [r for r in data["releases"] if r["release"] != name]
data["releases"].append({"release": name, "wine": wine, "fx": letter, "date": time.strftime("%Y-%m-%d"),
                         "base": part(f"{base}.tar.xz"), "overlay": part(f"{name}.tar.xz"), "patches": subjects})
path.write_text(json.dumps(data, indent=1) + "\n")
EOF
ls -la "$DIST"
echo "upload to $RELEASES_BASE: $NAME.tar.xz (and $BASE.tar.xz if it is not there yet), then releases.json"
