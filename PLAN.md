# mylinux — RAM-resident Linux + Qt GUI, built with Buildroot, run with QEMU on the Mac

Goal: a purpose-built arm64 Linux that boots from a kernel + initramfs (no disk), lives
entirely in RAM, and shows a full-screen Qt 6 application as its only UI. Built inside the
OrbStack Debian machine, run on the Mac with QEMU + Apple's hypervisor (HVF).

## Verified starting point (2026-09-07)

| Item | State |
|---|---|
| Mac | Apple M4 Pro, 14 cores, 48 GB RAM, Homebrew present, QEMU **not** installed |
| OrbStack Debian | trixie arm64, 13 vCPU, 15 GB RAM, 234 GB free on `/` |
| Debian toolchain | git, gcc, make, cmake, python3, rsync, bc, wget, cpio, unzip, file all **missing** |
| Buildroot | 2026.08 stable (released 2026-09-04) → Qt 6.11.1, kernel 6.18.7 |
| Board config `qemu_aarch64_virt` | already enables DRM, DRM_VIRTIO_GPU, FB, VIRTIO_INPUT, EVDEV, TMPFS, DEVTMPFS |

Decisions:
- **Buildroot 2026.08**, not the 2025.02 LTS: newer Qt and kernel matter more than 3-year support for a hobby image. Switching later is a one-line change.
- **Target arm64** (`-cpu host` under HVF). x86 would lose acceleration.
- **External initramfs** (`rootfs.cpio.gz` passed with `-initrd`) instead of embedding it in the kernel: rebuilding the rootfs does not rebuild the kernel.
- **Internal Buildroot glibc toolchain**: Bootlin prebuilt toolchains are x86_64-host binaries and won't run on the arm64 Debian host. Costs ~15 min once; ccache keeps it.
- **Busybox init** with one startup script. systemd is an option later if you need services.
- **Two graphics stages**: linuxfb first (software, guaranteed), then eglfs + Mesa (OpenGL ES, what Qt Quick really wants).
- **Build tree on Debian's own disk, project tree on the Mac**: Buildroot needs a case-sensitive filesystem with no spaces in paths. APFS is case-insensitive by default, so `output/` must live in Debian (`~/br`). The small BR2_EXTERNAL tree (configs, overlay, app source) stays in `/Users/vikkjart/prjs/mylinux`, which OrbStack exposes at the same path inside Debian, so it is editable from macOS and Git-tracked.

## Repository layout (this folder becomes a Buildroot BR2_EXTERNAL tree)

```
mylinux/
  PLAN.md
  external.desc                 # name: MYLINUX
  external.mk                   # include $(sort $(wildcard $(BR2_EXTERNAL_MYLINUX_PATH)/package/*/*.mk))
  Config.in                     # source "$BR2_EXTERNAL_MYLINUX_PATH/package/myapp/Config.in"
  configs/
    mylinux_defconfig           # the whole OS definition, ~60 lines
  board/
    linux.fragment              # kernel options added on top of Buildroot's qemu aarch64 config
    overlay/                    # files copied verbatim into the rootfs
      etc/init.d/S99myapp       # starts the GUI at boot
      etc/profile.d/qt.sh       # QT_QPA_* env for interactive shells
  package/
    myapp/
      Config.in
      myapp.mk                  # cmake-package, MYAPP_SITE_METHOD = local, source in ../../app
  app/                          # the Qt 6 application (CMake + QML)
    CMakeLists.txt
    main.cpp
    Main.qml
  run.sh                        # QEMU launch on the Mac
```

## Phase 0 — prerequisites (≈10 min)

Mac:
```bash
brew install qemu
```

Debian (inside `orb -m debian`):
```bash
sudo apt update && sudo apt install -y build-essential git cmake ninja-build python3 \
  rsync bc wget cpio unzip file libncurses-dev libssl-dev bzip2 xz-utils zstd \
  perl-modules ccache gawk texinfo patch diffutils findutils
```

Check the Mac folder is visible from Debian: `ls /Users/vikkjart/prjs/mylinux` inside the machine.

## Phase 1 — get Buildroot (≈2 min)

In Debian:
```bash
mkdir -p ~/br && cd ~/br
git clone --branch 2026.08 --depth 1 https://gitlab.com/buildroot.org/buildroot.git
mkdir -p ~/br/output ~/br/dl
```

`~/br/dl` is the download cache; set `BR2_DL_DIR` to it so re-configures never re-download.

## Phase 2 — the OS definition: `configs/mylinux_defconfig`

Start from Buildroot's `qemu_aarch64_virt_defconfig` and apply these changes. Stage A first.

```
# --- target & toolchain ---
BR2_aarch64=y
BR2_TOOLCHAIN_BUILDROOT_GLIBC=y
BR2_TOOLCHAIN_BUILDROOT_CXX=y
BR2_TOOLCHAIN_BUILDROOT_LOCALE=y
BR2_CCACHE=y
BR2_DL_DIR="/home/<you>/br/dl"
BR2_GLOBAL_PATCH_DIR="board/qemu/patches"
BR2_DOWNLOAD_FORCE_CHECK_HASHES=y

# --- system ---
BR2_TARGET_GENERIC_HOSTNAME="mylinux"
BR2_TARGET_GENERIC_ISSUE="mylinux"
BR2_TARGET_GENERIC_GETTY_PORT="ttyAMA0"
BR2_SYSTEM_DHCP="eth0"
BR2_ROOTFS_OVERLAY="$(BR2_EXTERNAL_MYLINUX_PATH)/board/overlay"
BR2_GENERATE_LOCALE="en_US.UTF-8"

# --- kernel: Buildroot's qemu config + our fragment ---
BR2_LINUX_KERNEL=y
BR2_LINUX_KERNEL_CUSTOM_VERSION=y
BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE="6.18.7"
BR2_LINUX_KERNEL_USE_CUSTOM_CONFIG=y
BR2_LINUX_KERNEL_CUSTOM_CONFIG_FILE="board/qemu/aarch64-virt/linux.config"
BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES="$(BR2_EXTERNAL_MYLINUX_PATH)/board/linux.fragment"
BR2_LINUX_KERNEL_NEEDS_HOST_OPENSSL=y
BR2_PACKAGE_HOST_LINUX_HEADERS_CUSTOM_6_18=y

# --- rootfs: initramfs only, no ext4, no host qemu ---
BR2_TARGET_ROOTFS_CPIO=y
BR2_TARGET_ROOTFS_CPIO_GZIP=y
# BR2_TARGET_ROOTFS_EXT2 is not set
# BR2_TARGET_ROOTFS_TAR is not set
# BR2_PACKAGE_HOST_QEMU is not set

# --- Qt 6 (Stage A: linuxfb, software rendering) ---
BR2_PACKAGE_QT6=y
BR2_PACKAGE_QT6BASE=y
BR2_PACKAGE_QT6BASE_GUI=y
BR2_PACKAGE_QT6BASE_WIDGETS=y
BR2_PACKAGE_QT6BASE_LINUXFB=y
BR2_PACKAGE_QT6BASE_FONTCONFIG=y
BR2_PACKAGE_QT6BASE_HARFBUZZ=y
BR2_PACKAGE_QT6BASE_PNG=y
BR2_PACKAGE_QT6BASE_JPEG=y
BR2_PACKAGE_QT6BASE_NETWORK=y
BR2_PACKAGE_QT6BASE_DEFAULT_QPA="linuxfb"
BR2_PACKAGE_QT6DECLARATIVE=y
BR2_PACKAGE_QT6DECLARATIVE_QUICK=y
BR2_PACKAGE_QT6SVG=y
BR2_PACKAGE_DEJAVU=y

# --- our app ---
BR2_PACKAGE_MYAPP=y
```

