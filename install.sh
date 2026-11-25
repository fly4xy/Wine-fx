#!/bin/bash
# Installs Wine-Fx over a ready Wine: the second way to get it (the first is build.sh).
#
#   bash install.sh [--dest DIR] [--yes] [--list] [--undo DIR]
#
# It asks the Wine version (the one of the archive it came in first, then the other releases on
# GitHub), downloads a ready Wine of that version as released (Kron4ek's build) and puts the
# release's files over it: from files/ next to it, or from that release's archive. The files
# they replace stay next to them as <file>.wfx-orig and share/wine-fx/overlay.json lists what
# it changed: installing another release of the same Wine (an update) first puts those back.
# Everything is checked against its SHA-256.
#
#   --dest DIR   where (default: asked, ~/.local/share/wine-fx/Wine-Fx-<version>)
#   --yes        do not ask: the first Wine of the list, the default folder
#   --list       the releases, and exit
#   --undo DIR   put back the files the release in DIR replaced (Wine as released again)
#
# Needs bash, curl or wget, tar with xz, sha256sum. WINEFX_LIST sets where releases.txt is.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
LIST_URL=${WINEFX_LIST:-https://github.com/fly4xy/Wine-fx/releases/latest/download/releases.txt}
STATE=share/wine-fx/overlay.json
ORIG=.wfx-orig
DEST="" YES="" UNDO="" LIST=""

die() { echo "error: $*" >&2; exit 1; }
say() { echo ">>> $*"; }

while [ $# -gt 0 ]; do
    case $1 in
        --dest) DEST=$2; shift ;;
        --yes|-y) YES=1 ;;
        --list) LIST=1 ;;
        --undo) UNDO=$2; shift ;;
        -h|--help) sed -n '2,/^set -e/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option $1 (see --help)" ;;
    esac
    shift
done

# started from the file manager (no terminal, no arguments): run again in a terminal window,
# which stays open at the end so that the result can be read
if [ -z "$DEST$YES$UNDO$LIST" ] && ! [ -t 0 ] && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    run="bash \"$HERE/install.sh\"; echo; read -rp 'Press Enter to close this window. '"
    for t in konsole gnome-terminal kgx xfce4-terminal mate-terminal kitty alacritty foot \
             x-terminal-emulator xterm; do
        command -v "$t" > /dev/null || continue
        case $t in
            gnome-terminal|kgx) exec "$t" -- bash -c "$run" ;;
            xfce4-terminal|mate-terminal) exec "$t" -x bash -c "$run" ;;
            kitty|foot) exec "$t" bash -c "$run" ;;
            *) exec "$t" -e bash -c "$run" ;;
        esac
    done
    command -v notify-send > /dev/null && notify-send "Wine-Fx" "No terminal found: run bash install.sh in one"
    exit 1
fi

# a question with a default: --yes or no terminal takes the default
ask()
{
    local answer=""
    if [ -z "$YES" ] && [ -t 0 ]; then read -rp "$1 [$2] " answer; fi
    echo "${answer:-$2}"
}

fetch()   # url file
{
    if command -v curl > /dev/null; then curl -fL --progress-bar -o "$2" "$1"
    elif command -v wget > /dev/null; then wget -q --show-progress -O "$2" "$1"
    else die "neither curl nor wget is installed"
    fi
}

fetch_quiet()   # url file
{
    if command -v curl > /dev/null; then curl -fsSL -o "$2" "$1"; else wget -q -O "$2" "$1"; fi
}

sha_ok() { [ "$(sha256sum "$1" | cut -d' ' -f1)" = "$2" ]; }

# a field of the top of overlay.json (release, wine, fx)
state_field()
{
    [ -f "$1/$STATE" ] || return 0
    sed -n "s/.*\"$2\": \"\([^\"]*\)\".*/\1/p" "$1/$STATE" | head -n 1
}

# the Wine version in a folder: from overlay.json, else from build.sh's version.txt; "" = none
wine_of()
{
    local w
    w=$(state_field "$1" wine)
    [ -n "$w" ] || w=$(sed -n '2s/^Wine //p' "$1/share/wine-fx/version.txt" 2>/dev/null || true)
    echo "$w"
}

# put back the files the installed release replaced, remove the ones it added; the Wine
# version stays known (Kron4ek's build has no version.txt of ours)
undo()
{
    local dest=$1 line path wine n=0
    [ -f "$dest/$STATE" ] || { echo "0 file(s) put back"; return 0; }
    wine=$(wine_of "$dest")
    while IFS= read -r line; do   # one file a line: "path": {"sha256": "...", "new": false}
        path=$(sed -n 's/^ *"\([^"]*\)": {"sha256".*/\1/p' <<< "$line")
        [ -n "$path" ] || continue
        if [ -e "$dest/$path$ORIG" ] || [ -L "$dest/$path$ORIG" ]; then
            mv -f "$dest/$path$ORIG" "$dest/$path"
        elif grep -q '"new": true' <<< "$line"; then
            rm -f "$dest/$path"
        fi
        n=$((n + 1))
    done < "$dest/$STATE"
    printf '{\n "wine": "%s"\n}\n' "$wine" > "$dest/$STATE"
    refresh_prefixes "$dest"
    echo "$n file(s) put back"
}

# prefixes keep copies of Wine's DLLs in system32 and take new ones only when wine.inf changed;
# programs that check their DLLs against those files (World of Warcraft) broke the loaded ones
# with the old copies' bytes
refresh_prefixes() { [ ! -f "$1/share/wine/wine.inf" ] || touch "$1/share/wine/wine.inf"; }

