# Claude Code: fix and strengthen myLinux

Review prepared on 2026-09-10 against commit `7d04ab9`. Paths below are repository-relative; function names are the primary references because line numbers will change.

## Task and working rules

You are working in the myLinux repository. Implement the concrete fixes below in small, reviewable batches, with regression tests. Preserve the project's defining choices: Buildroot arm64, RAM-resident base, persistent Debian apps disk, Qt/QML Wayland compositor, macOS-style appearance, Option-as-Super keyboard workflow, and SDK/9p development loop.

Read `docs/ANALYSIS-PROMPT.md`, the current source, and applicable repository instructions first. Recheck every finding against the current revision. Do not undo a later fix merely to match this review. Distinguish reproduced defects, source-level findings, and hypotheses requiring runtime verification. Begin implementation after a short plan; do not stop at a second architecture essay.

Implement sections 1–10 in order, adding tests alongside the changes. Section 11 is the integration acceptance gate. Section 12 is a follow-up roadmap: propose scoped work and measurements, not a wholesale rewrite or an unsolicited feature expansion.

Preserve existing uncommitted work. Use an isolated temporary VM disk and share for destructive/failure tests. Do not format, replace, migrate, or reset the user's actual apps disk, settings, credentials, browser profiles, or Tailscale state. Do not deploy the website, mutate production data, push commits, or publish releases as part of this task. Never use real API keys or private transcripts as test fixtures. Do not assume a stopped build VM or missing tool means checks passed; report the exact verification gap and continue independent work.

## Evidence already collected

- `web`: `bun run typecheck` passes.
- Shell scripts pass `sh -n`; tracked Python tools pass AST parsing.
- Local execution of the actual `web/src/server/ini.ts` functions reproduced prototype pollution, invalid numeric values passing normalization, injected INI sections, and known fields being overridden through `extra`.
- An isolated JavaScript harness executing the actual functions from `Desktop.qml` reproduced helper/scratchpad inclusion when enabling tiling. It also showed that switching to an empty workspace leaves the mocked Wayland seat focus unchanged. This is evidence of missing explicit focus handling, not a verified live key-delivery exploit.
- No fresh Qt build, full OS build, live Wayland test, production HTTP test, or database integration test was performed for this review.

## 1. Urgent: fix the web configuration parser and serializer

**Source:** `web/src/server/ini.ts`: `fromIni`, `normalizeConfig`, `toIni`; `web/src/client/MachineEditor.tsx`; `shell/Theme.qml`.

**Reproduced:** `fromIni("[__proto__]\nmylinuxReviewProbe=1")` makes `({}).mylinuxReviewProbe` equal `"1"` within that process. `c.extra` is a normal object; `c.extra[current] ??= {}` can resolve an inherited object and write into it. The authenticated INI upload route calls this parser. Do not claim unauthenticated exploitation, remote code execution, or a demonstrated cross-account takeover: those were not tested.

Use safe dictionaries and own-property checks throughout parsing/normalization, and reject dangerous property names consistently at every nesting level. Validate object shapes rather than accepting arbitrary arrays/objects through `any`. Add a regression that checks shared prototypes remain unchanged, using process isolation or guaranteed cleanup for the pre-fix test.

Other reproduced defects:

- `normalizeConfig` accepts `scale: "0"` and `brightness: "-3"`; the shell then converts persisted values without validation.
- A field containing `test\n[input]\nlayout=invalid` is emitted verbatim by `toIni`, creating another INI section.
- `extra.display.scale` overrides the primary `display.scale` during export.
- Web defaults and the English layout selector use `en`, while the shell uses `us`.

Define the supported configuration contract: bounded finite numeric values, recognized keyboard layouts, nonnegative background index, safe theme identifiers, bounded lists/strings, and a policy for unknown keys. Keep valid custom themes and safe forward-compatible settings. Prevent line/section injection and prevent `extra` from overriding managed keys. Validate again on the guest so manually edited settings cannot break geometry. Migrate old `en` values to `us` without losing other settings.

**Acceptance:** hostile sections/keys cannot modify prototypes; invalid input produces a controlled validation error; scale zero/NaN/infinity/negative values cannot reach surface calculations; injected newlines cannot create settings; web export and actual Qt QSettings round-trip representative quotes, commas, Unicode, unknown safe keys, empty autostart, and current `look`/`wm` settings. Document any intentionally unsupported INI constructs.

## 2. Fix web API consistency and resource limits

**Source:** `web/src/server/routes.ts`, `auth.ts`, `db.ts`, `web/src/index.ts`.

