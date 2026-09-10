# Report: review sections 6–10 (docs/CLAUDE-CODE-FIX-PROMPT.md)

Branch `fix/review-2026-09`, commits after `e3e1d2c` (sections 1–5). Nothing pushed, no release, no website
deploy. All VM work used the throwaway disk and share (`out/apps-fresh.img`, `out/fresh-share`, plus
`out/vmtest-*.img` for the disk tests); the user's `out/apps.img`, `share/`, credentials and Tailscale state
were not touched. No real API keys or transcripts were used as fixtures (synthetic logs in
`tools/vmtest/fixtures/agent`).

## Verification actually run

Final baked image: `out/IMAGE-REVISION` = `872299994c1b-dirty` (HEAD of the branch; "dirty" only because this
report was still untracked when the image was built). The hot-swap binary was removed from the test share, so
the suite below exercised the shell inside the image.

| Check | Result |
|---|---|
| `tools/check.sh`: web typecheck + 20 Bun tests, `sh -n`, Python ast, qmllint, 34 host-script tests, 90 guest-script tests (`tools/tests/guest.sh`: disk classification, serial lookup, secret parsing and export policy, verified downloads, theme installation, clipboard host and guest sides) | pass |
| `tools/vmtest/vmtest.py` on the baked image, 14 scenarios: boot, foot_typing, firefox_typing, empty_workspace_focus, helper_not_tiled, scratchpad, close_button, fullscreen, single_activation, scale_relayout, client_fullscreen, agent_usage_fixtures, clipboard_fidelity, shell_restart | 14/14 pass (`out/vmtest-final4.log`) |
| `tools/vmtest/disktest.py` on the baked image: blank (wipe, first-run setup interrupted with TERM during the desktop stage, retried to completion incl. both agents, Tailscale state migrated), states (foreign + second blank disk attached), lock (second instance refused), shutdown (chroot process running, all mounts unwound, restart works), reboot (home file persists, disk mounted and ready) | 5/5 pass (`out/disktest-final4.log`) |
| The same two suites on the three earlier bakes of this branch | each run found a real defect that was fixed before the next bake: rootfs re-extracted over a legacy disk (F7.2), interrupted dpkg never reconfigured (F7.2), killed installer not recording its stage (F7.2), inherited flock held by an orphaned apt-get (F7.2); details in the commit messages |
| Secrets: Qt-side validation and `QSaveFile` failure path (`Secrets::set`) | compiled and exercised only through the panel by hand in an earlier session; no automated test of a failing commit (would need an unwritable home in the VM) |
| Tailscale watchdog and error path | compiled; not exercised (no way to make `tailscale status` hang on demand without a fixture daemon) |
| WebP conversion in the thread pool | compiled; not exercised in the suite (no WebP fixture theme in the test disk) |
| Route tests against a real Postgres (carried over from sections 1–5) | not run: no `TEST_DATABASE_URL` |
| Real Tailscale login, real browser accounts, actual Claude/Codex sign-in flows | not run (accounts) |

## Section 6: fullscreen, activation, resize (`shell/MacWindow.qml`, `Tiling.qml`, `Desktop.qml`)

- F6.1 one configure path: `configure(w, h, extra)` builds every `sendConfigure` from the window's role
  (`xdgStates()`): `ActivatedState` only while `output.focusedWindow === win`; a window that loses focus is
  re-sent its current size without it (`onActivatedChanged`). Test `single_activation`: two tiled terminals,
  exactly one has the client-acknowledged `activated` state, and it follows ⌘←/⌘→.
- F6.2 real fullscreen: ⌘F / ⌘⌃F and the client's own `setFullscreen` request send `FullscreenState`, drop
  the title bar, take the window out of its tiling tree, cover the work area (follows layer resizes and scale
  changes), and on exit put it back into the tree or restore the saved floating geometry. Tests `fullscreen`
  (shell shortcut; a second window opened meanwhile tiles normally; focus returns; restore into the tree)
  and `client_fullscreen` (Firefox F11 in both directions).
- F6.3 maximize is distinct: green button, title double-click, ⌘⌥F and the client's `setMaximized` send
  `MaximizedState` with the work-area size and a saved geometry to return to; a tiled window's maximize
  request is answered with its tile (no state), so the client learns it was refused. Manual resize, ⌘-drag
  and tiling clear the zoomed state.
