#!/usr/bin/env python3
"""Behaviour tests for server-apps/claude_setup.py (Claude Install…, the part inside the machine), offline: a scratch
HOME and a scratch share, and a stand-in curl on PATH that hands out stand-in installers (Claude Code's, the status
line's, the skills'), so nothing is downloaded or installed. What a subscription added here leaves behind is compared
with what myLinux Apps writes for one (mylinux_apps.py, loaded with stand-ins for Textual), and the lines of run.sh's
block with run.sh. Usage: python3 tools/tests/claude_setup_test.py   (tools/tests/claude-setup.sh runs it)
"""
from __future__ import annotations

import importlib.util
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import types
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "server-apps/claude_setup.py"
TOKEN = "sk-ant-oat01-TESTtestTESTtestTESTtestTESTtest0123456789"
TOKEN2 = "sk-ant-oat01-OTHERotherOTHERotherOTHERother9876543210"
APIKEY = "mlx_TESTtestTESTtest0123"
fails = 0


def check(what: str, good: bool, detail: object = "") -> None:
    global fails
    print(("  ok   " if good else "  FAIL ") + what + ("" if good or detail == "" else f" ({detail})"))
    fails += 0 if good else 1


FAKE_CLAUDE = """#!/bin/sh
case "${1:-}" in
  --version) echo "9.9.9 (Claude Code)" ;;
  update) ;;
  *) echo "claude as ${MYLINUX_CLAUDE_ACCOUNT:-nobody} token ${CLAUDE_CODE_OAUTH_TOKEN:-none} key ${ANTHROPIC_API_KEY:-none}" ;;
esac
"""
INSTALLERS = {
    "claude": 'mkdir -p "$HOME/.local/bin"\ncat > "$HOME/.local/bin/claude" <<\'EOF\'\n' + FAKE_CLAUDE + 'EOF\nchmod 755 "$HOME/.local/bin/claude"\necho "Claude Code installed"\n',
    "statusline": 'mkdir -p "$HOME/.claude"\nprintf \'#!/bin/sh\\necho "$MYLINUX_CLAUDE_ACCOUNT"\\n\' > "$HOME/.claude/statusline.sh"\n'
                  'printf \'{"statusLine": {"type": "command", "command": "~/.claude/statusline.sh", "refreshInterval": 10}}\\n\' > "$HOME/.claude/settings.json"\n'
                  'echo "statusLine set"\n',
    "skills": 'mkdir -p "$HOME/.claude" "$HOME/.config/mylinux"\nprintf %s "$MYLINUX_API_KEY" > "$HOME/.config/mylinux/api-key"\necho "skills for ${MYLINUX_API_KEY:+a key}" > "$HOME/.claude/skills-ran"\n',
}
CURL = """#!/bin/sh
# a stand-in for curl: the installers this test knows, by URL ($STUB_FAIL names one that is not reachable)
out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    --retry|--connect-timeout) shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
case "$url" in
  https://claude.ai/install.sh) what=claude ;;
  */install/statusline) what=statusline ;;
  */install/skills) what=skills ;;
  *) echo "curl: unexpected $url" >&2; exit 22 ;;
esac
[ "${STUB_FAIL:-}" = "$what" ] && { echo "curl: (6) Could not resolve host" >&2; exit 6; }
echo "$what" >> "$STUB_LOG"
if [ -n "$out" ]; then cat "$STUB_DIR/$what.sh" > "$out"; else cat "$STUB_DIR/$what.sh"; fi
"""


