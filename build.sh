#!/bin/bash
# Builds Wine-Fx: a Wine release with the patches in versions/<version>/ (Epic Games' for
# Unreal Engine, then Wine-Fx's), installed as a complete Wine build, Wine-Fx-<version>.
#
#   bash build.sh [version] [options]
#
# Without options it asks which Wine version to build (when there are several), then whether
# to apply all of Wine-Fx's patches or to choose them one by one (each is shown with its
# description; Enter applies it).
#
#   version         a folder of versions/ (default: asked, or the newest without a terminal)
#   --all           all patches, without asking
#   --select        choose the patches one by one, without the first question
#   --patches LIST  only these of Wine-Fx's patches by number, e.g. --patches 0004,0016
#   --vanilla       no patches at all: Wine as released (the base of Wine-Fx's file releases)
#   --prefix DIR    where to install (default: wine_dist/Wine-Fx-<version> next to this script)
#   --source DIR    take the Wine sources from DIR (an unpacked release or a git checkout of
#                   the tag) instead of downloading them
#   --jobs N        parallel compile jobs (default: the processor's threads minus 2)
#   --yes           do not ask: keep sources already downloaded, install the dependencies
#   --no-deps       do not install the build dependencies
#   --clean         start the build from scratch
#   --keep-build    keep the build tree when the set of patches changes, so that only what the
#                   new patches touch is built again (make-release.sh: from none to all)
#   --skip LIST     leave out Wine-Fx's patches by number, e.g. --skip 0006,0009 (to find the one
#                   that broke something)
#
# Everything stays next to this script:
#   wine-source/wine-<version>/   the Wine sources, downloaded or found there (SOURCES=...)
#   work/<version>/               the sources with the patches, the build tree, the logs (WORK=...)
#   wine_dist/Wine-Fx-<version>/  the result, an ordinary Wine build to use from anywhere
#                                 (Wine Fox: add wine_dist to its Wine build directories)
# The build is "new WoW64": 64-bit Unix side, 32-bit programs run through it; no 32-bit
# system libraries are needed.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)

# started from the file manager (no terminal, no arguments): run again in a terminal window,
# which stays open at the end so that the result can be read
if [ $# -eq 0 ] && ! [ -t 0 ] && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    run="bash \"$HERE/build.sh\"; echo; read -rp 'Press Enter to close this window. '"
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
    command -v notify-send > /dev/null && notify-send "Wine-Fx" "No terminal found: run bash build.sh in one"
    exit 1
fi

VERSION="" PREFIX="" SOURCE="" YES="" DEPS=1 CLEAN="" KEEP="" SKIP="" ONLY="" CHOICE="" VANILLA=""
# the processor's threads but two, so that the computer stays usable while it builds
THREADS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 4)
JOBS=$(( THREADS > 3 ? THREADS - 2 : 1 ))

die() { echo "error: $*" >&2; exit 1; }
say() { echo ">>> $*"; }

while [ $# -gt 0 ]; do
    case $1 in
        --prefix) PREFIX=$2; shift ;;
        --source) SOURCE=$2; shift ;;
        --jobs) JOBS=$2; shift ;;
        --yes|-y) YES=1 ;;
        --no-deps) DEPS="" ;;
        --clean) CLEAN=1 ;;
        --keep-build) KEEP=1 ;;
        --skip) SKIP=$2; shift ;;
        --patches) ONLY=$2; shift ;;
        --all) CHOICE=all ;;
        --select) CHOICE=select ;;
        --vanilla) VANILLA=1 ;;
        -h|--help) sed -n '2,/^set -e/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown option $1 (see --help)" ;;
        *) VERSION=$1 ;;
    esac
    shift
done

# yes/no question: --yes answers the default, without a terminal the answer is no
ask()
{
    local answer
    if [ -n "$YES" ]; then [ "$2" = y ]; return; fi
    [ -t 0 ] || return 1
    read -r -p "$1 [$( [ "$2" = y ] && echo Y/n || echo y/N )] " answer
    case ${answer:-$2} in [yY]*) return 0 ;; *) return 1 ;; esac
}

