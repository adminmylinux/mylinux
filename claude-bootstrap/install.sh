#!/bin/sh
# Claude Code bootstrap: install Claude Code, log in with a long-lived token, start it.
#
#   curl -fsSL https://mylinux.app/claude | sh
#   (the same file: https://raw.githubusercontent.com/adminmylinux/mylinux/main/claude-bootstrap/install.sh)
#
# The token comes from `claude setup-token` on a machine that is already logged in. It is asked for (not
# echoed), or taken from $CLAUDE_CODE_OAUTH_TOKEN when that is set; an Anthropic API key in $ANTHROPIC_API_KEY
# (and no token) is used instead, approved ahead so Claude Code does not ask about it
# (https://mylinux.app/install/claude hands over the one you saved there). Nothing secret lives in this script.
# Plain sh, so it runs on a fresh Alpine (BusyBox ash, no bash) as well as Debian, Arch/Omarchy and macOS.
#
# Options (environment):
#   CLAUDE_BOOTSTRAP_NO_START=1   install and log in, but do not start claude
set -eu

TOKEN_FILE="$HOME/.config/claude/oauth-token.sh"

say()  { printf '\033[1;33m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;31m!!\033[0m %s\n' "$*" >&2; }
die()  { warn "$*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# Under `curl ... | sh` stdin is the script itself, so the prompt and the final claude session use the terminal.
if [ -r /dev/tty ] && (: </dev/tty) 2>/dev/null; then TTY=/dev/tty; else TTY=""; fi

case "$(uname -s)" in
  Linux|Darwin) ;;
  *) die "unsupported OS: $(uname -s) (Linux and macOS only)" ;;
esac

# root runs package managers itself; anyone else through sudo or doas (they ask on the terminal if they must)
as_root() {
  if [ "$(id -u)" = 0 ]; then "$@"
  elif have sudo; then sudo "$@"
  elif have doas; then doas "$@"
  else die "need root for: $* (no sudo or doas)"; fi
}

# --- 0. what the official installer and Claude Code need ----------------------------------------------------
EXTRA_ENV=""
if have apk; then
  # Alpine: the installer is a bash script, and the native build is linked for glibc's C++ runtime pieces that
  # musl systems add as packages; Claude Code's own ripgrep does not run on musl, the system one does
  need=""
  for p in bash curl libgcc libstdc++ ripgrep; do apk info -e "$p" >/dev/null 2>&1 || need="$need $p"; done
  if [ -n "$need" ]; then say "Installing for Alpine:$need"; as_root apk add --no-cache $need; fi
  EXTRA_ENV="export USE_BUILTIN_RIPGREP=0"
elif have pacman; then
  have curl || { say "Installing curl"; as_root pacman -S --needed --noconfirm curl; }
elif have apt-get; then
  have curl || { say "Installing curl"; as_root apt-get update -qq; as_root apt-get install -y -qq curl ca-certificates; }
fi
have curl || die "curl is required"
have bash || die "bash is required by Claude Code's installer"

# --- 1. token (or an API key) -------------------------------------------------------------------------------
token="${CLAUDE_CODE_OAUTH_TOKEN:-}"
apikey=""
[ -z "$token" ] && apikey="$(printf '%s' "${ANTHROPIC_API_KEY:-}" | tr -d '[:space:]')"
if [ -n "$apikey" ]; then
  case "$apikey" in *[!A-Za-z0-9_-]*) die "that does not look like an API key (letters, digits, - and _ only)" ;; esac
  case "$apikey" in sk-ant-api*) ;; *) warn "the API key does not start with sk-ant-api; continuing anyway" ;; esac
fi
if [ -z "$token" ] && [ -z "$apikey" ] && [ -f "$TOKEN_FILE" ]; then
  token="$(. "$TOKEN_FILE"; printf '%s' "${CLAUDE_CODE_OAUTH_TOKEN:-}")"
  [ -n "$token" ] && say "Using the token already saved in $TOKEN_FILE"
fi
if [ -z "$token" ] && [ -z "$apikey" ]; then
  [ -n "$TTY" ] || die "no terminal to ask for the token; set CLAUDE_CODE_OAUTH_TOKEN and run again"
  printf 'Paste your Claude Code token (from `claude setup-token`, input hidden): ' >"$TTY"
  stty -echo <"$TTY" 2>/dev/null || true
  IFS= read -r token <"$TTY" || true
  stty echo <"$TTY" 2>/dev/null || true
  printf '\n' >"$TTY"
fi
if [ -z "$apikey" ]; then
  token="$(printf '%s' "$token" | tr -d '[:space:]')"
  [ -n "$token" ] || die "no token given"
  case "$token" in
    *[!A-Za-z0-9_-]*) die "that does not look like a token (letters, digits, - and _ only)" ;;
  esac
  case "$token" in
    sk-ant-oat*) ;;
    *) warn "the token does not start with sk-ant-oat; continuing anyway" ;;
  esac
fi

