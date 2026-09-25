# Plan: native Mac remote access in myLinux Launcher

Written 2026-09-14. The problem: a VNC session through myLinux stacks three keyboard owners — macOS,
the myLinux desktop, then the viewer's remote — and each takes a Super/⌘ combination before the next
sees it. The fix is to make the Mac launcher itself the client: a native VNC viewer and SSH terminal in
`myLinux Launcher.app`, with one clear rule per connection for which keys the remote gets. The viewer
inside myLinux stays as it is; it is for use from inside the desktop.

## What the user gets

- The launcher's sidebar grows two groups: **Machines** (myLinux VMs, as today) and **Remote** (VNC
  desktops and SSH terminals). A remote entry opens in a tab of a viewer window; tabs can be torn into
  their own windows and each tab can go fullscreen on its own display.
- **Keyboard policy per connection**, chosen from a menu and changed live with a HUD:
  - *Mac keeps its shortcuts* — ⌘ combinations stay with macOS, the remote gets the rest (default for SSH).
  - *Option is Super* — Option acts as the remote's Super/⌘ key, ⌘ stays with the Mac (how myLinux
    itself runs today; good for Omarchy's Super-driven layout).
  - *Everything to the remote* — ⌘Tab, ⌘Space, ⌘Q, function keys, all of it; a release combination
    (Ctrl+Option+G, configurable) hands the keyboard back. Needs Accessibility permission once.
  - Per-key exceptions on top of any mode (for example "keep ⌘C/⌘V for the Mac clipboard").
- Fast picture: at least what the myLinux viewer does now (Tight/ZRLE decoded in C, drawn without
  copies), and on servers that offer it, **H.264 decoded in hardware** (wayvnc `--gpu`; both Omarchy
  boxes have the build for it). Retina-aware: a remote HiDPI desktop maps 1:1 onto Mac pixels.
- SSH tabs with the same look as the myLinux ones: keys from `~/.ssh` and the Mac's ssh-agent, saved
  passwords in the **Keychain**, optional tmux session, scrollback, paste; open tabs restored when the
  launcher starts.
- No audio. VNC has none, and the design does not reserve room for it.

## Technology choices

