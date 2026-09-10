# Analyze this project: myLinux

You are reviewing **myLinux**, a small Linux desktop distribution that runs as a virtual machine on
Apple-silicon Macs. Read the description below, then answer the questions at the end. Be concrete:
name the component, say what is wrong or risky, and propose the change. Do not restate the description.

## What it is

- A Buildroot 2026.08 Linux system for arm64 that boots entirely from RAM (kernel `Image` 14 MB plus
  `rootfs.cpio.gz` 111 MB), run by QEMU 11 with Apple's HVF hypervisor. Repo:
  https://github.com/adminmylinux/mylinux (GPL-3.0). Prebuilt images are on the GitHub release.
- Its own desktop: a Qt 6.11 Wayland compositor written in QML/C++ (about 2,800 lines, `shell/`),
  styled like macOS (menu bar, dock, traffic lights, glass panels) but with the keyboard workflow of
  Omarchy (Hyprland-based): dwindle tiling, nine workspaces, Super+key shortcuts, a searchable
  command menu, a keybindings sheet. Rendering is software only (Mesa llvmpipe over KMS); QEMU
  on macOS has no virtio-gpu-gl.
- A second, persistent disk (`out/apps.img`, ext4, 16 GB sparse) holds a Debian trixie arm64 chroot
  ("apps disk"): Chromium, Firefox, Remmina, btop, git, Claude Code, Codex, wl-clipboard, installed by
  the VM itself on first boot. The user's home (`/root`) is bind-mounted from it, so logins and
  settings survive reboots while the base system is immutable.
- Base-image extras: Tailscale (Buildroot package, kernel TUN), foot terminal, Omarchy-compatible
  themes (colors.toml plus backgrounds), a text clipboard bridge to the Mac.

## Architecture

**Host side (macOS, `run.sh`)**: picks the guest resolution from the display under the mouse, launches
QEMU through a thin app bundle (`out/myLinux.app`, a string-patched copy of Homebrew's QEMU so the
window and menu say "myLinux"), mounts the repo's `share/` folder into the guest over 9p, runs a
"host agent" loop that executes window commands the guest writes into `share/host-cmd` and mirrors
the Mac clipboard into `share/clipboard/`. A placer moves the window onto the chosen display through
macOS System Events (needs Accessibility permission).

**Guest boot**: BusyBox init. `S45apps` mounts the apps disk (`commit=1`) and bind-mounts `/root`;
`S47tailscale` starts tailscaled with state on the apps disk; `S99shell` mounts the share, merges
`share/hosts` into `/etc/hosts`, pins the KMS mode to the requested resolution and starts the
compositor (preferring `/mnt/share/myshell` for the hot-swap dev loop), then a clipboard daemon.

**Compositor (`shell/`)**: `Main.qml` (WaylandCompositor, XdgShell, server-side decorations preferred,
autostart), `Desktop.qml` (window bookkeeping, workspaces, scratchpad, shortcuts, screenshots),
`MacWindow.qml` (frame per xdg toplevel: title bar unless the client decorates itself, honours
xdg window geometry, resize handles, Super-drag), `Tiling.qml` (dwindle tree per workspace),
`MenuBar.qml`, `Dock.qml` (auto-hide), `Spotlight.qml` (command menu with categories Apps, Learn,
Trigger, Style, Setup, Install, Remove, Update, About, System, and free-text search), `KeyHelp.qml`
(cheat sheet and searchable list, highlights the rows matching held modifiers), `TailscalePanel.qml`,
`SettingsPanel.qml` (API keys exported as environment variables), `AgentPanel.qml`, `DisplayPanel.qml`,
`GlassPanel.qml`, `AppIcon.qml`. C++ singletons: `Launcher` (spawn apps, host commands), `Settings`
(ini on the share), `Secrets` (0600 file on the apps disk), `ThemeStore` (theme dirs, WebP conversion
through libwebp), `AgentUsage` (reads Claude Code / Codex logs), `Tailscale` (polls `tailscale
status --json`), `KeyGrab` (application-wide key filter: Super+digit by physical key code, held
modifier state).

