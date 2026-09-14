#!/bin/sh
# Behaviour tests for the guest-side scripts that can run on the Mac (POSIX sh, no VM): disk identification,
# secret parsing and export policy, verified downloads, theme installation, clipboard transfer. Fixtures are
# synthetic. Usage: sh tools/tests/guest.sh
REPO=$(cd "$(dirname "$0")/../.." && pwd)
OV="$REPO/board/overlay"
T=$(mktemp -d "${TMPDIR:-/tmp}/mylinux-guest.XXXXXX"); T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT
fails=0
ok() { echo "  ok   $1"; }
ko() { echo "  FAIL $1"; fails=$((fails + 1)); }
is() { [ "$2" = "$3" ] && ok "$1" || ko "$1 (got '$2', wanted '$3')"; }
is_rc() { [ "$2" -eq "$3" ] && ok "$1" || ko "$1 (rc $2, wanted $3)"; }
has() { printf '%s' "$2" | grep -qF -- "$3" && ok "$1" || ko "$1 (no '$3' in: $2)"; }
hasnt() { printf '%s' "$2" | grep -qF -- "$3" && ko "$1 ('$3' present in: $2)" || ok "$1"; }
same() { cmp -s "$2" "$3" && ok "$1" || ko "$1 (files differ)"; }
mkdisk() { dd if=/dev/zero of="$1" bs=1024 count=2048 2>/dev/null; }
# an ext4 superblock signature + label at the right offsets, nothing else
mklabel() { printf '\123\357' | dd of="$1" bs=1 seek=1080 conv=notrunc 2>/dev/null; printf '%s' "$2" | dd of="$1" bs=1 seek=1144 conv=notrunc 2>/dev/null; }
mkdir -p "$T/bin"

echo "usr/lib/mylinux/disk.sh"
. "$OV/usr/lib/mylinux/disk.sh"
mkdisk "$T/blank.img"; is "all-zero disk is blank" "$(disk_state "$T/blank.img")" blank
mkdisk "$T/apps.img"; mklabel "$T/apps.img" apps; is "ext4 with label apps" "$(disk_state "$T/apps.img")" apps
mkdisk "$T/other.img"; mklabel "$T/other.img" data; is "ext4 with another label is foreign" "$(disk_state "$T/other.img")" foreign
mkdisk "$T/junk.img"; printf 'not a filesystem' | dd of="$T/junk.img" bs=1 seek=700000 conv=notrunc 2>/dev/null; is "random bytes are foreign, not blank" "$(disk_state "$T/junk.img")" foreign
mkdisk "$T/late.img"; printf 'x' | dd of="$T/late.img" bs=1 seek=1000000 conv=notrunc 2>/dev/null; is "a byte late in the first MiB is not blank" "$(disk_state "$T/late.img")" foreign
dd if=/dev/zero of="$T/short.img" bs=1024 count=100 2>/dev/null; is "a short read is unreadable, not blank" "$(disk_state "$T/short.img")" unreadable
is "a missing device is unreadable" "$(disk_state "$T/nonexistent")" unreadable
# find_apps_disk over a fake /sys/block: serial wins, ordering does not matter
SYSBLOCK="$T/sys"; DEVDIR="$T/dev"; mkdir -p "$SYSBLOCK/vda" "$SYSBLOCK/vdb" "$DEVDIR"
cp "$T/other.img" "$DEVDIR/vda"; cp "$T/apps.img" "$DEVDIR/vdb"
printf 'other-disk\n' > "$SYSBLOCK/vda/serial"; printf 'mylinux-apps\n' > "$SYSBLOCK/vdb/serial"
is "apps disk found by serial although it is the second disk" "$(find_apps_disk)" "$DEVDIR/vdb"
printf 'mylinux-apps\n' > "$SYSBLOCK/vda/serial"; find_apps_disk > "$T/out" 2>&1; is_rc "two disks with the serial are ambiguous" $? 2
rm -f "$SYSBLOCK/vda/serial" "$SYSBLOCK/vdb/serial"
is "no serial anywhere: the one disk labelled apps" "$(find_apps_disk)" "$DEVDIR/vdb"
cp "$T/blank.img" "$DEVDIR/vdb"; find_apps_disk > /dev/null 2>&1; is_rc "no serial and a blank disk: nothing chosen (never guessed)" $? 1
printf 'x\n' > "$SYSBLOCK/vda/serial"; cp "$T/apps.img" "$DEVDIR/vda"; find_apps_disk > /dev/null 2>&1; is_rc "a labelled disk with someone else's serial is not ours" $? 1

