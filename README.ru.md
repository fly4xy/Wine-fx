# Wine-Fx

[English version](README.md)

Wine с исправлениями для Unreal Engine и других Windows-программ на Linux (KDE Plasma, X11 и
Wayland): патчи Epic Games для Unreal Engine и собственные исправления Wine-Fx. В этом
репозитории только патчи и скрипты, исходников Wine здесь нет. [Wine Fox](https://lis-carter.site/wine-fox/)
сам ставит и обновляет Wine-Fx («Wine и компоненты»).

Получить его можно двумя способами; в каждом [релизе](https://github.com/fly4xy/Wine-fx/releases)
есть архив для каждого:

| | Архив | Что делает его скрипт | Для кого |
|---|---|---|---|
| **Сборка** | `Wine-Fx-<версия>-<буква>-build.tar.gz` (`build.sh`) | спрашивает версию Wine, скачивает её исходники, ставит зависимости, накладывает все патчи или выбранные, собирает Wine | выбрать патчи, свои правки |
| **Установка** | `Wine-Fx-<версия>-<буква>.tar.xz` (`wine-fx-install.py`) | спрашивает версию Wine, скачивает готовый Wine этой версии и кладёт в него файлы релиза | все остальные: минуты вместо часа, ничего собирать не нужно |

Распакуйте архив и запустите его скрипт: из терминала или двойным щелчком (терминал откроется
сам).

Версии вида `<версия Wine>-<буква>`: `11.22-a`, затем `11.22-b` при следующем изменении патчей
для Wine 11.22.

## Установка (готовые файлы)

Распакуйте `Wine-Fx-<версия>-<буква>.tar.xz` из релиза, затем:

```bash
python3 wine-fx-install.py
```

Скрипт спрашивает, какая версия Wine (Enter — самая новая) и куда (Enter —
`~/.local/share/wine-fx/Wine-Fx-<версия>`). В первый раз он скачивает готовый Wine этой версии как
он вышел — [сборку Kron4ek](https://github.com/Kron4ek/Wine-Builds) (`wine-<версия>-amd64-wow64`),
затем кладёт файлы релиза из архива (`files/`, несколько мегабайт); для другой версии Wine
скачивает релиз этой версии. Всё сверяется по SHA-256. Обновление скачивает
только файлы релиза.

Unix-модулям релиза нужна glibc 2.35 или новее (Ubuntu 22.04, Debian 12, Fedora 36 и новее).

Файлы, которые релиз заменяет, остаются рядом как `<файл>.wfx-orig`, а их список — в
`share/wine-fx/overlay.json`. При установке другого релиза того же Wine (обновлении) сначала
возвращаются они, потом кладутся новые файлы. Другие варианты:

```bash
python3 wine-fx-install.py --list                       # релизы
python3 wine-fx-install.py --release Wine-Fx-11.22-a    # этот релиз, место всё равно спросит
python3 wine-fx-install.py --undo ~/.local/share/wine-fx/Wine-Fx-11.22   # снова Wine Kron4ek как был
```

Нужен только Python 3 (стандартная библиотека). `WINEFX_RELEASES` задаёт, где лежит
`releases.json` (адрес или путь).

## Сборка

```bash
bash build.sh
```

(`Wine-Fx-<версия>-<буква>-build.tar.gz` из релиза, распакованный, или клон этого репозитория.)
Скрипт:

1. спрашивает, какую версию Wine собирать, если в `versions/` их несколько (Enter — самую новую);
2. ставит зависимости для сборки, спросив вас (Debian/Ubuntu, Fedora, Arch, openSUSE; на других
   дистрибутивах пишет, что поставить);
3. скачивает исходники Wine в `wine-source/` или берёт те, что уже там (спрашивает);
4. спрашивает, накладывать ли все патчи Wine-Fx. Ответьте «нет», чтобы выбрать: каждый патч
   показывается с номером и описанием, Enter его накладывает. Патчи Epic Games накладываются
   всегда. Некоторые патчи опираются на более ранние: если выбранный не накладывается, выберите
   и тот, что ему нужен;
5. собирает Wine и ставит его в `wine_dist/Wine-Fx-<версия>/`.

| Папка | Что |
|---|---|
| `wine-source/wine-<версия>/` | исходники Wine, скачанные или положенные вами |
| `work/<версия>/` | исходники с патчами, дерево сборки и логи; после сборки можно удалить |
| `wine_dist/Wine-Fx-<версия>/` | результат: обычная сборка Wine (`bin/wine`) для любого лаунчера, её можно переносить |

Сборка идёт от 20 минут до часа. Параметры (`bash build.sh --help`): `--all`, `--select`,
`--patches 0004,0016`, `--skip 0006`, `--vanilla` (без патчей), `--prefix DIR`, `--source DIR`,
`--jobs N`, `--yes`, `--no-deps`, `--clean`.

Сборка в режиме «новый WoW64»: 32-битные Windows-программы работают через 64-битную часть,
32-битные системные библиотеки не нужны. В сборке всегда оба драйвера экрана, X11 и Wayland.

В Wine Fox: «Настройки», «Каталоги сборок Wine», добавьте `wine_dist` (или сборку в ней).

## Патчи (Wine 11.22)

`versions/11.22/epic/`: патчи Epic Games из WineResources (MIT, `epic/LICENSE`), кроме двух для
учёта памяти в облачных контейнерах и патча для crypt32 (он уже в Wine):
`gdk_so_conditional_accept`, `globalmemorystatusex-cache-window`, `imagegetdigeststream`,
`minidump-apiset`, `winex11-set-wm-class`.

`versions/11.22/patches/`: исправления Wine-Fx в порядке наложения. Каждый файл начинается с
описания: что исправлено и почему; у объединённых — список исправлений, из которых они собраны.
«Было» — номера до объединения связанных исправлений (описания внутри патчей ссылаются на них).

| Патч | Модули | Что исправляет | Было |
|---|---|---|---|
| 0001 pointer-window-and-x11-window-region | winex11, winewayland | тултипы и попапы программ, которые рисуют через Vulkan или OpenGL (Unreal Engine), под X11 не чёрные и не обрезаны; драйвер сообщает, над окном ли Wine указатель, и тултипы не всплывают поверх других приложений (этим пользуется патч Wine Fox для user32) | 0003, 0007 |
| 0002 ntdll-zero-attributes-keep-readonly | ntdll | файлы только для чтения: им можно менять время, не делая их записываемыми, как в Windows (Perforce) | 0006 |
| 0003 winewayland-app-id-from-winewmclass | winewayland | под Wayland `WINEWMCLASS` задаёт имя окон (app_id), как `winex11-set-wm-class` от Epic Games под X11: рабочий стол сопоставляет окна с пунктом меню | 0009 |
| 0004 winewayland-client-surfaces | win32u, winewayland | под Wayland у тултипов и попапов, которые рисуют через Vulkan или OpenGL, нет чёрного фона (обрезка по региону окна), они проявляются с прозрачностью окна, а повторно показанный тултип не вспыхивает предыдущим | 0010, 0012, 0017 |
| 0005 theme-cursors-for-unreal-grab-hands | user32, winex11, winewayland | «рука» Unreal Engine берётся из темы курсоров рабочего стола, а не белая рука Windows | 0011 |
| 0006 no-blank-window-surfaces | win32u, winex11, winewayland | меню, попапы и тултипы, которые рисуют через Vulkan или OpenGL, не вспыхивают белым (Wayland) или чёрным (X11) до первого кадра, у растущих окон нет белого края; `WINE_BLANK_COLOR=RRGGBB` красит ещё не нарисованное этим цветом (Wine Fox задаёт `242424` для Unreal Engine) | 0013, 0019, 0022 |
| 0007 winewayland-drag-and-drop | winewayland | под Wayland файлы и текст можно перетаскивать с рабочего стола в программы | 0014 |
| 0008 winewayland-keyboard | winewayland | под Wayland: клавиатура возвращается в программу после системного диалога; NumLock и CapsLock совпадают с рабочим столом; у клавиш Delete нет символа (Delete работает в Content Browser Unreal); раскладка-IME только при запущенном методе ввода (Content Drawer Unreal не закрывается на первой букве) | 0016, 0032, 0036, 0037 |
| 0009 winewayland-popups-and-dragged-tabs | winewayland | под Wayland меню и выпадающие списки открываются на своём месте; тултипы и вкладка, вытащенная из окна Unreal, идут за указателем, в том числе за пределы плавающего окна и когда она была в нём последней | 0008, 0015, 0018, 0020, 0021 |
| 0010 winewayland-server-side-decorations | winewayland | под Wayland у окон с заголовком системная рамка (KWin), а не рамка Windows; кроме тех, что рисуют заголовок сами | 0023 |
| 0011 winewayland-tray-icons-statusnotifieritem | winewayland | под Wayland иконки трея (UnrealGameSync, P4V) попадают в трей рабочего стола (StatusNotifierItem) | 0024 |
| 0012 winewayland-compositor-move-and-window-positions | winewayland | под Wayland после перемещения или изменения размера композитором кнопка мыши больше не «залипает»; Wine подстраивает положение окон под экран по движению указателя (кнопки заголовка и перетаскиваемые вкладки плавающих окон) | 0025, 0027 |
| 0013 win32u-vulkan-win32-import-name-only-without-handle | win32u | импорт в Vulkan общих Windows-хэндлов: Substance Designer больше не падает при создании проекта | 0026 |
| 0014 owned-windows | win32u, winex11, winewayland | окна, принадлежащие другому окну (плавающие редакторы Unreal), остаются над ним, имеют свою кнопку на панели задач, прячутся и возвращаются вместе с ним, как в Windows (X11 и Wayland) | 0028, 0033, 0034 |
| 0015 winex11-activated-tool-popups-stay-unmanaged | winex11 | под X11 меню (tool-попапы без заголовка) при активации остаются неуправляемыми: KWin больше не обрезает меню при раскрытии категории («+» в Niagara) | 0035 |
| 0016 chromium-composition-and-cursor | dcomp, dxgi, win32u, server, winex11, winewayland | программы на WebView2/Chromium (новый Epic Games Launcher) показывают окно вместо белой или сплошной заливки, под X11 и Wayland, со встроенными d3d11/dxgi Wine (не DXVK); курсор виден над их содержимым | 0029, 0030, 0031, 0038 |
| 0017 ntdll-written-copy-on-write-pages-are-read-write | ntdll | VirtualProtect отдаёт прежнюю защиту страниц copy-on-write как read-write: Chromium в Battle.net (libcef) больше не останавливает сам себя | 0039 |

## Патчи (Wine 11.7)

На Wine 11.7 основана собственная сборка Epic Games. `versions/11.7/epic/`: патчи Epic Games
(вместе с патчем для crypt32). `versions/11.7/patches/`:

| Патч | Модули | Что исправляет |
|---|---|---|
| 0001 winex11-window-region-and-pointer-window | winex11 | как 0001 для 11.22 под X11, плюс без подсказок размера у попапов без заголовка (KWin ограничивал изменение их размера) |
| 0002 server-ntdll-readonly-file-attributes | server, ntdll | файлы только для чтения: их время можно прочитать и изменить, как в Windows (Perforce) |

Чего здесь нет: исправлений Wine-Fx в Windows-модулях, которые можно поставить в один префикс
(системные диалоги файлов, перетаскивание файлов, `.bat`-скрипты, запуск Epic Games Launcher).
Их несёт [Wine Fox](https://lis-carter.site/wine-fox/) и ставит в префиксы («Инструменты»,
«Патчи»). Новому Epic Games Launcher нужно и это исправление в его префиксе, и 0016 отсюда.

## Плагин Unreal Editor

[`unreal/WineFoxVSCode`](unreal/WineFoxVSCode) добавляет в Unreal Editor под Wine пункт *Tools → Open in VS Code (Linux)*.
В редакторе блупринта он открывает C++-родителя блупринта (его `.h` и `.cpp`), в остальных
местах, например во вьюпорте, — линуксовый workspace проекта (`<Project>.linux.code-workspace`).

Скопируйте папку в `Plugins/` проекта (или в `Engine/Plugins/` движка) и один раз соберите
редактор. VS Code запускается на стороне Linux: тот, что Wine Fox находит (`code`, `codium` или
Flatpak) при запуске редактора, иначе `code` из `PATH`; `WINEFOX_CODE` его заменяет.

## Релизы (для сопровождающих)

```bash
bash make-release.sh 11.22
```

Скрипт собирает Wine 11.22 без патчей, затем накладывает их на то же дерево, и пересобирается
только то, что они затрагивают; отличающиеся файлы идут в `dist/Wine-Fx-11.22-<буква>.tar.xz` с
`manifest.json`, а `dist/releases.json` описывает релиз вместе с основой (`BASE_URL` из
`wine.conf`: сборка Kron4ek, сюда не выкладывается). Собирайте на старом дистрибутиве, например в
chroot Ubuntu 22.04, чтобы Unix-модули работали там же, где основа. Перед релизом изменённых
патчей поднимите `FX_RELEASE` в `versions/11.22/wine.conf`, поставьте на коммит тег
`11.22-<буква>` и приложите архив и `releases.json` к релизу этого тега на GitHub.

Новая версия Wine: скопируйте `versions/<версия>` в папку для неё, задайте в её `wine.conf`
`WINE_VERSION`, `WINE_URL`, `WINE_SHA256`, `BASE_URL`, `BASE_SIZE`, `BASE_SHA256` и `FX_RELEASE=a` и проверьте, что патчи накладываются:
`bash build.sh <версия> --all`.

## Лицензии

Wine и патчи к нему: LGPL 2.1 или новее (`LICENSE.LGPL`). Патчи Epic Games: MIT
(`versions/*/epic/LICENSE`). Скрипты: GPL 3 (`LICENSE`).