**Source findings:** `POST /api/machines` checks a 50-machine limit, but `PUT /api/machines/:id/ini` creates machines through `saveMachine` without that check. Count-then-insert operations for machines and tokens are also susceptible to concurrent requests exceeding limits. INI size is checked after `req.text()` and in string length; JSON configuration size is not explicitly bounded at the application level.

Centralize creation/limit enforcement in the persistence layer and make it concurrency-safe for both creation routes. Distinguish POST create semantics from intentional INI upserts: a duplicate POST must not silently overwrite an existing profile because of a race. Bound request bytes before fully materializing bodies where supported, as well as parsed collection sizes. Return consistent 4xx responses for malformed JSON, invalid configuration, invalid IDs and conflicts. Preserve the existing user ownership checks; do not describe them as absent.

**Acceptance:** test both creation routes at the limit and concurrently, duplicate creation, malformed/oversized requests, token limit races, and user A versus user B access using both sessions and API tokens. Run against a disposable database. No production requests are needed.

## 3. Make failed builds and downloads preserve the last working image

**Source:** `build.sh:9`, `tools/app-build.sh`, `tools/get-image.sh`, `tools/make-app-bundle.sh`.

**Source findings:** `build.sh` runs its pipeline under Debian `sh` but checks `${PIPESTATUS:-0}`. On a shell without PIPESTATUS, the fallback reports success even after `make` fails. It then copies existing output artifacts. `tools/get-image.sh` overwrites the active kernel/rootfs before completing downloads and checksum verification. Its three `latest` URLs can also resolve to different releases if publication happens between requests.

Use explicit, correct build-status propagation, safe argument passing, and full logs. No-match log filtering must not turn a successful build into a failure. Stage and verify artifacts before promotion, resolve one release identity per download, and preserve a coherent previous kernel/rootfs pair on interruption or verification failure. Apply the same principle to hot-swap binaries and branded QEMU creation where appropriate. Note that `tools/app-build.sh` already explicitly handles a failed Ninja invocation; retain that fix.

**Acceptance:** fake failing `make`, successful output with no filter matches, failed download, checksum mismatch, interrupted promotion, and paths containing spaces. Failures must return nonzero and leave the previous runnable artifacts intact. Confirm which git revision the resulting image contains.

## 4. Fix launch-path handling and instance isolation

**Source:** `run.sh`, `tools/host-window.sh`, `tools/fresh-start.sh`.

**Source findings:** `run.sh` assumes the caller's current directory is the repository; prefixes `$PWD/` to `SHARE_DIR` even when it is absolute; expands a string containing all disk arguments unquoted; and interpolates `APPS_IMG` into Python source. These break legitimate paths and make error handling fragile. Host window commands target process `myLinux` rather than the requesting instance, despite distinct VM names/shares being supported.

Resolve repository/default paths deliberately, preserve documented override semantics, pass paths as arguments rather than generated source, and construct QEMU arguments without shell word splitting. Validate resolution and disk-size inputs. Fail before starting background services when dependencies or artifacts are missing. Tie command handling to the correct instance and clean up owned helpers on exit/signals. Preserve the host-command allowlist; never turn it into arbitrary guest-supplied shell execution.

**Acceptance:** launch through an absolute script path from another directory, absolute/relative shares, disk paths with spaces/apostrophes, malformed settings, missing QEMU, and two isolated VM instances. A command from the test instance must not manipulate the user's normal VM window.

## 5. Repair window membership, focus, and workspace transitions

**Source:** `shell/Desktop.qml`: `finishAdd`, `windowMapped`, `toggleTiling`, `focusTopmost`, `switchWorkspace`, scratchpad functions; `MacWindow.qml`; `Tiling.qml`.

**Reproduced logic defect:** `toggleTiling()` adds every non-minimized untiled window, including helper surfaces and scratchpad windows. It also bypasses the floating-app policy. Introduce a common eligibility predicate and maintain the invariant that each eligible window belongs to exactly one correct workspace tree.

**Source findings requiring live verification:**

- Switching to an empty workspace clears `focusedWindow` but `focusTopmost()` does nothing when there is no candidate. Explicitly coordinate QML focus and Wayland seat focus when switching, minimizing the last window, hiding scratchpad windows, and closing overlays.
- `finishAdd()` inserts into the currently selected `tiling`, even though a window can have been created on an earlier workspace before its app ID arrives.
- `MacWindow.onTitleHeightChanged` relayouts `output.tiling`, not necessarily the window's own workspace tree.
- A normal mapped application with neither title nor app ID is classified as a clipboard helper regardless of its size. This can hide legitimate clients. Use a narrower, documented identification policy.
- Hidden/minimized members can remain directional-focus candidates; make navigation and minimize/restore policy consistent.