class Box:
    """A scratch machine: its home, its share, and a PATH with the stand-in curl in front."""

    def __init__(self, root: Path, name: str) -> None:
        self.home, self.share, self.stub = root / name / "home", root / name / "share", root / name / "stub"
        for d in (self.home, self.share / ".mylinux/claude", self.stub):
            d.mkdir(parents=True)
        for what, body in INSTALLERS.items():
            (self.stub / f"{what}.sh").write_text(body)
        (self.stub / "curl").write_text(CURL)
        (self.stub / "curl").chmod(0o755)
        self.n = 0

    def env(self, **more: str) -> dict[str, str]:
        return dict({"HOME": str(self.home), "MYLINUX_SHARE": str(self.share), "PATH": f"{self.stub}:/usr/bin:/bin:/usr/sbin:/sbin",
                     "STUB_DIR": str(self.stub), "STUB_LOG": str(self.stub / "log"), "USER": "tester"}, **more)

    def ident(self) -> str:
        self.n += 1
        return f"{self.n:08x}"

    def status(self) -> dict:
        i = self.ident()
        subprocess.run([sys.executable, str(SCRIPT), "status", i], env=self.env(), check=True)
        return json.loads((self.share / f".mylinux/claude/status-{i}.json").read_text())

    def apply(self, request: dict | None, **more: str) -> tuple[dict, str, str]:
        """The result, the progress file's text and the id."""
        i = self.ident()
        d = self.share / ".mylinux/claude"
        if request is not None:
            (d / f"request-{i}.json").write_text(json.dumps(request))
        subprocess.run([sys.executable, str(SCRIPT), "apply", i], env=self.env(**more))
        return json.loads((d / f"result-{i}.json").read_text()), (d / f"progress-{i}.jsonl").read_text(), i

    def fetched(self) -> list[str]:
        log = self.stub / "log"
        return log.read_text().split() if log.exists() else []

    def alias(self, name: str, shell: str = "bash") -> str:
        """What the alias runs in a new shell of this home (the stand-in claude says who it is)."""
        script = f'. "$HOME/.{"bashrc" if shell == "bash" else "profile"}"; {name}'
        if shell == "bash":
            script = "shopt -s expand_aliases\n" + f'. "$HOME/.bashrc"\n{name}'
        r = subprocess.run([shell, "-c", script] if shell == "bash" else [shell, "-ic", script], env=self.env(), capture_output=True, text=True, stdin=subprocess.DEVNULL)
        return (r.stdout + r.stderr).strip()


def mode(p: Path) -> str:
    return oct(stat.S_IMODE(p.stat().st_mode))


DEFAULTS = json.loads((REPO / "server-apps/catalog.json").read_text())["aliases"]
DEFAULT_ALIASES = [{"name": a["name"], "command": a["command"]} for a in DEFAULTS if a.get("default")]


def stand_in_textual() -> None:
    """mylinux_apps.py imports Textual and Rich for its screen; what is compared here needs neither."""
    class Meta(type):
        def __getattr__(cls, name): return cls
        def __getitem__(cls, item): return cls

    class Stub(metaclass=Meta):
        def __init__(self, *a, **k): pass
        def __call__(self, *a, **k): return self

    class Module(types.ModuleType):
        def __getattr__(self, name): return Stub

    for name in ("textual", "textual.app", "textual.binding", "textual.containers", "textual.screen", "textual.widgets",
                 "rich", "rich.markup", "rich.text"):
        sys.modules.setdefault(name, Module(name))


