#!/bin/bash
# Makes the file release of Wine-Fx for one Wine version (what wine-fx-install.py and Wine Fox
# install), into dist/:
#
#   bash make-release.sh [version] [--jobs N]
#
#   Wine-Fx-<version>-<fx>.tar.xz  the files the patches change or add, with manifest.json
#                                  (fx: FX_RELEASE of versions/<version>/wine.conf)
#   releases.json                  every release in dist/, for the installers
#
# The base is not ours: a ready Wine of that version as released (BASE_URL of wine.conf,
# Kron4ek's build), downloaded by the installers; the release's files go over it. To know which
# files the patches change, Wine is built without them, then they are applied to the same tree
# and only what they touch is built again.
# Build it on an old distribution (an Ubuntu 22.04 chroot, glibc 2.35): the Unix modules of the
# release then also run on the systems the base runs on.
# Upload the archive to the GitHub release of the tag <version>-<fx>, with releases.json. Raise
# FX_RELEASE in wine.conf before releasing changed patches.
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
[ -n "${BASE_URL:-}" ] || { echo "error: no BASE_URL in versions/$VERSION/wine.conf" >&2; exit 1; }
FX=${FX_RELEASE:-a}
DIST=$HERE/dist
NAME=Wine-Fx-$VERSION-$FX
WORK=$HERE/work/$VERSION-release      # one tree for both builds
PREFIX=$WORK/install                  # the same prefix for both: nothing differs by its path
mkdir -p "$DIST"
export WORK

echo ">>> Wine $WINE_VERSION without the patches"
bash "$HERE/build.sh" "$VERSION" --vanilla --yes --no-deps --prefix "$PREFIX" "${JOBS[@]}"
rm -rf "$WORK/vanilla"
cp -a "$PREFIX" "$WORK/vanilla"

echo ">>> $NAME: the patches over the same tree"
bash "$HERE/build.sh" "$VERSION" --all --yes --no-deps --keep-build --prefix "$PREFIX" "${JOBS[@]}"

echo ">>> $NAME.tar.xz: what differs from the base"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
python3 - "$WORK/vanilla" "$PREFIX" "$STAGE/$NAME" "$NAME" "$WINE_VERSION" "$FX" <<'EOF'
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
python3 - "$DIST" "$NAME" "$WINE_VERSION" "$FX" "$HERE/versions/$VERSION/patches" "$BASE_URL" "$BASE_SIZE" "$BASE_SHA256" <<'EOF'
import hashlib, json, re, sys, time
from pathlib import Path
dist, name, wine, letter, patches = Path(sys.argv[1]), *sys.argv[2:5], Path(sys.argv[5])
base_url, base_size, base_sha = sys.argv[6:9]
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
                         "base": {"file": base_url.rsplit("/", 1)[1], "url": base_url,
                                  "size": int(base_size), "sha256": base_sha}, "overlay": part(f"{name}.tar.xz"), "patches": subjects})
path.write_text(json.dumps(data, indent=1) + "\n")
EOF
ls -la "$DIST"
echo "upload $NAME.tar.xz and releases.json to the GitHub release $VERSION-$FX"
