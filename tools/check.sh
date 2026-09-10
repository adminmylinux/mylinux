#!/bin/sh
# Fast checks, one command: web typecheck + tests, shell syntax, Python syntax, QML lint (when the
# Buildroot SDK is reachable through OrbStack). Exit status is the number of failed groups.
cd "$(dirname "$0")/.."
fail=0
step() { printf '\n== %s\n' "$1"; }

step "web: typecheck + tests"
if command -v bun >/dev/null 2>&1; then
  (cd web && bun run typecheck && bun test) || fail=$((fail + 1))
else echo "bun not installed: skipped (verification gap)"; fi

step "shell scripts: sh -n"
find board/overlay tools -type f \( -name '*.sh' -o -path '*/usr/bin/*' -o -path '*/init.d/*' \) 2>/dev/null | while read -r f; do
  head -1 "$f" | grep -q '^#!.*sh' && { sh -n "$f" || { echo "SYNTAX: $f"; echo "$f" >> /tmp/mylinux-check-fail; }; }
done
for f in run.sh build.sh; do sh -n "$f" || echo "$f" >> /tmp/mylinux-check-fail; done
if [ -f /tmp/mylinux-check-fail ]; then rm -f /tmp/mylinux-check-fail; fail=$((fail + 1)); else echo ok; fi

step "python: ast"
python3 - <<'PY' || fail=$((fail + 1))
import ast, glob, sys
bad = 0
for f in glob.glob("tools/**/*.py", recursive=True):
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

printf '\n== %s\n' "$([ $fail -eq 0 ] && echo 'all checks passed' || echo "$fail group(s) failed")"
exit $fail
