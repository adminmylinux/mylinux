#!/bin/sh
# Fast checks, one command: shell syntax, Python syntax, QML lint (when the Buildroot SDK is reachable
# through OrbStack), the script tests and the launcher's Swift tests. Exit status is the number of failed
# groups. The website has its own checks in its own repository (adminmylinux/mylinux-web).
cd "$(dirname "$0")/.."
fail=0
step() { printf '\n== %s\n' "$1"; }
FAILED=$(mktemp); trap 'rm -f "$FAILED"' EXIT

step "shell scripts: sh -n"
find board/overlay tools omarchy -type f \( -name '*.sh' -o -path '*/usr/bin/*' -o -path '*/init.d/*' \) 2>/dev/null | while read -r f; do
  head -1 "$f" | grep -q '^#!.*sh' && { sh -n "$f" || { echo "SYNTAX: $f"; echo "$f" >> "$FAILED"; }; }
done
for f in run.sh run-omarchy.sh run-server.sh run-debian.sh run-alpine.sh debian_install.sh alpine_install.sh build.sh mac/build-app.sh server-apps/run.sh server-apps/mount-share.sh; do bash -n "$f" || { echo "SYNTAX: $f"; echo "$f" >> "$FAILED"; }; done
if [ -s "$FAILED" ]; then : > "$FAILED"; fail=$((fail + 1)); else echo ok; fi

step "python: ast"
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
seen = set()
for sn in json.load(open("server-apps/snippets.json"))["snippets"]:
    miss = [k for k in ("id", "name", "description", "os", "text") if not sn.get(k)]
    if sn.get("id") in seen: miss.append("unique id")
    seen.add(sn.get("id"))
    if any(o not in ("mylinux", "omarchy", "debian", "alpine") for o in sn.get("os", [])): miss.append("known systems")
    if miss: print("SNIPPETS:", sn.get("id"), "has no", ", ".join(miss)); bad += 1
cat = json.load(open("server-apps/catalog.json"))
for al in cat.get("aliases", []):
    miss = [k for k in ("name", "command", "description") if not al.get(k)]
    if al.get("app") and al["app"] not in ids: miss.append(f"an app {al['app']} in the catalog")
    if not al.get("name", "").replace("-", "").isalnum(): miss.append("a plain name")
    if miss: print("CATALOG: alias", al.get("name"), "has no", ", ".join(miss)); bad += 1
print("ok" if not bad else f"{bad} file(s) failed"); sys.exit(1 if bad else 0)
PY

step "qml: qmllint (SDK)"
if command -v orb >/dev/null 2>&1 && orb -m debian test -x /home/vikkjart/br/sdk/bin/qmllint 2>/dev/null; then
  orb -m debian sh -c 'cd /Users/vikkjart/prjs/mylinux/shell && ~/br/sdk/bin/qmllint -I ~/br/sdk/aarch64-buildroot-linux-gnu/sysroot/usr/lib/qt6/qml --bare *.qml 2>&1 | grep -v "^Info\|^$" | grep -E "Error|Warning" | grep -v "Unqualified access\|not found\|could not\|Could not" | head -20' 
  echo "(warnings about unresolved MyShell types are expected outside the build tree)"
else echo "SDK not reachable: skipped (verification gap)"; fi

step "tests: shell script behaviour"
sh tools/tests/scripts.sh || fail=$((fail + 1))
sh tools/tests/claude-bootstrap.sh || fail=$((fail + 1))
sh tools/tests/apps-claude.sh || fail=$((fail + 1))

step "tests: guest script libraries (disk, secrets, downloads, themes, clipboard)"
sh tools/tests/guest.sh || fail=$((fail + 1))

step "mac launcher: swift tests"
if command -v swift >/dev/null 2>&1; then
  # the exit status is swift's, not the filter's
  sh tools/get-ghosttykit.sh >/dev/null || fail=$((fail + 1))          # the Ghostty terminal package, pinned
  (cd mac && swift test > "$FAILED.swift" 2>&1; rc=$?; grep -E "error:|failed|Executed [0-9]+ tests" "$FAILED.swift" | tail -3; rm -f "$FAILED.swift"; exit $rc) || fail=$((fail + 1))
else echo "swift not installed: skipped (verification gap)"; fi


printf '\n== %s\n' "$([ $fail -eq 0 ] && echo 'all checks passed' || echo "$fail group(s) failed")"
exit $fail