- F6.4 client limits: `minSize`/`maxSize` clamp manual resizes; Tiling refuses a split that would leave either
  window below its minimum (the new window floats instead) and never emits a negative or overlapping rect
  (`layoutNode` bends the split point to the subtree minimums, `toggleSplit` refuses a flip that does not
  fit). Test `scale_relayout` asserts non-negative, in-area, non-overlapping tiles; a small work area still
  gives small tiles rather than overlap.
- F6.5 scale and title-bar changes relayout every workspace tree (`relayoutAll`), not only the visible one;
  test `scale_relayout` changes scale while workspace 3's tree is hidden and checks it afterwards.
- Not done: a client whose minimum size exceeds the whole work area still gets a too-small tile; popups and
  input methods were not audited beyond "unchanged" (Qt's `autoCreatePopupItems` path is untouched).

## Section 7: apps disk (`S45apps`, `S47tailscale`, `apps-mounts`, `apps-setup`, `apps-run`, `FirstRun.qml`, `Main.qml`)

- F7.1 identification: `/usr/lib/mylinux/disk.sh` finds the disk by the virtio serial `mylinux-apps`
  (`/sys/block/vdX/serial`, which `run.sh` already sets), independent of `vda`/`vdb` order; without any serial
  the only fallback is a single disk without a serial that already carries the ext4 label `apps`. Blank means
  "the whole first MiB reads back as zeros"; a short or failed read is `unreadable`; ext4 with another label
  or arbitrary bytes is `foreign`; two candidates are `ambiguous`. None of those is ever formatted, by
  `S45apps` or by `apps-setup`. Tests: `tools/tests/guest.sh` (classification and lookup), `disktest states`
  (foreign and second blank disk attached: only ours mounted, the others byte-identical afterwards).
- F7.2 staged setup: `apps-setup` takes a `flock`, records `stage-<name>-done` markers on the disk, writes
  `/run/apps-setup.status` (`state=running|failed|partial|done`, `stage=`, `message=`), writes the ready
  marker `/mnt/apps/.mylinux/ready` only after rootfs, desktop and devtools succeeded, and treats the agents
  as an optional stage reported as `partial`. A second instance exits 3. `Main.qml` autostarts apps only when
  the ready marker exists; `S45apps` grants the marker to disks set up before it existed (they are complete
  by construction at boot time). `FirstRun.qml` shows the disk state, the failed stage with its message, a
  Retry/Continue button, and an error text for disks that are not ours. Tests: `disktest lock`, `disktest
  blank` (interrupted during the desktop stage, then continued without downloading the rootfs again).
- F7.3 mounts once per boot: `apps-mounts prepare` (bind mounts, devpts, shm, runtime dir, share, resolv.conf,
  helper files written atomically) runs under a lock from `S45apps` or `apps-setup`; `apps-run` only runs
  `apps-mounts check` and refuses with a message otherwise. `hosts-sync` runs at shell start, not per launch.
- F7.4 shutdown: `S45apps stop` ends every process whose root is the chroot (TERM, then KILL), unwinds the
  nested mounts innermost first, reports what stayed mounted, then `sync`. Test `disktest shutdown` (a
  chroot process running during stop; zero mounts left; restart works).
- F7.5 Tailscale: `S47tailscale` keeps its state in `/run/tailscale-state` while `/root` is still RAM, and
  `apps-setup` calls `S47tailscale migrate` once `/root` is the disk (state copied, daemon restarted on the
  persistent path). Test `disktest blank` checks the state path before and after setup. Not tested: an actual
  login (needs a real account).
- F7.6 wording: README says the journal commit interval limits, not prevents, data loss; the website says the
  base image is reset at boot instead of "read-only".

## Section 8: secrets and clipboard (`shell/secrets.*`, `SettingsPanel.qml`, `apps-run`, `secrets.sh`, clipboard scripts, `run.sh`)

- F8.1 selective export: `apps-run` exports the saved keys only to an allowlist (claude, codex, shells, node,
  npm, bun, deno, python, pip, git, gh, aider, opencode, env, apt) and to nothing else; browsers and Remmina
  start without them. `APPS_SECRETS=all|none` overrides one launch. The Settings panel says so. This
  reduces accidental exposure only: everything still runs as root and can read the file (roadmap item 1).
- F8.2 data, not code: the file is `KEY=value` lines parsed by `secrets_filter` (names
  `^[A-Z][A-Z0-9_]{2,63}$`, one-line values, legacy `KEY='v'` unwrapped) and exported with `export "KEY=value"`
  through an unlinked 0600 file on fd 3 (apps-run) or a here-document (interactive shells); `$(…)`, backticks
  and quotes in values stay literal. Tests in `tools/tests/guest.sh` (a value containing `$(dangerous)` is
  exported byte-identical and nothing runs).
- F8.3 saves: `Secrets::set` validates, writes with `QSaveFile` at 0600, and on any failure restores the
  previous values and exposes `lastError`/`saveFailed`, shown in red in the panel; `changed` fires only after
  a successful commit.
- F8.4 clipboard: content moves only as files; each side bumps a sequence counter after writing
  (`mac.seq`, `guest.seq`); the host compares with `cmp` and remembers what it last pbcopied so the guest's
  text does not echo back; the guest bridge keeps the applied sequence in `/run` across restarts; empty
  text is not mirrored in either direction; 1 MB bound; `run.sh` removes the files at exit; "Clipboard
  sharing: on/off" in the Setup menu (persisted, `/run/clipboard.off`). Tests: `tools/tests/guest.sh`
  (Unicode, trailing newlines, two updates in a row, identical values, empty text, size bound, restart,
  shell-metacharacter content), VM `clipboard_fidelity` (bytes through wl-copy/wl-paste, focus unchanged).

## Section 9: downloads and themes (`manifest.env`, `fetch.sh`, `apps-setup-ai`, `theme-install`, `themestore.cpp`)

- F9.1 manifest: `/usr/share/mylinux/manifest.env` pins the Debian rootfs to a commit-addressed URL with its
  sha256 and Codex to a release tag with its sha256; `fetch_verified` downloads to a `.part` file, checks the
  sum, and only then moves it into place. `tools/manifest-update.sh` refreshes the pins explicitly;
  `apps-setup-ai --latest` is the deliberate way to install an unpinned Codex. The Claude installer has no
  published checksum or signature; the manifest says so, the script is staged and its exit status checked,
  and the output states that only TLS verified it. Tests in `guest.sh` (match, mismatch, failed download,
  no-sum case).
- F9.2 `theme-install`: `owner/repo`, GitHub URLs (including `/tree/…` and `git@github.com:`) and other git
  URLs are classified separately; names are lower-cased, stripped of `omarchy-`/`-theme`, and must be
  `[a-z0-9-]` (no empty, dot, traversal); archives are listed first and refused if they contain links,
  absolute paths or `..`; extraction goes to a staging directory under the themes folder; `colors.toml`
  must carry valid `background`, `foreground` and an accent; promotion is `mv` with the previous version
  restored on failure. Tests in `guest.sh` with local tarball fixtures (good, no palette, bad palette,
  symlink, traversal, failed download, replacement).
- F9.3 WebP conversion runs in `QThreadPool` with `ThemeStore.converting` shown in the picker; the picker
  no longer blocks on it.

## Section 10: processes and agent usage (`launcher.cpp`, `tailscale.cpp`, `agentusage.cpp`, `settings.cpp`, `AgentPanel.qml`)

- F10.1 `Launcher::launch` uses `startDetached`: no wait on the compositor thread, no `QProcess` retained per
  launch, start failures reported through `failed()` immediately; client output goes to `/var/log/apps.log`.
- F10.2 Tailscale: one status query at a time with an 8 s watchdog; `errorOccurred` and timeouts drop the
  process and record `lastError`, so a hung query no longer blocks every later refresh.
- F10.3 usage scanning runs in a worker thread with a per-file (mtime, size) cache; unchanged files are not
  re-read; refreshes during a scan are coalesced into one more scan; the network probe keeps its 10 s
  timeout and 15 s recent-probe cache.
- F10.4 reset deadlines: Codex `resets_in_seconds` is added to the log entry's own timestamp and shown with
  "as of"; a rescan of unchanged logs yields the same deadline (test `agent_usage_fixtures`). Claude's
  `resets_at` was already absolute.
- F10.5 window alignment: the chart and every aggregator use today and the six days before it (test:
  2026-09-04 counted, 2026-09-03 excluded, seven rows).
- F10.6 units from the schema: `utilization`, `percent` and `used_percent` are percent fields; any other
  field yields "unknown" (`pct = -1`, shown as such). Test: all buckets below 1 read as 0.5 %, not 50 %,
  and an unknown field gives -1. Token semantics: input, output, cache-creation and cache-read are summed as
  four separate buckets (verified against the fixture: 100+50+20+30 = 200 once, the streamed duplicate
  ignored).
- F10.7 the stats-cache fallback with only all-time totals is labelled "All-time totals" in the panel.
- F10.8 Settings reports where it writes (share vs `/tmp`, decided from `/proc/mounts`, not from
  directory writability) and QSettings write errors; both appear at the bottom of the Display panel.

## Files changed

52 files, +2012/−397 lines since `e3e1d2c`.

- Compositor: `shell/{MacWindow,Tiling,Desktop,Main,FirstRun,SettingsPanel,DisplayPanel,AgentPanel,Spotlight,Theme,MenuBar}.qml`,
  `shell/{launcher,tailscale,agentusage,settings,secrets,themestore}.{h,cpp}`, `shell/main.cpp`.
- Guest scripts: `board/overlay/etc/init.d/{S45apps,S47tailscale}`, `board/overlay/etc/profile.d/secrets.sh`,
  `board/overlay/usr/bin/{apps-mounts,apps-run,apps-setup,apps-setup-ai,clipboard-bridge,clipboard-send,theme-install}`,
  `board/overlay/usr/lib/mylinux/{disk,fetch,secrets}.sh`, `board/overlay/usr/share/mylinux/manifest.env`.
- Host: `run.sh`, `tools/clipboard-host.sh`, `tools/manifest-update.sh`, `tools/check.sh`.
- Tests: `tools/tests/guest.sh`, `tools/vmtest/{vmtest,disktest}.py`, `tools/vmtest/fixtures/{typing.html,agent/…}`.
- Docs: `README.md`, `web/src/index.html`, `PLAN.md`, this report.

## Compatibility and migration notes

- Disks set up before this change have no stage markers; `S45apps` writes `ready` for them at boot when
  Debian and Chromium are present. Running `apps-setup` on such a disk re-runs the apt installs (fast when
  already installed) and reinstalls the agents from the manifest, then writes the markers.
- `secrets.env` written by older builds (`KEY='v'`) is read; the next save rewrites it as `KEY=value`.
  Keys with names outside the validated pattern are dropped on the next save.
- Browsers no longer see API keys. Anything that relied on that (a web app reading `OPENAI_API_KEY` from its
  environment) needs `APPS_SECRETS=all apps-run …` explicitly.
- The clipboard files gained `*.seq`/`*.last` siblings; `run.sh` cleans all of them at exit. Third-party
  writers of `mac.txt` must bump `mac.seq` (see `tools/clipboard-host.sh`).
- The pinned Debian rootfs is a fixed snapshot; `tools/manifest-update.sh` moves it deliberately.
- `Launcher.launch` no longer returns false for a program that starts and exits at once; only failures to
  start return false.
- Client windows now receive `ActivatedState` changes on focus moves and real fullscreen/maximized states;
  apps that draw their own decorations (GTK, Chromium) now render inactive/active headers accordingly.

## Remaining uncertainties and gaps

- `Launcher::launch` now goes through `QProcess::startDetached`; the smoke suite launches terminals, Firefox
  and the clipboard helper through it, but the compositor's own log no longer carries client output
  (`/var/log/apps.log` does).
- The Tailscale watchdog, the `Secrets` save-failure path and the threaded WebP conversion are compiled and
  reviewed, not covered by an automated scenario (see the table).
- `disk_state` reads the first MiB; a disk whose superblock area is intact but whose data beyond it is corrupt
  is reported as `apps` and then fails at mount time (`mount-failed`, with the fsck hint), not earlier.
- The apps-setup interruption test sends TERM to the installer and to apt/dpkg; a power cut mid-stage is
  covered only indirectly (the reboot scenario, and the dpkg reconfiguration on the next run). The rootfs
  extraction itself is not resumable: an interrupted unpack is redone from the download.
- The agents stage installs Claude Code through Anthropic's installer, which has no checksum upstream; the
  suite verified that the pinned Codex tarball and the Debian rootfs match their manifest sums.
- The clipboard scenario checks Mac to guest bytes and focus; guest to Mac (`clipboard-send` through
  `tools/clipboard-host.sh`) is covered by the script tests with fake `pbpaste`/`pbcopy`, not end to end.
- `single_activation` and `fullscreen` use foot; GTK's reaction to activation changes (header bar dimming) was
  observed by hand with Firefox but is not asserted.
- Two VM instances at once (section 4) still untested live.

## Roadmap proposals (section 12; none implemented here)

| # | Item | Impact | Effort | Depends on | Measurable outcome |
|---|---|---|---|---|---|
| 1 | Application privilege separation: a `user` account in the chroot for browsers and agents, root only for apt and mounts, Chromium with its sandbox, host-control files and Tailscale state root-owned | High (real containment of the secrets and host-command surface; the fixes in section 8 only reduce accidents) | 4–6 days: ownership migration of `/root` on a disposable disk, Wayland socket permissions, CLI login flows (Claude/Codex write under `$HOME`), `apps-path` dispatch as the user | Section 7 staging (a migration stage with a marker), a decision on the home path (`/home/user` vs keeping `/root` for compatibility) | A browser started from the dock cannot read `secrets.env` or write `/mnt/share/host-cmd`; Chromium runs without `--no-sandbox`; all existing smoke scenarios pass on a migrated copy of a set-up disk |
| 2 | Backup, restore and versioned upgrades: `tools/apps-backup.sh` (sparse-aware copy or `tar` of `/mnt/apps` from the guest), base-image rollback (`out/*.prev` already exists), a `setup-version` on the disk with explicit migrations, restored-profile test | High for users with logins and installed software | 2–3 days | Stage markers (done), `IMAGE-REVISION` (done) | Restore of a backup boots to the same ready state, Chromium profile and agent logins intact, in the smoke suite; Tailscale identity is excluded from the backup by default and documented |
| 3 | Data-driven app and shortcut catalogues: one `apps.json` feeding Dock, MenuBar, Spotlight and the key sheet; later `.desktop` discovery from the apps disk | Medium (removes four duplicated tables; new installs become launchable) | 2 days, plus 1 day for `.desktop` | Smoke suite for the launcher paths (exists) | Adding an app touches one file; an installed `.desktop` appears in Spotlight with a stable app id |
| 4 | Measured software-rendering work: a benchmark script (QMP-driven) recording guest compositor CPU, client CPU, host QEMU CPU, frame timing and input latency for idle, typing, an animated local page, resize, solid vs glass, 1x vs 2x | Medium-high (today's tuning is by feel) | 2 days for the harness, then per finding | vmtest harness | Numbers per scenario in the repo; a regression budget (for instance idle compositor CPU under 5 %) enforced by the suite |
| 5 | HiDPI and protocol coverage: integer output scale 2 with physical-buffer vs logical-coordinate tests, then check Qt's actual fractional-scale/viewporter support; a data-control based clipboard that removes the wl-copy helper surface | Medium (crisp 2x on the MacBook display; no focus-stealing helper) | 3–4 days | Section 6 state model (done) | 2x renders without upscaling blur (screenshot pixel check), typing scenarios pass at 2x, no helper window ever appears in diagnostics |
| 6 | Daily-use essentials, ranked: audio out (QEMU `-audiodev coreaudio` + virtio-sound, PipeWire in the chroot), Compose/dead keys, notifications (a small layer-shell-like panel), session lock, secret service, screen-share portal | High for audio and dead keys, polish for the rest | Audio 2 days, dead keys 0.5 day, notifications 1 day, others later | Audio needs a QEMU device decision first | Sound plays from Firefox; `´` + `e` types `é` on the NO layout in the typing scenario; a notification from `notify-send` appears |
| 7 | Web operations: scoped/expiring machine tokens, bounded caches, explicit CORS/origin policy, migrations with backups, sync conflict handling | Medium | 2 days | Section 2 store (done) | Token expiry enforced in route tests; migration script tested locally before deploy |
| 8 | Release and platform maintenance: pin Buildroot/Qt/QEMU versions in one place, smoke-test the qt6wayland patches on upgrade, branding fallback (done), build provenance and license/source artifacts, split `PLAN.md` into "current limitations" and "history" | Medium | 1–2 days | `IMAGE-REVISION` (done) | A release records image revision, manifest pins and Buildroot/Qt versions; `PLAN.md` has a short "Known limitations" section |
