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
BUN=1         # option: Bun
TAILSCALE=1   # option: Tailscale

# plain sh: Alpine starts with BusyBox ash; bash comes with the packages below
# and becomes the login shell
set -eu
cd "$HOME"
mkdir -p "$HOME/.local/bin"

packages="bash bash-completion curl ca-certificates git tmux less"
# Claude Code on musl needs these
[ "$CLAUDE" = 1 ] && packages="$packages libgcc libstdc++ ripgrep"
# Codex reads its background server's start time with a full ps; BusyBox's cannot give it
[ "$CODEX" = 1 ] && packages="$packages procps"
[ "$BTOP" = 1 ] && packages="$packages btop"
[ "$BUN" = 1 ] && packages="$packages unzip"                 # Bun's installer stops without unzip
echo "== packages: $packages"
doas apk update -q
doas apk add -q $packages

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

# bash as the login shell, reading ~/.bashrc; the PATH and the aliases in one marked block of it
if [ "$BUN" = 1 ]; then
  echo "== Bun"
  curl -fsSL https://bun.sh/install | bash
fi

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
  [ "$CODEX" = 1 ] && echo "alias cx='codex --dangerously-bypass-approvals-and-sandbox'"
  echo '# <<< myLinux <<<'
} >> "$HOME/.bashrc"

echo "== done"
[ "$CLAUDE" = 1 ] && "$HOME/.local/bin/claude" --version
[ "$CODEX" = 1 ] && "$HOME/.local/bin/codex" --version
[ "$BTOP" = 1 ] && btop --version | head -1
[ "$BUN" = 1 ] && echo "bun $("$HOME/.bun/bin/bun" --version)"
echo "Aliases: cc (Claude), cx (Codex); bash is the login shell now (this terminal switches to it)."

# Tailscale last: signing in waits for a browser, and nothing else should wait behind it
if [ "$TAILSCALE" = 1 ]; then
  echo "== Tailscale"
  doas apk add -q tailscale
  doas rc-update add tailscale default >/dev/null
  doas rc-service tailscale start >/dev/null 2>&1 || true
  tailscale version | head -1
  if ! doas tailscale status >/dev/null 2>&1; then
    echo "Sign in with the link below (⌘-click opens it). Ctrl-C skips; sign in later with: doas tailscale up"
    # Ctrl-C ends only the sign-in: the script still finishes, so the terminal still switches to the new setup
    trap 'echo; echo "Skipped. Sign in later with: doas tailscale up"' INT
    doas tailscale up || true
    trap - INT
  fi
fi