# which Wine version: asked when there are several (Enter: the newest)
if [ -z "$VERSION" ]; then
    versions=($(ls "$HERE/versions" | sort -V))
    VERSION=${versions[-1]}
    if [ ${#versions[@]} -gt 1 ] && [ -z "$YES" ] && [ -t 0 ]; then
        echo "Wine versions Wine-Fx has patches for:"
        for i in "${!versions[@]}"; do echo "  $((i + 1))) ${versions[$i]}"; done
        read -r -p "Which one? [${#versions[@]}] " answer
        [ -n "$answer" ] && VERSION=${versions[$((answer - 1))]:-}
        [ -n "$VERSION" ] || die "no such version: $answer"
    fi
fi
CONF=$HERE/versions/$VERSION/wine.conf
[ -f "$CONF" ] || die "no version $VERSION (versions: $(ls "$HERE/versions" | tr '\n' ' '))"
# shellcheck source=/dev/null
. "$CONF"
NAME=Wine-Fx-$VERSION
RELEASE=$NAME-${FX_RELEASE:-a}             # the patches' release: 11.22-a, 11.22-b...
PREFIX=${PREFIX:-$HERE/wine_dist/$NAME}
case $PREFIX in /*) ;; *) PREFIX=$PWD/$PREFIX ;; esac    # configure needs an absolute path
WORK=${WORK:-$HERE/work/$VERSION}
SOURCES=${SOURCES:-$HERE/wine-source}       # the downloaded releases, wine-<version> each
PRISTINE=$SOURCES/wine-$WINE_VERSION       # the sources as released
SRC=$WORK/src                              # the sources with the patches
BUILD=$WORK/build

# ---------------------------------------------------------------- dependencies
# the build tools, the mingw cross compilers for the Windows side, and the libraries of the
# usual Wine features (X11, Wayland, Vulkan, OpenGL, sound, fonts, TLS, GStreamer...)
deps_install()
{
    local id like cmd
    id=$(. /etc/os-release 2>/dev/null; echo "${ID:-} ${ID_LIKE:-}")
    case " $id " in
        *" debian "*|*" ubuntu "*)
            cmd="sudo apt-get install -y --no-install-recommends gcc make flex bison perl patch xz-utils gettext
                gcc-mingw-w64 g++-mingw-w64 libx11-dev libxext-dev libxrender-dev libxrandr-dev libxi-dev libxcursor-dev
                libxcomposite-dev libxinerama-dev libxfixes-dev libxxf86vm-dev libfreetype-dev libfontconfig-dev
                libvulkan-dev libgl-dev libegl-dev libwayland-dev libwayland-bin libxkbcommon-dev libxkbregistry-dev libasound2-dev libpulse-dev
                libgnutls28-dev libdbus-1-dev libudev-dev libsdl2-dev libgstreamer1.0-dev
                libgstreamer-plugins-base1.0-dev libkrb5-dev libcups2-dev libunwind-dev libusb-1.0-0-dev
                libpcap-dev libv4l-dev ocl-icd-opencl-dev libva-dev libpcsclite-dev libsane-dev libgphoto2-dev
                libcapi20-dev samba-dev" ;;
        *" fedora "*|*" rhel "*|*" centos "*)
            cmd="sudo dnf install -y --skip-unavailable gcc make flex bison perl patch xz gettext
                mingw64-gcc mingw32-gcc mingw64-gcc-c++ mingw32-gcc-c++ libX11-devel libXext-devel libXrender-devel libXrandr-devel libXi-devel
                libXcursor-devel libXcomposite-devel libXinerama-devel libXfixes-devel libXxf86vm-devel
                freetype-devel fontconfig-devel vulkan-loader-devel mesa-libGL-devel mesa-libEGL-devel
                wayland-devel libxkbcommon-devel alsa-lib-devel pulseaudio-libs-devel gnutls-devel dbus-devel
                systemd-devel SDL2-devel gstreamer1-devel gstreamer1-plugins-base-devel krb5-devel cups-devel
                libunwind-devel libusb1-devel libpcap-devel libv4l-devel ocl-icd-devel opencl-headers libva-devel
                pcsc-lite-devel sane-backends-devel libgphoto2-devel libnetapi-devel" ;;
        *" arch "*)
            cmd="sudo pacman -S --needed --noconfirm gcc make flex bison perl patch xz gettext
                mingw-w64-gcc libx11 libxext libxrender libxrandr libxi libxcursor libxcomposite libxinerama
                libxfixes libxxf86vm freetype2 fontconfig vulkan-icd-loader vulkan-headers mesa wayland
                libxkbcommon alsa-lib libpulse gnutls dbus systemd-libs sdl2 gstreamer gst-plugins-base-libs
                krb5 libcups libunwind libusb libpcap v4l-utils opencl-icd-loader opencl-headers libva pcsclite
                sane libgphoto2 smbclient" ;;
        *" opensuse"*|*" suse "*)
            cmd="sudo zypper install -y gcc make flex bison perl patch xz gettext-tools
                mingw64-cross-gcc mingw32-cross-gcc mingw64-cross-gcc-c++ mingw32-cross-gcc-c++ libX11-devel libXext-devel libXrender-devel libXrandr-devel
                libXi-devel libXcursor-devel libXcomposite-devel libXinerama-devel libXfixes-devel
                libXxf86vm-devel freetype2-devel fontconfig-devel vulkan-devel Mesa-libGL-devel
                Mesa-libEGL-devel wayland-devel libxkbcommon-devel libxkbregistry-devel alsa-devel libpulse-devel libgnutls-devel
                dbus-1-devel libudev-devel SDL2-devel gstreamer-devel gstreamer-plugins-base-devel krb5-devel
                cups-devel libunwind-devel libusb-1_0-devel libpcap-devel libv4l-devel ocl-icd-devel opencl-headers
                libva-devel pcsc-lite-devel sane-backends-devel libgphoto2-devel libnetapi-devel" ;;
        *)
            echo "Unknown distribution ($id): install yourself gcc, make, flex, bison, perl, patch, the"
            echo "mingw-w64 cross compilers (i686 and x86_64) and the -dev packages of the libraries above."
            return 0 ;;
    esac
    cmd=$(echo $cmd)                   # one line
    say "build dependencies:"
    echo "    $cmd"
    if ask "Install them now?" y; then
        $cmd || echo "warning: the install failed; the build goes on and configure says what is missing"
    fi
}

# ---------------------------------------------------------------- sources
get_sources()
{
    mkdir -p "$WORK" "$SOURCES"
    if [ -n "$SOURCE" ]; then
        [ -f "$SOURCE/configure" ] || die "$SOURCE is not a Wine source tree"
        say "taking the sources from $SOURCE"
        rm -rf "$PRISTINE"
        mkdir -p "$PRISTINE"
        (cd "$SOURCE" && tar --exclude=.git -cf - .) | (cd "$PRISTINE" && tar -xf -)
        return
    fi
    if [ -f "$PRISTINE/configure" ]; then
        if ! ask "The sources of Wine $WINE_VERSION are already in $PRISTINE. Download them again?" n; then
            return
        fi
        rm -rf "$PRISTINE"
    fi
    local tarball=$SOURCES/${WINE_URL##*/}
    say "downloading $WINE_URL"
    curl -fL --retry 3 -o "$tarball.part" "$WINE_URL"
    mv "$tarball.part" "$tarball"
    if [ -n "${WINE_SHA256:-}" ]; then
        echo "$WINE_SHA256  $tarball" | sha256sum -c --quiet - || die "the download is damaged (checksum)"
    else
        echo "warning: no checksum for this version in wine.conf: $(sha256sum "$tarball" | cut -d' ' -f1)"
    fi
    tar -xf "$tarball" -C "$SOURCES"
    rm -f "$tarball"
    [ -f "$PRISTINE/configure" ] || die "the archive did not unpack to $PRISTINE"
}