def load(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def main() -> int:
    root = Path(tempfile.mkdtemp(prefix="mylinux-claude-setup.")).resolve()
    try:
        print("claude-setup: a machine without Claude Code")
        b = Box(root, "fresh")
        s = b.status()
        check("nothing is installed", s["claude"] == {"installed": False, "version": "", "path": ""}, s["claude"])
        check("no subscription, no login", s["accounts"] == [] and s["default"] == {"token": False, "account": "", "browser": False}, s)
        check("no status line", s["statusLine"]["script"] is False and s["statusLine"]["configured"] is False)
        check("nothing was written into the home folder", not any(b.home.iterdir()), list(b.home.iterdir()))

        print("claude-setup: the first subscription, also as the login of plain claude")
        (b.home / ".bashrc").write_text("# the user's own\nexport EDITOR=vi\n")
        result, progress, i = b.apply({"alias": "cc1", "account": "viktor_gmail", "token": TOKEN, "apiKey": "", "makeDefault": True,
                                       "defaultAliases": DEFAULT_ALIASES})
        check("it ends well", result["ok"] is True, result)
        check("the request is taken from the share", not (b.share / f".mylinux/claude/request-{i}.json").exists())
        check("no token in what the wizard reads", TOKEN not in progress and TOKEN not in json.dumps(result))
        check("Claude Code was installed with its own installer", b.fetched()[:1] == ["claude"] and (b.home / ".local/bin/claude").exists(), b.fetched())
        steps = {x["step"]: x for x in result["steps"]}
        check("each step is told", [x["step"] for x in result["steps"]] == ["claude", "account", "aliases", "statusline"] and
              all(x["state"] == "done" for x in result["steps"]), result["steps"])
        check("  (the version it installed)", steps["claude"]["detail"] == "version 9.9.9", steps["claude"])
        running = [json.loads(line) for line in progress.splitlines()]
        check("a step is told when it starts", {"step": "claude", "title": "Installing Claude Code", "state": "running", "detail": ""} in running)
        env = b.home / ".config/mylinux/claude-accounts/cc1.env"
        check("the token and the name are saved for the alias", f"export CLAUDE_CODE_OAUTH_TOKEN='{TOKEN}'" in env.read_text()
              and "export MYLINUX_CLAUDE_ACCOUNT='viktor_gmail'" in env.read_text())
        check("only its owner reads it", mode(env) == "0o600" and mode(env.parent) == "0o700", (mode(env), mode(env.parent)))
        aliases = (b.home / ".config/mylinux/aliases.sh").read_text().splitlines()
        check("a new aliases file starts with the catalog's defaults, then the subscription",
              [line.split("=", 1)[0] for line in aliases[1:]] == ["alias cc", "alias cx", "alias cc1"], aliases)
        rc = (b.home / ".bashrc").read_text()
        check("~/.bashrc keeps what was there and loads the aliases", rc.startswith("# the user's own\nexport EDITOR=vi\n") and
              "# >>> myLinux Apps >>>" in rc and '. "$HOME/.config/mylinux/aliases.sh"' in rc, rc)
        check("~/.profile loads them too", "# >>> myLinux Apps >>>" in (b.home / ".profile").read_text())
        token_file = b.home / ".config/claude/oauth-token.sh"
        check("plain claude's login is the token, for its owner only", f"export CLAUDE_CODE_OAUTH_TOKEN='{TOKEN}'" in token_file.read_text()
              and "export MYLINUX_CLAUDE_ACCOUNT='viktor_gmail'" in token_file.read_text() and mode(token_file) == "0o600")
        check("~/.bashrc loads that login", str(token_file) in rc)
        check("the first-run screens are marked done", json.loads((b.home / ".claude.json").read_text()) == {"hasCompletedOnboarding": True})
        check("the status line is installed", (b.home / ".claude/statusline.sh").exists() and b.fetched() == ["claude", "statusline"], b.fetched())
        check("no skills without an API key", not (b.home / ".claude/skills-ran").exists())
        s = result["status"]
        check("the status after it: installed, signed in, the account shown",
              s["claude"]["installed"] and s["claude"]["version"] == "9.9.9" and s["claude"]["path"] == "~/.local/bin/claude"
              and s["accounts"] == [{"alias": "cc1", "account": "viktor_gmail", "token": True, "aliasLine": True}]
              and s["default"] == {"token": True, "account": "viktor_gmail", "browser": False}
              and s["aliases"] == {"names": ["cc", "cx", "cc1"], "loaded": True}
              and s["statusLine"] == {"script": True, "showsAccount": True, "configured": True, "command": "~/.claude/statusline.sh"}
              and s["onboarded"] is True, s)
        check("cc1 in a new bash is Claude Code as that subscription", b.alias("cc1") == f"claude as viktor_gmail token {TOKEN} key none", b.alias("cc1"))
        check("cc is too", b.alias("cc") == f"claude as viktor_gmail token {TOKEN} key none", b.alias("cc"))

        print("claude-setup: a second subscription beside it")
        result, progress, _ = b.apply({"alias": "cc2", "account": "work@example", "token": TOKEN2, "apiKey": APIKEY, "makeDefault": False,
                                       "defaultAliases": DEFAULT_ALIASES})
        check("it ends well", result["ok"] is True, result)
        check("neither the token nor the API key in what the wizard reads", all(x not in progress + json.dumps(result) for x in (TOKEN2, APIKEY)))
        check("Claude Code and the status line are not installed again, the skills are", b.fetched() == ["claude", "statusline", "skills"], b.fetched())
        check("the skills' installer got the API key", (b.home / ".config/mylinux/api-key").read_text() == APIKEY)
        check("both subscriptions, each with its alias", [(a["alias"], a["account"], a["aliasLine"]) for a in result["status"]["accounts"]]
              == [("cc1", "viktor_gmail", True), ("cc2", "work@example", True)], result["status"]["accounts"])
        check("cc2 runs as the second", b.alias("cc2") == f"claude as work@example token {TOKEN2} key none", b.alias("cc2"))
        check("cc1 and plain claude stay the first", b.alias("cc1").startswith("claude as viktor_gmail") and b.alias("claude").startswith("claude as viktor_gmail"))
        check("the rc files are not written twice", (b.home / ".bashrc").read_text().count("# >>> myLinux Apps >>>") == 1
              and (b.home / ".bashrc").read_text().count("oauth-token.sh") == 2, (b.home / ".bashrc").read_text())

        print("claude-setup: what myLinux Apps writes is what this writes")
        os.environ["HOME"] = str(root / "apps-home")
        (root / "apps-home").mkdir()
        stand_in_textual()
        apps = load(REPO / "server-apps/mylinux_apps.py", "mylinux_apps")
        setup = load(SCRIPT, "claude_setup")
        check("the alias's command", apps.account_command("cc1") == setup.account_command("cc1"))
        apps.save_account("cc1", "viktor_gmail", TOKEN)
        check("the subscription's file", (root / "apps-home/.config/mylinux/claude-accounts/cc1.env").read_text() == setup.account_text("cc1", "viktor_gmail", TOKEN))
        check("the checks of alias, account and token", (apps.ALIAS_RE.pattern, apps.ACCOUNT_RE.pattern, apps.TOKEN_RE.pattern)
              == (setup.ALIAS_RE.pattern, setup.ACCOUNT_RE.pattern, setup.TOKEN_RE.pattern))
        apps.save_account("cc2", "work@example", TOKEN2)
        apps.write_aliases(DEFAULTS, apps.aliases_on(DEFAULTS))
        check("the aliases file, line for line", (root / "apps-home/.config/mylinux/aliases.sh").read_text() == (b.home / ".config/mylinux/aliases.sh").read_text(),
              (root / "apps-home/.config/mylinux/aliases.sh").read_text())
        run_sh = (REPO / "server-apps/run.sh").read_text()
        check("run.sh's block: the PATH line and the aliases line", f"PATHLINE='{setup.PATHLINE}'" in run_sh and f"ALIASLINE='{setup.ALIASLINE}'" in run_sh
              and f"echo '{setup.BLOCK_START}'" in run_sh and f"echo '{setup.BLOCK_END}'" in run_sh)
        bootstrap = (REPO / "claude-bootstrap/install.sh").read_text()
        check("claude-bootstrap keeps plain claude's login in the same file", 'TOKEN_FILE="$HOME/.config/claude/oauth-token.sh"' in bootstrap
              and "export CLAUDE_CODE_OAUTH_TOKEN='%s'" in bootstrap and "export MYLINUX_CLAUDE_ACCOUNT='%s'" in bootstrap)

        print("claude-setup: a repair (no token): the status line and an alias that went missing")
        (b.home / ".claude/statusline.sh").write_text("#!/bin/sh\necho mine\n")
        keep = [line for line in (b.home / ".config/mylinux/aliases.sh").read_text().splitlines() if not line.startswith("alias cc2=")]
        (b.home / ".config/mylinux/aliases.sh").write_text("\n".join(keep + ["alias mine='ls -la'"]) + "\n")
        s = b.status()
        check("the status tells both", s["statusLine"] == {"script": True, "showsAccount": False, "configured": True, "command": "~/.claude/statusline.sh"}
              and [a["aliasLine"] for a in s["accounts"]] == [True, False], s)
        result, _, _ = b.apply({"defaultAliases": DEFAULT_ALIASES})
        check("it ends well, with no subscription added", result["ok"] is True and result["alias"] == "" and
              [x["step"] for x in result["steps"]] == ["claude", "aliases", "statusline"], result)
        s = result["status"]
        check("the status line shows the account again", s["statusLine"]["showsAccount"] is True and b.fetched()[-1] == "statusline")
        check("cc2 is back, and the user's own alias stays", s["aliases"]["names"] == ["cc", "cx", "cc1", "mine", "cc2"], s["aliases"])
        check("the tokens are as they were", TOKEN2 in (b.home / ".config/mylinux/claude-accounts/cc2.env").read_text())

        print("claude-setup: a new token for an alias that is there")
        result, _, _ = b.apply({"alias": "cc2", "account": "work2", "token": TOKEN, "defaultAliases": DEFAULT_ALIASES})
        check("it replaces the token and the name", result["ok"] is True and b.alias("cc2") == f"claude as work2 token {TOKEN} key none", b.alias("cc2"))
        check("the skills run again with the API key saved here", b.fetched()[-1] == "skills", b.fetched())

        print("claude-setup: what is refused, and what fails")
        c = Box(root, "refused")
        for what, request in (("an alias of myLinux Apps' own", {"alias": "cc", "account": "a", "token": TOKEN, "defaultAliases": DEFAULT_ALIASES}),
                              ("an alias that is not one word", {"alias": "c c; rm -rf", "account": "a", "token": TOKEN}),
                              ("an account name with a quote", {"alias": "cc1", "account": "a'b", "token": TOKEN}),
                              ("a token with a quote", {"alias": "cc1", "account": "a", "token": "sk-ant-oat01-abc'; touch pwned; '0123456789"}),
                              ("an API key that is not one", {"alias": "cc1", "account": "a", "token": TOKEN, "apiKey": "sk-ant-api03-zzzzzzzzzzzz"}),
                              ("no request at all", None)):
            result, progress, _ = c.apply(request)
            check(f"{what}: refused, nothing written or fetched", result["ok"] is False and result["steps"][0]["state"] == "failed"
                  and not (c.home / ".config/mylinux/claude-accounts").exists() and c.fetched() == [], result)
        result, progress, _ = c.apply({"alias": "cc1", "account": "a", "token": TOKEN}, STUB_FAIL="claude")
        steps = {x["step"]: x for x in result["steps"]}
        check("Claude Code's installer out of reach: told, the subscription still saved", result["ok"] is False and steps["claude"]["state"] == "failed"
              and "Could not resolve host" in steps["claude"]["detail"] and steps["account"]["state"] == "done", result)
        check("  (a later run installs it and ends well)", c.apply({})[0]["ok"] is True and (c.home / ".local/bin/claude").exists())
        (c.home / ".claude/statusline.sh").unlink()
        result, _, _ = c.apply({}, STUB_FAIL="statusline")
        check("the status line's installer out of reach: told", result["ok"] is False and {x["step"]: x["state"] for x in result["steps"]}["statusline"] == "failed", result)
        result, _, _ = c.apply({"apiKey": APIKEY}, STUB_FAIL="skills")
        check("the skills out of reach: told, and not the setup's failure", result["ok"] is True and {x["step"]: x["state"] for x in result["steps"]}["skills"] == "skipped", result)
        r = subprocess.run([sys.executable, str(SCRIPT), "apply", "../../etc"], env=c.env(), capture_output=True, text=True)
        check("an id that is not one is not a file name", r.returncode == 64)

        print("claude-setup: a login made in the browser, and another status line")
        d = Box(root, "browser")
        (d.home / ".claude").mkdir()
        (d.home / ".claude/.credentials.json").write_text("{}")
        (d.home / ".claude/settings.json").write_text('{"statusLine": {"type": "command", "command": "npx ccusage statusline"}, "theme": "dark"}')
        s = d.status()
        check("the browser login is seen, the other status line is not taken for ours", s["default"]["browser"] is True and
              s["statusLine"] == {"script": False, "showsAccount": False, "configured": False, "command": "npx ccusage statusline"}, s)
    finally:
        shutil.rmtree(root, ignore_errors=True)
    print(f"claude-setup: {'all passed' if fails == 0 else str(fails) + ' failed'}")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
