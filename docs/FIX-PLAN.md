# Plan for docs/CLAUDE-CODE-FIX-PROMPT.md

Written 2026-09-10 against commit 7d04ab9. The review's decisive source claims were re-checked and hold:
dash has no `PIPESTATUS` (build.sh reports success after a failed make), `Launcher::launch` blocks the
compositor for up to 3 s, `toggleTiling` sweeps helper and scratchpad windows into the tree, `finishAdd`
inserts into the current workspace's tree rather than the window's, `MacWindow.onTitleHeightChanged`
relayouts the wrong tree, run.sh prefixes `$PWD/` to `SHARE_DIR` and interpolates `APPS_IMG` into Python,
`fromIni` writes into inherited objects, and `web/` has no tests.

## Ground rules for the work

- Branch `fix/review-2026-09`, one commit per batch, nothing pushed and no release until the user says
  so (the review forbids pushing and publishing as part of the task).
- Every batch: change, test, note in PLAN.md, and a line in the final report with the finding ID.
- All VM tests on `out/apps-fresh.img` and `out/fresh-share` (`tools/fresh-start.sh keep`), window title
  "myLinux (test)". Never the user's `out/apps.img`, `share/`, browser profiles or Tailscale state.
- Baked-image checks once per batch that touches the base overlay; hot-swap for compositor iterations.
- Unrun tests are reported as unrun.

## Order and scope

Ordered by risk to real users and by how much later work depends on it. Sections 1–2 (web) and 3–4
(host scripts) are independent of the compositor and go first because they are cheap and their tests
are pure.

### Batch A: test harness first (from section 11, brought forward)

Nothing below is safe to change without a way to catch regressions.

1. `tools/check.sh`: web typecheck + `bun test`, `sh -n` on every shell script in `board/overlay`,
   `run.sh`, `tools/`, Python `ast` parse, and `qmllint` when the SDK is present. One command, exit
   status meaningful.
2. `tools/vmtest/`: a Python driver over the existing QMP + serial sockets with deadlines and
   assertions (not screenshots as pass criteria). Primitives: boot-and-wait, key/combo/type, read a
   file from the guest through the share, screenshot-and-assert-pixel, plus a test-only diagnostics
   dump written by the compositor to `/mnt/share/diag.json` on demand (window inventory, workspace,
   focus, tree membership, helper flags). The diagnostic is triggered by a file in the share, no
   network endpoint.
3. Typing fixture: a local HTML page on the share that appends every keypress to `document.title`
   and to a file through a `<textarea>` the test reads back via screenshot text? No: the driver reads
   the title through the compositor's diagnostics (window titles are visible to the shell). Works for
   Firefox and Chromium without accounts.
4. Smoke suite skeleton with the review's scenarios as named tests, initially marked expected-fail
   where the behaviour is known broken.

Measure of done: `tools/check.sh` green on the current tree; the smoke suite runs end to end on the
test disk and reports pass/fail per scenario.

### Batch B: section 1 and 2, web parser and API (pure TypeScript, Bun tests)

- Replace the parser's plain objects with `Map`s or `Object.create(null)` and a `safeKey()` guard used at
  every level; define the config contract as a validator (`parseConfig()`), bounded numbers, layout
  enum `us|no|is` with `en -> us` migration, background index >= 0, theme id pattern, string and list
  bounds, unknown keys kept only under `extra` and never able to shadow managed keys.
- `toIni`: escape or reject newlines and `[` at line start; property-test the round trip with QSettings
  by running the actual Qt reader in the guest against exported fixtures (one vmtest).
- Routes: move the 50-machine and token limits into a single transaction in the persistence layer;
  POST create must 409 on an existing name, PUT INI upserts; bound body bytes before reading; uniform
  4xx JSON errors. Tests: both routes at the limit, concurrent creates with `Promise.all`, user A vs
  user B with session and token, oversized and malformed bodies. Disposable SQLite per test.
- Guest side: `Theme.qml` validates `display/scale` (0.5–3), `textScale`, `brightness` (0.2–1) and
  falls back to defaults; the same guard in `Settings::value` callers that feed geometry.

### Batch C: sections 3 and 4, build, download and launch scripts

- `build.sh`: run the pipeline with `set -o pipefail` under bash inside Debian, or capture make's exit
  through a status file; never filter into a false failure; copy `Image` and `rootfs.cpio.gz` to a
  staging dir and promote atomically as a pair; print the git revision baked in (write it to
  `/etc/mylinux-release` in the overlay at build time, read it in About).
- `tools/get-image.sh`: resolve one release tag first (`gh`/API or the redirect target), download to
  `out/.staging/`, verify, then rename the pair; keep the previous pair as `*.prev`.
- `tools/make-app-bundle.sh`: patch into a temp file and move; keep the last good binary if
  brand-qemu fails (fallback: plain copy with a warning).
- `run.sh`: `cd` to the script's directory, absolute-path aware `SHARE_DIR`/`APPS_IMG`, QEMU args in an
  array-free POSIX-safe form (build the command with `set --`), Python gets the path as `sys.argv`,
  validate `RES` and `APPS_SIZE_GB`, fail before starting the host agent when QEMU or the images are
  missing, kill helpers on EXIT/INT/TERM.
- Instance isolation: the host agent and `tools/host-window.sh` act on the window whose title is
  `$NAME` (the placer already does); the guest writes its instance name into `host-cmd` and the
  agent ignores mismatches.
- Tests: fake `make` failure, path with spaces and an apostrophe, missing QEMU, two instances.

### Batch D: section 5, window membership and focus (compositor)

- One predicate `manageable(w)`: not helper, not scratch, not in `floatingApps`; used by
  `toggleTiling`, `finishAdd`, `activateApp`, directional focus and the dock.
