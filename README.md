# Wine-Fx

[Русская версия](README.ru.md)

Wine with fixes for Unreal Engine and other Windows programs on Linux (KDE Plasma, X11 and
Wayland): Epic Games' patches for Unreal Engine and Wine-Fx's own. This repository has only
the patches and the scripts, no Wine sources. [Wine Fox](https://lis-carter.site/wine-fox/)
installs and updates Wine-Fx by itself (Wine & components).

There are two ways to get it:

| | What it does | For |
|---|---|---|
| **Build** (`build.sh`) | downloads the Wine sources, installs the build dependencies, applies all the patches or the ones you choose, builds Wine | choosing patches, your own changes, a Wine version with no release yet |
| **Install** (`wine-fx-install.py`) | downloads a ready Wine of the version and puts the release's files into it | everyone else: minutes instead of an hour, nothing to build |

Versions are `<Wine version>-<letter>`: `11.22-a`, then `11.22-b` with the next change of the
patches for Wine 11.22.

## Install (ready files)

```bash
python3 wine-fx-install.py
```

It asks which release (Enter: the newest) and where (Enter: `~/.local/share/wine-fx/Wine-Fx-<version>`).
The first time it downloads Wine of that version as released (`Wine-<version>-base`, built by
this repository's `build.sh --vanilla`), then the release's files (`Wine-Fx-<version>-<letter>`,
a few megabytes). Both are checked against their SHA-256.

The files a release replaces stay next to them as `<file>.wfx-orig`, and
`share/wine-fx/overlay.json` lists them. Installing another release of the same Wine (an
update) puts them back first, then puts the new files in. Other options:

```bash
python3 wine-fx-install.py --list                       # the releases
python3 wine-fx-install.py --release Wine-Fx-11.22-a    # that one, still asks where
python3 wine-fx-install.py --undo ~/.local/share/wine-fx/Wine-Fx-11.22   # Wine as released again
```

Only Python 3 (standard library) is needed. `WINEFX_RELEASES` sets where `releases.json`
is (a URL or a path).

## Build

```bash
bash build.sh
```

The script:

1. asks which Wine version to build, when there are several in `versions/` (Enter: the newest);
2. installs the build dependencies, after asking (Debian/Ubuntu, Fedora, Arch, openSUSE; on
   other distributions it lists what to install);
3. downloads the Wine sources into `wine-source/`, or uses the ones already there (it asks);
4. asks whether to apply all of Wine-Fx's patches. Answer *no* to choose them: each patch is
   shown with its number and description, Enter applies it. Epic Games' patches are always
   applied. Some patches build on earlier ones: if a chosen one does not apply, choose the one
   it needs too;
5. builds Wine and installs it into `wine_dist/Wine-Fx-<version>/`.

| Folder | What |
|---|---|
| `wine-source/wine-<version>/` | the Wine sources, downloaded or put there by you |
| `work/<version>/` | the sources with the patches, the build tree and the logs; can be deleted after the build |
| `wine_dist/Wine-Fx-<version>/` | the result: an ordinary Wine build (`bin/wine`) for any launcher, movable |

The build takes 20 minutes to an hour. Options (`bash build.sh --help`): `--all`, `--select`,
`--patches 0004,0016`, `--skip 0006`, `--vanilla` (no patches), `--prefix DIR`, `--source DIR`,
`--jobs N`, `--yes`, `--no-deps`, `--clean`.

The build is "new WoW64": 32-bit Windows programs run through the 64-bit side, no 32-bit
system libraries are needed. It always has both display drivers, X11 and Wayland.

In Wine Fox: Settings, *Wine build directories*, add `wine_dist` (or the build in it).

## Patches (Wine 11.22)

`versions/11.22/epic/`: Epic Games' patches from WineResources (MIT, `epic/LICENSE`), except
the two for memory accounting in cloud containers and the crypt32 one (it is in Wine):
`gdk_so_conditional_accept`, `globalmemorystatusex-cache-window`, `imagegetdigeststream`,
`minidump-apiset`, `winex11-set-wm-class`.

`versions/11.22/patches/`: Wine-Fx's, in the order they apply. Each file starts with what it
fixes and why; merged patches list the fixes they are made of. *Old* is the number a fix had
before related fixes were merged (the descriptions inside still use those numbers).

| Patch | Modules | What it fixes | Old |
|---|---|---|---|
| 0001 pointer-window-and-x11-window-region | winex11, winewayland | tooltips and popups of programs that draw with Vulkan or OpenGL (Unreal Engine) are not black or cut off under X11; the display driver tells whether the pointer is over a Wine window, so tooltips do not show over other applications (used by Wine Fox's patch for user32) | 0003, 0007 |
| 0002 ntdll-zero-attributes-keep-readonly | ntdll | read-only files: their times can be set without making them writable, as on Windows (Perforce) | 0006 |
| 0003 winewayland-app-id-from-winewmclass | winewayland | under Wayland `WINEWMCLASS` names the windows (app_id), as Epic Games' `winex11-set-wm-class` does under X11: the desktop matches them with their menu entry | 0009 |
| 0004 winewayland-client-surfaces | win32u, winewayland | under Wayland, tooltips and popups drawn with Vulkan or OpenGL have no black background (cropped to the window region), fade in with their window's opacity, and a tooltip shown again does not flash the previous one | 0010, 0012, 0017 |
| 0005 theme-cursors-for-unreal-grab-hands | user32, winex11, winewayland | Unreal Engine's grab hand is the desktop's theme cursor, not a white Windows hand | 0011 |
| 0006 no-blank-window-surfaces | win32u, winex11, winewayland | menus, popups and tooltips drawn with Vulkan or OpenGL no longer flash white (Wayland) or black (X11) before their first frame, growing windows show no white edge; `WINE_BLANK_COLOR=RRGGBB` gives what is not drawn yet that colour (Wine Fox sets `242424` for Unreal Engine) | 0013, 0019, 0022 |
| 0007 winewayland-drag-and-drop | winewayland | under Wayland, files and text can be dragged from the desktop into programs | 0014 |
| 0008 winewayland-keyboard | winewayland | under Wayland: the keyboard comes back to the program after a desktop dialog; NumLock and CapsLock follow the desktop; the Delete keys have no character (Delete works in Unreal's Content Browser); the IME layout only with a running input method (Unreal's Content Drawer no longer closes on the first letter) | 0016, 0032, 0036, 0037 |
| 0009 winewayland-popups-and-dragged-tabs | winewayland | under Wayland, menus and drop-down lists open where they belong; tooltips and a tab dragged out of an Unreal window follow the pointer, also out of a floating window and when it was its last tab | 0008, 0015, 0018, 0020, 0021 |
| 0010 winewayland-server-side-decorations | winewayland | under Wayland, windows with a title bar get the desktop's frame (KWin's), not a frame of Windows; not those that draw their own | 0023 |
| 0011 winewayland-tray-icons-statusnotifieritem | winewayland | under Wayland, tray icons (UnrealGameSync, P4V) go to the desktop's tray (StatusNotifierItem) | 0024 |
| 0012 winewayland-compositor-move-and-window-positions | winewayland | under Wayland, after a move or resize by the compositor the mouse button is no longer stuck down; Wine keeps where windows are in step with the screen as the pointer goes over them (caption buttons and dragged tabs of floating windows) | 0025, 0027 |
| 0013 win32u-vulkan-win32-import-name-only-without-handle | win32u | Vulkan imports of shared Windows handles: Substance Designer no longer crashes creating a project | 0026 |
| 0014 owned-windows | win32u, winex11, winewayland | owned windows (Unreal's floating editors) stay above their owner, have their own taskbar button, and hide and come back with it, as on Windows (X11 and Wayland) | 0028, 0033, 0034 |
| 0015 winex11-activated-tool-popups-stay-unmanaged | winex11 | under X11, menus (captionless tool popups) stay unmanaged when activated: KWin no longer cuts a menu when a category is expanded (Niagara's "+") | 0035 |
| 0016 chromium-composition-and-cursor | dcomp, dxgi, win32u, server, winex11, winewayland | programs on WebView2/Chromium (the new Epic Games Launcher) show their window instead of white or a solid fill, under X11 and Wayland, with Wine's own d3d11/dxgi (not DXVK); the cursor shows over their content | 0029, 0030, 0031, 0038 |
| 0017 ntdll-written-copy-on-write-pages-are-read-write | ntdll | VirtualProtect gives the old protection of copy-on-write pages as read-write: Chromium in Battle.net (libcef) no longer stops itself | 0039 |

Not here: Wine-Fx's fixes to Windows modules that can go into one prefix (native file dialogs,
dragging files in, `.bat` scripts, the Epic Games Launcher's start). [Wine Fox](https://lis-carter.site/wine-fox/)
carries them and installs them into prefixes (Tools, Patches). The new Epic Games Launcher
needs that fix in its prefix as well as 0016 here.

## Releases (maintainers)

```bash
bash make-release.sh 11.22
```

It builds Wine 11.22 as released once (`--vanilla`, kept in `dist/Wine-11.22-base.tar.xz`),
builds it with all the patches, packs the files that differ into `dist/Wine-Fx-11.22-<letter>.tar.xz`
with `manifest.json`, and updates `dist/releases.json`. Upload the new archives, then
`releases.json`. Raise `FX_RELEASE` in `versions/11.22/wine.conf` before releasing changed
patches, and tag the commit `11.22-<letter>`.

A new Wine version: copy `versions/<version>` to a folder for it, set `WINE_VERSION`,
`WINE_URL`, `WINE_SHA256` and `FX_RELEASE=a` in its `wine.conf`, and check that the patches
apply: `bash build.sh <version> --all`.

## Licences

Wine and the patches to it: LGPL 2.1 or later (`LICENSE.LGPL`). Epic Games' patches: MIT
(`versions/*/epic/LICENSE`). The scripts: GPL 3 (`LICENSE`).
