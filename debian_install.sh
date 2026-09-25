#!/bin/bash
# myLinux: set up a Debian Server machine. Safe to run again.
#
# Install Script… in the myLinux menu of a Debian terminal loads this file from GitHub
# (adminmylinux/mylinux, main), shows it, and runs it in the machine's terminal.
# Each "# option:" line is a checkbox in that dialog (1 = on, 0 = off): a new choice
# needs a line here and a block below, not a new launcher.
CLAUDE=1      # option: Claude Code
CODEX=1       # option: Codex
BTOP=1        # option: btop
TAILSCALE=1   # option: Tailscale

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
cd "$HOME"
mkdir -p "$HOME/.local/bin"

packages="curl ca-certificates git tmux"
[ "$BTOP" = 1 ] && packages="$packages btop"
echo "== packages: $packages"
sudo apt-get update -q
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q $packages

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
  command -v tailscale >/dev/null || curl -fsSL https://tailscale.com/install.sh | sh
fi

# the PATH and the aliases, in one marked block of ~/.bashrc (replaced on a rerun, so nothing piles up)
echo "== shell setup"
touch "$HOME/.bashrc"
sed -i '/^# >>> myLinux >>>$/,/^# <<< myLinux <<<$/d; /^# >>> myLinux agents >>>$/,/^# <<< myLinux agents <<<$/d' "$HOME/.bashrc"
{
  echo '# >>> myLinux >>>'
  echo 'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac'
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
  sudo tailscale status >/dev/null 2>&1 || sudo tailscale up
fi
echo "Aliases: cc (Claude), cx (Codex); new shells have them (this one after: source ~/.bashrc)."