# the patches to apply, in order: Epic Games', then Wine-Fx's chosen ones (none with --vanilla)
patch_list()
{
    local p n
    [ -z "$VANILLA" ] || return 0
    for p in "$HERE/versions/$VERSION"/epic/*.patch "$HERE/versions/$VERSION"/patches/*.patch; do
        [ -f "$p" ] || continue
        n=${p##*/}; n=${n%%-*}
        case ",$SKIP," in *",$n,"*) continue ;; esac
        case $p in */patches/*) [ -z "$ONLY" ] || case ",$ONLY," in *",$n,"*) ;; *) continue ;; esac ;; esac
        echo "$p"
    done
}

# a patch's description: its subject, and the subjects of the fixes merged into it (* lines),
# else its first paragraph
describe()
{
    local subject bullets
    subject=$(sed -n 's/^Subject: \[PATCH\] //p' "$1" | head -1)
    bullets=$(sed -n '/^Subject:/,/^diff --git/{s/^\* /      - /p}' "$1")
    echo "  ${1##*/}" | sed 's/\.patch$//'
    echo "    $subject"
    if [ -n "$bullets" ]; then echo "$bullets"
    else sed -n '/^Subject:/,/^diff --git/p' "$1" | sed '1,2d' | sed '/^$/q' | sed 's/^/      /' | head -6
    fi
}