Stage B (add after Stage A boots and shows the app):
```
BR2_PACKAGE_MESA3D=y
BR2_PACKAGE_MESA3D_GALLIUM_DRIVER_LLVMPIPE=y    # pulls LLVM: +30-60 min first build
BR2_PACKAGE_MESA3D_GALLIUM_DRIVER_VIRGL=y       # for Stage C GPU passthrough
BR2_PACKAGE_MESA3D_OPENGL_EGL=y
BR2_PACKAGE_MESA3D_OPENGL_ES=y
BR2_PACKAGE_MESA3D_GBM=y
BR2_PACKAGE_QT6BASE_EGLFS=y
BR2_PACKAGE_QT6BASE_OPENGL_ES2=y
BR2_PACKAGE_QT6BASE_DEFAULT_QPA="eglfs"
BR2_PACKAGE_QT6SHADERTOOLS=y
```

`board/linux.fragment` (things the stock qemu config lacks for our use):
```
CONFIG_BLK_DEV_INITRD=y
CONFIG_RD_GZIP=y
CONFIG_DRM_FBDEV_EMULATION=y
CONFIG_FRAMEBUFFER_CONSOLE=y
CONFIG_VT=y
CONFIG_INPUT_MOUSEDEV=y
# fast app iteration: share a Mac folder into the VM over 9p
CONFIG_NET_9P=y
CONFIG_NET_9P_VIRTIO=y
CONFIG_9P_FS=y
```

## Phase 3 — boot script and app package

`board/overlay/etc/init.d/S99myapp` (busybox init runs S* scripts in order):
```sh
#!/bin/sh
case "$1" in
  start)
    export QT_QPA_PLATFORM=${QT_QPA_PLATFORM:-linuxfb}   # eglfs in Stage B
    export QT_QPA_FB_DRM=1                                # linuxfb via DRM dumb buffers
    export QT_QPA_EVDEV_MOUSE_PARAMETERS=abs               # virtio-tablet is absolute
    export QT_QUICK_BACKEND=software                       # remove in Stage B
    export XDG_RUNTIME_DIR=/tmp
    /usr/bin/myapp > /var/log/myapp.log 2>&1 &
    ;;
  stop) killall myapp ;;
esac
```

`package/myapp/myapp.mk`:
```make
MYAPP_SITE = $(BR2_EXTERNAL_MYLINUX_PATH)/app
MYAPP_SITE_METHOD = local
MYAPP_DEPENDENCIES = qt6base qt6declarative
MYAPP_CONF_OPTS = -DCMAKE_BUILD_TYPE=Release
$(eval $(cmake-package))
```

`app/`: a minimal Qt 6 CMake project (`qt_add_executable`, `qt_add_qml_module`) whose
`Main.qml` is a full-screen `Window` with a clock and a button. Small on purpose: it proves
the pipeline before real UI work starts. The same project opens in Qt Creator on the Mac.

## Phase 4 — first build (Stage A ≈ 45–70 min on 13 cores; later rebuilds are minutes)

In Debian:
```bash
cd ~/br/buildroot
make O=$HOME/br/output BR2_EXTERNAL=/Users/vikkjart/prjs/mylinux mylinux_defconfig
cd ~/br/output
make -j13 2>&1 | tee build.log
```

Outputs: `~/br/output/images/Image` (kernel) and `~/br/output/images/rootfs.cpio.gz`.
Copy them to the Mac side, e.g. `cp images/{Image,rootfs.cpio.gz} /Users/vikkjart/prjs/mylinux/out/`
(a `make` post-image hook can do this automatically).

Useful loops:
- `make menuconfig` then `make savedefconfig BR2_DEFCONFIG=/Users/vikkjart/prjs/mylinux/configs/mylinux_defconfig` — edit config and save it back to the repo.
- `make myapp-rebuild all` — rebuild only the app, repack the initramfs.
- `make linux-menuconfig` — poke at kernel options; copy the delta into `linux.fragment`.
- `make graph-size` — where the bytes went.

## Phase 5 — run on the Mac: `run.sh`

```bash
#!/bin/sh
exec qemu-system-aarch64 \
  -M virt -accel hvf -cpu host -smp 4 -m 2G \
  -kernel out/Image -initrd out/rootfs.cpio.gz \
  -append "console=ttyAMA0 console=tty0 quiet" \
  -device virtio-gpu-pci \
  -device virtio-keyboard-pci -device virtio-tablet-pci \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -display cocoa,show-cursor=on \
  -serial mon:stdio \
  -virtfs local,path="$PWD/share",mount_tag=share,security_model=none,id=share
```

Expected: the Cocoa window shows kernel messages for ~1 s, then the Qt app. The terminal is a
root shell over the serial console (no password by default; add `BR2_TARGET_GENERIC_ROOT_PASSWD` later).
Stop with Ctrl-A X in the terminal.

Stage C (optional GPU acceleration): `-device virtio-gpu-gl-pci -display cocoa,gl=es` with the
virgl Mesa driver. Support on macOS QEMU builds is patchy; treat it as an experiment, not a dependency.

## Phase 6 — daily development loop

1. **App logic**: develop in Qt Creator on macOS against a host Qt (`brew install qt`), full debugger, instant runs.
2. **Test in the VM without rebuilding the image**: `make sdk` in Buildroot produces a relocatable
   cross-toolchain + sysroot. Cross-build the app in Debian with it, drop the binary into `share/`,
   and inside the VM: `mount -t 9p -o trans=virtio share /mnt && /mnt/myapp`. Seconds, not minutes.
