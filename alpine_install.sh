#!/bin/sh
# myLinux: set up an Alpine Server machine. Safe to run again.
#
# Install Script… in the myLinux menu of an Alpine terminal loads this file from GitHub
# (adminmylinux/mylinux, main), shows it, and runs it in the machine's terminal.
# Each "# option:" line is a checkbox in that dialog (1 = on, 0 = off): a new choice
# needs a line here and a block below, not a new launcher.
CLAUDE=1      # option: Claude Code
CODEX=1       # option: Codex
BTOP=1        # option: btop
TAILSCALE=1   # option: Tailscale

# plain sh: Alpine starts with BusyBox ash; bash comes with the packages below
# and becomes the login shell
set -eu
cd "$HOME"
mkdir -p "$HOME/.local/bin"

packages="bash bash-completion curl ca-certificates git tmux less"
# Claude Code on musl needs these
[ "$CLAUDE" = 1 ] && packages="$packages libgcc libstdc++ ripgrep"
[ "$BTOP" = 1 ] && packages="$packages btop"
[ "$TAILSCALE" = 1 ] && packages="$packages tailscale"
echo "== packages: $packages"
doas apk update -q
doas apk add -q $packages

if [ "$CLAUDE" = 1 ]; then
  echo "== Claude Code"
  curl -fsSL https://claude.ai/install.sh | bash
fi

if [ "$CODEX" = 1 ]; then
  echo "== Codex"
  asset=codex-$(uname -m)-unknown-linux-musl
  curl -fsSL -o /tmp/codex.tar.gz "https://github.com/openai/codex/releases/latest/download/$asset.tar.gz"
  tar -xzf /tmp/codex.tar.gz -C /tmp "$asset"
  install -m 0755 "/tmp/$asset" "$HOME/.local/bin/codex"
  rm -f /tmp/codex.tar.gz "/tmp/$asset"
fi

if [ "$TAILSCALE" = 1 ]; then
  echo "== Tailscale"
  doas rc-update add tailscale default >/dev/null
  doas rc-service tailscale start >/dev/null 2>&1 || true
fi

# bash as the login shell, reading ~/.bashrc; the PATH and the aliases in one marked block of it
echo "== shell setup"
me=$(id -un)
doas sed -i -E "s#^($me:([^:]*:){5}).*#\1/bin/bash#" /etc/passwd
[ -f "$HOME/.bash_profile" ] || printf '%s\n' '[ -f ~/.bashrc ] && . ~/.bashrc' > "$HOME/.bash_profile"
touch "$HOME/.bashrc"
sed -i '/^# >>> myLinux >>>$/,/^# <<< myLinux <<<$/d' "$HOME/.bashrc"
{
  echo '# >>> myLinux >>>'
  echo 'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac'
  [ "$CLAUDE" = 1 ] && echo "export USE_BUILTIN_RIPGREP=0"
  [ "$CLAUDE" = 1 ] && echo "alias cc='claude update && claude --dangerously-skip-permissions'"
  [ "$CODEX" = 1 ] && echo "alias cx='codex --full-auto'"
  echo '# <<< myLinux <<<'
} >> "$HOME/.bashrc"

echo "== done"
[ "$CLAUDE" = 1 ] && "$HOME/.local/bin/claude" --version
[ "$CODEX" = 1 ] && "$HOME/.local/bin/codex" --version
[ "$BTOP" = 1 ] && btop --version | head -1
if [ "$TAILSCALE" = 1 ]; then
  tailscale version | head -1
  # signing in prints a link (⌘-click it); it waits until you have, so it comes last
  doas tailscale status >/dev/null 2>&1 || doas tailscale up
fi
echo "Aliases: cc (Claude), cx (Codex); bash is the login shell now (this terminal switches to it)."