# put a release (release.conf, SHA256SUMS, files/ in $2) into $1, after undoing the one there
apply()
{
    local dest=$1 src=$2 sum path new sep="" RELEASE WINE FX
    (cd "$src" && sha256sum --quiet -c SHA256SUMS) || die "the files of the release are damaged"
    . "$src/release.conf"
    undo "$dest" > /dev/null
    mkdir -p "$dest/share/wine-fx"
    {
        printf '{\n "release": "%s",\n "wine": "%s",\n "fx": "%s",\n "files": {\n' "$RELEASE" "$WINE" "$FX"
        while read -r sum path; do
            path=${path#files/}
            new=true
            if [ -e "$dest/$path" ] || [ -L "$dest/$path" ]; then
                mv -f "$dest/$path" "$dest/$path$ORIG"   # a running Wine keeps the file it has open
                new=false
            fi
            mkdir -p "$(dirname "$dest/$path")"
            cp -a "$src/files/$path" "$dest/$path"
            # programs stay programs: a release folder copied through another system (a Windows
            # share) loses the executable bit, and Wine without an executable wineserver cannot start
            case $path in bin/*) [ -L "$dest/$path" ] || chmod 755 "$dest/$path" ;; esac
            printf '%s  "%s": {"sha256": "%s", "new": %s}' "$sep" "$path" "$sum" "$new"
            sep=$',\n'
        done < "$src/SHA256SUMS"
        printf '\n }\n}\n'
    } > "$dest/$STATE.new"
    mv -f "$dest/$STATE.new" "$dest/$STATE"
    refresh_prefixes "$dest"
    echo "$(grep -c . "$src/SHA256SUMS") file(s) of $RELEASE"
}

TMP=""
cleanup() { [ -z "$TMP" ] || rm -rf "$TMP"; }
trap cleanup EXIT

if [ -n "$UNDO" ]; then
    undo "$UNDO"
    exit 0
fi

# the releases: this archive's first (its files are here), then the newest of each other Wine
# version on GitHub (releases.txt: release, wine, archive URL, its SHA-256, tab separated)
TMP=$(mktemp -d)
NAMES=() WINES=() URLS=() SUMS=()
if [ -f "$HERE/release.conf" ] && [ -f "$HERE/SHA256SUMS" ] && [ -d "$HERE/files" ]; then
    (. "$HERE/release.conf"; echo "$RELEASE	$WINE") > "$TMP/local"
    IFS=$'\t' read -r name wine < "$TMP/local"
    NAMES+=("$name") WINES+=("$wine") URLS+=("") SUMS+=("")
fi
if fetch_quiet "$LIST_URL" "$TMP/releases.txt" 2> /dev/null; then
    while IFS=$'\t' read -r name wine url sum; do
        [ -n "$name" ] || continue
        case " ${WINES[*]-} " in *" $wine "*) continue ;; esac
        NAMES+=("$name") WINES+=("$wine") URLS+=("$url") SUMS+=("$sum")
    done < "$TMP/releases.txt"
elif [ ${#NAMES[@]} -eq 0 ]; then
    die "cannot read the list of releases ($LIST_URL)"
fi

if [ -n "$LIST" ]; then
    for i in "${!NAMES[@]}"; do echo "${NAMES[$i]}  (Wine ${WINES[$i]})"; done
    exit 0
fi

echo "Wine versions with a release of Wine-Fx:"
for i in "${!NAMES[@]}"; do
    where="files in this archive"
    [ -z "${URLS[$i]}" ] || where="downloaded"
    echo "  $((i + 1))) Wine ${WINES[$i]}  (${NAMES[$i]}, $where)"
done
n=$(ask "Which Wine?" 1)
[[ $n =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le ${#NAMES[@]} ] || die "no Wine $n in the list"
i=$((n - 1))

default=$HOME/.local/share/wine-fx/Wine-Fx-${WINES[$i]}
[ -n "$DEST" ] || DEST=$(ask "Install into" "$default")
DEST=${DEST/#\~/$HOME}
mkdir -p "$(dirname "$DEST")"
DEST=$(cd "$(dirname "$DEST")" && pwd)/$(basename "$DEST")
now=$(state_field "$DEST" release)
echo "${NAMES[$i]} -> $DEST${now:+ (now $now)}"

# the release's files: here, or its archive downloaded
SRC=$HERE
if [ -n "${URLS[$i]}" ]; then
    say "downloading ${URLS[$i]##*/}"
    fetch "${URLS[$i]}" "$TMP/release.tar.xz"
    sha_ok "$TMP/release.tar.xz" "${SUMS[$i]}" || die "${URLS[$i]##*/} is damaged (checksum)"
    tar -C "$TMP" -xJf "$TMP/release.tar.xz"
    SRC=$TMP/${NAMES[$i]}
fi
. "$SRC/release.conf"

# Wine itself, the first time
if [ "$(wine_of "$DEST")" != "$WINE" ]; then
    if [ -e "$DEST" ] && [ -n "$(ls -A "$DEST")" ]; then
        die "$DEST is not empty and has no Wine $WINE: choose another folder"
    fi
    say "downloading Wine $WINE as released: $BASE_URL"
    fetch "$BASE_URL" "$TMP/base.tar.xz"
    sha_ok "$TMP/base.tar.xz" "$BASE_SHA256" || die "${BASE_URL##*/} is damaged (checksum)"
    mkdir "$TMP/base"
    tar -C "$TMP/base" -xJf "$TMP/base.tar.xz"
    top=$(find "$TMP/base" -mindepth 1 -maxdepth 1)
    [ "$(echo "$top" | wc -l)" = 1 ] && [ -x "$top/bin/wine" ] || die "${BASE_URL##*/}: unexpected layout"
    rmdir "$DEST" 2> /dev/null || true
    mv "$top" "$DEST"
fi

say "putting the files of $RELEASE in"
apply "$DEST" "$SRC"
echo "done: $DEST/bin/wine"