**Apps chroot**: `apps-run` enters the Debian chroot with the Wayland socket, `/mnt/share` and the
user's cwd bound in, exports the saved API keys, and rewrites its helper files on every run.
`apps-install <title> "<packages>" <test-path> <command>` installs on first use in a terminal window,
then starts the app detached. `apps-path` symlinks every chroot command the base lacks into
`/usr/local/bin`, so `claude`, `git`, `apt` work in any terminal.

**Patches to Qt Wayland** (kept in `patches/qt6wayland/`): wl_seat v5 with pointer frames and
wl_data_device_manager v3 (modern clients require them); keyboard events delivered to every
`wl_keyboard` object of the focused client (Firefox binds the seat twice).

**Website** (`web/`): mylinux.app, a Bun/TypeScript site deployed with Docker and Caddy.

## Notable design decisions and their reasons

- RAM-resident base plus a mutable Debian disk: the base cannot rot, apt gives the software
  catalogue, and one 9p folder is the only coupling to the Mac.
- Software rendering: forced by QEMU on macOS. Consequences handled so far: menus and sheets are
  solid (blur behind app windows read badly and cost CPU), Chromium runs with
  `--force-prefers-reduced-motion` because a permanently animating page (claude.ai) made the
  compositor redraw the whole screen 60 times a second and burn four cores.
- Window title bars are drawn by the compositor only for apps that do not decorate themselves
  (detected through xdg-decoration or shadow margins in the window geometry).
- Keyboard: the Mac Option key is Super inside the guest (QEMU `swap-opt-cmd`), so Cmd stays with
  macOS; `GRAB=full` captures everything. Super+Shift+digit is matched by physical key code
  because Shift turns digit keys into layout-dependent symbols.
- Clipboard: Mac to guest is automatic (polling `pbpaste`, applied with wl-copy); guest to Mac is on
  request (Super+Ctrl+C) because wl-clipboard needs a focus-stealing helper surface on a
  compositor without the data-control protocol, and that surface is now hidden by the compositor.
- Keyboard focus is granted only after a surface has its first buffer; GTK ignores an earlier one.
- Chromium runs as root with `--no-sandbox` (the chroot has no unprivileged user yet).

## Known gaps

No fractional scaling (2x is upscaled), no dead-key compose, no notifications, no lock screen,
no clipboard manager or emoji picker, no images or files across the clipboard bridge, saved
Remmina passwords are unencrypted (no secret service), no unprivileged user in the chroot,
no automated tests (verification is scripted through QEMU's QMP: key injection and screenshots),
and QEMU's Cocoa window sizing needed the bundle to be marked non-Retina to get a 1:1 window.

## What to analyze

1. Architecture: is the split RAM base / Debian disk / Mac share sound? What would you change
   before the project grows, and what will bite first?
2. Security: root everywhere, `--no-sandbox` Chromium, API keys in a 0600 file exported to every
   process, a clipboard bridge through a shared folder, Tailscale state on the apps disk. Rank the
   risks and give the cheapest mitigation for each.
3. The compositor: what is fragile in a QML/C++ Wayland compositor of this size, which Wayland
   protocols are missing that common apps will ask for next, and how would you approach
   fractional scaling on llvmpipe?
4. Performance on software rendering: beyond reduced motion, which changes would cut the
   compositor's per-frame cost the most (partial repaints, frame-rate capping, texture upload)?
5. Developer workflow: the image rebuild takes minutes and the compositor hot-swaps over 9p in
   30 seconds; testing is QMP screenshots. Propose a testing strategy that catches regressions such
   as "typing does not reach Firefox" or "the dock helper window got tiled".
6. Product: for a user who wants an Omarchy-like Linux desktop on a Mac without dual-booting,
   what is missing for daily use, in priority order?

Answer each section with numbered findings. Prefer specific, verifiable statements over general
advice.
