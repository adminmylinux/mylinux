# myLinux Apps, Claude Code subscriptions (the Claude Code row at the top, the dialog, cc1/cc2 aliases): driven by
# Textual's pilot in a scratch HOME, installs replaced by a recorder. Run by tools/tests/apps-claude.sh.
# Usage: HOME=<scratch> python3 apps_claude_pilot.py <server-apps dir>
import asyncio, json, os, stat, subprocess, sys
from pathlib import Path

sys.path.insert(0, sys.argv[1])
import mylinux_apps as m
from textual.widgets import Input

HOME = Path(os.environ["HOME"])
CAT = Path(sys.argv[1]) / "catalog.json"
FAKE = "sk-ant-oat01-" + "A" * 60
ran = []


async def main():
    app = m.MyLinuxApps(CAT)
    # no real installs: record what would run
    def fake_hand_over(script, banner, wait, env=None):
        ran.append((script, banner, dict(env or {})))
        return 0
    app.hand_over = fake_hand_over
    async with app.run_test(size=(140, 45)) as pilot:
        await pilot.pause()
        first = app.shown[0]
        assert first.setup and first.name == "Claude Code", first
        # Enter on it: the dialog, with cc1 and acc
        await pilot.press("enter"); await pilot.pause()
        dlg = app.screen
        assert type(dlg).__name__ == "ClaudeAccount", dlg
        assert dlg.query_one("#alias", Input).value == "cc1"
        assert dlg.query_one("#account", Input).value == "acc"
        assert dlg.query_one("#token", Input).password
        # a reserved alias is refused
        dlg.query_one("#alias", Input).value = "cc"
        dlg.query_one("#token", Input).value = FAKE
        dlg.action_ok(); await pilot.pause()
        assert "own aliases" in str(dlg.query_one("#error").render()), dlg.query_one("#error").render()
        dlg.query_one("#alias", Input).value = "cc1"
        dlg.query_one("#account", Input).value = "viktor_gmail"
        # Enter on the token field: the API key field is empty, so focus moves there; Enter again sets up
        dlg.query_one("#token", Input).focus(); await pilot.press("enter"); await pilot.pause()
        assert dlg.query_one("#apikey", Input).has_focus
        await pilot.press("enter"); await pilot.pause(); await pilot.pause()
        assert app.screen is not dlg
        env_file = HOME / ".config/mylinux/claude-accounts/cc1.env"
        assert stat.S_IMODE(env_file.stat().st_mode) == 0o600, oct(env_file.stat().st_mode)
        assert stat.S_IMODE(env_file.parent.stat().st_mode) == 0o700
        text = env_file.read_text()
        assert f"CLAUDE_CODE_OAUTH_TOKEN='{FAKE}'" in text and "MYLINUX_CLAUDE_ACCOUNT='viktor_gmail'" in text
        aliases = (HOME / ".config/mylinux/aliases.sh").read_text()
        assert "alias cc1='( . \"$HOME/.config/mylinux/claude-accounts/cc1.env\"" in aliases, aliases
        assert "alias cc=" in aliases                     # the catalog's defaults stay
        assert FAKE not in aliases                        # the token is not in the alias
        script, banner, env = ran[-1]
        assert "install/statusline" in script and "install/skills" not in script and FAKE not in script
        assert json.loads((HOME / ".claude.json").read_text())["hasCompletedOnboarding"] is True
        # the new row, under the cursor
        cur = app.current()
        assert cur.name == "cc1" and cur.account == "viktor_gmail", cur
        # a second one: cc2, with an API key: skills too, the key only in the environment
        app.move_to(app.apps[0]); await pilot.pause()
        await pilot.press("enter"); await pilot.pause()
        dlg = app.screen
        assert dlg.query_one("#alias", Input).value == "cc2"
        dlg.query_one("#account", Input).value = "work"
        dlg.query_one("#token", Input).value = "sk-ant-oat01-" + "B" * 60
        dlg.query_one("#apikey", Input).value = "mlx_testkey"
        dlg.action_ok(); await pilot.pause(); await pilot.pause()
        script, banner, env = ran[-1]
        assert "install/skills" in script and "mlx_testkey" not in script and env == {"MYLINUX_API_KEY": "mlx_testkey"}
        assert [n for n, _ in m.load_accounts()] == ["cc1", "cc2"]
        # ^U on cc1: a new token, the alias field locked
        app.move_to(next(x for x in app.apps if x.name == "cc1")); await pilot.pause()
        await pilot.press("ctrl+u"); await pilot.pause()
        dlg = app.screen
        assert type(dlg).__name__ == "ClaudeAccount" and dlg.query_one("#alias", Input).disabled
        assert dlg.query_one("#account", Input).value == "viktor_gmail"
        dlg.query_one("#token", Input).value = "sk-ant-oat01-" + "C" * 60
        dlg.action_ok(); await pilot.pause(); await pilot.pause()
        assert "C" * 60 in (HOME / ".config/mylinux/claude-accounts/cc1.env").read_text()
        # ^R on cc2: confirm, gone, and out of aliases.sh
        app.move_to(next(x for x in app.apps if x.name == "cc2")); await pilot.pause()
        await pilot.press("ctrl+r"); await pilot.pause()
        await pilot.press("enter"); await pilot.pause(); await pilot.pause()
        assert [n for n, _ in m.load_accounts()] == ["cc1"]
        assert "alias cc2=" not in (HOME / ".config/mylinux/aliases.sh").read_text()
        assert not any(x.name == "cc2" for x in app.apps)

asyncio.run(main())

# the alias itself, in a real shell: the token and account inside the subshell only, not after it
aliases = HOME / ".config/mylinux/aliases.sh"
fakebin = HOME / "bin"; fakebin.mkdir(exist_ok=True)
(fakebin / "claude").write_text('#!/bin/sh\n[ "$1" = update ] && exit 0\necho "claude as $MYLINUX_CLAUDE_ACCOUNT token=${CLAUDE_CODE_OAUTH_TOKEN#sk-ant-oat01-} api=${ANTHROPIC_API_KEY:-none} args=$*"\n')
(fakebin / "claude").chmod(0o755)
for shell in ("bash", "sh"):
    out = subprocess.run([shell, "-c", f'shopt -s expand_aliases 2>/dev/null; export PATH="{fakebin}:$PATH" ANTHROPIC_API_KEY=global CLAUDE_CODE_OAUTH_TOKEN=globaltok; . "{aliases}"\ncc1\necho "after: $CLAUDE_CODE_OAUTH_TOKEN ${{MYLINUX_CLAUDE_ACCOUNT:-unset}}"'],
                         capture_output=True, text=True, env=dict(os.environ))
    lines = out.stdout.strip().splitlines()
    assert lines[0] == "claude as viktor_gmail token=" + "C" * 60 + " api=none args=--dangerously-skip-permissions", (shell, out.stdout, out.stderr)
    assert lines[1] == "after: globaltok unset", (shell, lines)
print("pilot ok:", len(ran), "setups;", "alias checked in bash and sh")
