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
for f in run.sh run-omarchy.sh run-debian.sh debian_install.sh build.sh mac/build-app.sh; do bash -n "$f" || { echo "SYNTAX: $f"; echo "$f" >> "$FAILED"; }; done
if [ -s "$FAILED" ]; then : > "$FAILED"; fail=$((fail + 1)); else echo ok; fi

step "python: ast"
python3 - <<'PY' || fail=$((fail + 1))
import ast, glob, sys
bad = 0
for f in glob.glob("tools/**/*.py", recursive=True) + ["omarchy/session/omarchy-session"]:
    try: ast.parse(open(f).read(), f)
    except SyntaxError as e: print("SYNTAX:", f, e); bad += 1
print("ok" if not bad else f"{bad} file(s) failed"); sys.exit(1 if bad else 0)
PY

step "qml: qmllint (SDK)"
if command -v orb >/dev/null 2>&1 && orb -m debian test -x /home/vikkjart/br/sdk/bin/qmllint 2>/dev/null; then
  orb -m debian sh -c 'cd /Users/vikkjart/prjs/mylinux/shell && ~/br/sdk/bin/qmllint -I ~/br/sdk/aarch64-buildroot-linux-gnu/sysroot/usr/lib/qt6/qml --bare *.qml 2>&1 | grep -v "^Info\|^$" | grep -E "Error|Warning" | grep -v "Unqualified access\|not found\|could not\|Could not" | head -20' 
  echo "(warnings about unresolved MyShell types are expected outside the build tree)"
else echo "SDK not reachable: skipped (verification gap)"; fi

step "tests: shell script behaviour"
sh tools/tests/scripts.sh || fail=$((fail + 1))

step "tests: guest script libraries (disk, secrets, downloads, themes, clipboard)"
sh tools/tests/guest.sh || fail=$((fail + 1))

step "mac launcher: swift tests"
if command -v swift >/dev/null 2>&1; then
  # the exit status is swift's, not the filter's
  (cd mac && swift test > "$FAILED.swift" 2>&1; rc=$?; grep -E "error:|failed|Executed [0-9]+ tests" "$FAILED.swift" | tail -3; rm -f "$FAILED.swift"; exit $rc) || fail=$((fail + 1))
else echo "swift not installed: skipped (verification gap)"; fi


printf '\n== %s\n' "$([ $fail -eq 0 ] && echo 'all checks passed' || echo "$fail group(s) failed")"
exit $fail
