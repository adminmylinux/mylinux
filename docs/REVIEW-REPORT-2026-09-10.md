# Report: review sections 1–5 (docs/CLAUDE-CODE-FIX-PROMPT.md)

Branch `fix/review-2026-09`, based on `7d04ab9`. Nothing pushed, no release, no website deploy.
All VM work used `out/apps-fresh.img` and `out/fresh-share` (window title "myLinux (test)").

## Verification actually run

| Check | Result |
|---|---|
| `tools/check.sh` (web typecheck + 20 Bun tests, `sh -n` on every script, Python ast, qmllint, 34 script behaviour tests) | pass |
| `tools/vmtest/vmtest.py` on the hot-swapped shell | 7/7 pass |
| `tools/vmtest/vmtest.py` on the baked image (`out/IMAGE-REVISION` = 7d04ab97dfef-dirty) | 7/7 pass (Firefox scenario re-run after switching it to a throwaway profile; the first run hit Firefox's "Troubleshoot Mode?" prompt caused by earlier kills) |
| Route tests against a real Postgres | not run: no `TEST_DATABASE_URL` available; the in-memory store mirrors the transactional semantics, and the SQL store is 60 lines that the same tests would exercise |
| Two simultaneous VM instances with host commands | not run as a live test; the isolation is by window title and per-share files, which the placer already used and the DRYRUN tests cover |

## Section 1: web configuration parser and serializer (`web/src/server/ini.ts`)

- F1.1 prototype pollution: parsing and normalization use prototype-less dictionaries and own-property
  checks; `__proto__`, `constructor`, `prototype` are rejected as section and key names at every level.
  Test: hostile sections/keys leave `Object.prototype` untouched (checked with random probe names).
- F1.2 unbounded numbers: `scale`/`textScale` 0.5–3, `brightness` 0.2–1, `terminalFontPt` 6–40 integer,
  `background` 0–999 integer; NaN, Infinity, negative, zero rejected.
- F1.3 newline injection: values must be single printable lines; `toIni` additionally escapes, so a
  value that bypassed validation still cannot open a section. Test: injected `[input]` never becomes
  a second section.
- F1.4 `extra` shadowing managed keys: rejected on input and skipped on export.
- F1.5 `en` vs `us`: contract uses `us`; `en`, `en-us`, `english` migrate; the client selector and
  the guest (`Theme.qml`) map `en` to `us` too.
- Guest revalidation: `Theme.qml` clamps persisted numbers and layouts (`bounded()`), so a hand-edited
  ini cannot produce a zero scale.
- Round trip: quotes, commas (escaped in lists), Unicode, unknown safe keys, empty autostart, `look`/`wm`
  sections. Unsupported constructs are listed in the file header.
- Not done: the QSettings round trip was verified against what the guest writes today (fixture in the
  test), not by running Qt's reader on exported files in the VM.

## Section 2: web API (`store.ts`, `routes.ts`)

- F2.1 limits: machine and token creation run inside one transaction with a row lock on the user;
  both creation routes (POST and INI PUT) go through the store. Test: 49 machines then three
  concurrent creates yield exactly one success.
- F2.2 POST vs PUT: POST is create-only (409 on an existing name); INI PUT upserts, and an upsert of an
  existing machine is still allowed at the cap.
- F2.3 bounded bodies: Content-Length and streamed size checked before materializing; 413 for JSON over
  256 KB and INI over 64 KB.
- F2.4 uniform errors: 400 malformed JSON/name, 404 not found or not owned, 409 conflict/limit, 413 too
  large, 422 invalid configuration with a `problems` list. Ownership checks preserved and tested for
  sessions and tokens.

## Section 3: builds and downloads

- F3.1 `build.sh`: bash `pipefail` inside Debian, no grep in the status path (`|| true` on the filter),
  staged copy and pair promotion, previous pair kept as `*.prev`, `out/IMAGE-REVISION` and
  `/etc/mylinux-release` in the image record the git revision (suffix `-dirty` when uncommitted).
- F3.2 `tools/get-image.sh`: resolves one release tag first, downloads into a staging directory,
  verifies there, promotes the pair, keeps `*.prev`, cleans staging on any exit.
- F3.3 `tools/make-app-bundle.sh`: patches into a temporary file and moves; falls back to an unbranded
  signed copy with a warning if branding fails.
- `tools/app-build.sh` already aborted on a failed Ninja run; kept.
- Tests (`tools/tests/scripts.sh`): failing make, successful build whose output matches the error
  filter, checksum mismatch, failed download, staging cleanup, branding failure.

## Section 4: launch path and instance isolation (`run.sh`, `tools/host-window.sh`)

- F4.1 works from any directory; relative `SHARE_DIR`/`APPS_IMG` resolve against the caller, absolute
  paths pass through; paths with spaces and apostrophes tested.
- F4.2 QEMU arguments are an argument list (`set --`), no word splitting; the apps disk path goes to
  Python as `sys.argv`.
- F4.3 validation of `RES`, `APPS_SIZE_GB`, `GRAB`; missing images or QEMU fail before the host agent
  starts; `DRYRUN=1` prints the command.
- F4.4 instance scoping: host commands and the placer act on the window titled `$NAME`; `share/instance`
  names the instance; helpers are killed and transient files removed on EXIT/INT/TERM.
- The host-command allowlist is unchanged (`fit|center|fullscreen|native`), still never executed as shell.

## Section 5: window membership, focus, workspaces (`Desktop.qml`, `MacWindow.qml`)

- F5.1 `tileable(w)` (not helper, not scratch, not floating-by-policy) used by `finishAdd`, `toggleTiling`,
  `setFloating`. Test: tiling toggled twice with a wl-clipboard helper and a scratchpad window present;
  neither enters a tree.
- F5.2 per-workspace trees: `finishAdd` inserts into the window's own tree; `onTitleHeightChanged`
  relayouts the window's tree.
- F5.3 seat focus on empty workspaces: `focusTopmost()` clears the seat when nothing is focusable. This
  needed a C++ helper (`Launcher.setSeatFocus`): assigning `null` to the seat's `keyboardFocus`
  property from QML is a no-op, which Spotlight, the key sheet and Settings had relied on; they use the
  helper now. Test: switch to workspace 9, seat focus is null; back to 1, a window is focused.
- F5.4 helper identification narrowed to no app id AND (1×1 buffer or title `wl-clipboard`); a nameless
  window of normal size is a plain floating window.
- F5.5 directional focus only among mapped, visible tiled windows.
- F5.6 `scratchVisible` resets when the last scratchpad window closes.
- Firefox keyboard: first focus enter only after the first buffer (kept from the earlier fix); the
  broadcast patch (0002) kept. Tests: typing into foot (marker file) and into Firefox (fixture page
  mirrors the text into the window title, read through diagnostics).
- Diagnostics: with `[test] diag=true` in the share's ini, a `diag-request` file makes the shell write
  `diag.json` (windows, workspace, trees, seat focus, layer offsets). Off by default, no network.

## Files changed

`web/src/server/{ini.ts,store.ts,routes.ts,ini.test.ts,routes.test.ts}`, `web/src/client/MachineEditor.tsx`,
`build.sh`, `run.sh`, `tools/{get-image.sh,make-app-bundle.sh,host-window.sh,check.sh}`,
`tools/tests/scripts.sh`, `tools/vmtest/{vmtest.py,fixtures/typing.html}`,
`shell/{Desktop.qml,MacWindow.qml,Theme.qml,KeyHelp.qml,SettingsPanel.qml,Spotlight.qml,launcher.h,launcher.cpp}`,
`README.md`, `PLAN.md`, `.gitignore`.

## Compatibility notes

- Profiles stored with `input.layout = "en"` normalize to `us` on the next read or save; the guest maps
  `en` to `us` as well, so old share files keep working.
- Existing configs with out-of-range numbers are rejected on the next JSON save (422 with the field
  named); INI uploads keep the stored value and report the problem instead.
- `build.sh` now refuses to overwrite `out/` after a failed make; `out/*.prev` files appear after the
  first successful build or download.

## Follow-ups (in the plan, not done here)

Sections 6–10 of the review: fullscreen/configure state, apps-disk lifecycle, secrets and clipboard,
downloads and themes, background processes and agent usage. A real-Postgres run of the route tests.