3. **Promote**: when the app is right, `make myapp-rebuild all` and re-run `run.sh` for a clean boot test.
4. Commit the `mylinux/` tree; Buildroot itself and `output/` are never committed.

## Phase 7 — hardening and polish (pick as needed)

- Size: `make graph-size`; drop widgets if QML-only; strip locales; consider `BR2_TARGET_ROOTFS_CPIO_ZSTD` (+`CONFIG_RD_ZSTD`).
- Boot time: `quiet`, drop `FRAMEBUFFER_CONSOLE`, `CONFIG_LOGO` off, trim kernel drivers you don't use, `initcall_debug` to find slow bits.
- Look: hide the cursor, boot splash (a static image via the `psplash` package), set `QT_QPA_EGLFS_HIDECURSOR=1`.
- Input: add `libinput` and `BR2_PACKAGE_QT6BASE_TSLIB` only if you later target real touch hardware.
- Services: switch `BR2_INIT_SYSTEMD=y` if you need networking/udev/journald semantics; costs size and boot time.
- Read-only root and a tmpfs `/var` are automatic with initramfs; state you want to persist needs a virtio-blk disk or the 9p share.
- Real hardware later (Raspberry Pi 5, etc.): same BR2_EXTERNAL tree, new defconfig, new kernel config. The Qt app does not change.

## Risks and how we'll know

| Risk | Signal | Mitigation |
|---|---|---|
| Qt Quick without GL is slow or fails | Blank window or stutter in Stage A | `QT_QUICK_BACKEND=software` is set on purpose in Stage A; Stage B fixes it properly |
| eglfs can't find a GBM device | "Could not open DRM device" in `myapp.log` | Check `/dev/dri/card0` exists; try `QT_QPA_EGLFS_INTEGRATION=eglfs_kms`; fall back to linuxfb |
| LLVM build time | Stage B first build > 1 h | Expected; ccache makes it one-time. Softpipe is the tiny slow alternative |
| Build on shared Mac filesystem | Very slow or case-collision errors | Keep `output/` on Debian's disk as planned |
| Memory | Kernel OOM at boot | Bump `-m`; rootfs uncompressed is ~150 MB (Stage A) to ~450 MB (Stage B with LLVM) |

## Status — 2026-09-07 evening

Stage A is built and verified on the Mac:

- Buildroot 2026.08 in `~/br/buildroot` (Debian), output in `~/br/output`; first build 52 min, rebuilds ~1 min.
- Image: `Image` 13 MB + `rootfs.cpio.gz` 44 MB (127 MB unpacked). Boots to the Qt app in ~1 s of guest uptime; 89 MB RAM used.
- Verified: virtio-gpu framebuffer 1280×800, Qt 6.11.1 QML clock + button, mouse hover/click, DHCP, 9p share mount, local time (Europe/Oslo).
- Deviations from the plan above, all now in the repo:
  - `BR2_PRIMARY_SITE=https://sources.buildroot.net` — ftpmirror.gnu.org was returning 502 and stalled downloads.
  - `BR2_TARGET_TZ_INFO` + `BR2_TARGET_LOCALTIME`, and `LANG`/`LC_ALL` in `qt.sh` (Qt complained about a C locale).
  - Input: linuxfb's evdev auto-discovery skips the virtio tablet as a mouse and claims it as an always-pressed touchscreen. `qt.sh` sets `QT_QPA_FB_DISABLE_INPUT=1` and loads `evdevmouse:/dev/input/event1:abs,evdevkeyboard:/dev/input/event0` explicitly.
  - `run.sh` honours `SERIAL=...` so scripts can take the console (the virt machine has one UART) and use `-qmp unix:out/qmp.sock,server,nowait` for automation. HMP `mouse_move` does not produce absolute motion for the virtio tablet; use QMP `input-send-event`. The kernel drops absolute events whose value is unchanged, so always move before clicking in scripted tests.
- Scripts: `./build.sh [make targets]` builds in Debian and copies images to `out/`; `./run.sh` boots them.

### 2026-09-08 morning — Phase 6 done, Stage B building

- `tools/sdk-update.sh` exports the Buildroot SDK to `~/br/sdk` (Debian, 1.1 GB, relocated). Re-run it whenever the image config changes.
- `tools/app-build.sh` cross-builds `app/` with that SDK (CMake + Ninja, ~10 s incremental) into `share/myapp`.
- `S99myapp` mounts the 9p share at `/mnt/share` on boot and runs `/mnt/share/myapp` if it exists, else `/usr/bin/myapp`. The app footer shows which binary is running.
- Verified: SDK-built binary launched from `/mnt/share` in the Stage A VM, clicks work.
- Stage B config landed (`BR2_PACKAGE_MESA3D_LLVM=y` is required explicitly — llvmpipe *depends on* it, nothing selects it). `qt.sh` now defaults to eglfs/eglfs_kms with `MESA_LOADER_DRIVER_OVERRIDE=kms_swrast`; linuxfb stays in the image as fallback.

- **Buildroot gotcha:** changing a package's options does not rebuild it. After the Stage B config change, `make` built Mesa/LLVM but left qt6base at its Stage A build (no eglfs plugin). Fix: `make qt6base-dirclean qt6shadertools-dirclean qt6declarative-dirclean qt6svg-dirclean myapp-dirclean` then `make`. Mesa 26 ships one `libgallium-*.so` megadriver; there is no `/usr/lib/dri` directory any more.

### 2026-09-08 07:05 — Stage B verified

- Image: `Image` 13 MB + `rootfs.cpio.gz` 78 MB (210 MB unpacked; LLVM alone is 65 MB). Boots to the app in ~1 s; 178 MB RAM used.
- Qt reports platform `eglfs`, backend eglfs_kms on `/dev/dri/card0` via GBM, Mesa 26.1.8 llvmpipe (`MESA_LOADER_DRIVER_OVERRIDE=kms_swrast`). Qt logs "Running on a software rasterizer (LLVMpipe)" once per GL context — expected.
- Input unchanged: one explicit evdev mouse + one keyboard handler, clicks verified.
- Screendumps taken through QMP do not include the hardware cursor plane, so the pointer is invisible in scripted screenshots but visible in the QEMU window.
- SDK re-exported with the Stage B libraries (1.8 GB); `tools/app-build.sh` verified against it.
- Stage A's linuxfb plugin is still in the image. Fallback: `QT_QPA_PLATFORM=linuxfb QT_QUICK_BACKEND=software myapp`.