**Acceptance:** real Firefox and foot receive typing after map/focus; empty workspaces do not send typing to hidden clients; helper surfaces never enter tiling or the dock after toggles; scratchpad windows remain floating; delayed app IDs and decoration changes affect the owning workspace; rapid helper open/close restores focus correctly. Preserve the recent Firefox keyboard-broadcast and mapped-surface fixes until equivalent behavior is proved.

## 6. Make fullscreen, activation, and resize state coherent

**Source:** `shell/MacWindow.qml`: `setTileRect`, `toggleFullscreen`, `zoom`, resize handlers; `shell/Tiling.qml`; `shell/Theme.qml`.

**Source findings:** configure calls repeatedly include `ActivatedState` for windows regardless of focus. `toggleFullscreen()` enlarges the window but sends no fullscreen state, saves no previous floating geometry, and leaves the window eligible for ordinary tiling relayout. Changing scale can change client item size without a complete reconfiguration of tile geometry.

Centralize window state and configure generation. Distinguish maximize/work-area zoom from actual fullscreen, preserve/restore geometry, and handle client requests through the supported Qt APIs. Ensure only the appropriate toplevel is activated. Audit client min/max sizes, configure acknowledgements, title-bar modes, popups, and scale changes; do not implement speculative protocol patches without checking existing Qt behavior.

**Acceptance:** enter/exit fullscreen with both shell shortcuts and browser UI, create another window while fullscreen, change workspace/scale/title-bar settings, and verify geometry restoration and usable input. Test client-decorated and server-decorated apps. Small work areas and repeated splits must not yield negative rectangles or overlapping windows because minimum sizes were ignored.

