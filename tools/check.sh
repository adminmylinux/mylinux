#!/bin/sh
# Fast checks, one command: shell syntax, Python syntax, QML lint (when the Buildroot SDK is reachable
# through OrbStack), the script tests and the launcher's Swift tests. Exit status is the number of failed
# groups. The website has its own checks in its own repository (adminmylinux/mylinux-web).
#
# Usage: tools/check.sh          the tests of what changed since the last release (the v* tag before this work), with
#                                what is not committed yet: a change to the launcher's Swift does not run the guest's
#                                script tests, and the two launcher tests that wait ten seconds each run only when
#                                their part changed. This is the check before a release.
#        tools/check.sh --all    every test, as before (about 70 seconds): after a change that reaches wide, and now
#                                and then
cd "$(dirname "$0")/.."
fail=0
step() { printf '\n== %s\n' "$1"; }
ALL=0; [ "${1:-}" = "--all" ] && ALL=1
BASE=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null) || ALL=1
CHANGED=""
if [ "$ALL" = 0 ]; then
  CHANGED=$( { git diff --name-only "$BASE" 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null; } | sort -u )
  printf 'checking what changed since %s: %s file(s) (tools/check.sh --all runs every test)\n' "$BASE" "$(printf '%s\n' "$CHANGED" | grep -c .)"
fi
# whether a group's part of the repository changed (always, with --all)
touched() { [ "$ALL" = 1 ] || printf '%s\n' "$CHANGED" | grep -qE "$1"; }
skipped() { echo "nothing of it changed: skipped"; }
FAILED=$(mktemp); trap 'rm -f "$FAILED"' EXIT

step "shell scripts: sh -n"
find board/overlay tools omarchy -type f \( -name '*.sh' -o -path '*/usr/bin/*' -o -path '*/init.d/*' \) 2>/dev/null | while read -r f; do
  head -1 "$f" | grep -q '^#!.*sh' && { sh -n "$f" || { echo "SYNTAX: $f"; echo "$f" >> "$FAILED"; }; }
done
for f in run.sh run-omarchy.sh run-windows.sh tools/get-windows.sh tools/desktop-window.sh run-server.sh run-debian.sh run-alpine.sh debian_install.sh alpine_install.sh build.sh mac/build-app.sh server-apps/run.sh server-apps/mount-share.sh; do bash -n "$f" || { echo "SYNTAX: $f"; echo "$f" >> "$FAILED"; }; done
if [ -s "$FAILED" ]; then : > "$FAILED"; fail=$((fail + 1)); else echo ok; fi

step "python: ast, the apps catalog and the snippets"
if ! touched '\.py$|^server-apps/|^omarchy/session/|^mac/build-app\.sh$|ServerApps\.swift$'; then skipped; else
python3 - <<'PY' || fail=$((fail + 1))
import ast, glob, os, sys
bad = 0
for f in glob.glob("tools/**/*.py", recursive=True) + glob.glob("server-apps/*.py") + ["omarchy/session/omarchy-session"]:
    try: ast.parse(open(f).read(), f)
    except SyntaxError as e: print("SYNTAX:", f, e); bad += 1
# myLinux Apps' catalog: every app named, found by a program, runnable, and installable somewhere
import json
ids = set()
for a in json.load(open("server-apps/catalog.json"))["apps"]:
    if a.get("builtin"):
        # a script that comes with the app (the speed test): beside it, and copied by the launcher
        miss = [k for k in ("id", "name", "category", "description") if not a.get(k)]
        if not os.path.exists("server-apps/" + a["builtin"]): miss.append("its script in server-apps")
        if a["builtin"] not in open("mac/Sources/myLinux/Agents/ServerApps.swift").read(): miss.append("its script in ServerApps.files")
        if a["builtin"] not in open("mac/build-app.sh").read(): miss.append("its script in build-app.sh")
        if miss: print("CATALOG:", a.get("id"), "has no", ", ".join(miss)); bad += 1
        ids.add(a.get("id")); continue
    miss = [k for k in ("id", "name", "category", "description", "bin", "run") if not a.get(k)]
    if a.get("id") in ids: miss.append("unique id")
    ids.add(a.get("id"))
    if not any(a.get(k) for k in ("apk", "apt", "pacman", "alpine", "debian", "arch", "script")): miss.append("a way to install it")
    if a.get("icon") and not all(c in "0123456789abcdef" for c in a["icon"].lower()): miss.append("a hex icon")
    if miss: print("CATALOG:", a.get("id"), "has no", ", ".join(miss)); bad += 1