### 2026-09-08 — Desktop shell (Wayland compositor): milestone 1 done

Goal: a macOS-like desktop. The shell (`shell/`, package `myshell`) is a **Qt Wayland compositor written in QML**
running on eglfs; apps are separate Wayland client processes (the clock app, the `foot` terminal). Config additions:
`BR2_PACKAGE_QT6WAYLAND(_COMPOSITOR)`, `BR2_PACKAGE_MESA3D_LEGACY_BIND_WAYLAND_DISPLAY`, `BR2_PACKAGE_XKEYBOARD_CONFIG`,
`BR2_PACKAGE_FOOT`, `BR2_PACKAGE_DEJAVU_MONO`, `BR2_PACKAGE_MYSHELL`. Boot script is now `S99shell`.

**Important Buildroot 2026.08 + Qt 6.11 bug, worked around locally:** Qt 6.11 moved the `wayland_client` /
`wayland_server` / `waylandscanner` feature switches from qtwayland into **qtbase** (`src/gui/configure.cmake`). They are
exported through `Qt6::Gui`, and qtwayland builds nothing when they were OFF at qtbase configure time — silently, in
about one second. Buildroot still passes `-DFEATURE_wayland_*` to qt6wayland (ignored) and does not make qt6base depend
on wayland. Fix: `tools/buildroot-patch.sh` appends a snippet to `package/qt6/qt6base/qt6base.mk` (documented in
`buildroot-patches/`) that adds the wayland dependencies and turns the features on for qt6base and host-qt6base.
Run it after every fresh Buildroot clone. Symptom to recognise: `Qt6WaylandCompositorConfig.cmake does NOT exist`,
and qt6wayland's configure log lists `FEATURE_wayland_client` under "Manually-specified variables were not used".

**Two more Buildroot gotchas hit here:**
- **Removed overlay files stay in the image.** `output/target/` accumulates; deleting `board/overlay/etc/init.d/S99myapp`
  did not remove it from the image, so the old fullscreen clock kept grabbing DRM master before the compositor
  ("Could not set DRM mode ... Permission denied"). Fix: `rm output/target/<path>` (or a full `make clean`) after
  removing/renaming overlay files.
- **Qt's compositor speaks old protocol versions**: `wl_seat` 4 and `wl_data_device_manager` 1. foot requires seat >= 5
  and treats a data-device manager < 3 as fatal (exit 230, right after "no clipboard available"). `patches/qt6wayland/`
  bumps both (seat 5 with `wl_pointer.frame` events; ddm/source/offer/device 3), applied via `BR2_GLOBAL_PATCH_DIR`.
  Write patches with a real `diff -u` against the extracted source: Buildroot applies them without fuzz.

**Milestone 1 verified (08:07):** boot → compositor (menu bar, gradient wallpaper, dock) in ~20 s; clock app and `foot`
terminal open as Wayland clients in frames with traffic lights; drag by title bar, click-through, keyboard input into the
terminal, dock launches new windows, red button closes (client exits). Menu bar shows the focused app's title.
RAM used: ~215 MB with two terminals and the clock. Clients render in software (wl_shm); the compositor uses llvmpipe GL.
**Milestone 2 verified (08:31) — window management + shortcuts.** `Desktop.qml` keeps a window list keyed by xdg
`app_id`; the dock shows a running dot per app, dims the icon when its windows are minimised, and a click restores
minimised windows / raises / launches. Minimise and restore animate (scale+fade). Windows cascade inside the layer
and stay clear of the menu bar and dock; the title bar drag is clamped. Shortcuts (QML `Shortcut`, application
context, intercepted before the client gets the key): close window, quit app (close all its windows), minimise,
new terminal, cycle windows.

**Shortcut modifier caveat:** the intended key is Cmd (Meta/Super), but Qt's built-in evdev keymap has *no entry for
KEY_LEFTMETA* and the evdev handler has no Meta modifier, so with the current evdev input backend only the **Alt**
variants fire (Option key on a Mac keyboard in QEMU). Both `Meta+X` and `Alt+X` are bound. Fix later by switching
the compositor's input to libinput (`BR2_PACKAGE_LIBINPUT`, eudev, `QT_QPA_EGLFS_NO_LIBINPUT` unset) or a custom
Qt keymap; then Cmd works and Alt can be released to the terminal.

**Milestone 3 verified (08:38) — edge resizing, app icons, wallpaper.** Resize handles on all four edges and
corners (`MacWindow.qml` inline `ResizeHandle`); left/top drags keep the opposite edge fixed by re-anchoring while
the client's surface resizes. App icons are drawn in QML (`AppIcon.qml`: gradient plate, highlight, terminal glyph,
live analogue clock face) with hover magnification and a tooltip label. Wallpaper is `shell/assets/wallpaper.png`
(1600×1000, 271 KB) generated by `tools/gen-wallpaper.py` (pure Python, no deps) and embedded as a Qt resource.
Lessons: QML inline components must sit at the file root; `XdgToplevel.*` enums need
`import QtWayland.Compositor.XdgShell` (the green zoom button had been silently broken by that).

