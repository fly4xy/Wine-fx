#!/bin/bash
# Makes the release of Wine-Fx for one Wine version, into dist/: the two ways to get it.
#
#   bash make-release.sh [version] [--jobs N] [--pack-only]
#
#   Wine-Fx-<version>-<fx>-build.tar.gz  1. build it: build.sh and the patches of this version.
#                                           build.sh asks the Wine version, downloads its
#                                           sources, installs the dependencies, asks all patches
#                                           or chosen ones, builds Wine.
#   Wine-Fx-<version>-<fx>.tar.xz        2. install it ready: install.sh and the files the
#                                           patches change (files/, SHA256SUMS, release.conf;
#                                           manifest.json for Wine Fox). The script asks the
#                                           Wine version, downloads a ready Wine of it (the
#                                           base: BASE_URL of wine.conf, Kron4ek's build) and
#                                           puts the files over it. Light: no Wine inside.
#   releases.txt, install.sh             the list install.sh reads, and the script on its own
#   releases.json                        the list Wine Fox reads
#
# (fx: FX_RELEASE of versions/<version>/wine.conf.) To know which files the patches change, Wine
# is built without them, then they are applied to the same tree and only what they touch is
# built again. Build it on an old distribution (an Ubuntu 22.04 chroot, glibc 2.35): the Unix
# modules of the release then run on the systems the base runs on. --pack-only packs again
# from the builds already made (work/<version>-release).
# Attach everything in dist/ to the GitHub release of the tag <version>-<fx>. Raise FX_RELEASE in
# wine.conf before releasing changed patches.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
VERSION="" JOBS=() PACK_ONLY=""
while [ $# -gt 0 ]; do
    case $1 in
        --jobs) JOBS=(--jobs "$2"); shift ;;
        --pack-only) PACK_ONLY=1 ;;
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
DOWNLOADS=${DOWNLOADS:-https://github.com/fly4xy/Wine-fx/releases/download}   # <tag>/<file>
WORK=$HERE/work/$VERSION-release      # one tree for both builds
PREFIX=$WORK/install                  # the same prefix for both: nothing differs by its path
mkdir -p "$DIST"
export WORK

if [ -z "$PACK_ONLY" ]; then
    echo ">>> Wine $WINE_VERSION without the patches"
    bash "$HERE/build.sh" "$VERSION" --vanilla --yes --no-deps --prefix "$PREFIX" "${JOBS[@]}"
    rm -rf "$WORK/vanilla"
    cp -a "$PREFIX" "$WORK/vanilla"
    echo ">>> $NAME: the patches over the same tree"
    bash "$HERE/build.sh" "$VERSION" --all --yes --no-deps --keep-build --prefix "$PREFIX" "${JOBS[@]}"
fi
[ -d "$WORK/vanilla" ] && [ -f "$PREFIX/share/wine-fx/version.txt" ] || { echo "error: no builds in $WORK" >&2; exit 1; }

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

echo ">>> $NAME.tar.xz (2. install it ready): what differs from Wine without the patches"
python3 - "$WORK/vanilla" "$PREFIX" "$STAGE/$NAME" "$NAME" "$WINE_VERSION" "$FX" "$BASE_URL" "$BASE_SIZE" "$BASE_SHA256" <<'EOF'
import hashlib, json, os, shutil, sys
from pathlib import Path
base, fx, out = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
name, wine, letter, base_url, base_size, base_sha = sys.argv[4:10]
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
manifest = {"release": name, "wine": wine, "fx": letter,
            "base": {"file": base_url.rsplit("/", 1)[1], "url": base_url, "size": int(base_size), "sha256": base_sha},
            "files": files}
(out / "manifest.json").write_text(json.dumps(manifest, indent=1))
print(f"    {len(files)} file(s)")
EOF
install -m 755 "$HERE/install.sh" "$STAGE/$NAME/"
(cd "$STAGE/$NAME" && find files ! -type d | sort | xargs sha256sum) > "$STAGE/$NAME/SHA256SUMS"
printf 'RELEASE=%s\nWINE=%s\nFX=%s\nBASE_URL=%s\nBASE_SIZE=%s\nBASE_SHA256=%s\n' \
    "$NAME" "$WINE_VERSION" "$FX" "$BASE_URL" "$BASE_SIZE" "$BASE_SHA256" > "$STAGE/$NAME/release.conf"
cat > "$STAGE/$NAME/README.txt" << EOF
$NAME: Wine-Fx's patches for Wine $WINE_VERSION, built, to put over a ready Wine $WINE_VERSION.

    bash install.sh      (or a double click on install.sh)

It downloads Wine $WINE_VERSION as released (Kron4ek's build: $BASE_URL)
and puts the files of files/ over it; the files it replaces stay next to them as *.wfx-orig.
Again with --undo <folder> puts them back. Needs glibc 2.35 or later.

The patches and how to build it yourself: https://github.com/fly4xy/Wine-fx
EOF
tar -C "$STAGE" -cJf "$DIST/$NAME.tar.xz" "$NAME"

echo ">>> $NAME-build.tar.gz (1. build it): build.sh and the patches"
B=$STAGE/$NAME-build
mkdir -p "$B"
cp -a "$HERE/versions" "$B/"      # all of them: build.sh asks which Wine
cp "$HERE/README.md" "$HERE/README.ru.md" "$HERE/LICENSE" "$HERE/LICENSE.LGPL" "$B/"
chmod -R u=rwX,go=rX "$B" && find "$B" -type f -exec chmod 644 {} +   # not the modes of a Windows disk
install -m 755 "$HERE/build.sh" "$B/"
tar -C "$STAGE" -czf "$DIST/$NAME-build.tar.gz" "$NAME-build"

echo ">>> releases.json, releases.txt"
python3 - "$DIST" "$NAME" "$WINE_VERSION" "$FX" "$HERE/versions/$VERSION/patches" "$BASE_URL" "$BASE_SIZE" "$BASE_SHA256" "$DOWNLOADS/$VERSION-$FX" <<'EOF'
import hashlib, json, re, sys, time
from pathlib import Path
dist, name, wine, letter, patches = Path(sys.argv[1]), *sys.argv[2:5], Path(sys.argv[5])
base_url, base_size, base_sha, downloads = sys.argv[6:10]
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
                                  "size": int(base_size), "sha256": base_sha},
                         "overlay": dict(part(f"{name}.tar.xz"), url=f"{downloads}/{name}.tar.xz"),
                         "patches": subjects})
key = lambda r: ([int(x) for x in r["wine"].split(".")], r["fx"])
data["releases"].sort(key=key, reverse=True)
path.write_text(json.dumps(data, indent=1) + "\n")
# for install.sh: release, wine, archive URL, its SHA-256 (tab separated, newest first)
(dist / "releases.txt").write_text("".join(
    f'{r["release"]}\t{r["wine"]}\t{r["overlay"]["url"]}\t{r["overlay"]["sha256"]}\n' for r in data["releases"]))
EOF
install -m 755 "$HERE/install.sh" "$DIST/"
ls -la "$DIST"
echo "attach everything in dist/ to the GitHub release $VERSION-$FX"
