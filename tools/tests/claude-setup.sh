#!/bin/sh
# Claude Install… (the launcher's wizard for Omarchy), the part inside the machine: server-apps/claude_setup.py in a
# scratch HOME and share with stand-in installers (claude_setup_test.py), and the agent's request check
# (omarchy-session --selftest). Offline; nothing is downloaded or installed.
cd "$(dirname "$0")/../.."
python3 tools/tests/claude_setup_test.py || exit 1
python3 omarchy/session/omarchy-session --selftest