echo "usr/lib/mylinux/secrets.sh"
. "$OV/usr/lib/mylinux/secrets.sh"
cat > "$T/secrets.env" <<'EOS'
# comment
OPENAI_API_KEY=sk-plain
ANTHROPIC_API_KEY='sk-quoted-legacy'
GITHUB_TOKEN='it'\''s $(dangerous) `stuff` "q"'
lowercase=no
X=tooshort
BAD-NAME=nope
1LEADING=nope
EMPTY=
TRAILING_SPACE=keep 
EOS
out=$(secrets_filter < "$T/secrets.env")
has "plain value kept" "$out" "OPENAI_API_KEY=sk-plain"
has "legacy single quotes unwrapped" "$out" "ANTHROPIC_API_KEY=sk-quoted-legacy"
has "quote escape, \$(), backticks and double quotes stay literal" "$out" "GITHUB_TOKEN=it's \$(dangerous) \`stuff\` \"q\""
hasnt "lower-case name rejected" "$out" "lowercase"
hasnt "two-letter name rejected" "$out" "X=tooshort"
hasnt "dash in name rejected" "$out" "BAD-NAME"
hasnt "leading digit rejected" "$out" "1LEADING"
hasnt "empty value skipped" "$out" "EMPTY"
has "trailing space in a value kept" "$out" "TRAILING_SPACE=keep "
is "no command substitution ran (no file created)" "$(ls "$T" | grep -c dangerous)" 0
# the export path used by profile.d/secrets.sh: export "KEY=value" does not evaluate
( while IFS= read -r l; do [ -n "$l" ] && export "$l"; done <<EOS2
$(secrets_filter < "$T/secrets.env")
EOS2
  printf '%s' "$GITHUB_TOKEN" > "$T/exported" )
is "exported value byte-identical" "$(cat "$T/exported")" "it's \$(dangerous) \`stuff\` \"q\""

echo "apps-run secret policy (dry run)"
cp "$OV/usr/bin/apps-run" "$T/bin/apps-run"
run_policy() { APPS_RUN_DRYRUN=1 SECRETS_FILE="$T/secrets.env" MYLINUX_LIB="$OV/usr/lib/mylinux" sh "$T/bin/apps-run" "$@" 2>&1; }
out=$(run_policy chromium); has "browser gets no keys" "$out" "policy=none"; hasnt "browser: no key lines" "$out" "API_KEY"
out=$(run_policy firefox-esr --new-window); has "Firefox gets no keys" "$out" "policy=none"
out=$(run_policy remmina); has "Remmina gets no keys" "$out" "policy=none"
out=$(run_policy claude); has "Claude Code gets keys" "$out" "policy=all"; has "Claude Code: key exported" "$out" "OPENAI_API_KEY=sk-plain"
out=$(run_policy codex); has "Codex gets keys" "$out" "policy=all"
out=$(run_policy bash); has "a shell gets keys" "$out" "policy=all"
out=$(run_policy /usr/bin/git status); has "git (by path) gets keys" "$out" "policy=all"
out=$(APPS_SECRETS=none run_policy claude); has "APPS_SECRETS=none overrides" "$out" "policy=none"
out=$(APPS_SECRETS=all run_policy chromium); has "APPS_SECRETS=all overrides" "$out" "policy=all"

