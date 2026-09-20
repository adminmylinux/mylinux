#!/bin/sh
# Install the session save/restore into this Omarchy account: run inside Omarchy, from the folder these files are in
# (run-omarchy.sh puts them in the shared folder as mylinux/):  sh ~/Mac/mylinux/install-session.sh
# Afterwards the layout is saved every minute and at logout, and reopened at login. To remove: install-session.sh --remove
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
BIN="$HOME/.local/bin"; UNITS="$HOME/.config/systemd/user"
if [ "${1:-}" = --remove ]; then
  systemctl --user disable --now omarchy-session-restore.service omarchy-session-save.timer 2>/dev/null || true
  rm -f "$BIN/omarchy-session" "$UNITS"/omarchy-session-*; systemctl --user daemon-reload; echo "removed"; exit 0
fi
mkdir -p "$BIN" "$UNITS"
install -m 0755 "$HERE/omarchy-session" "$BIN/omarchy-session"
install -m 0644 "$HERE"/omarchy-session-*.service "$HERE"/omarchy-session-*.timer "$UNITS/"
systemctl --user daemon-reload
systemctl --user enable --now omarchy-session-save.timer omarchy-session-restore.service >/dev/null 2>&1 || systemctl --user enable omarchy-session-save.timer omarchy-session-restore.service
"$BIN/omarchy-session" save
echo "installed: the layout is saved every minute and at logout, and reopened at login (omarchy-session status shows it)"
