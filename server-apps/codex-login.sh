#!/bin/sh
# Sign Codex in here with the login of the Mac this machine runs on: no browser, no code to type.
#   curl -fsSL https://raw.githubusercontent.com/adminmylinux/mylinux/main/server-apps/codex-login.sh | sh
# (Snippets… › "Sign Codex in as on the Mac", and Apps… › "Codex login from the Mac", run exactly this.)
#
# Codex has no token to paste, as `claude setup-token` gives Claude Code. What OpenAI documents for a machine
# without a browser is a copy of ~/.codex/auth.json from a computer that is signed in. Nothing inside a machine can
# read the Mac's files, so this asks: it writes .mylinux/codex-login-request into the Mac share folder, myLinux
# Launcher (0.7.57 or newer) sees it and asks you on the Mac, and on yes puts the Mac's login file into the share
# as .mylinux/codex-auth.json, which is moved to ~/.codex/auth.json here (or $CODEX_HOME, for an account of its own).
# A login that was here before is kept beside it as auth.json.before-mac.
set -eu
say() { printf '%s\n' "$*"; }

# the share: /mnt/mac on Debian, Alpine and Arch, a folder mounted in the home folder on Omarchy
share=""
for d in /mnt/mac "$HOME"/*; do
  [ -d "$d" ] && [ ! -L "$d" ] || continue
  if mountpoint -q "$d" 2>/dev/null; then share=$d; break; fi
done
[ -n "$share" ] || { say "This machine has no Mac share folder. Give it one on its page in the launcher (Share folder), restart it and run this again."; exit 1; }

dir="$share/.mylinux"; req="$dir/codex-login-request"; got="$dir/codex-auth.json"; no="$dir/codex-login-declined"
home="${CODEX_HOME:-$HOME/.codex}"
mkdir -p "$dir"; rm -f "$got" "$no"
trap 'rm -f "$req" "$got" "$no"' EXIT
trap 'exit 130' INT TERM
date +%s > "$req"
say "Asked myLinux Launcher on your Mac: answer the question it shows there (it appears within a few seconds)."
n=0
while [ ! -s "$got" ] && [ ! -e "$no" ] && [ "$n" -lt 180 ]; do sleep 1; n=$((n + 1)); done
if [ -e "$no" ]; then say "Not signed in: $(cat "$no" 2>/dev/null)"; exit 1; fi
[ -s "$got" ] || { say "No answer from the Mac. This needs myLinux Launcher 0.7.57 or newer, running."; exit 1; }

mkdir -p "$home"; chmod 700 "$home"
if [ -s "$home/auth.json" ] && ! cmp -s "$got" "$home/auth.json"; then
  cp -p "$home/auth.json" "$home/auth.json.before-mac"
  say "(the login that was here is kept as $home/auth.json.before-mac)"
fi
(umask 077; cat "$got" > "$home/auth.json.new") && mv -f "$home/auth.json.new" "$home/auth.json"
rm -f "$got"
say "Codex is signed in here as on your Mac."
PATH="$HOME/.local/bin:$PATH"
if command -v codex >/dev/null 2>&1; then codex login status 2>&1 || true
else say "(Codex itself is not installed yet: Install Codex in Snippets…, or Codex in Apps…)"; fi