| Part | Choice | Why |
|---|---|---|
| RFB protocol, auth, TLS | **libvncclient** (Homebrew `libvncserver`, OpenSSL) | Proven in the myLinux viewer; VeNCrypt X509 with our trust-on-first-use pins carries over unchanged; `rfbClientRegisterExtension` lets us add encodings. |
| Picture, standard encodings | libvncclient decodes straight into an **IOSurface**; a `CALayer` shows the surface | No copy between decoder and screen; damage rectangles only invalidate what changed. |
| Picture, H.264 | **Open H.264 RFB encoding** (what neatvnc sends with `--gpu`) → **VideoToolbox** → `AVSampleBufferDisplayLayer` | Hardware decode and zero-copy display; the fastest path a Mac has for a full desktop at 60 Hz. Falls back to Tight/ZRLE when the server does not offer it. |
| Keyboard grab | `NSEvent` for normal modes; **CGEventTap** at HID level for "everything to the remote" | The tap sees ⌘Tab and ⌘Space before macOS acts on them (what QEMU's full-grab and Parallels do). Accessibility permission is the price, asked only when that mode is first chosen. |
| Key translation | Carbon `UCKeyTranslate` + a keycode→keysym table | Layout-aware (Norwegian included): the remote gets the keysym the key means on the Mac layout, dead keys handled. |
| Terminal | **SwiftTerm** (MIT, Swift package) over a pty running the Mac's `ssh` | A complete, maintained VT emulator; `ssh` from macOS uses the user's keys, agent and known_hosts. |
| Secrets | Keychain | Native, per-user, no plain-text file. |
| Profiles | `profiles.json` gains a `remote` list; import from a myLinux share's `machines.json` on request | One file, one editor; the VM side keeps its own list. |

Rejected: RealVNC SDK (commercial, closed), Apple's Screen Sharing framework (private), writing the
RFB protocol in Swift (libvncclient already does the hard parts; only the H.264 rect handler is new).

## Phases

**0. Spike (half a day).** A throwaway window: libvncclient from Swift, framebuffer in an IOSurface,
CALayer display, mouse and a few keys, against the Omarchy iMac and the myLinux test VM's Xvnc. Measure:
frames per second while dragging a window, click-to-pixel latency, CPU. This decides whether phase 5 is
needed for comfort or is a bonus.

**1. VNC viewer in the launcher (2 days).** `RemoteView` window with tabs; `VncConnection` wrapping
libvncclient on its own thread (the myLinux viewer's structure, ported); Tight/ZRLE/CopyRect; VeNCrypt
X509 with pins in `~/Library/Application Support/myLinux/vnc-certs`; VncAuth and username/password;
mouse, wheel with trackpad momentum, pinch to zoom, the follow-the-pointer zoom from the myLinux viewer;
clipboard both ways; fullscreen per tab; Retina 1:1 mode. Profiles and Keychain. Tests: keysym mapping
(XCTest), a headless connection test against the myLinux test VM's Xvnc (the VM is already the CI
fixture; the Mac reaches it through a forwarded port).

**2. Keyboard policy (1 day).** The three modes, the exception list, the release combination and the
HUD ("Keys go to omarchy-imac — Ctrl+Option+G returns them"); the event tap installed only while a
grabbing window is key and dropped on release, app switch or window close (a stuck tap would lock the
Mac's keyboard — this needs a watchdog and a test). Option-as-Super remap done in the translation
layer, so it works in all modes.

**3. SSH terminal (1 day).** SwiftTerm view in a tab; `ssh` on a pty (`forkpty`), the password answer
at the first prompt, key file and tmux options as on the myLinux side; A−/A+, paste, Shift+PageUp;
per-machine colours later. Tests: an SSH tab into the myLinux test VM (its sshd from `vmtest`).

**4. Sessions and launch paths (half a day).** Open tabs restored at launch (same rule as myLinux: kept
on a crash or logout, forgotten when closed on purpose); ⌘K quick-connect palette; `mylinux://vnc/<name>`
and `mylinux://ssh/<name>` URLs so the Dock's myLinux icon and Shortcuts can open a machine; import
from a share's `machines.json`.

**5. H.264 (2 days, after measuring in phase 0).** Register the Open H.264 encoding with libvncclient;
parse the rect stream into NAL units; VideoToolbox session per resolution; `AVSampleBufferDisplayLayer`
with the same zoom/follow geometry; fall back per rect to the software path (neatvnc mixes encodings).
Needs wayvnc started with `--gpu` on the server; the plan includes the one-line Omarchy config change
and a check in the launcher that reports which encoding is in use.

**6. Polish and release (1 day).** Latency/fps HUD, connection log in the tab, error texts, the same
documentation style as the myLinux viewer, ad-hoc signing as today (Developer ID and notarization are
a separate decision).

About seven working days. Phases 1–3 give the goal (one keyboard owner, native speed); 4–6 are
comfort.

## Risks and how the plan handles them

- **Accessibility permission for the full grab.** macOS grants it per app and per build signature;
  an ad-hoc signed app loses it on every rebuild. Mitigation: a stable signing identity for the
  launcher (a self-signed certificate is enough to keep the permission), and the other two modes need
  no permission at all.
- **⌘Space and ⌘Tab.** An HID-level tap does intercept them, but macOS versions differ in what a tap
  may swallow. Phase 0 verifies on this Mac (macOS 26) before phase 2 is designed around it.
- **H.264 on the servers.** wayvnc needs a working VA-API device: the MSI's NVIDIA card needs
  `nvidia-vaapi-driver`, the iMac depends on its GPU. If a box cannot encode, it stays on Tight/ZRLE,
  which the spike will show is already good on a LAN.
- **Homebrew dependency.** libvncclient comes from Homebrew like QEMU does today. Vendoring it into
  the build (static, with OpenSSL) is possible later for a standalone download.
- **SwiftTerm coverage.** Full-screen programs (vim, htop, tmux) and 256/true colour are supported; mouse
  reporting to remote programs is available and can be turned on per tab.

## Not in this plan

The myLinux desktop and its own viewer stay unchanged. Replacing QEMU's window with a native display
of the VM, or audio, are separate topics.

## Spike result (2026-09-15)

`mac/spike/` (SwiftPM, `swift build -c release`, needs Homebrew `libvncserver`): libvncclient on a thread decoding
into an IOSurface, a CALayer showing it, mouse/keys, a HUD, and an HID-level event tap for the full grab. Run
against the Omarchy iMac (wayvnc 0.10, VeNCrypt X509 with our pinned certificate; connecting by IP and verifying
the certificate's own name works by opening the socket first and marking the client as `listenSpecified`).

- **Decoding is not the bottleneck.** Dragging a window sent bursts of up to ~1000 rectangles/s; decoding cost at
  most ~45 ms per second of wall time, the process stayed at 1–6 % CPU, memory flat. The IOSurface path costs
  nothing; when the surface's row size differs from width×4 (it did for 1360 px), copying only the damaged
  rectangles is just as cheap.
- **Update rate is server-bound: 8–11 updates/s** even while dragging. libvncclient requests the next update as
  soon as one arrives, so this is wayvnc's pace on the iMac (its `max_fps`, and how often Hyprland hands it
  frames). Phase 1 should try RFB continuous updates and check the server settings before touching encodings.
  H.264 (phase 5) would lower bandwidth, not raise this rate; it stays optional.
- **Latency:** keystroke to changed picture typically 26–54 ms, average ~42 ms, with occasional 140–280 ms
  outliers (server-side frame pacing, same cause as above).
- **Full grab works on macOS 26:** the HID-level tap installs once Accessibility is granted, keys typed while
  grabbed reach the remote, Ctrl+Option+G releases. (Whether ⌘Tab/⌘Space were swallowed is confirmed by the
  user's test, see the session notes.)
- **Retina 1:1** (F2) shows one remote pixel per Mac pixel; the layer's `contentsScale` handles it.

Decision: proceed with phases 1–3 as planned; keep phase 5 (H.264) as an option after the server-side frame
rate is understood.

## Status (2026-09-15): phases 1–3 implemented

In `mac/Sources/myLinux/Remote/`: `RemoteProfile` (profiles in remote.json, passwords in the Keychain through the
`security` tool so ssh's askpass helper can read them without a prompt), `VncConnection` (libvncclient thread,
IOSurface or staged copy, pins, cut text), `VncView` (layer, zoom/follow, wheel with momentum, pinch, keyboard modes),
`KeyboardGrab` (HID event tap with watchdog, keep-for-Mac list, Ctrl+Option+G), `CertPin` + `TLSPeek` (the VeNCrypt
handshake in Network.framework, the certificate read through SecureTransport's break-on-server-auth), `SshTerminal`
(SwiftTerm over `/usr/bin/ssh`, SSH_ASKPASS to the Keychain, tmux), `RemoteWindow` (native window tabs, toolbar,
HUD, trust and password sheets), `RemoteEditor` (SwiftUI form). `myLinux --remote <id>` and
`mylinux-launcher://remote/<id>` open a profile. Tests: 17 XCTests (key map, profile format, certificate parsing, a
gated probe against a real VeNCrypt server) and `tools/mac-remote-test.sh` end to end against the test VM.
Menu bar item (2026-09-15, `StatusMenu`): there from launch, because "Everything to the remote" swallows every key and
a user with the mouse alone had no way back. "Release Keyboard to the Mac" (the icon is a filled keyboard while a
grab is on), Quick Connect…, Machines…, the remote profiles, Close Remote Windows, Quit; keys pass through to the
menu while it is open. Open question from the spike: whether ⌘Tab/⌘Space are swallowed by the tap on this macOS —
the user's test decides.

## Status (2026-09-15): phase 4 implemented

`RemoteSession`: the open remote windows are remembered in `remote-session.json` next to remote.json, written on
every open and close, removed when the last one is closed on purpose, left alone by a quit or a crash; the next
launch (without `--remote`) opens them again. `RemoteLink`: `mylinux://vnc/<name>`, `mylinux://ssh/<name>`,
`mylinux://remote/<name or id>` (the bundle registers the `mylinux` scheme next to `mylinux-launcher`; the older
`mylinux-launcher://remote/<id>` still works); the name matches a profile's name, then its host, or its id.
`QuickConnect`: ⌘K (also in the menu bar item) — a floating field over every window, every word of the query must
match the name or the host, ↑↓ and Return open a remote machine or start a myLinux machine. `RemoteImport`: "Import
from machines.json…" under the sidebar reads the viewer's file (name, type, host, port, username, quality, keyFile,
tmux; entries without a type are VNC) and a `secrets.env` next to it or one folder up for the passwords
(`VNC_<NAME>_PASSWORD` / `SSH_<NAME>_PASSWORD`, the viewer's key rule), merging by name and kind so a re-import
updates the address but keeps the id, the keyboard mode and the window position; the guest keeps both files on its
apps disk, so they are copied to the share first. Tests: session file round trip, link parsing, find by
name/host/id, import parsing and secrets, merge, the ⌘K filter (26 XCTests in all).
Not yet: phase 5 (H.264, optional after the spike's numbers) and 6 (polish).