**Milestone 4 (2026-09-08 ~09:50) — menus, glass, display panel, Mac window.**
- `MenuBar.qml`: Apple/app/File/Edit/View/Window/Help menus as glass drop-downs (one bar-level `Loader`, not nested
  in the Row: a nested Loader's items were never hit-testable). Window menu lists live windows. About panel.
- `GlassPanel.qml`: `ShaderEffectSource` of the backdrop (wallpaper + windows) + `MultiEffect` blur, masked to a
  rounded rect, tint, hairline, specular highlight. Used by menu bar, dock, menus, About, Display panel. Idle CPU 0%.
- `DisplayPanel.qml` (icon left of the clock): brightness (software dimming overlay), text size (shell fonts +
  rewrites `/etc/xdg/foot/foot.ini` for new terminals), UI scale 1x–2.5x (chrome via `Theme.px()`, client surfaces
  via item `scale`; the wl_output scale stays 1), and Mac-window buttons. Settings persist in `share/mylinux.ini`
  (`Settings` C++ singleton, QSettings) because the rootfs is RAM.
- **Mac window**: `run.sh` runs the guest at `RES` (default 1920x1200, `mylinux.res=` on the kernel cmdline, pinned
  through `QT_QPA_EGLFS_KMS_CONFIG` by `S99shell` — otherwise QEMU's *preferred* mode follows the host window size and
  a compositor restart picks e.g. 640x400) with `-display cocoa,zoom-to-fit=on` so the window is freely resizable and
  scales the guest. A host agent loop in `run.sh` watches `share/host-cmd`; the guest's Display panel writes
  `fit|center|fullscreen|native` and `tools/host-window.sh` clicks macOS's Window > Fill / Center menu items via
  AppleScript. That needs Accessibility permission for the terminal app (macOS prompts once).
- Serial console autologin: `BR2_TARGET_GENERIC_GETTY_OPTIONS="-n -l /bin/sh"` (remember `make mylinux_defconfig`
  after editing the defconfig, or `build.sh` builds the old config).
- `tools/qmp.py` takes `SCREEN=WxH` (default 1920x1200) — with the old 1280x800 constant every click was mis-aimed
  after the resolution change, which cost an hour of false "the panel doesn't open" debugging.

**Build gotcha that bit hard (fixed 09:50):** Buildroot syncs a `SITE_METHOD = local` package's sources only at
extract time; a plain `make` afterwards keeps the old build. Every `./build.sh` bake between ~08:10 and 09:50 shipped
a stale `myshell` (the milestone-1 one with the broken resize grip), which is why a freshly booted image did not
match what the SDK hot-swap showed. `build.sh` now defaults to `make myapp-rebuild myshell-rebuild all`.
Always verify an image change by *booting the image*, not only by hot-swapping over 9p.

**Milestone 5 verified (2026-09-08 10:04) — libinput for Cmd, Debian apps disk with Chromium.**
- Input: `BR2_ROOTFS_DEVICE_CREATION_DYNAMIC_EUDEV` + `BR2_PACKAGE_LIBINPUT`; Buildroot's qt6base then builds
  `FEATURE_libinput=ON` (needs the Qt stack rebuilt via `*-dirclean`). `qt.sh` no longer names evdev devices;
  libinput enumerates via udev, classifies the virtio tablet properly and maps Super to Qt's Meta, so the ⌘
  shortcuts fire. `run.sh` passes `left-command-key=on` so QEMU forwards the left Cmd key to the guest.
- Apps disk: `tools/make-apps-disk.sh` debootstraps Debian trixie arm64 (minbase + Chromium) into a sparse ext4
  image `out/apps.img`; `run.sh` attaches it as virtio-blk when present and gives the VM 4 GB. `S45apps` mounts
  it at `/mnt/apps`; `apps-run` bind-mounts /dev,/proc,/sys,/tmp and the Wayland runtime dir into the chroot and
  execs the program as a Wayland client; `/usr/bin/chromium` wraps it with `--ozone-platform=wayland --no-sandbox
  --disable-gpu`. `apps-run apt install <pkg>` is the package manager. The OS itself stays RAM-only.

**Milestone 6 (2026-09-08 10:30) — AI apps by default.** There are no Linux builds of the Claude or ChatGPT desktop
apps, so: `claude-code` = Claude Code CLI (native arm64 binary installed on the apps disk by `apps-setup-ai`, run in
its own foot window via `apps-run`); `chatgpt` / `claude-web` = Chromium `--app=` windows (`webapp` wrapper), which
get their own dock icons via Chromium's `chrome-<host>__-Default` app ids. Default autostart (Settings
`[session] autostart`, editable in `share/mylinux.ini`) is now `claude-code,chatgpt`. Menu bar maps app ids to dock
names. VM RAM default is 6 GB. Verified in the test VM: autostart opens both; the ChatGPT window works (login needed).

**Chromium stability note:** reproduced one *renderer* crash on mbl.is during a resize (crash dump ptype=renderer);
the browser survived. "Chromium didn't shut down correctly" also appears after the VM is powered off with Chromium
open, which is what happened when the disk lock forced a relaunch. Mitigations so far: 6 GB RAM; if it recurs, try
`--disable-features=Vulkan --use-gl=angle --use-angle=swiftshader` in `/usr/bin/chromium` or raise `MEM`.

**Milestone 7 (2026-09-08 10:45) — Firefox, crisp 1:1 display, Inter, myLinux.app.**
- Firefox ESR on the apps disk (`apps-run apt install firefox-esr`), `/usr/bin/firefox` wrapper, dock icon, File menu.
  Google Chrome itself is x86_64-only on Linux; Chromium stays for the ChatGPT/Claude app windows.
- Crispness: `run.sh` now derives `RES` from the Mac screen in points (Finder desktop bounds, minus window margins,
  e.g. 1648x984 on a 1728x1117-pt display) so the guest is shown 1:1 instead of downscaled from 1920x1200;
  `zoom-interpolation=on` for the times it is scaled. `QT_QUICK_DEFAULT_TEXT_RENDER_TYPE=native` in `qt.sh` gives
  hinted per-pixel glyphs instead of soft distance-field text. UI font is Inter (own Buildroot package
  `package/inter`, OFL, 4 static weights), DejaVu Sans as fallback; the menu-bar clock is now vertically centred
  (Row top-aligns children; it needed `anchors.verticalCenter`).
- Mac branding: `tools/make-app-bundle.sh` builds `out/myLinux.app` (symlink to Homebrew's qemu + Info.plist + icon
  from `tools/gen-icon.py`); `run.sh` launches through it with `-name myLinux`, so the app menu, Dock and window
  title read "myLinux". `tools/host-window.sh` targets process "myLinux".
- Retina option for later: RES at 2x points (e.g. 3296x1968) + Wayland output scale 2 + Theme.scale 2 would give true
  HiDPI for Chromium/Firefox/foot (they support wl_output scale 2); costs ~4x compositing work on llvmpipe.

- Self-installing launchers (10:50): `apps-install <title> <pkg> <test-path> <cmd...>` opens a terminal, apt-installs
  the package onto the apps disk, then execs the app; `/usr/bin/firefox` and `/usr/bin/claude-code` use it, so a
  fresh apps disk gets Firefox / Claude Code on first click. Verified: removed firefox-esr, clicked the dock icon,
  installer window appeared, Firefox started ~2 min later.