- Windows remember `workspace` at creation; `finishAdd` and `onTitleHeightChanged` use `tilingOf(w)`.
- Explicit seat focus: `switchWorkspace`, minimise of the last window, scratch hide and overlay close
  end with `setSeatFocus(topmostOrNull)`, which sets `compositor.defaultSeat.keyboardFocus = null`
  when there is no candidate. Directional focus considers only visible, mapped, manageable windows.
- Helper identification narrowed to: no app id, and (title `wl-clipboard` or buffer <= 2x2). A
  mapped nameless window larger than that becomes a normal floating window with title "Window".
- Keep the Firefox fixes (broadcast patch, focus after map) and prove them through the typing
  fixture in the smoke suite.

### Batch E: section 6, fullscreen, activation and resize coherence

- A single `configure(w, states)` helper in MacWindow that computes size from role (tiled rect,
  fullscreen area, floating) and states from focus (`ActivatedState` only for the focused window,
  `FullscreenState` when fullscreen, `MaximizedState` for zoom).
- Fullscreen: send the real state, save and restore floating geometry, remove from the tree while
  fullscreen and re-add on exit; handle the client's own fullscreen request
  (`toplevel.setFullscreen` signal) with the same path.
- Honour `minSize` in Tiling: a split that would violate it is refused (window floats instead).
- Scale change triggers `relayout()` of every workspace tree, not only the current one.

### Batch F: section 7, apps disk lifecycle

- QEMU: `-device virtio-blk-pci,drive=apps,serial=mylinux-apps`; guest resolves
  `/dev/disk/by-id/virtio-mylinux-apps` (eudev is present) with a fallback that requires the ext4 label
  `apps`; unreadable or unlabeled disks are an error with a dialog, never formatted.
- `apps-setup` becomes staged with markers in `/mnt/apps/.mylinux/stage-N-done` and a lock; FirstRun
  shows the stage, failure and a Retry button; autostart waits for the ready marker.
- `apps-run`: mounts and helper rewrites done once per boot by `S45apps` under a lock, `apps-run` only
  checks; `S45apps stop` unwinds nested mounts in reverse order and reports failures.
- Tailscale: state dir created after `/root` is bound (start order `S46`, after apps), and a migration
  step for state left in the RAM root.
- README and website: "flushes the journal every second; recently written file data can still be lost"
  and "reset on reboot" instead of "read-only".

### Batch G: section 8, secrets and clipboard

- Secrets: keys validated `^[A-Z][A-Z0-9_]{2,63}$`, written with `QSaveFile` and reported through a
  `saveFailed` signal shown in the panel; not sourced as shell. Export policy: a per-launcher allowlist
  (`claude-code`, `codex`, terminals get all; browsers and Remmina get none) implemented in `apps-run`
  by reading the file with a small parser instead of `. file`.
- Clipboard: byte-exact files with a monotonically increasing sequence file, no `$(...)`, empty text
  handled, a Style/Setup toggle "Clipboard sharing" persisted in settings, files removed on shutdown,
  bounded size (1 MB).

### Batch H: section 9, downloads and themes

- `tools/manifest.json` with URL + sha256 for the Debian rootfs tarball (that URL is a content-addressed
  blob and can be pinned) and for Codex releases (pin a tag); the Claude installer script has no
  published hash, documented as such and downloaded to a staged file whose exit status is checked.
- `theme-install`: parse `owner/repo`, `https://github.com/...`, and any other `git://`/`https://` clone
  URL separately; validate names; extract into staging; require `colors.toml` with the mandatory keys;
  replace atomically; WebP conversion moved to a `QThreadPool` task with a "converting" state.

### Batch I: section 10, background processes and agent usage

- `Launcher::launch` uses `QProcess::startDetached` (no wait); `Tailscale` uses a `QTimer` watchdog and
  `errorOccurred` cleanup; `AgentUsage` scanning moved to a worker with per-file mtime caching and
  coalesced refreshes; reset deadlines anchored to the source timestamp; seven-day window aligned;
  utilization unit chosen from the field name/schema version only, otherwise shown as "unknown";
  `Settings` reports whether it writes to the share or to `/tmp` and surfaces write errors in the
  Display panel.

### Batch J: section 11, acceptance run

Full smoke suite on the baked image, plus the manual scenarios that cannot be scripted (Tailscale
login, real browser accounts) listed as not run. Final report as the review specifies.

## What I will push back on or scope down

- **Section 12 roadmap items** stay proposals with effort/impact estimates; none are implemented in
  this task.
- **Privilege separation** (12.1) is real work: a normal user in the chroot breaks the current
  `/root` bind design. I will write the migration design and test it on the disposable disk only.
- **Pinned hash for the Claude installer**: not possible upstream; documented, not invented.
- **Fractional scaling**: out of scope here; integer 2x correctness is a separate item.

## Estimates

| Batch | Days | Verification |
|---|---|---|
| A harness | 1.5 | suite runs on test disk |
| B web | 1 | bun tests + one QSettings round-trip vmtest |
| C scripts | 1 | script tests + baked image once |
| D focus/membership | 1.5 | smoke: typing, empty workspace, helpers, scratchpad |
| E fullscreen/resize | 1 | smoke: fullscreen enter/exit, splits |
| F apps disk | 1.5 | blank/existing/foreign disk, interrupted setup |
| G secrets/clipboard | 1 | env sentinels, clipboard fidelity cases |
| H downloads/themes | 1 | offline and corrupt fixtures |
| I processes/usage | 1 | synthetic logs, hung subprocess |
| J acceptance | 0.5 | full suite on baked image |

About ten working days of agent time; batches A–D deliver the user-visible fixes and can be merged
before the rest. Each batch ends with a note in PLAN.md so the state is recoverable across sessions.
