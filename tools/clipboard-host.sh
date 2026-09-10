#!/bin/sh
# Host side of the text clipboard bridge (run by run.sh in the background; one instance per VM):
#   Mac -> guest: pbpaste into $DIR/mac.txt byte-for-byte, then bump $DIR/mac.seq, whenever the text changed
#   guest -> Mac: when $DIR/guest.seq changes, pbcopy $DIR/guest.txt (written by clipboard-send in the guest)
# Content only ever moves as files (cmp, cp, mv); nothing is executed or word-split. Empty text is not
# mirrored in either direction. Files above 1 MB are skipped. Usage: clipboard-host.sh DIR [once]
DIR="$1"; ONCE="${2:-}"; MAX=1048576
[ -n "$DIR" ] || { echo "usage: clipboard-host.sh DIR [once]" >&2; exit 2; }
mkdir -p "$DIR"
M="$DIR/mac.txt"; MS="$DIR/mac.seq"; G="$DIR/guest.txt"; GS="$DIR/guest.seq"
# state survives a restart of this loop (and the `once` mode): the current Mac sequence and the last guest one
MSEQ=$(cat "$MS" 2>/dev/null); case "$MSEQ" in ''|*[!0-9]*) MSEQ=0 ;; esac
LAST_GUEST_SEQ=$(cat "$GS.done" 2>/dev/null)
export LC_ALL=en_US.UTF-8
bump() { MSEQ=$((MSEQ + 1)); printf '%s\n' "$MSEQ" > "$MS.tmp" && mv -f "$MS.tmp" "$MS"; }
while :; do
  # guest -> Mac
  if [ -f "$GS" ]; then
    S=$(cat "$GS" 2>/dev/null)
    if [ -n "$S" ] && [ "$S" != "$LAST_GUEST_SEQ" ]; then
      LAST_GUEST_SEQ=$S; printf '%s\n' "$S" > "$GS.done"

      size=$(wc -c < "$G" 2>/dev/null | tr -d ' ')
      if [ -n "$size" ] && [ "$size" -gt 0 ] && [ "$size" -le $MAX ]; then
        pbcopy < "$G" && cp -f "$G" "$M.last"     # what the Mac now holds: no echo back to the guest
      fi
    fi
  fi
  # Mac -> guest
  pbpaste > "$M.new" 2>/dev/null || : > "$M.new"
  size=$(wc -c < "$M.new" | tr -d ' ')
  if [ "$size" -gt 0 ] && [ "$size" -le $MAX ] && ! cmp -s "$M.new" "$M.last" 2>/dev/null; then
    cp -f "$M.new" "$M.last" && mv -f "$M.new" "$M" && bump
  else rm -f "$M.new"; fi
  [ "$ONCE" = once ] && exit 0
  sleep 0.5
done