echo "usr/lib/mylinux/fetch.sh"
mkdir -p "$T/srv"; printf 'payload' > "$T/srv/good.bin"; GOODSUM=$(shasum -a 256 "$T/srv/good.bin" | cut -d' ' -f1)
cat > "$T/bin/curl" <<EOF
#!/bin/sh
out=""; url=""
while [ \$# -gt 0 ]; do case "\$1" in -o) out="\$2"; shift ;; http*) url="\$1" ;; esac; shift; done
f=\${url##*/}; [ -f "$T/srv/\$f" ] || exit 22
cp "$T/srv/\$f" "\$out"
EOF
printf '#!/bin/sh\nshasum -a 256 "$@"\n' > "$T/bin/sha256sum"
chmod +x "$T/bin/curl" "$T/bin/sha256sum"
: > "$T/manifest.env"
fetch_test() { ( PATH="$T/bin:$PATH" MANIFEST="$T/manifest.env"; . "$OV/usr/lib/mylinux/fetch.sh"; fetch_verified "$@" ) }
fetch_test http://x/good.bin "$GOODSUM" "$T/dl1" > /dev/null 2>&1; is_rc "matching checksum succeeds" $? 0; [ -f "$T/dl1" ] && ok "file in place" || ko "file missing"
fetch_test http://x/good.bin "0000" "$T/dl2" > /dev/null 2>&1; is_rc "checksum mismatch fails" $? 1; [ ! -e "$T/dl2" ] && [ ! -e "$T/dl2.part" ] && ok "mismatch leaves nothing behind" || ko "mismatch left a file"
fetch_test http://x/missing.bin "$GOODSUM" "$T/dl3" > /dev/null 2>&1; is_rc "failed download fails" $? 1; [ ! -e "$T/dl3.part" ] && ok "failed download leaves no partial file" || ko "partial file left"
out=$(fetch_test http://x/good.bin "" "$T/dl4" 2>&1); is_rc "no checksum: fetch succeeds" $? 0; has "no checksum is said out loud" "$out" "no upstream checksum"

echo "theme-install"
TI="$OV/usr/bin/theme-install"
is "owner/repo shorthand" "$(sh "$TI" basecamp/omarchy-nord-theme --dry-run)" "kind=github name=nord repo=basecamp/omarchy-nord-theme url="
is "GitHub URL" "$(sh "$TI" https://github.com/Someone/Omarchy-Rose-Pine-Theme.git --dry-run)" "kind=github name=rose-pine repo=Someone/Omarchy-Rose-Pine-Theme url="
is "GitHub tree URL" "$(sh "$TI" https://github.com/a/b/tree/main --dry-run)" "kind=github name=b repo=a/b url="
is "other git URL is git, not GitHub" "$(sh "$TI" https://codeberg.org/x/omarchy-ice-theme.git --dry-run)" "kind=git name=ice repo= url=https://codeberg.org/x/omarchy-ice-theme.git"
is "git:// URL" "$(sh "$TI" git://example.org/themes/dusk --dry-run)" "kind=git name=dusk repo= url=git://example.org/themes/dusk"
sh "$TI" "a/../etc" --dry-run > /dev/null 2>&1; is_rc "traversal in a GitHub path refused" $? 2
sh "$TI" "owner/.." --dry-run > /dev/null 2>&1; is_rc "dot-dot repository refused" $? 2
sh "$TI" "owner/omarchy--theme" --dry-run > /dev/null 2>&1; is_rc "empty theme name refused" $? 2
sh "$TI" "plainword" --dry-run > /dev/null 2>&1; is_rc "bare word refused" $? 2
sh "$TI" "" --dry-run > /dev/null 2>&1; is_rc "empty source refused" $? 2
# real installs from local fixtures: a fake curl serves tarballs from $T/srv by repository name
mkfixture() {  # name, then a command run inside the fixture's repo-HEAD directory
  n="$1"; shift; rm -rf "$T/fx/$n"; mkdir -p "$T/fx/$n/repo-HEAD"
  ( cd "$T/fx/$n/repo-HEAD" && "$@" )
  ( cd "$T/fx/$n" && tar -czf "$T/srv/$n.tgz" repo-HEAD )
}
cat > "$T/bin/curl" <<EOF
#!/bin/sh
out=""; url=""
while [ \$# -gt 0 ]; do case "\$1" in -o) out="\$2"; shift ;; http*) url="\$1" ;; esac; shift; done
repo=\$(printf '%s' "\$url" | sed 's#https://codeload.github.com/[^/]*/##; s#/tar.gz/HEAD##')
[ -f "$T/srv/\$repo.tgz" ] || exit 22
cp "$T/srv/\$repo.tgz" "\$out"
EOF
good() { printf 'background = "#101010"\nforeground = "#f0f0f0"\naccent = "#3366ff"\n' > colors.toml; mkdir backgrounds; printf 'png' > backgrounds/1.png; }
mkfixture omarchy-good-theme good
mkfixture nocolors sh -c 'echo readme > README.md'
mkfixture badpalette sh -c 'printf "background = \"#101010\"\n" > colors.toml'
mkfixture symlinked sh -c 'printf "background = \"#101010\"\nforeground = \"#f0f0f0\"\naccent = \"#3366ff\"\n" > colors.toml; ln -s /etc/passwd leak'
mkdir -p "$T/fx/trav/repo-HEAD"; printf 'background = "#101010"\nforeground = "#f0f0f0"\naccent = "#3366ff"\n' > "$T/fx/trav/repo-HEAD/colors.toml"; printf 'x' > "$T/fx/trav/escape"
( cd "$T/fx/trav" && tar -czf "$T/srv/trav.tgz" repo-HEAD ../trav/escape 2>/dev/null )
DEST="$T/themes"; mkdir -p "$DEST"
ti() { ( PATH="$T/bin:$PATH" THEME_DEST="$DEST" HOME="$T" sh "$TI" "$@" ) }
ti x/omarchy-good-theme > /dev/null 2>&1; is_rc "good theme installs" $? 0
[ -f "$DEST/good/colors.toml" ] && [ -f "$DEST/good/backgrounds/1.png" ] && ok "installed files in place" || ko "theme files missing"
printf 'marker' > "$DEST/good/marker"
ti x/nocolors > /dev/null 2>&1; is_rc "repository without colors.toml fails" $? 1
ti x/badpalette > /dev/null 2>&1; is_rc "palette without foreground fails" $? 1
ti x/symlinked > /dev/null 2>&1; is_rc "theme with a symlink refused" $? 1
ti x/trav > /dev/null 2>&1; is_rc "archive with a path outside the theme refused" $? 1
[ ! -e "$DEST/escape" ] && [ ! -e "$T/escape" ] && ok "nothing extracted outside staging" || ko "traversal file appeared"
ti x/missing > /dev/null 2>&1; rc=$?; [ $rc -ne 0 ] && ok "failed download fails" || ko "failed download returned 0"
[ -f "$DEST/good/marker" ] && ok "existing theme untouched by the failures" || ko "existing theme lost"
mkfixture omarchy-good-theme sh -c 'printf "background = \"#202020\"\nforeground = \"#f0f0f0\"\naccent = \"#3366ff\"\n" > colors.toml'
ti x/omarchy-good-theme > /dev/null 2>&1; is_rc "reinstall succeeds" $? 0
grep -q 202020 "$DEST/good/colors.toml" && [ ! -e "$DEST/good/marker" ] && ok "theme replaced wholesale" || ko "theme not replaced"
[ -z "$(ls -A "$DEST" | grep '^\.')" ] && ok "no staging directories left" || ko "staging left: $(ls -A "$DEST")"

echo "clipboard: host side (tools/clipboard-host.sh) with fake pbpaste/pbcopy"
C="$T/clip"; mkdir -p "$C"
printf '#!/bin/sh\ncat "%s/pasteboard"\n' "$T" > "$T/bin/pbpaste"
printf '#!/bin/sh\ncat > "%s/pasteboard"; cp "%s/pasteboard" "%s/pbcopy.last"\n' "$T" "$T" "$T" > "$T/bin/pbcopy"
chmod +x "$T/bin/pbpaste" "$T/bin/pbcopy"
host_once() { ( PATH="$T/bin:$PATH" sh "$REPO/tools/clipboard-host.sh" "$C" once ); }
printf 'line one\nline two\n' > "$T/pasteboard"; host_once
same "multiline text with a trailing newline reaches mac.txt byte-exact" "$C/mac.txt" "$T/pasteboard"; is "sequence 1" "$(cat "$C/mac.seq")" 1
host_once; is "unchanged text: no new sequence" "$(cat "$C/mac.seq")" 1
printf 'ünïcödé — 日本語 🎉' > "$T/pasteboard"; host_once; same "Unicode without trailing newline byte-exact" "$C/mac.txt" "$T/pasteboard"; is "sequence 2" "$(cat "$C/mac.seq")" 2
printf 'a' > "$T/pasteboard"; host_once; printf 'b' > "$T/pasteboard"; host_once; is "two updates in a row both counted" "$(cat "$C/mac.seq")" 4; is "latest content wins" "$(cat "$C/mac.txt")" b
: > "$T/pasteboard"; host_once; is "empty Mac text is not mirrored" "$(cat "$C/mac.seq")" 4; is "mac.txt keeps the last text" "$(cat "$C/mac.txt")" b
printf 'b' > "$T/pasteboard"; host_once; is "same value again after empty: no resend" "$(cat "$C/mac.seq")" 4
dd if=/dev/zero bs=1024 count=1100 2>/dev/null | tr '\0' 'x' > "$T/pasteboard"; host_once; is "text above 1 MB skipped" "$(cat "$C/mac.seq")" 4
printf 'guest says $(hi) `x` \\n' > "$C/guest.txt"; echo 1 > "$C/guest.seq"; host_once
same "guest text pbcopied byte-exact" "$T/pbcopy.last" "$C/guest.txt"
host_once; is "the guest text now on the pasteboard does not echo back as a new Mac sequence" "$(cat "$C/mac.seq")" 4
echo 1 > "$C/guest.seq"; rm -f "$T/pbcopy.last"; host_once; [ ! -e "$T/pbcopy.last" ] && ok "same guest sequence is not copied twice" || ko "guest text copied again"
: > "$C/guest.txt"; echo 2 > "$C/guest.seq"; host_once; [ ! -e "$T/pbcopy.last" ] && ok "empty guest text is not copied" || ko "empty guest text copied"

echo "clipboard: guest side (clipboard-bridge, clipboard-send) with a fake apps-run"
cat > "$T/bin/apps-run" <<EOF
#!/bin/sh
case "\$1" in wl-copy) cat > "$T/wlcopy.in"; echo x >> "$T/wlcopy.count" ;; wl-paste) cat "$T/selection" ;; esac
EOF
chmod +x "$T/bin/apps-run"
G="$T/gclip"; mkdir -p "$G"; rm -f "$T/wlcopy.count"
bridge_once() { ( PATH="$T/bin:$PATH" CLIPBOARD_ONESHOT=1 CLIP_DIR="$G" CLIP_OFF="$T/off" CLIP_STATE="$T/bridge.seq" sh "$OV/usr/bin/clipboard-bridge" ); }
printf 'from mac\n\n' > "$G/mac.txt"; echo 1 > "$G/mac.seq"; bridge_once
same "bridge applies mac.txt byte-exact (trailing newlines kept)" "$T/wlcopy.in" "$G/mac.txt"
bridge_once; is "a second pass with the same sequence does not copy again" "$(wc -l < "$T/wlcopy.count" | tr -d ' ')" 1
printf 'from mac\n\n' > "$G/mac.txt"; echo 2 > "$G/mac.seq"; bridge_once; is "identical content with a new sequence is applied again (explicit copy on the Mac)" "$(wc -l < "$T/wlcopy.count" | tr -d ' ')" 2
: > "$G/mac.txt"; echo 3 > "$G/mac.seq"; bridge_once; is "empty file is not applied" "$(wc -l < "$T/wlcopy.count" | tr -d ' ')" 2
touch "$T/off"; printf 'x' > "$G/mac.txt"; echo 4 > "$G/mac.seq"; bridge_once; is "sharing off: nothing applied" "$(wc -l < "$T/wlcopy.count" | tr -d ' ')" 2; rm -f "$T/off"
printf 'sel $(x) \n' > "$T/selection"
send_once() { ( PATH="$T/bin:$PATH" CLIP_DIR="$G" sh "$OV/usr/bin/clipboard-send" ); }
send_once; same "clipboard-send writes the selection byte-exact" "$G/guest.txt" "$T/selection"; is "guest sequence 1" "$(cat "$G/guest.seq")" 1
send_once; is "guest sequence 2" "$(cat "$G/guest.seq")" 2
: > "$T/selection"; send_once; is "empty selection not sent" "$(cat "$G/guest.seq")" 2
dd if=/dev/zero bs=1024 count=1100 2>/dev/null | tr '\0' 'y' > "$T/selection"; send_once > /dev/null 2>&1; is "selection above 1 MB not sent" "$(cat "$G/guest.seq")" 2
[ ! -e "$G/guest.txt.tmp" ] && ok "no temporary file left" || ko "temporary file left"

echo "color-scheme-apply"
CS="$OV/usr/bin/color-scheme-apply"; H="$T/home"; AR="$T/apps"; mkdir -p "$H/.config/gtk-3.0" "$AR/etc"
printf '[Settings]\ngtk-theme-name=Adwaita\ngtk-application-prefer-dark-theme=0\n' > "$H/.config/gtk-3.0/settings.ini"
( HOME_DIR="$H" APPS_ROOT="$AR" sh "$CS" dark ); is_rc "dark applies" $? 0
has "gtk-3.0 prefers dark" "$(cat "$H/.config/gtk-3.0/settings.ini")" "gtk-application-prefer-dark-theme=1"
has "other gtk-3.0 keys kept" "$(cat "$H/.config/gtk-3.0/settings.ini")" "gtk-theme-name=Adwaita"
is "the key appears once" "$(grep -c prefer-dark "$H/.config/gtk-3.0/settings.ini")" 1
has "gtk-4.0 created with the key" "$(cat "$H/.config/gtk-4.0/settings.ini")" "gtk-application-prefer-dark-theme=1"
has "Chromium gets the dark flag" "$(cat "$AR/etc/chromium.d/mylinux-appearance")" "force-dark-mode"
is "mode recorded" "$(cat "$H/.config/mylinux/appearance")" dark
( HOME_DIR="$H" APPS_ROOT="$AR" sh "$CS" light ); is_rc "light applies" $? 0
has "gtk-3.0 back to light" "$(cat "$H/.config/gtk-3.0/settings.ini")" "gtk-application-prefer-dark-theme=0"
hasnt "Chromium flag removed for light" "$(cat "$AR/etc/chromium.d/mylinux-appearance")" "force-dark-mode"
( HOME_DIR="$H" APPS_ROOT="$AR" sh "$CS" blue ) 2>/dev/null; is_rc "bad mode refused" $? 2

echo "usr/lib/mylinux/shell-run"
SR="$OV/usr/lib/mylinux/shell-run"; SRD="$T/shellrun"; mkdir -p "$SRD"
# a fake shell: counts its runs, crashes (SIGSEGV) the first two times, then waits for the stop flag and is "killed"
cat > "$SRD/myshell" <<EOF2
#!/bin/sh
n=\$(cat "$SRD/runs" 2>/dev/null || echo 0); n=\$((n + 1)); echo \$n > "$SRD/runs"
echo "log line of run \$n"
if [ \$n -le 2 ]; then printf 'myshell: fatal signal 11\\n0x1234\\n' > "$SRD/run/crash.txt"; kill -SEGV \$\$; fi
while [ ! -e "$SRD/run/stop" ]; do sleep 0.2; done
exit 143
EOF2
chmod +x "$SRD/myshell"
export MYLINUX_SHELL_RUN="$SRD/run" MYLINUX_SHELL_LOG="$SRD/shell.log" MYLINUX_SHELL_EXITS="$SRD/exits.log"
sh "$SR" "$SRD/myshell" 2>/dev/null & SRPID=$!
for i in $(seq 1 50); do [ "$(cat "$SRD/runs" 2>/dev/null)" = 3 ] && break; sleep 0.2; done
is "a crashed shell is started again" "$(cat "$SRD/runs")" 3
has "the exit is recorded with its signal" "$(cat "$SRD/exits.log")" "ended unexpectedly (signal 11)"
has "the end of the shell log is recorded" "$(cat "$SRD/exits.log")" "log line of run 1"
has "the crash report is recorded" "$(cat "$SRD/exits.log")" "myshell: fatal signal 11"
[ ! -e "$SRD/run/crash.txt" ] && ok "the crash report is not repeated for the next exit" || ko "crash report left behind"
touch "$SRD/run/stop"
for i in $(seq 1 30); do kill -0 $SRPID 2>/dev/null || break; sleep 0.2; done
kill -0 $SRPID 2>/dev/null && { ko "a deliberate stop ends shell-run"; kill $SRPID; } || ok "a deliberate stop ends shell-run"
is "a deliberate stop is not recorded as a crash" "$(grep -c 'ended unexpectedly' "$SRD/exits.log")" 2
# crash loop: a shell that always dies is given up on after MAX restarts
printf '#!/bin/sh\nexit 1\n' > "$SRD/broken"; chmod +x "$SRD/broken"; rm -f "$SRD/run/stop" "$SRD/exits.log"
MYLINUX_SHELL_MAX_RESTARTS=2 sh "$SR" "$SRD/broken"; is_rc "a crash loop gives up" $? 1
is "the crash loop ran MAX + 1 times" "$(grep -c 'ended unexpectedly' "$SRD/exits.log")" 3
has "giving up is recorded" "$(cat "$SRD/exits.log")" "giving up"
unset MYLINUX_SHELL_RUN MYLINUX_SHELL_LOG MYLINUX_SHELL_EXITS

if [ $fails -eq 0 ]; then echo "guest: all passed"; else echo "guest: $fails failed"; fi
exit $fails
