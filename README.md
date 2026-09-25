# myLinux

A small Linux desktop that lives entirely in RAM, built for Apple-silicon Macs.
It boots in a few seconds as a QEMU virtual machine (Apple's Hypervisor.framework), runs a
Qt 6 Wayland compositor with a macOS-style look (menu bar, dock, glass panels) and borrows its
keyboard-driven workflow and themes from [Omarchy](https://omarchy.org): tiling windows,
Super+Space launcher, Super+K keybinding sheet, Omarchy theme packs and backgrounds.

Persistent things (your home directory, Debian apps, browsers, Claude Code, Codex) live on a
separate "apps disk" image that the system sets itself up on first boot.

![Screenshot](docs/screenshot.png)

## What is inside

| Layer | Choice |
|---|---|
| Build system | [Buildroot](https://buildroot.org) 2026.08, this repo is the `BR2_EXTERNAL` tree |
| Target | arm64, Linux 6.18, glibc, busybox init, initramfs only (~110 MB kernel + rootfs) |
| Graphics | virtio-gpu, Qt 6.11 `eglfs_kms`; Mesa virgl on the accelerated QEMU runtime (the Mac's GPU through Metal), Mesa llvmpipe on Homebrew's QEMU |
| Desktop | `shell/`: QML Qt Wayland Compositor ("myshell"), foot terminal, Inter font |
| Apps disk | Debian trixie arm64 chroot with apt: Chromium, Firefox, Remmina (VNC/RDP), btop, git, Claude Code, Codex, wl-clipboard |
| Host | QEMU 11 (Homebrew), HVF acceleration, 9p shared folder, macOS app bundle `myLinux.app` |

## Requirements

- Apple-silicon Mac, macOS 15 or newer, about 8 GB of free RAM for the VM.
- [Homebrew](https://brew.sh) with `brew install qemu`.
- To build the image: [OrbStack](https://orbstack.dev) with a Debian machine named `debian`
  (Buildroot needs a case-sensitive filesystem; the build tree lives inside Debian at `~/br`).
  Prebuilt images are attached to the releases of the public
  [mylinux-releases](https://github.com/adminmylinux/mylinux-releases) repository, so building is optional.

## Install and run (prebuilt image)

```bash
brew install qemu
git clone https://github.com/adminmylinux/mylinux.git
cd mylinux
tools/get-image.sh      # downloads Image + rootfs.cpio.gz of the latest release into out/, checks SHA256
./run.sh
```

Homebrew's QEMU is optional: `tools/get-qemu-runtime.sh` installs myLinux's own QEMU into `out/qemu-runtime`
(about 10 MB), and `run.sh` uses it whenever it is there. That runtime is QEMU 11.1 with VirGL, so a guest whose
Mesa has the `virgl` driver renders on the Mac's GPU (virtio-gpu-gl, virglrenderer, ANGLE, Metal): images built
after 2026-09-19 do, and the desktop's compositor then costs a few percent of a core where software rendering took two
and a half cores for a repainting terminal. `RENDER=soft ./run.sh` keeps the guest on software GL. `MYLINUX_QEMU=brew ./run.sh` insists on Homebrew's, `tools/get-qemu-runtime.sh --remove`
goes back for good. It is built by `tools/build-qemu-runtime.sh` from a pinned commit of
[Try Omarchy](https://github.com/omacom/try-omarchy)'s runtime build; sources and licences travel inside it (`NOTICES.md`).

### Omarchy machines

The same runtime also starts real [Omarchy](https://omarchy.org) (Arch Linux with Hyprland) as a second kind of
machine: `tools/get-omarchy.sh` downloads the ARM64 guest that the [Try Omarchy](https://github.com/omacom/try-omarchy)
project publishes (1.4 GB, one pinned release, checked against a pinned SHA-256, the publisher's signature and the
guest's own checksums; nothing from it is run on the Mac), and `./run-omarchy.sh` boots it with Hyprland drawn by the
Mac's GPU. A machine is a folder holding its root disk (unpacked on first start, `DISK_SIZE_GB=32`, grown by the guest)
and `boot/`, the kernel that disk was made with. `SHARE_DIR=~/Work` shows up inside as `~/Work`; `GRAB`, `MEM`, `RES`
work as for `run.sh`; `QMP=socket` gives a control socket, where `system_powerdown` is a clean shutdown. The window's
title bar has three buttons at the right: back to the starting size, 10% larger (Omarchy follows with a higher
resolution), and full screen; Control+Command+F toggles full screen in every keyboard mode, and a small floating
box with an exit button appears while in full screen. They come from `tools/qemu-runtime-patches/`, myLinux's own
patch on the runtime. In the
launcher it is **Add Omarchy**. Open windows come back after a restart: `omarchy/session` is written into a new
machine's disk before its first boot (`tools/omarchy-bake-session.sh`, with the runtime's `debugfs`; nothing is mounted),
system-wide and enabled for every account. The layout, each window's command line and a terminal's working directory, is
saved every minute and at logout and reopened on the same workspaces at login. Apps that restore their own state come
back complete, terminals come back empty in the right folder. `omarchy-session status|save|restore|interval|disable`
inside Omarchy; on a machine made before this existed, `sh ~/<share>/mylinux-tools/install-session.sh` installs it into
the account (run-omarchy.sh puts the files in the share folder as `mylinux-tools/`), and `install-session.sh --remove`
takes it out. The Session menu in the middle of the window's title bar (and in the
floating box in full screen) saves, restores and sets how often the layout is saved; it hands the command to the
tool through the share folder. The clipboard is shared both ways, text and PNG images, through
Omarchy's own clipboard agent and, on the Mac, the launcher's own binary in a helper mode
(`myLinux Launcher --omarchy-clipboard <socket>`, which the app hands to run-omarchy.sh as `MYLINUX_HELPER`; from the
command line without the app, `tools/omarchy-clipboard.py` when a working python3 is there). `CLIPBOARD=0` turns it
off. New Omarchy machines in the launcher send every key to Omarchy with Command as Super (`GRAB=full`); the
machine page switches to Option. Neither a machine's first start nor a download needs python3. Not there
(they need Try Omarchy's own helper app): camera and Touch ID; sound plays through the Mac's default output.

### Debian server machines

The third kind of machine is a plain Debian server with no window at all: the latest stable Debian (trixie) from
its official arm64 cloud image, for anything that only needs a terminal. `tools/get-debian.sh` downloads the image
(about 300 MB, checked against Debian's SHA512SUMS; the raw disk is kept sparse in `out/debian`) and the UEFI
firmware it boots with (the edk2 build QEMU itself ships, from the runtime's pinned QEMU commit, by checksum), and
`./run-debian.sh` boots it on the runtime or Homebrew's QEMU. Each machine has its own disk, copied from the image
on the first start and grown to `DISK_SIZE_GB` (cloud-init grows the root filesystem into it), and is set up by
cloud-init from a seed made on the Mac: the `debian` account with sudo, an SSH key generated for the machine
(`ssh_key` beside the disk), a random console password (`console-password`, for the serial console), the machine's
name as its host name, and the share folder mounted at `/mnt/mac` and linked from the home folder. SSH is forwarded
to `SSH_PORT` on 127.0.0.1 (default 2223; `FORWARD=host:guest` adds more ports), the serial console goes to `SERIAL`,
and `QMP` gives the socket a clean `system_powerdown` uses. In the launcher it is **Debian Server**: the machine
page has the settings, the Console tab the serial console, and Start opens an SSH terminal with the machine's key
as soon as its sshd answers (the Terminal button opens it again). That terminal window has a **myLinux** menu in the middle of its title bar; **Install Script…** opens
[`debian_install.sh`](debian_install.sh), loaded from this repository on GitHub (the copy built into the launcher
stands in when GitHub can't be reached), in an editable text field. Above it is a checkbox for each option the
script declares (a `NAME=1   # option: Label` line: Claude Code, Codex, btop and Tailscale, all on). Ticking a box
rewrites its line, so the text is always what runs. **Run in Terminal** copies the text into the machine
(`~/.local/share/mylinux/debian_install.sh`, over the machine's SSH connection) and runs it in the terminal, in
view. It installs git and tmux, the chosen tools, and the aliases `cc` (`claude update && claude
--dangerously-skip-permissions`) and `cx` (`codex --full-auto`) in a marked block of `~/.bashrc`. With Tailscale on,
it ends at Tailscale's sign-in link. The script can change on `main` without a new launcher. **Show
Browser** splits the window with a WebKit browser whose traffic goes through a SOCKS tunnel into the machine
(`ssh -D`), so it sees the network as the machine does; the machine's `localhost:3000` is reached through a port
forward opened on demand (`ssh -L`, since WebKit sends local addresses straight to the Mac), and the bar still says
localhost. ⌘-click a link in the terminal (the Claude login URL, say) and it opens there; **Open Last URL in
Browser** finds the last address in the scrollback. **Screenshot Browser to Machine** and **Paste Screenshot
Path** put a PNG of the page, or of the Mac clipboard, into the machine's share folder and type its path into the
terminal, so an agent inside can look at it. The Omarchy keys work here too: ⌘↩ splits the tab with one more
terminal (side by side; under the others once the browser is on the right), ⇧⌘↩ shows the browser with its address
bar ready, and ⌘T opens another tab to the machine. A terminal leaves the tab when its shell ends. So one tab can
hold Claude in one terminal, Codex in another below it, and the result in the browser beside them. Environment: `DISK`, `DISK_SIZE_GB=32`, `NAME`, `MEM=2G`, `CPUS`, `SHARE_DIR`, `SSH_PORT`, `FORWARD`,
`SERIAL`, `QMP`, `DRYRUN=1`.

`run.sh` wraps QEMU in `out/myLinux.app` so the Mac shows it as "myLinux". The window opens at the
size of the display under your mouse pointer; if the first start puts it on another display, give your
terminal app Accessibility permission (System Settings › Privacy & Security) and it is moved automatically.

The first boot shows a welcome dialog. "Set up the apps disk" formats the blank
`out/apps.img` (a sparse 16 GB file created by `run.sh`), downloads Debian's minimal rootfs
and installs the desktop apps plus Claude Code and Codex. It takes a few minutes and uses
about 1.3 GB. Everything you install or save afterwards persists on that disk.

Useful environment variables for `run.sh`: `RES=1600x1000` guest resolution (default is your
screen minus margins), `MEM=8G`, `APPS_IMG=path`, `SHARE_DIR=path`, `GRAB=opt|full|none`,
`MOUSE=tablet|relative` (relative: a click captures the Mac pointer for the guest, hidden and confined,
until Ctrl+Option+G; tablet, the default, lets it slide in and out of the window), `MYLINUX_QEMU=brew|runtime` (which QEMU, see above), `RENDER=soft` (software GL in the guest), `PLACER=0` (leave the
window where macOS puts it), `MYLINUX_OUT=dir` (kernel, rootfs, apps disk and the QEMU wrapper elsewhere
than `out/`).

## The Mac app

Instead of the command line, `mac/build-app.sh` builds **myLinux Launcher.app**: saved machines with a
Start button, the guest's serial console, and the settings above as a form.

```sh
mac/build-app.sh --install    # builds out/mac/ and copies it to /Applications (needs Xcode's Swift)
```

Each machine has its own apps disk and share folder, so "Work" and "Try things out" are separate myLinux
installs, plus its own keyboard and pointer handling, memory, screen size and clipboard setting. **Shut
Down** powers the guest off through the serial console (the guest has no power button); **Force Quit** is
the power cut. Machines keep running when the launcher quits, and a machine started from a terminal shows
up as "running outside the app". Keep **myLinux** itself in the Dock too (it is `out/myLinux.app`, or the one
in Application Support): clicking it starts the machine you used last through the launcher, or brings it
forward when it is already running.

**Remote machines, natively.** The launcher's sidebar has a *Remote* group: VNC desktops and SSH terminals
opened straight from the Mac, so only one keyboard owner sits between you and the remote (see
`docs/MAC-REMOTE-PLAN.md`). VNC uses libvncclient (Homebrew `libvncserver`) decoding into an IOSurface, with
Tight/ZRLE, VeNCrypt TLS and a trust-on-first-use certificate sheet like the myLinux viewer's; zoom (Fit, −/+,
1:1) follows the pointer; ⌘+trackpad and pinch zoom too. Each connection gets a keyboard mode — *Mac keeps its
shortcuts*, *Option is Super*, or *Everything to the remote* (⌘Tab and ⌘Space included, Ctrl+Option+G gives the
keyboard back; needs Accessibility permission once) — plus a list of shortcuts the Mac always keeps. SSH tabs run
the Mac's `ssh` in a SwiftTerm view: your keys and agent work as in Terminal, a saved password is handed to ssh
through an askpass helper that reads the Keychain, and a tmux session name attaches on login. Connections open as
native window tabs and can go fullscreen per display. Passwords live in the Keychain, profiles in
`~/Library/Application Support/myLinux/remote.json`, certificate pins next to it. The launcher's menu bar item is
the way back when a remote window holds every key: *Release Keyboard to the Mac*. Remote windows open at quit come
back at the next launch (close them yourself and they do not); ⌘K is a quick-connect field over any window;
`open mylinux://vnc/<name>` or `mylinux://ssh/<name>` opens a machine from Shortcuts or a script; *Import from
machines.json…* reads the guest viewer's saved machines (copy `~/.config/mylinux/vnc/machines.json` and, for the
passwords, `~/.config/mylinux/secrets.env` to the share first).

Without this checkout the app works on its own: it downloads the release image into
`~/Library/Application Support/myLinux` and keeps machines there, using its own copy of `run.sh`, and
libvncclient with its libraries travel inside the bundle (`Contents/Frameworks`), so Homebrew is not needed.
QEMU is the accelerated runtime (Settings › QEMU downloads it) or Homebrew's. Point Settings › Developer at a
checkout to start from that checkout's `run.sh`, `out/` and `share/` instead, which is what you want while
working on myLinux itself. A local build is signed ad hoc, so on another Mac Gatekeeper needs right-click › Open once.

**A release for other Macs** is a notarised DMG with the QEMU runtime inside, installed on the app's first start:

```sh
tools/build-libvncclient.sh      # libvncclient, libjpeg-turbo and OpenSSL from pinned sources, built for macOS 15 (once)
tools/build-qemu-runtime.sh      # out/qemu-runtime-macos-arm64.tar.gz at the version in tools/qemu-runtime.version
mac/release.sh --notarize <notarytool keychain profile>   # Developer ID from the keychain; out/mac/myLinux-Launcher-<version>.dmg
```

`mac/release.sh` builds the app with `MYLINUX_RELEASE=1` (the runtime tarball rides in `Contents/Resources/runtime`,
no checkout path in Info.plist), signs it inside out with the hardened runtime, and `mac/package-dmg.sh` has Apple
notarise the app and the disk image and staples both tickets. Homebrew's libvncclient is built for the macOS it was
installed on (26 here), which is why the release uses the libraries from `tools/build-libvncclient.sh` in `out/libvnc`;
`mac/build-app.sh` prefers them whenever they are there. The DMG goes into a release in `adminmylinux/mylinux-releases`.

## Keys

The Mac **Option** key is the Super key inside myLinux (Cmd stays with macOS).
Press **Option+K** for the full list.

| Keys | Action |
|---|---|
| Option+Space, Option+Esc | Menu (Apps, Learn, Trigger, Style, Setup, Install, Remove, Update, About, System); type to find anything, `=` calculator, `install`/`remove <pkg>` |
| Option+Shift+Esc | System menu |
| Option+Enter / Option+Shift+Enter / Option+Shift+F | Terminal / Browser / Files |
| Option+W or Q, Option+M, Option+F, Option+Alt+F | Close, minimise, full screen, full width |
| Option+T, Option+J, Option+Shift+T | Float/tile a window, toggle split direction, tiling on/off |
| Option+Arrows, Option+Shift+Arrows, Option+Ctrl+Arrows | Focus, swap, resize tiles |
| Option + drag, Option + right drag | Move, resize a window |
| Option+1 … Option+9 | Switch workspace (the menu bar shows the occupied ones) |
| Option+Shift+1 … 9, Option+Shift+Alt+1 … 9 | Move the window to that workspace and follow it, or move it silently |
| Option+Tab, Option+Shift+Tab, Option+Ctrl+Tab | Next, previous, former workspace |
| Option+S, Option+Alt+S | Show/hide the scratchpad, move the window to it |
| Option+Ctrl+Shift+Space, Option+Ctrl+Space | Theme picker, next background |
| Option+/ , Option+Alt+/ | Scale up, down |
| Print | Screenshot into your home folder |
| Option+K | Keybindings sheet (with search) |

The set follows Omarchy's, so the same fingers work on both. Alt+Tab (window cycling) reaches the guest
only with `GRAB=full`, because Alt is the Mac Cmd key and macOS keeps Cmd+Tab otherwise.

### Startup apps

The desktop starts with the launcher menu open and no windows. To open apps at start instead, list them
in `share/mylinux.ini`:

```ini
[session]
autostart=/usr/bin/claude-web,/usr/bin/chatgpt
```

Any command works there, for example `/usr/bin/claude-code` for the terminal agent or `/usr/bin/foot`.

### Clipboard

Text copied on the Mac can be pasted inside myLinux right away: run.sh mirrors the Mac clipboard
through the share folder and a small daemon in the guest applies it. The other direction is on
request, like Omarchy: press **Option+Ctrl+C** to send what you copied in myLinux to the Mac
clipboard. Text only; `CLIPBOARD=0 ./run.sh` turns it off.

### Dock

The dock hides below the screen edge and slides up when the pointer touches the bottom of the
screen. Style › "Dock: always visible" keeps it on screen instead.

### Window frames

Apps that draw their own header bar (Firefox, Chromium, Remmina and other GTK apps) get no second
title bar; the terminal and other plain windows get the macOS-style one. Window › "Title bars"
switches between auto, always and never.

### VNC viewer

`vnc` in the dock and the Apps menu (or `vnc host[:port]` in a terminal, `vnc host` typed into the
launcher) opens myLinux's own viewer: tabs for several machines, saved profiles with passwords in the
secrets store, Tight/ZRLE encodings with a fast/balanced/best quality choice, VeNCrypt TLS with username and
password as wayvnc on Omarchy uses it. F11 makes a connection fullscreen; the compositor then hands every
key and the pointer to the remote, Super shortcuts included, until Ctrl+Alt+G. ⌘⌃G grabs the keys in a
window too. The shell's clipboard reaches the remote through the RFB cut-text message. The tab bar zooms
the picture: Fit, −/+ steps, 1:1 for real remote pixels; zoomed in, the view follows the pointer.

**SSH terminals** live in the same window: pick "SSH terminal" in the Machines form and each connection
opens as its own tab, so several sessions run side by side. The OpenSSH client is in the base image; keys in
`~/.ssh` (on the apps disk) are tried first, a saved password answers the first prompt, and a key file can
be named per machine. The tab bar has A−/A+ for the text size and Paste (also Ctrl+Shift+V); Shift+PageUp
scrolls the history. `vnc <name>` in a terminal opens a saved SSH machine too.

Open tabs come back after a restart: the viewer remembers them (`~/.config/mylinux/vnc/session.json`) and the
shell reopens it with the same VNC and SSH connections when the machine or the shell starts again. Closing
the window or its last tab forgets them. For an SSH machine, name a **tmux session** in its profile and the
login attaches to it (`tmux new-session -A`): whatever ran there survives a closed tab or a restart. That
needs tmux on the remote machine.

### Bar modules

Your own items in the menu bar, in the shape of Omarchy's bar modules: a descriptor per module in
`~/.config/mylinux/bar/modules/` (on the apps disk), watched for changes so edits show at once.

```json
{ "id": "vpn", "type": "command", "exec": "~/bin/vpn-status", "interval": 5, "tooltip": "VPN", "on-click": "vpn-toggle" }
```

The command runs on the apps disk; its first line of output is the text, a second line the tooltip, or it
can print a JSON object `{"text", "tooltip", "color"}`. A `"type": "qml"` module loads `<id>.qml` from the
same folder: full QML with the shell's singletons (`Theme`, `AgentUsage`, `Weather`, `Tailscale`, `Launcher`).
Style › "Bar modules: install the examples" copies four examples there: load average, Tailscale, agents, and
a Proxmox status widget (running VMs and containers, node CPU and memory; needs a read-only API token saved
as `PROXMOX_API_TOKEN` in the Settings panel, see the comment at the top of `proxmox.qml`). QML modules can
call `Http.get(url, headers, {insecure: true}, callback)` for homelab APIs with self-signed certificates.
Modules are your code running inside the shell; nothing sandboxes them.

### Quitting

Use **Shut Down…** (or **Restart…**) from the  menu at the top left, or type `shut` into the
⌘K sheet. That unmounts the apps disk cleanly. Closing the myLinux window or pressing Cmd+Q on the
Mac side is a power cut for the virtual machine. The disk is journalled and the journal is committed
every second (`commit=1`), which limits the damage, but file data written shortly before the cut can
still be lost: ext4 flushes data on its own schedule, and the journal does not cover it. A clean shutdown
is the safe habit.


### Terminal

Option+Enter opens a terminal in your home directory (`/root`, on the apps disk). The base system is
BusyBox; everything installed on the apps disk is on the PATH as well, so `claude`, `codex`, `git`,
`python3`, `apt install …` just work (they run inside the Debian chroot, in the same directory). For a
full Debian shell type `apps-run bash`.

### Settings and API keys

The gear in the menu bar opens Settings: OpenRouter, Anthropic, OpenAI and Tailscale API keys and a
GitHub token. They are saved with owner-only permissions in `~/.config/mylinux/secrets.env` on the
apps disk and exported as environment variables to every new terminal and app, so tools such as
Claude Code, Codex or OpenRouter clients find them without further setup.

### Tailscale

Tailscale is built in. The menu bar's dot-grid icon opens its panel: Connect joins your tailnet as
`mylinux` (the login page opens in the browser), and once connected the panel lists every machine on
the tailnet with its online state and IP; click one for an SSH terminal. The login is kept on the apps disk. After that, MagicDNS names such as
`omarchy-imac` resolve inside myLinux, and other tailnet machines can reach the VM. The `tailscale`
command works in any terminal.

### Remote desktops

The dock's Remote Desktop icon (or "Remote" in the launcher) starts Remmina, installed from Debian on
first use. Add one profile per machine (VNC, RDP or SSH); connections open as tabs in a single window,
so one window switches between all your machines.

VNC servers with TLS (wayvnc on Omarchy, for example) need two things: the server's certificate as
"CA Certificate File" (put it in `share/` on the Mac and pick it from `/mnt/share`), and a server
address that matches the certificate's name. The VNC library rejects a certificate issued to
`omarchy-imac` when you connect to its IP address. Add a line like `192.168.0.61 omarchy-imac` to
`share/hosts` on the Mac, which is merged into the guest's hosts file at every start, and connect to
`omarchy-imac` instead.

## Themes (Omarchy compatible)

Themes use Omarchy's format: a directory with `colors.toml`, optional `light.mode` and a
`backgrounds/` folder. Twenty Omarchy palettes ship in the image with generated wallpapers.

- Theme picker: "Download Omarchy backgrounds for all themes" fetches the real Omarchy photos
  (about 70 MB) into your home on the apps disk.
- Install any Omarchy theme repo from GitHub: type `install owner/repo` in the theme picker, or
  run `theme-install https://github.com/owner/repo` in a terminal.
- Your own themes go in `~/.config/mylinux/themes/<name>/`.

## Build the image yourself

Inside the Debian machine (`orb -m debian`):

```bash
sudo apt install -y build-essential git cmake ninja-build python3 rsync bc wget cpio unzip file \
  libncurses-dev libssl-dev bzip2 xz-utils zstd perl-modules ccache gawk texinfo patch
mkdir -p ~/br && cd ~/br && git clone --branch 2026.08 --depth 1 https://gitlab.com/buildroot.org/buildroot.git
mkdir -p ~/br/output ~/br/dl
```

Then from the Mac, in this repo:

```bash
tools/buildroot-patch.sh        # small Buildroot fix for Qt 6.11 wayland features
orb run -m debian sh -c "cd ~/br/output && make O=\$PWD BR2_EXTERNAL=$PWD -C ~/br/buildroot mylinux_defconfig"
./build.sh                      # first build ~1 h on 13 cores (toolchain, Qt, Mesa, kernel), later builds minutes
```

Fast loop for the desktop shell without rebuilding the image:

```bash
tools/sdk-update.sh             # once: export the Buildroot SDK
tools/app-build.sh shell        # builds shell/ into share/myshell, the VM picks it up on next shell restart
```

`PLAN.md` documents every design decision and milestone in detail.

## Layout

```
configs/mylinux_defconfig   the whole OS definition
board/                      kernel fragment and rootfs overlay (init scripts, apps-disk tools, themes)
package/                    Buildroot packages: myshell, myapp, inter
shell/                      the Qt Wayland compositor (C++ + QML)
app/                        small Qt demo app (clock)
patches/                    Qt Wayland compositor patch (wl_seat v5, data device v3)
tools/                      build, SDK, apps-disk, automation helpers
mac/                        the Mac launcher app (SwiftUI; mac/build-app.sh bundles it)
run.sh / build.sh           run on the Mac / build inside Debian
run-omarchy.sh, run-debian.sh   the other two kinds of machine (Omarchy desktop, Debian server)
```

## Checks and tests

`tools/mac-remote-test.sh` drives the launcher's native VNC and SSH against the test VM (its ports forwarded to
the Mac with `FORWARD=`), typing through the viewer and logging in with a Keychain password.


```bash
tools/check.sh              # web typecheck + tests, shell syntax, Python syntax, QML lint, script tests
tools/vmtest/vmtest.py      # boots the throwaway test VM and runs the smoke scenarios (typing, focus, tiling)
```

The VM suite uses `out/apps-fresh.img` and `out/fresh-share` only and drives QEMU through its QMP
socket; it asserts on a diagnostics dump the shell writes when `[test] diag=true` is set in that
share's `mylinux.ini`. `./build.sh` and `tools/get-image.sh` promote a kernel + rootfs pair only after
a successful build or verified download and keep the previous pair as `out/*.prev`; `out/IMAGE-REVISION`
names the git revision or release the images came from. `DRYRUN=1 ./run.sh` prints the QEMU command
instead of starting it.

## License

GPL-3.0-or-later (see `LICENSE`). The desktop shell links the Qt Wayland Compositor module,
which Qt offers under the GPL v3 only. Theme palettes are from Omarchy (MIT, see
`board/overlay/usr/share/mylinux/themes/LICENSE.omarchy`); the Inter font is under the SIL OFL.
The launcher's welcome sheet shows two marks in `tools/icons/`: `debian.png` is the Debian Open Use Logo,
Copyright (c) 1999 Software in the Public Interest, Inc., under LGPL-3 or CC-BY-SA 3.0; `omarchy.png` is the
Omarchy mark from Omarchy's brand kit (as used by Try Omarchy), a pending trademark of the Omarchy project.