**Milestone 8 (2026-09-08 11:30) — ⌘Space launcher / ⌘⌥Space menu (Omarchy-style).** `Spotlight.qml`: centred glass
dialog, search field ("Search…"), filtered list of apps + actions, ↑↓/Enter/Esc/Tab, click, prefixes `=` (calculator),
`?` (web search in Firefox), `install <pkg>` (apt on the apps disk). ⌘⌥Space opens the menu mode ("Go…"): Apps ›
Setup › Install › Update › About › System, with breadcrumbs and Esc to go back. While open, the compositor's seat
keyboard focus is cleared so keys go to the dialog; closing raises the focused window to hand focus back.
Keyboard modes in `run.sh` (default now `GRAB=opt`: Option is the Super key, per the user): `GRAB=full` (QEMU full-grab: Cmd+Space/Tab captured for the guest, needs Accessibility),
`GRAB=opt` (Option acts as Cmd/Super), default = plain forwarding (Cmd+Space still opens Spotlight on the Mac).
Mode-pin fix: `video=Virtual-1:${RES}@60` on the kernel cmdline adds the requested mode permanently, so the KMS pin
survives host window resizes (before, resizing the Mac window removed the "preferred" 1648x984 from the mode list and
a shell restart fell back to 640x384).

**Milestone 9 (2026-09-08 11:37) — keyboard layout switcher.** Badge in the menu bar (EN / NO / IS) with a glass
chooser; the choice sets the Wayland seat keymap (`WaylandSeat.keymap` layout us/no/is, variant `mac`, model pc105)
so every client interprets the Mac keyboard correctly, persists as `[input] layout=` in `share/mylinux.ini`, and
`S99shell` exports it as `XKB_DEFAULT_LAYOUT` for the shell's own text fields at boot. Verified: with NO selected the
US keys `;'[-` and Shift+2 typed `øæå+"` in foot. Lesson repeated twice today: popups must be hosted at the menu-bar
level and any click-away layer must sit *below* the bar (z 5), or clicks never reach the popup.

- Chroot integration (11:50): `apps-run` drops `/usr/local/bin/mylinux-browser` into the chroot and exports
  `BROWSER` to it, so `xdg-open` / Claude Code's login open our Chromium; `wl-clipboard` (wl-copy/wl-paste) is on the
  apps disk (setup script + disk builder) so "c to copy" and Wayland clipboard work between apps.

**Milestone 10 (2026-09-08 12:05) — agent usage panel + Codex.** Starburst icon in the menu bar opens
`AgentPanel.qml` (Omarchy-style): Claude Code / Codex tabs, LIMITS with bars and "Resets in", TOKENS BY DAY (7 days),
TOKENS BY MODEL. Data comes from `agentusage.cpp` (C++ singleton `AgentUsage`, refreshed on open and every 60 s):
- Claude Code: `/mnt/apps/root/.claude/projects/**/*.jsonl` (`message.usage.*` summed per day/model, streamed
  duplicates de-duplicated by message id + requestId); plan name from `.claude/.credentials.json`; limits from
  `GET https://api.anthropic.com/api/oauth/usage` with the OAuth bearer (unofficial endpoint, handled gracefully).
- Codex: `~/.codex/sessions/**/*.jsonl` `token_count` events (`last_token_usage`, `rate_limits.primary/secondary`).
- `apps-setup-ai [claude|codex|all]` installs both (Claude native installer; Codex arm64 musl release binary);
  `/usr/bin/codex` launcher + dock icon self-install on first click like Claude Code.