Reference: [Qt QWaylandXdgToplevel](https://doc.qt.io/qt-6/qwaylandxdgtoplevel.html) documents the distinct configure states and request signals. Check the pinned Qt version's source as well.

## 7. Make apps-disk setup and shutdown recoverable

**Source:** `S45apps`, `S47tailscale`, `S99shell`, `apps-setup`, `apps-setup-ai`, `apps-run`, `apps-install`, `apps-update`, `FirstRun.qml`, `Main.qml`.

**Source findings:**

- Disk selection relies on `/dev/vda`/`vdb` order. Blankness is inferred from only a small region, and a failed read can appear empty. A positive identity check must precede formatting.
- First-run readiness is inferred from the Chromium executable appearing. That can occur before package configuration, developer packages, and agent installation finish; autostart can race the installer. Failure leaves `running` true in the dialog, with no automatic retry presentation.
- `apps-run` repeatedly performs mounts and rewrites helpers/hosts during every command launch, without serialization or consistently fatal mount errors.
- `S45apps stop` tries only two unmounts despite nested chroot mounts, and suppresses their errors.
- Tailscale starts before first-time apps-disk setup binds a different `/root` over its state directory. Verify its first-boot persistence and restart/migration behavior.

Give the disk a stable QEMU serial and resolve it reliably in the guest. Treat unreadable, ambiguous, or unrecognized disks as errors, not blank disks. Support existing disks with an explicit compatible identification path. Serialize setup/repair, track durable versioned stage completion, and use an explicit ready marker only after required stages succeed. Optional agent failures need an honest partial-success status and targeted retry. Connect the UI to completion/failure, not executable existence. Prepare mounts/helper files once or atomically under a lock; shut down services and unwind owned nested mounts in the correct order.

**Acceptance:** blank disk, existing disk, extra unrelated disk, read failure, interrupted unpack/install, concurrent launch/install, disk-full, reboot after setup, and clean shutdown with browsers/Tailscale active. Persistent files and identity survive, unrelated disks remain untouched, failures remain diagnosable.

Correct the README and website claim that `commit=1` guarantees losing at most one second of writes. The [kernel ext4 documentation](https://www.kernel.org/doc/html/latest/admin-guide/ext4.html) distinguishes journal transaction age from delayed data writeback; older data can be lost. Describe the base as reset on reboot, not read-only or security-immutable.

## 8. Reduce secret exposure and make clipboard transfer correct

**Source:** `shell/secrets.cpp/.h`, `SettingsPanel.qml`, `apps-run`, `etc/profile.d/secrets.sh`, `run.sh`, `clipboard-bridge`, `clipboard-send`.

**Source findings:** every chroot application loads every saved API key, including browsers. Mode 0600 does not isolate those credentials from applications running as the same root user. `Secrets::set` updates memory and emits success-like change notification even when `save()` fails. The secrets file is sourced as shell code. Clipboard transfer uses shell command substitution (strips trailing newlines), ignores empty content, and detects guest-side updates with whole-second mtimes, so changes can be lost or left stale.

For this batch, introduce explicit per-launch credential selection and remove blanket export to unrelated apps. Preserve terminal/agent usability through a clear opt-in mechanism. Treat stored credentials as data with validated names, use atomic restricted writes, surface save errors, and leave the last valid state intact. This reduces accidental exposure; do not claim it establishes isolation while everything remains root.

Transfer clipboard bytes through files, use robust change IDs/content tracking and atomic handoff, and define empty clipboard and feedback-loop behavior. Make clipboard sharing visibly controllable while preserving the intended default behavior unless the user changes it. Limit retained clipboard data and clear transient files on shutdown. Keep shell commands allowlisted and independent from clipboard content.

**Acceptance:** browsers do not inherit unrelated key sentinels; authorized tools get only expected keys; failed secret saves are visible and preserve old data; quote/Unicode values round-trip without executing content. Clipboard tests cover Unicode, multiline/trailing newlines, empty text, two updates within a second, repeated identical values, large input limits, bridge restart, and focus restoration. Use synthetic content only.

## 9. Make downloads and theme installation predictable

**Source:** `apps-setup`, `apps-setup-ai`, `theme-install`, `theme-fetch-backgrounds`, `shell/themestore.cpp`.

**Source findings:** the Debian rootfs and agent installs depend on mutable URLs, with no repository-level pinned verification for these artifacts. The Claude installer pipeline can hide a failed download. `theme-install` routes essentially every URL containing `/` through GitHub, preventing the advertised generic Git fallback. It deletes an existing theme before the replacement is safely installed; normalized names and extracted archive content need validation before promotion.

Use a versioned download manifest with real verified hashes/provenance where supported. Fetch installers to a verified staged file before execution and check each exit status. If an upstream has no useful verification mechanism, document that precise limitation rather than inventing hashes/signature support. Support explicit updates instead of silent drift on repair.

Parse GitHub shorthand, GitHub URLs, and supported other Git URLs distinctly. Reject empty/dot/path-traversal names, constrain archive extraction and symlinks to staging, validate required palette data, and promote a complete theme with rollback. Run expensive WebP conversion outside the compositor UI thread rather than synchronously when opening the picker.

**Acceptance:** corrupt downloads, offline operation, interrupted installs, GitHub and non-GitHub URLs, bad names, malformed palettes, and failed replacement all leave previously working software/themes intact. Use local fixtures for failure tests.

## 10. Fix background process and agent usage behavior

**Source:** `shell/launcher.cpp`, `tailscale.cpp`, `agentusage.cpp`, `settings.cpp`, `AgentPanel.qml`.

**Source findings:**

- `Launcher::launch` waits synchronously for up to three seconds on the compositor thread and only schedules process deletion on `finished`.
- Tailscale's `m_proc` is cleared only on `finished`; a start failure or hanging process can prevent all future refreshes.
- Agent refresh synchronously rescans all session files. This will become more expensive as history grows.
- Relative usage reset times are added to the current time on each refresh instead of the recorded event time, continually moving the deadline forward.
- The daily chart contains seven dates but aggregators include `today - 7`, an eighth date. The Claude cache fallback can also substitute all-time model totals for a recent-period display.
- Claude utilization units are guessed from whether any bucket is at least 1. Under the percent-format assumption already stated in the code, a payload with all buckets below 1 is misinterpreted. Unit selection needs schema evidence, not magnitude guessing.
- Settings persistence tests directory writability rather than whether the share is mounted, and does not expose QSettings write errors.

Use asynchronous process starts, bounded subprocess lifetimes, explicit error cleanup, and visible failures. Cache/incrementally scan logs in a worker and coalesce refreshes; preserve the existing Claude network timeout and recent-probe caching. Anchor reset timestamps to their source events and label stale/unknown data. Verify token counter semantics and repeated-event behavior against sanitized versioned fixtures before changing totals; do not assume cached-input fields are independent of input counts. Align date ranges and label all-time fallbacks honestly. Make persistence status explicit, using the mounted apps disk as a fallback where appropriate.

**Acceptance:** failed/hung subprocesses recover on later refresh; repeated launch failures do not accumulate process objects; large synthetic log history does not stall input; an unchanged log yields a fixed reset deadline; dates and totals are consistent; unknown schemas do not display fabricated zero/100% values; save failures and absent shares are visible. [Qt QProcess documentation](https://doc.qt.io/qt-6/qprocess.html) distinguishes process-start errors and blocking wait functions.

## 11. Required verification and delivery

Add a documented fast check command: web typecheck and Bun tests, shell lint/syntax, Python checks, and Qt/QML checks when the SDK is available. Tests should assert user-visible behavior or invariants, not merely grep for implementation text. Run shell behavior tests in the actual supported host shell and guest BusyBox/Debian shells where their semantics differ.

Add a repeatable QMP/serial smoke suite using a throwaway apps disk and share. Make failure detection explicit with deadlines and assertions; screenshots alone are not a pass condition. A local browser fixture that records typed text can verify Firefox input without real accounts. Assert window inventory/focus/tree membership through test-only diagnostics with no production network endpoint. Derive screen size from the VM rather than relying on old 1920x1200 constants.

Minimum smoke scenarios: boot; first-run retry and persistence; Firefox typing after first map; workspace switch to empty/back; helpers excluded from tiling; scratchpad transitions; title-bar close versus resize handles; fullscreen/restore; clipboard fidelity and focus; shell restart; clean shutdown and reboot. Verify the baked image once, not just a hot-swapped binary. Keep tests independent of external AI accounts and live web pages.

Deliver a concise report with fixed finding IDs, files changed, actual tests/results, remaining uncertainties, migration/compatibility notes, and prioritized follow-ups. Never describe an unrun integration test as passed.

## 12. Improvements to propose after the fixes

Produce a short roadmap with impact, effort, dependencies, and a measurable outcome for each item:

1. **Application privilege separation.** A normal desktop user, a narrowly scoped privileged installation path, sandboxed Chromium, and restricted access to host control files and Tailscale state. Design and test home/ownership migration on a disposable disk. Merely changing `USER` in the environment is insufficient; preserve Wayland socket access, browser profiles, CLI login flows, and root-only maintenance. Do not migrate the user's actual disk automatically.
2. **Backup, restore, and versioned upgrades.** A recoverable apps-disk backup workflow, base-image rollback, explicit setup/schema migrations, and a restored-profile test. Treat Tailscale identity cloning and stored credentials deliberately. Website profile sync is not a backup of user files or application data.
3. **Data-driven application and shortcut catalogues.** Consolidate the duplicated menu/dock/shortcut/help mappings, then consider `.desktop` discovery so installed applications become discoverable. Preserve stable app IDs and the existing keyboard workflow. Avoid a large abstraction rewrite before tests exist.
4. **Measured software-rendering work.** Benchmark idle desktop, typing, a local animated browser page, resize, solid/glass panels, and 1x/2x output at a fixed resolution. Record guest compositor CPU, client CPU, host QEMU CPU, frame timing, memory and input latency separately. Investigate damaged-region handling, buffer uploads, hidden-window work and frame scheduling only after locating the bottleneck. Keep solid panels and reduced-motion behavior. No unsupported promises about partial repaint savings.
5. **Correct HiDPI and protocol coverage.** Explore true integer output scaling before fractional scaling, with explicit physical-buffer versus logical-coordinate tests. Verify Qt's actual support for fractional-scale/viewporter, data-control, activation, primary selection and input methods against the pinned version and real client needs. Avoid advertising protocol versions while ignoring required semantics. A secure clipboard mechanism could remove the current focus-stealing helper workaround; do not add protocols indiscriminately.
6. **Daily-use essentials.** Audit and rank sound output, microphone, dead keys/Compose, notifications, session locking, secret service for saved app passwords, and screen-sharing portals. Audio currently has no explicit device/backend in `run.sh`; verify the rest of the stack before proposing its implementation. Distinguish missing functionality from optional polish.
7. **Web operations and access policy.** Scoped/expiring personal tokens, bounded caches, deliberate origin policy, database migrations/backups, and sync conflict/version handling. Preserve already-present token hashing and account ownership checks. Propose and test migrations locally before deployment.
8. **Release and platform maintenance.** Pin supported Buildroot/Qt/QEMU combinations, smoke-test the local Wayland patches, add a graceful branding fallback when QEMU's Mach-O layout changes, and document build provenance plus license/source artifact generation. Separate current limitations from historical milestones in `PLAN.md`.

For these follow-ups, prefer the smallest change that fixes a measured problem. Retain Qt/QML and the current OS split unless evidence shows a specific requirement cannot be met.