# all of Wine-Fx's patches, or chosen one by one (Enter applies a patch)
choose_patches()
{
    local p n chosen=""
    [ -z "$VANILLA$ONLY$YES" ] || return 0
    [ "$CHOICE" != all ] || return 0
    [ -t 0 ] || return 0
    if [ "$CHOICE" != select ] && ask "Apply all of Wine-Fx's patches?" y; then return 0; fi
    for p in "$HERE/versions/$VERSION"/patches/*.patch; do
        n=${p##*/}; n=${n%%-*}
        case ",$SKIP," in *",$n,"*) continue ;; esac
        echo; describe "$p"
        ask "Apply it?" y && chosen="$chosen,$n"
    done
    ONLY=${chosen#,}
    [ -n "$ONLY" ] || VANILLA=1
    echo
}

# the released sources plus the patches, in a copy: the released ones stay as they are
patch_sources()
{
    say "applying the patches"
    rm -rf "$SRC"
    cp -a "$PRISTINE" "$SRC"
    # sources that went through a Windows disk or a zip lost the executable bits of configure
    # and of Wine's tool scripts: give them back to every file that starts with #!
    find "$SRC" -type f ! -perm -u+x -print0 |
        perl -0ne 'chomp; open(my $f, "<", $_) or next; read($f, my $b, 2); chmod(0755, $_) if $b eq "#!"'
    local p
    for p in $(patch_list); do
        [ -f "$p" ] || continue
        echo "    ${p#"$HERE"/versions/}"
        patch -d "$SRC" -p1 --quiet --forward --no-backup-if-mismatch < "$p" \
            || die "$p does not apply${ONLY:+ (it may need one of the patches left out: choose it too)}"
    done
    # patches may change the server protocol: regenerate what is made from it
    (cd "$SRC" && ./tools/make_requests)
}

# make "$@" with its output in the log $1, showing how far it is: the compile commands it ran
# out of those make -n lists beforehand (in a terminal one updated line, else a line every 30 s)
make_with_progress()
{
    local log=$1 total done pct="" line start=$SECONDS last=0 pid status=0
    shift
    total=$(make -n "$@" 2>/dev/null | grep -c -- ' -c -o ' || true)
    make "$@" > "$log" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        sleep 2
        done=$(grep -c -- ' -c -o ' "$log" || true)
        [ "$total" -gt 0 ] && pct="$(( done * 100 / total > 99 ? 99 : done * 100 / total ))%, "
        line=$(printf '    %s%d of %d files, %d:%02d' "$pct" "$done" "$total" \
               $(( (SECONDS - start) / 60 )) $(( (SECONDS - start) % 60 )))
        if [ -t 1 ]; then printf '\r%s ' "$line"
        elif [ $(( SECONDS - last )) -ge 30 ]; then echo "$line"; last=$SECONDS
        fi
    done
    wait "$pid" || status=$?
    [ -t 1 ] && echo
    return "$status"
}