Verified with sample logs on the test disk: day/model totals render; limits show a sign-in hint until logged in.
Note: `data` is a reserved Item property in QML (AgentPanel's binding had to be renamed `usage`).

**Milestone 11 verified (2026-09-08 12:40) — persistent home + first-boot setup inside the VM.**
- `S45apps` bind-mounts the apps disk's `/root` over the base system's `/root`, so the terminal's home persists and
  is the same home Claude Code / Codex / browsers use. Blank disks (all zeros at the superblock offset; busybox
  `blkid` is not reliable for this) are detected and left for `apps-setup`.
- `run.sh` creates a blank sparse `out/apps.img` (16 GB, `APPS_SIZE_GB=`) when none exists.
- `apps-setup` (guest): mke2fs the disk, `curl` Debian's official minimal trixie arm64 rootfs (the OCI blob from
  debuerreotype/docker-debian-artifacts, ~50 MB), `gunzip | tar` it (busybox tar has no `-z`), apt-install the desktop
  set (Chromium, fonts, GL, wl-clipboard, curl), then `apps-setup-ai all`. Idempotent. Base image gained curl +
  ca-certificates + e2fsprogs + xz (util-linux had to be dirclean'd to get libuuid for e2fsprogs).
- `FirstRun.qml`: welcome dialog when the disk has no Debian/Chromium; "Set up the apps disk" runs the setup in a
  terminal window (`apps-setup-window`, log in `/var/log/apps-setup.log`); autostart entries that need the disk are
  skipped until it is ready and run afterwards (`Main.qml runAutostart`).
- Verified end to end on a blank 16 GB sparse file: dialog → format → rootfs download (50 MB) → apt (Chromium etc.)
  → Claude Code + Codex, **3.5 minutes total**, 1.3 GB used; Chromium and Codex then launch from the dock; a file
  written to `/root` survived a reboot; on the second boot no dialog, autostart opened Claude Code + ChatGPT.

- `tools/fresh-start.sh` boots as a brand-new user (blank `out/apps-fresh.img`, empty `out/fresh-share/`, so
  `run.sh`'s `SHARE_DIR`/`APPS_IMG` are used) without touching the real disk/settings; `keep` re-boots it.

**Milestone 12 (2026-09-08 13:33) — themes (Omarchy-compatible).** `board/overlay/usr/share/mylinux/themes/<id>/`
holds `colors.toml` (Omarchy's palette format, 19 palettes fetched by `tools/fetch-omarchy-themes.sh`, MIT) plus
`light.mode` and `backgrounds/*.png` (two per theme, generated from the palette by `tools/gen-wallpaper.py`, 5.7 MB
total); `mylinux` is the default theme. `ThemeStore` (C++) lists themes and rewrites `/etc/xdg/foot/foot.ini`
(`[colors-dark]`/`[colors-light]`, font). `Theme.qml` exposes bg/fg/accent/isLight and derived panel/bar tints; the
wallpaper, glass panels, menu bar text, selection highlights follow. ⌘⌃⇧Space opens the picker (Spotlight "theme"
mode with swatches, Enter applies), ⌘⌃Space cycles the theme's backgrounds; persisted in `[theme]`. User themes can be
dropped into `/mnt/apps/root/.config/mylinux/themes/`. Verified: Tokyo Night, background cycle, Flexoki Light.

**Milestone 13 (13:40) — Omarchy-style keys and tiling.** ⌘Enter terminal, ⌘⇧Enter browser (Firefox), ⌘K keybinding
sheet (`KeyHelp.qml`, generated from `Desktop.keybindings`). `Tiling.qml`: dwindle binary-split layout over the work
area (gap 10) — new windows split the focused tile along its longer side; ⌘arrows focus by direction, ⌘⇧arrows swap,
⌘⌃arrows resize the split, ⌘V float/tile, ⌘F fullscreen, ⌘⇧T tiling on/off (`[wm] tiling`), dragging a tiled window's
title bar floats it. Tiling is on by default. Verified with three terminals.
`tools/fresh-start.sh keep` now works (the `keep` argument was being passed to QEMU).

**Milestone 14 (14:10) — Omarchy backgrounds + theme store.** `theme-fetch-backgrounds` (guest) downloads the
basecamp/omarchy repo tarball (~70 MB) and copies every theme's real `backgrounds/` (plus `colors.toml`/`light.mode`)
into `~/.config/mylinux/themes/<id>/`; WebP files are converted to PNG by `myshell --convert-webp <dir>` (offscreen
Qt, libwebp via QLibrary, since Buildroot's webp package ships no `dwebp`). `theme-install <github url|owner/repo>`
installs any Omarchy-format theme repo (tarball, finds `colors.toml`; non-GitHub URLs fall back to `apps-run git`).
`ThemeStore` merges `/usr/share/mylinux/themes` with the user dir (user colours win, backgrounds unioned) and
understands both the old `color0..15` and the Omarchy 3 named-colour `colors.toml` formats. The theme picker gained
"Download Omarchy backgrounds for all themes" and `install <url>` entries. Verified in the fresh VM: 92 images for
22 themes downloaded, 79 WebP converted, picker shows background counts, Tokyo Night applied, ⌘⌃Space cycles.
Repo prepared for GitHub: GPL-3.0 (Qt Wayland Compositor is GPL-only), README, `.gitignore`, user paths removed.

**Milestone 14 follow-ups (14:37).** (1) busybox init starts services with `HOME=/`, so the shell and everything it
launched used the RAM-only root as home: `theme-fetch-backgrounds` wrote to `/.config/…` (lost on reboot, and not
where `ThemeStore` looks). `qt.sh` now exports `HOME=/root` (the apps-disk-backed home). (2) `S99shell restart` typed
in a terminal window killed that terminal (a compositor client) and with it the script, leaving a black screen; the
restart now runs in its own session (`setsid`) and the shell is started with `setsid` too. (3) `ThemeStore` converts
stray `*.webp` at scan time (`ThemeStore::convertWebp`, shared with `myshell --convert-webp`) and lists user
backgrounds before the generated ones, so a downloaded photo shows as soon as a theme is applied. (4) Mac side:
`tools/brand-qemu.py` copies Homebrew's QEMU into `out/myLinux.app`, rewrites the four hardcoded Cocoa strings
("QEMU %s" window title, About/Hide/Quit QEMU) by placing new strings in the zero padding at the end of `__TEXT` and
repointing the CFString constants (chained-fixup pointers: low 36 bits = file offset), and re-signs ad hoc with QEMU's
hypervisor entitlement; `Contents/share` links to Homebrew's data dir. `make-app-bundle.sh` refreshes the copy when
Homebrew's binary changes; `run.sh` calls it every launch. Verified: title "myLinux", menu items renamed, HVF boot OK.
Published: https://github.com/adminmylinux/mylinux (GPL-3.0), release v0.1.0 with Image + rootfs.cpio.gz.

**Milestone 14 follow-ups II (14:55).** The theme picker dropped its "Download Omarchy backgrounds" / "Install a theme"
entries as soon as the filter had text (typing "download" + Enter did nothing); they now match on label/hint.
`theme-fetch-backgrounds` replaces a theme's downloaded photos and copies only files with a PNG/JPEG/RIFF magic (a
saved 404 page named `.png` had made the wallpaper "Unsupported image format", showing only the fallback tint). WebP
conversion scales to ≤ 2560 px wide (Omarchy photos are up to 5000 px; llvmpipe textures and decode time). Fresh-VM
end-to-end: picker → "down" → Enter → download window → Hackerman shows the synth-scape photo.

Safer quitting (2026-09-08 15:20): the apps disk is mounted with commit=1 (journal + data flushed every second), so
Cmd+Q on the QEMU window, which is a power cut, loses at most ~1 s; the QEMU quit confirmation is rebranded to say
so and point at ⌘ › Shut Down…; README has a "Quitting" section. Verified: /proc/mounts shows commit=1, dialog text,
clean poweroff exits QEMU.

Terminal PATH (2026-09-08 16:00): apps-path symlinks every apps-disk command the base lacks into /usr/local/bin
(-> apps-exec -> apps-run); apps-run keeps the caller's cwd under /root or /tmp and has /root/.local/bin on its
PATH; claude-code/codex run inline when typed in a terminal; the desktop starts in $HOME so terminals open in /root.

Dock icons (2026-09-08 16:05): AppIcon draws a gradient plate per app plus an SVG glyph from shell/assets/icons
(Claude starburst, Claude Code terminal window, OpenAI-style knot for ChatGPT/Codex, cloud terminal); Chromium and
Firefox use the real hicolor icons from the apps disk once installed (SVG fallback otherwise). git (+ openssh-client,
less) is part of the default apps-disk set; apps-setup is idempotent so it adds git to older disks.

Window size (2026-09-08 19:10): QEMU 11's zoom-to-fit never grows the window past its initial 640x480 (only fixes
the aspect), so the VM opened tiny; run.sh now uses zoom-to-fit=off (QEMU sizes the non-resizable window to the
guest and centres it) with the bundle marked NSHighResolutionCapable=false so guest pixels are points. RES comes from
the display under the mouse (NSScreen via JXA) instead of the Finder desktop bounds, which are the union of all
displays. A placer moves the window onto that display (System Events, by window title: pids are not a safe handle
when two processes share the bundle). NAME=... sets the window title; fresh-start.sh uses "myLinux (test)".

Menu bar (2026-09-08 21:30, offsets 2026-09-09 04:50): 20 px (was 28; the user wants it slimmer than the 24 pt macOS bar); text sits 2 px and icons 1 px below the geometric centre (caps rows 6-16 of 0-19), which reads as centred, titles 13 px / logo 16 px. tools/get-image.sh downloads and
verifies the latest release into out/; README "Install and run" is now clone + get-image + run.sh.

Workspaces (2026-09-09 05:30): 9 Omarchy-style workspaces; ⌘1-9 switch, ⌘⇧1-9 move the focused window and follow.
Windows carry a workspace number (hidden when not current), one dwindle tree per workspace (Desktop.tilings), the menu
bar shows occupied workspaces as pills (click to switch), the Window menu tags other workspaces' windows with [n]; the
dock activates an app on its workspace when it has no window here.

Window geometry (2026-09-09 06:30): MacWindow honours xdg_surface window geometry (GTK/Chromium CSD shadow margins were
showing as padding inside the frame): frame size = geometry, surface item offset by -geometry origin, margins clipped;
configure sizes use the geometry. Firefox and Chromium still draw their own min/max/close buttons (CSD) - follow-up.

Remote desktops (2026-09-09 06:55): /usr/bin/remmina installs Remmina + VNC/RDP plugins from Debian on first use
(apps-install now takes a package list, closes its window after installing and starts the app detached; trap HUP + sleep, the pty hangup used to kill the child before setsid) and seeds tab_mode=2 so every connection is a tab in one window; dock icon
"Remote Desktop" (kind remote), File menu and launcher entries. Verified: installs in ~1 min, runs on Wayland. No secret
plugin, so saved passwords are stored unencrypted - follow-up if wanted (remmina-plugin-secret + a keyring).

Title bars (2026-09-09 07:50): MacWindow.selfDecorated (xdg-decoration client-side, or window geometry smaller than the
surface = CSD shadow margins) drops our title bar/frame for GTK/Chromium windows; Theme.titleBars auto|always|never
(Settings wm/titlebars, Window menu). titleHeight change re-lays out the tile.

Chromium (2026-09-09 08:15): --test-type silences the "--no-sandbox unsupported flag" bar (cosmetic; the sandbox is off because the chroot runs as root - the proper fix is an unprivileged user on the apps disk); apps-run rewrites its chroot helper files every run so flag changes reach existing disks.

Key sheet (2026-09-09 09:05): KeyGrab publishes the held modifiers (Q_PROPERTY modifiers); the ⌘K sheet highlights the
bindings whose modifiers equal the held set (⌘, ⌘⇧, ⌘^, ⌘⌥) and dims the rest; panel tint raised so windows behind do not
bleed through. tools/qmp.py gained kdown/kup to hold keys in tests.

Menu (2026-09-09 09:15): ⌘Space opens the Omarchy-style menu (Apps, Learn, Trigger, Style, Setup, Install, Remove, Update,
About, System) with the search field on top; typing searches everything the menu offers (Spotlight.everything()), plus
the = ? install remove prefixes. The old flat "search" mode is gone from the shortcuts.

Key sheet tabs (2026-09-09 09:20): ⌘K has "Sheet" (grid by group) and "Search" (compact list: key chip, description,
group; filtered by a text field). Tab switches; typing on the sheet jumps into search with that text; Esc clears, then
closes. Modifier highlighting works in both tabs.

Omarchy keys (2026-09-09 09:40): the shortcut set now matches Omarchy: ⌘T float, ⌘J toggle split, ⌘Tab/⇧Tab/⌃Tab
next/previous/former workspace, ⌘⇧⌥1-9 move silently (KeyGrab digit(n, shift, alt)), ⌘S/⌘⌥S scratchpad (MacWindow.scratch,
Desktop.scratchVisible), ⌘⇧F files (Nautilus via apps-install), ⌘⌥F/⌘⌃F = fullscreen, ⌘Esc/⌘⇧Esc menus, ⌘/ ⌘⌥/ scale
steps, Print screenshot (backdrop.grabToImage -> /root), ⌃⌥⌦ close all, ⌘+drag move / ⌘+right drag resize
(MacWindow superDrag, enabled while KeyGrab reports Meta). Alt+Tab cycles windows but only reaches the guest with
GRAB=full. Not ported: clipboard manager, emoji picker, lock, nightlight, notifications, groups, monitor moves.

Solid panels (2026-09-09 09:45): GlassPanel.solid (default Theme.solidPanels = true, Settings look/solidPanels) draws
the tint opaque and skips the software blur; menus, sheets, popovers, About and FirstRun are solid, the dock and menu
bar stay glass (they sit over the wallpaper). Style menu: Panels: solid / glass.

Autostart (2026-09-09 09:50): default is now claude-web (the claude.ai app window) + chatgpt instead of claude-code; override with [session] autostart=... in share/mylinux.ini.

Dock auto-hide (2026-09-09 09:55): default on (Theme.dockAutoHide, Settings look/dockAutoHide); a 3 px hover strip at the
bottom edge reveals the dock, it hides 600 ms after the pointer leaves dock and strip; the window layer then extends to
the bottom. Style menu: Dock: auto-hide / always visible. tools/app-build.sh now fails loudly when ninja fails (it used
to copy the stale binary because the exit status went through `| tail`).

Clipboard (2026-09-09 10:25): text clipboard Mac <-> guest over the share folder. run.sh's host agent mirrors pbpaste
into share/clipboard/mac.txt and pbcopies share/clipboard/guest.txt (CLIPBOARD=0 disables); the guest daemon
clipboard-bridge (started by S99shell, waits for wayland-0 + wl-copy on the apps disk) applies mac.txt with wl-copy and
publishes wl-paste changes to guest.txt, twice a second. QtWayland accepts set_selection / offers the selection to
unfocused clients, so no focus tricks are needed. Text only; images/files are a follow-up.

Known gaps: 2x scale is upscaled (blurry) until fractional-scale support; no Compose file for dead keys, foot warns about
primary-selection / xdg-activation / fractional-scale protocols (harmless), no app icons yet, single wallpaper
gradient, no menus behind the menu bar items, no Mission Control / Spotlight / Control Center yet.
Dev loop for the shell: `tools/app-build.sh shell` then `/etc/init.d/S99shell restart` in the VM (~30 s round trip,
no image rebuild). Note: OrbStack's shared filesystem caches attributes for ~1 s; the build script waits 2 s before
ninja so fresh edits are seen.

Homebrew's QEMU (11.1) has no `virtio-gpu-gl` device and no OpenGL display on macOS, so Stage C (virgl) is not
possible with it; UTM's QEMU build or a source build with virglrenderer+ANGLE would be needed.

## Order of work

1. Phase 0 + 1 (install tools, clone Buildroot)
2. Write the BR2_EXTERNAL tree: defconfig, fragment, overlay, package, hello app, run.sh
3. Stage A build → boot → see the QML clock in the Cocoa window
4. Phase 6 loop: sdk + 9p share for fast iteration
5. Stage B (Mesa + eglfs) build → verify GPU path, drop software backend
6. Real application work in `app/`
7. Phase 7 items as they become relevant
