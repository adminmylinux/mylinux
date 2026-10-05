#!/bin/sh
# myLinux Apps' Claude Code subscriptions, with Textual's pilot (apps_claude_pilot.py) in a scratch HOME: the dialog,
# its checks, the token file (600), the aliases, skills only with an API key, a new token, removal, and each alias in
# bash and sh using its own token only in its subshell. Skipped when this python3 has no Textual
# (python3 -m pip install textual, or PYTHON=<a venv's python> to pick one).
cd "$(dirname "$0")/../.."
PY=${PYTHON:-python3}
if ! "$PY" -c 'import textual' >/dev/null 2>&1; then echo "apps-claude: no Textual for $PY: skipped (verification gap)"; exit 0; fi
H=$(mktemp -d); trap 'rm -rf "$H"' EXIT
HOME="$H" "$PY" tools/tests/apps_claude_pilot.py "$PWD/server-apps"