build()
{
    # X11 and Wayland are required: configure stops and names what is missing instead of
    # building Wine without a display driver
    # --libdir: wine looks for its libraries in bin/../lib, whatever a config.site of the system
    # says; no -g: debugging information would triple the size of the build
    # -ffile-prefix-map: no work/ paths in the modules (__FILE__ names critical sections), so that
    # a module the patches do not touch is the same in every build and stays out of a release
    local map="-ffile-prefix-map=$SRC/=wine/ -ffile-prefix-map=$BUILD/=wine/"
    local config=(--prefix="$PREFIX" --libdir="$PREFIX/lib" --enable-archs=i386,x86_64 --disable-tests
                  --with-x --with-wayland CFLAGS="-O2 $map" CROSSCFLAGS="-O2 $map")
    # a different set of patches (or sources, or configure options) starts over: files a dropped
    # patch had changed come back with their old dates, and make would keep objects built from it
    local id
    id=$(cat $(patch_list) 2>/dev/null \
         | cat - <(echo "${config[*]}") <(ls -l --time-style=+%s "$PRISTINE") | sha1sum | cut -c1-12)
    if [ -n "$CLEAN" ] || { [ -z "$KEEP" ] && [ "$(cat "$BUILD/.wine-fx-id" 2>/dev/null)" != "$id" ]; }; then
        rm -rf "$BUILD"
    fi
    mkdir -p "$BUILD"
    echo "$id" > "$BUILD/.wine-fx-id"
    if [ ! -f "$BUILD/Makefile" ] || [ "$SRC/configure" -nt "$BUILD/Makefile" ]; then
        say "configuring (a minute or two; the log: $WORK/configure.log)"
        (cd "$BUILD" && "$SRC/configure" "${config[@]}") \
            > "$WORK/configure.log" 2>&1 || { tail -30 "$WORK/configure.log"; die "configure failed"; }
        # what configure left out for want of a library
        grep -E "^configure: (WARNING|OpenCL|.*won't be supported)" "$WORK/configure.log" | sed 's/^configure: /    /' || true
    fi
    # the Windows modules' PE timestamp: the date of Wine's sources, not now (same reason as above)
    export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(stat -c %Y "$PRISTINE/configure")}
    say "compiling, $JOBS at a time (the log: $WORK/make.log)"
    make_with_progress "$WORK/make.log" -C "$BUILD" -j"$JOBS" \
        || { grep -E -B3 " error:|\*\*\*" "$WORK/make.log" | head -40; die "the build failed"; }
    say "installing into $PREFIX (a minute or two)"
    # a previous Wine-Fx build there goes first, so that nothing of it stays (another folder is
    # left as it is)
    if [ -f "$PREFIX/share/wine-fx/version.txt" ]; then rm -rf "$PREFIX"; fi
    # install-lib: what programs need to run, without Wine's headers and development tools
    make -C "$BUILD" install-lib > "$WORK/install.log" 2>&1 || { tail -20 "$WORK/install.log"; die "make install failed"; }
    [ -f "$PREFIX/lib/wine/x86_64-unix/ntdll.so" ] \
        || die "the install has no lib/wine/x86_64-unix/ntdll.so (see $WORK/install.log)"
    mkdir -p "$PREFIX/share/wine-fx"
    local release=$RELEASE
    [ -z "$VANILLA" ] || release="Wine $WINE_VERSION (vanilla)"
    [ -z "$ONLY$SKIP" ] || release="$RELEASE (custom)"
    { echo "$release"; echo "Wine $WINE_VERSION"; patch_list | sed "s#^$HERE/versions/$VERSION/##"; } \
        > "$PREFIX/share/wine-fx/version.txt"
}

choose_patches
say "$RELEASE -> $PREFIX"
usable=$(nproc 2>/dev/null || echo "$THREADS")
if [ "$usable" -lt "$THREADS" ] && [ "$usable" -lt 4 ]; then
    # nproc counts the threads this process may use: a terminal or sandbox may have limited it
    echo "warning: this terminal lets the build use $usable of the $THREADS processor threads:" \
         "it will take hours. Run it from an ordinary terminal."
fi
[ -z "$DEPS" ] || deps_install
for tool in make gcc flex bison perl patch tar; do
    command -v $tool > /dev/null || die "$tool is missing (install the build dependencies)"
done
command -v x86_64-w64-mingw32-gcc > /dev/null && command -v i686-w64-mingw32-gcc > /dev/null \
    || die "the mingw-w64 cross compilers (x86_64 and i686) are missing"
get_sources
patch_sources
build
version=$("$PREFIX/bin/wine" --version 2>&1) || die "the build does not start: $version"
say "done: $PREFIX/bin/wine ($version)"
