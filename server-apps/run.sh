#!/bin/sh
# myLinux Apps on a Debian or Alpine machine: find, run and install programs (mylinux_apps.py, catalog.json).
# Apps… in the launcher's CMD menu copies this folder into the machine's Mac share (/mnt/mac/.mylinux/apps) and
# types `sh /mnt/mac/.mylinux/apps/run.sh` into the terminal. The first time, it installs Python's Textual from the
# distribution (Alpine: py3-textual, Debian: python3-textual, Omarchy: python-textual) and adds the command
# mylinux-apps to ~/.local/bin. In Omarchy, Apps… (⇧⌘A) in its window has the session agent open a terminal running it.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
# Alpine (apk, doas), Omarchy (Arch: pacman, sudo, which asks for the password), Debian (apt, sudo)
if command -v apk >/dev/null 2>&1; then
  ROOT=doas
  textual() { doas apk update -q >/dev/null && doas apk add -q python3 py3-textual; }
elif command -v pacman >/dev/null 2>&1; then
  ROOT=sudo
  # from the package lists as they are (as Omarchy's own omarchy-pkg-add does); when those are too old for the mirrors
  # (a 404), synced first. Not a full upgrade: Try Omarchy holds back its kernel and Hyprland (IgnorePkg), so one stops.
  textual() { sudo pacman -S --needed --noconfirm python-textual || sudo pacman -Sy --needed --noconfirm python-textual; }
else
  ROOT=sudo
  textual() { sudo apt-get update -q >/dev/null && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q python3 python3-textual; }
fi
if ! python3 -c 'import textual' >/dev/null 2>&1; then
  echo "myLinux Apps: installing Python's Textual (once) ..."
  textual
fi
# mylinux-apps starts it again from any shell (the share is there whenever the machine runs)
mkdir -p "$HOME/.local/bin"
CMD="$HOME/.local/bin/mylinux-apps"
WANT=$(printf '#!/bin/sh\n# myLinux Apps (the launcher'"'"'s Apps… keeps the files up to date in the Mac share)\nexec sh "%s/run.sh" "$@"\n' "$HERE")
if [ "$(cat "$CMD" 2>/dev/null)" != "$WANT" ]; then printf '%s\n' "$WANT" > "$CMD" && chmod 755 "$CMD"; fi
# what the installers put in ~/.local/bin (Claude Code, Codex, uv), ~/.bun/bin and ~/.cargo/bin: on the PATH of every
# new shell (~/.profile for Alpine's ash and login shells, ~/.bashrc for bash), in one marked block kept up to date
PATHLINE='for d in "$HOME/.local/bin" "$HOME/.bun/bin" "$HOME/.cargo/bin"; do case ":$PATH:" in *":$d:"*) ;; *) PATH="$d:$PATH" ;; esac; done; export PATH'
# the aliases turned on in the app (Aliases, at the top: cc, cx, ...), which keeps them in this file
ALIASLINE='[ -f "$HOME/.config/mylinux/aliases.sh" ] && . "$HOME/.config/mylinux/aliases.sh"'
for rc in "$HOME/.profile" "$HOME/.bashrc"; do
  touch "$rc"
  if ! grep -qxF "$PATHLINE" "$rc" || ! grep -qxF "$ALIASLINE" "$rc"; then
    sed -i '/^# >>> myLinux Apps >>>$/,/^# <<< myLinux Apps <<<$/d' "$rc"
    {
      echo '# >>> myLinux Apps >>>'
      echo "$PATHLINE"
      # Claude Code's own ripgrep is built for glibc; on Alpine it uses the system's (the catalog installs ripgrep)
      [ "$ROOT" = doas ] && echo 'export USE_BUILTIN_RIPGREP=0'
      echo "$ALIASLINE"
      echo '# <<< myLinux Apps <<<'
    } >> "$rc"
  fi
done
# nothing compiled into the Mac's folder
export PYTHONDONTWRITEBYTECODE=1
python3 "$HERE/mylinux_apps.py" "$HERE/catalog.json" "$@"
# the shell this was started from still has the PATH it began with: a new program is found in a new shell
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) [ -n "${MYLINUX_APPS_RELOGIN:-}" ] || echo "myLinux Apps: new programs are found in a new shell (exec \$SHELL -l)" ;; esac
