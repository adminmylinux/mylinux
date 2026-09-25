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
BUN=1         # option: Bun
TAILSCALE=1   # option: Tailscale

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
cd "$HOME"
mkdir -p "$HOME/.local/bin"

packages="curl ca-certificates git tmux"
[ "$BTOP" = 1 ] && packages="$packages btop"
[ "$BUN" = 1 ] && packages="$packages unzip"                 # Bun's installer stops without unzip
echo "== packages: $packages"
sudo apt-get update -q
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q $packages

if [ "$CLAUDE" = 1 ]; then
  echo "== Claude Code"
  curl -fsSL https://claude.ai/install.sh | bash
fi

if [ "$CODEX" = 1 ]; then
  echo "== Codex"
  # OpenAI's standalone installer: ~/.local/bin/codex and its package in ~/.codex (the bare release binary no
  # longer runs on its own); no questions asked
  curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh
fi

# the PATH and the aliases, in one marked block of ~/.bashrc (replaced on a rerun, so nothing piles up)
if [ "$BUN" = 1 ]; then
  echo "== Bun"
  curl -fsSL https://bun.sh/install | bash
fi

echo "== shell setup"
touch "$HOME/.bashrc"
sed -i '/^# >>> myLinux >>>$/,/^# <<< myLinux <<<$/d; /^# >>> myLinux agents >>>$/,/^# <<< myLinux agents <<<$/d' "$HOME/.bashrc"
{
  echo '# >>> myLinux >>>'
  echo 'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac'
  [ "$CLAUDE" = 1 ] && echo "alias cc='claude update && claude --dangerously-skip-permissions'"
  [ "$CODEX" = 1 ] && echo "alias cx='codex --dangerously-bypass-approvals-and-sandbox'"
  echo '# <<< myLinux <<<'
} >> "$HOME/.bashrc"

echo "== done"
[ "$CLAUDE" = 1 ] && "$HOME/.local/bin/claude" --version
[ "$CODEX" = 1 ] && "$HOME/.local/bin/codex" --version
[ "$BTOP" = 1 ] && btop --version | head -1
[ "$BUN" = 1 ] && echo "bun $("$HOME/.bun/bin/bun" --version)"
echo "Aliases: cc (Claude), cx (Codex); new shells have them (this one after: source ~/.bashrc)."

# Tailscale last: signing in waits for a browser, and nothing else should wait behind it
if [ "$TAILSCALE" = 1 ]; then
  echo "== Tailscale"
  command -v tailscale >/dev/null || curl -fsSL https://tailscale.com/install.sh | sh
  tailscale version | head -1
  if ! sudo tailscale status >/dev/null 2>&1; then
    echo "Sign in with the link below (⌘-click opens it). Ctrl-C skips; sign in later with: sudo tailscale up"
    # Ctrl-C ends only the sign-in: the script still finishes, so the terminal still switches to the new setup
    trap 'echo; echo "Skipped. Sign in later with: sudo tailscale up"' INT
    sudo tailscale up || true
    trap - INT
  fi
fi
