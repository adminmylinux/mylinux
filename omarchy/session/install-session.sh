#!/bin/sh
# Install the session save/restore into this Omarchy account: run inside Omarchy, from the folder these files are in
# (run-omarchy.sh puts them in the shared folder as mylinux-tools/):  sh ~/Mac/mylinux-tools/install-session.sh
# Afterwards the layout is saved every minute and at logout, and reopened at login. To remove: install-session.sh --remove
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
BIN="$HOME/.local/bin"; UNITS="$HOME/.config/systemd/user"
ALL="omarchy-session-restore.service omarchy-session-save.timer omarchy-session-agent.service"
if [ "${1:-}" = --remove ]; then
  systemctl --user disable --now $ALL 2>/dev/null || true
  rm -rf "$BIN/omarchy-session" "$UNITS"/omarchy-session-* "$UNITS"/omarchy-session-save.timer.d; systemctl --user daemon-reload
  # a copy baked into the disk (/etc/systemd/user) cannot be removed by the account; masking it there has the same effect
  [ -f /etc/systemd/user/omarchy-session-agent.service ] && { systemctl --user mask $ALL >/dev/null 2>&1 || true; }
  echo "removed"; exit 0
fi
mkdir -p "$BIN" "$UNITS"
systemctl --user unmask $ALL >/dev/null 2>&1 || true
install -m 0755 "$HERE/omarchy-session" "$BIN/omarchy-session"
install -m 0644 "$HERE"/omarchy-session-*.service "$HERE"/omarchy-session-*.timer "$UNITS/"
systemctl --user daemon-reload
systemctl --user enable --now omarchy-session-save.timer omarchy-session-restore.service omarchy-session-agent.service >/dev/null 2>&1 || systemctl --user enable omarchy-session-save.timer omarchy-session-restore.service omarchy-session-agent.service
systemctl --user restart omarchy-session-agent.service 2>/dev/null || true
"$BIN/omarchy-session" save
echo "installed: the layout is saved every minute and at logout, and reopened at login (omarchy-session status shows it);"
echo "the Session menu in the Mac window's title bar saves, restores and sets the interval"