# Snippets…: each with an id, a name, a line about it, systems the launcher knows, and text
for sf, systems in (("snippets.json", ("mylinux", "omarchy", "debian", "alpine", "arch", "kali", "windows")), ("snippets-vnc.json", ("vnc",))):
  seen = set()
  for sn in json.load(open("server-apps/" + sf))["snippets"]:
    miss = [k for k in ("id", "name", "description", "os", "text") if not sn.get(k)]
    if sn.get("id") in seen: miss.append("unique id")
    seen.add(sn.get("id"))
    if any(o not in systems for o in sn.get("os", [])): miss.append("known systems")
    if miss: print("SNIPPETS:", sn.get("id"), "has no", ", ".join(miss)); bad += 1
cat = json.load(open("server-apps/catalog.json"))
for al in cat.get("aliases", []):
    miss = [k for k in ("name", "command", "description") if not al.get(k)]
    if al.get("app") and al["app"] not in ids: miss.append(f"an app {al['app']} in the catalog")
    if not al.get("name", "").replace("-", "").isalnum(): miss.append("a plain name")
    if miss: print("CATALOG: alias", al.get("name"), "has no", ", ".join(miss)); bad += 1
print("ok" if not bad else f"{bad} file(s) failed"); sys.exit(1 if bad else 0)
PY
fi

step "qml: qmllint (SDK)"
if ! touched '^shell/'; then skipped
elif command -v orb >/dev/null 2>&1 && orb -m debian test -x /home/vikkjart/br/sdk/bin/qmllint 2>/dev/null; then
  orb -m debian sh -c 'cd /Users/vikkjart/prjs/mylinux/shell && ~/br/sdk/bin/qmllint -I ~/br/sdk/aarch64-buildroot-linux-gnu/sysroot/usr/lib/qt6/qml --bare *.qml 2>&1 | grep -v "^Info\|^$" | grep -E "Error|Warning" | grep -v "Unqualified access\|not found\|could not\|Could not" | head -20' 
  echo "(warnings about unresolved MyShell types are expected outside the build tree)"
else echo "SDK not reachable: skipped (verification gap)"; fi

step "tests: shell script behaviour"
# the scripts that start and fetch machines, what the launcher carries of them, and their own tests
if touched '^[^/]*\.sh$|^tools/|^windows/|^tiny/|^omarchy/|^mac/[^/]*\.sh$|^mac/bin/|^skills/|^server-apps/snippets'; then
  if [ "$ALL" = 1 ]; then sh tools/tests/scripts.sh; else CHECK_CHANGED="$CHANGED" sh tools/tests/scripts.sh; fi || fail=$((fail + 1))
else echo "the machines' scripts: $(skipped)"; fi
# Claude Code's and the apps' setup inside a machine
if touched '^server-apps/|^tools/tests/(claude|apps)|^debian_install\.sh$|^alpine_install\.sh$'; then
  sh tools/tests/claude-bootstrap.sh || fail=$((fail + 1))
  sh tools/tests/apps-claude.sh || fail=$((fail + 1))
  sh tools/tests/claude-setup.sh || fail=$((fail + 1))
else echo "Claude Code's setup inside a machine: $(skipped)"; fi

step "tests: guest script libraries (disk, secrets, downloads, themes, clipboard)"
if touched '^board/|^tools/tests/guest'; then sh tools/tests/guest.sh || fail=$((fail + 1)); else skipped; fi

step "mac launcher: swift tests"
if ! touched '^mac/|^server-apps/|^windows/|^skills/|^omarchy/session/'; then skipped
elif command -v swift >/dev/null 2>&1; then
  # Two tests wait for a time-out each (a VNC server that never answers: 10 s; Omarchy's agent asked to open an
  # app: 8 s), of 22 s for all 120: left out unless the part they test changed
  SKIP=""
  touched '^mac/Sources/myLinux/Remote/' || SKIP="$SKIP --skip testAVncServerThatNeverAnswersEndsInAMessage"
  touched 'ServerApps|^omarchy/session/|^server-apps/' || SKIP="$SKIP --skip testOmarchysAgentIsAskedToOpenTheApp"
  [ -z "$SKIP" ] || echo "left out:$(printf '%s' "$SKIP" | sed 's/ --skip / /g')"
  # the exit status is swift's, not the filter's
  sh tools/get-ghosttykit.sh >/dev/null || fail=$((fail + 1))          # the Ghostty terminal package, pinned
  # shellcheck disable=SC2086
  (cd mac && swift test $SKIP > "$FAILED.swift" 2>&1; rc=$?; grep -E "error:|failed|Executed [0-9]+ tests" "$FAILED.swift" | tail -3; rm -f "$FAILED.swift"; exit $rc) || fail=$((fail + 1))
else echo "swift not installed: skipped (verification gap)"; fi


printf '\n== %s\n' "$([ $fail -eq 0 ] && echo 'all checks passed' || echo "$fail group(s) failed")"
exit $fail