mkdir -p "$(dirname "$TOKEN_FILE")"
# the file holds one of the two: with both, the API key would win over the subscription
( umask 077
  { if [ -n "$apikey" ]; then printf "unset CLAUDE_CODE_OAUTH_TOKEN\nexport ANTHROPIC_API_KEY='%s'\n" "$apikey"
    else printf "export CLAUDE_CODE_OAUTH_TOKEN='%s'\n" "$token"; fi
    if [ -n "$EXTRA_ENV" ]; then printf '%s\n' "$EXTRA_ENV"; fi; } >"$TOKEN_FILE" )
chmod 600 "$TOKEN_FILE"
if [ -n "$apikey" ]; then say "API key saved in $TOKEN_FILE (mode 600)"; else say "Token saved in $TOKEN_FILE (mode 600)"; fi

# Every new shell loads the token and finds ~/.local/bin: ~/.profile for login shells (Alpine's ash reads only
# that), ~/.bashrc for bash, ~/.zshrc when zsh is there.
for rc in "$HOME/.profile" "$HOME/.bashrc" "$HOME/.zshrc"; do
  case "$rc" in *.zshrc) [ -f "$rc" ] || have zsh || continue ;; esac
  touch "$rc"
  if ! grep -qF "$TOKEN_FILE" "$rc"; then
    {
      printf '\n# Claude Code (added by claude-bootstrap)\n'
      printf '[ -f "%s" ] && . "%s"\n' "$TOKEN_FILE" "$TOKEN_FILE"
      printf 'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac\n'
    } >>"$rc"
    say "Added the token loader to $rc"
  fi
done

. "$TOKEN_FILE"
export PATH="$HOME/.local/bin:$PATH"

# --- 2. install Claude Code ---------------------------------------------------------------------------------
if have claude; then
  say "Claude Code is already installed: $(claude --version 2>/dev/null || echo 'version unknown')"
else
  say "Installing Claude Code (the official installer)"
  inst="$(mktemp)"
  curl -fsSL https://claude.ai/install.sh -o "$inst" || { rm -f "$inst"; die "could not download the installer"; }
  bash "$inst" </dev/null || { rm -f "$inst"; die "the installer failed"; }
  rm -f "$inst"
  hash -r 2>/dev/null || true
  have claude || die "claude is not on PATH after the install"
fi

# --- 3. skip the first-run screens (the login comes from the token), and approve an API key ahead -------------
# Claude Code keeps its approved API keys by their last 20 characters in ~/.claude.json
cfg="$HOME/.claude.json"
approve="$(printf '%s' "$apikey" | tail -c 20)"
[ -s "$cfg" ] || printf '{}\n' >"$cfg"
tmp="$(mktemp)"
if have jq; then
  jq --arg k "$approve" '.hasCompletedOnboarding = true
    | if $k == "" then . else .customApiKeyResponses.approved = ((.customApiKeyResponses.approved // []) - [$k] + [$k])
      | .customApiKeyResponses.rejected = ((.customApiKeyResponses.rejected // []) - [$k]) end' "$cfg" >"$tmp" && mv "$tmp" "$cfg"
elif have python3; then
  python3 - "$cfg" "$approve" <<'PY'
import json, sys
p, k = sys.argv[1], sys.argv[2]
d = json.load(open(p))
d["hasCompletedOnboarding"] = True
if k:
    r = d.setdefault("customApiKeyResponses", {})
    r["approved"] = [x for x in r.get("approved", []) if x != k] + [k]
    r["rejected"] = [x for x in r.get("rejected", []) if x != k]
json.dump(d, open(p, "w"), indent=2)
PY
  rm -f "$tmp"
else
  # no jq or python3 (a minimal box): the keys go right after the first "{" when they are not there yet
  add=""
  grep -q '"hasCompletedOnboarding": *true' "$cfg" || add='"hasCompletedOnboarding": true,'
  if [ -n "$approve" ] && ! grep -q '"customApiKeyResponses"' "$cfg"; then
    add="$add \"customApiKeyResponses\": {\"approved\": [\"$approve\"], \"rejected\": []},"
  elif [ -n "$approve" ] && ! grep -qF "\"$approve\"" "$cfg"; then
    warn "add the API key to customApiKeyResponses in $cfg by hand, or approve it when claude asks"
  fi
  if [ -n "$add" ]; then
    # an empty object takes them without the trailing comma
    if [ "$(tr -d ' \n' <"$cfg")" = "{}" ]; then printf '{%s}\n' "${add%,}" >"$cfg"
    else awk -v a="$add" '!done && sub(/\{/, "{" a) { done = 1 } { print }' "$cfg" >"$tmp" && mv "$tmp" "$cfg"; fi
  fi
  rm -f "$tmp"
fi

# --- 4. start -----------------------------------------------------------------------------------------------
say "Done. New shells pick up the token by themselves."
if [ "${CLAUDE_BOOTSTRAP_NO_START:-}" = 1 ] || [ -z "$TTY" ]; then
  say "Start it with: exec \$SHELL -l, then claude"
  exit 0
fi
say "Starting claude..."
cd "$HOME"
exec claude <"$TTY" >"$TTY" 2>&1
