#!/bin/sh
# Behaviour tests for claude-bootstrap/install.sh, offline: a scratch HOME, a stand-in claude on PATH (so nothing is
# downloaded or installed), no terminal. The token path, the API-key path (approved ahead in ~/.claude.json, with
# python3 and on a box with neither jq nor python3), and switching from one to the other.
# Usage: sh tools/tests/claude-bootstrap.sh
REPO=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/mylinux-bootstrap.XXXXXX")
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT
fails=0
ok() { echo "  ok   $1"; }
ko() { echo "  FAIL $1"; fails=$((fails + 1)); }
has() { printf '%s' "$2" | grep -qF -- "$3" && ok "$1" || ko "$1 (no '$3' in: $2)"; }
hasnt() { printf '%s' "$2" | grep -qF -- "$3" && ko "$1 ('$3' in: $2)" || ok "$1"; }

# a bin with only what the script needs (no jq, no python3 unless asked), and a claude that answers --version
mkbin() {
  b="$1"; mkdir -p "$b"
  for t in sh tr tail grep awk mktemp chmod mkdir cat dirname id uname touch mv rm printf head sed env bash curl stty; do
    p=$(command -v "$t" 2>/dev/null) && [ -n "$p" ] && [ -x "$p" ] && ln -sf "$p" "$b/$t"
  done
  printf '#!/bin/sh\necho "2.0.0 (Claude Code)"\n' > "$b/claude"; chmod +x "$b/claude"
}
run() {  # run HOME BIN [VAR=value ...]
  h="$1"; b="$2"; shift 2
  env -i HOME="$h" PATH="$b" CLAUDE_BOOTSTRAP_NO_START=1 "$@" sh "$REPO/claude-bootstrap/install.sh" </dev/null 2>&1
}
PYBIN="$T/bin-py"; mkbin "$PYBIN"; ln -sf "$(command -v python3)" "$PYBIN/python3"
MINBIN="$T/bin-min"; mkbin "$MINBIN"

echo "claude-bootstrap: a Claude Code token"
H="$T/home-token"; mkdir -p "$H"
out=$(run "$H" "$PYBIN" CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-abcdefghijklmnopqrstuvwxyz0123456789); rc=$?
[ $rc -eq 0 ] && ok "it ends well" || ko "it ends well (rc $rc: $out)"
f=$(cat "$H/.config/claude/oauth-token.sh" 2>/dev/null)
has "the token is saved" "$f" "export CLAUDE_CODE_OAUTH_TOKEN='sk-ant-oat01-abcdefghijklmnopqrstuvwxyz0123456789'"
[ "$(stat -f %Lp "$H/.config/claude/oauth-token.sh" 2>/dev/null || stat -c %a "$H/.config/claude/oauth-token.sh")" = 600 ] && ok "only its owner reads it" || ko "only its owner reads it"
has "onboarding is marked done" "$(cat "$H/.claude.json")" '"hasCompletedOnboarding": true'
hasnt "no API key is approved" "$(cat "$H/.claude.json")" "customApiKeyResponses"
has "~/.profile loads it" "$(cat "$H/.profile")" ".config/claude/oauth-token.sh"

echo "claude-bootstrap: an Anthropic API key, with python3"
H="$T/home-key"; mkdir -p "$H"; printf '{"theme": "dark", "numStartups": 3}\n' > "$H/.claude.json"
KEY=sk-ant-api03-ZYXWVUTSRQPONMLKJIHGFEDCBA9876543210-abc
out=$(run "$H" "$PYBIN" ANTHROPIC_API_KEY=$KEY); rc=$?
[ $rc -eq 0 ] && ok "it ends well" || ko "it ends well (rc $rc: $out)"
f=$(cat "$H/.config/claude/oauth-token.sh")
has "the API key is saved" "$f" "export ANTHROPIC_API_KEY='$KEY'"
has "a token from before does not stay beside it" "$f" "unset CLAUDE_CODE_OAUTH_TOKEN"
j=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("hasCompletedOnboarding"), d["customApiKeyResponses"]["approved"], d["theme"], d["numStartups"])' "$H/.claude.json" 2>&1)
has "its last 20 characters are approved" "$j" "True ['$(printf '%s' "$KEY" | tail -c 20)']"
has "  (the file's own settings)" "$j" "dark 3"
out=$(run "$H" "$PYBIN" ANTHROPIC_API_KEY=$KEY)
n=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["customApiKeyResponses"]["approved"]))' "$H/.claude.json")
[ "$n" = 1 ] && ok "a second run approves it once" || ko "a second run approves it once ($n)"

echo "claude-bootstrap: an Anthropic API key, without jq or python3"
H="$T/home-min"; mkdir -p "$H"
out=$(run "$H" "$MINBIN" ANTHROPIC_API_KEY=$KEY); rc=$?
[ $rc -eq 0 ] && ok "it ends well" || ko "it ends well (rc $rc: $out)"
j=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["hasCompletedOnboarding"], d["customApiKeyResponses"])' "$H/.claude.json" 2>&1)
has "valid JSON, onboarding done and the key approved" "$j" "True {'approved': ['$(printf '%s' "$KEY" | tail -c 20)'], 'rejected': []}"
printf '{"theme": "light"}\n' > "$H/.claude.json"
out=$(run "$H" "$MINBIN" ANTHROPIC_API_KEY=$KEY)
j=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["hasCompletedOnboarding"], d["theme"], d["customApiKeyResponses"]["approved"])' "$H/.claude.json" 2>&1)
has "an existing file keeps its settings and gains both" "$j" "True light ['$(printf '%s' "$KEY" | tail -c 20)']"

echo "claude-bootstrap: a token after an API key"
H="$T/home-key"
out=$(run "$H" "$PYBIN" CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-second0123456789)
f=$(cat "$H/.config/claude/oauth-token.sh")
has "the token replaces the key" "$f" "export CLAUDE_CODE_OAUTH_TOKEN='sk-ant-oat01-second0123456789'"
hasnt "the key is gone from the file" "$f" "ANTHROPIC_API_KEY"
out=$(run "$H" "$PYBIN")
has "a run with neither reuses the saved token" "$out" "Using the token already saved"

echo "claude-bootstrap: refused input"
H="$T/home-bad"; mkdir -p "$H"
out=$(run "$H" "$PYBIN" ANTHROPIC_API_KEY="sk-ant-api03-bad;rm -rf x"); rc=$?
[ $rc -ne 0 ] && ok "a key with shell characters is refused" || ko "a key with shell characters is refused"
[ ! -e "$H/.config/claude/oauth-token.sh" ] && ok "  and nothing is saved" || ko "  and nothing is saved"

[ $fails -eq 0 ] && echo "claude-bootstrap: all passed" || { echo "claude-bootstrap: $fails failed"; exit 1; }
