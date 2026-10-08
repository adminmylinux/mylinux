#!/usr/bin/env python3
"""Claude Install… (the launcher's wizard for an Omarchy machine, in its window's ⌘ menu): the part inside the machine.

    claude_setup.py status <id>   what is there, as <share>/.mylinux/claude/status-<id>.json: Claude Code and its
                                  version, the saved subscriptions (their aliases and account names, never a token),
                                  the status line, and whether new shells load the aliases
    claude_setup.py apply <id>    carries out <share>/.mylinux/claude/request-<id>.json, which is taken (read and
                                  removed) first: Claude Code installed when missing, a subscription saved as an alias
                                  (cc1, cc2, …) with its long-lived token, the status line that shows its account, your
                                  skills with a myLinux API key. Each step goes into progress-<id>.jsonl as it starts
                                  and ends, the outcome into result-<id>.json

The launcher writes this file and the request into the machine's Mac share and leaves "claude status <id>" or "claude
apply <id>" for Omarchy's session agent (omarchy/session), which starts it; the wizard reads the answers from the
share. What it writes in the home folder is what myLinux Apps writes for a subscription (server-apps/mylinux_apps.py:
Claude Code, at the top), so a subscription added here is a row there and the other way round:
~/.config/mylinux/claude-accounts/<alias>.env (mode 600: the token and MYLINUX_CLAUDE_ACCOUNT, which the status line
shows), the alias in ~/.config/mylinux/aliases.sh, and run.sh's marked block in ~/.profile and ~/.bashrc, which
loads that file. With "makeDefault" the token is also the login of plain `claude` and the alias cc, kept as
claude-bootstrap keeps it (~/.config/claude/oauth-token.sh). No secret is written to a progress or result file.
Python 3.9 and later, nothing beyond the standard library.
"""
from __future__ import annotations

import fcntl
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HOME = Path.home()
SHARE = Path(os.environ.get("MYLINUX_SHARE", "/mnt/mac"))
DIR = SHARE / ".mylinux/claude"
SITE = os.environ.get("MYLINUX_SITE", "https://mylinux.app")
CLAUDE_INSTALLER = "https://claude.ai/install.sh"

ACCOUNTS_DIR = HOME / ".config/mylinux/claude-accounts"
ALIASES_FILE = HOME / ".config/mylinux/aliases.sh"
API_KEY_FILE = HOME / ".config/mylinux/api-key"
TOKEN_FILE = HOME / ".config/claude/oauth-token.sh"          # claude-bootstrap's: the login of plain claude
STATUSLINE = HOME / ".claude/statusline.sh"
SETTINGS = HOME / ".claude/settings.json"
ID_RE = re.compile(r"^[0-9a-f]{8,32}$")
# as myLinux Apps checks them
ALIAS_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_-]{0,31}$")
ACCOUNT_RE = re.compile(r"^[A-Za-z0-9._@-]{1,40}$")
TOKEN_RE = re.compile(r"^[A-Za-z0-9_-]{20,}$")
APIKEY_RE = re.compile(r"^mlx_[A-Za-z0-9_-]{8,}$")
ALIASES_HEADER = "# myLinux Apps: the aliases turned on in it (Aliases, at the top); it rewrites this file"
# run.sh's block in ~/.profile and ~/.bashrc, line for line (tools/check.sh compares them)
PATHLINE = 'for d in "$HOME/.local/bin" "$HOME/.bun/bin" "$HOME/.cargo/bin"; do case ":$PATH:" in *":$d:"*) ;; *) PATH="$d:$PATH" ;; esac; done; export PATH'
ALIASLINE = '[ -f "$HOME/.config/mylinux/aliases.sh" ] && . "$HOME/.config/mylinux/aliases.sh"'
BLOCK_START, BLOCK_END = "# >>> myLinux Apps >>>", "# <<< myLinux Apps <<<"


def search_path() -> str:
    """The PATH with where the installers put things: ~/.local/bin first (Claude Code's own installer, and Omarchy's
    claude, a script there that fetches it with mise at its first run), then the session's, then mise's shims."""
    first, last = [str(HOME / ".local/bin")], [str(HOME / ".local/share/mise/shims"), "/usr/local/bin"]
    have = [p for p in os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin").split(":") if p and p not in first]
    return ":".join(first + have + [p for p in last if p not in have])


def account_command(name: str) -> str:
    return (f'( . "$HOME/.config/mylinux/claude-accounts/{name}.env" && unset ANTHROPIC_API_KEY'
            f' && claude update && claude --dangerously-skip-permissions )')


def quote_alias(command: str) -> str:
    return "'" + command.replace("'", "'\\''") + "'"


def account_text(name: str, account: str, token: str) -> str:
    return (f"# myLinux Apps: Claude Code as {account} (the alias {name}); a long-lived token from claude setup-token\n"
            f"export CLAUDE_CODE_OAUTH_TOKEN='{token}'\nexport MYLINUX_CLAUDE_ACCOUNT='{account}'\n")


def exported(path: Path) -> dict[str, str]:
    """The variables a file of export lines sets (the last of each), without running it."""
    out: dict[str, str] = {}
    try:
        lines = path.read_text().splitlines()
    except (OSError, UnicodeDecodeError):
        return out
    for line in lines:
        m = re.match(r"^\s*export\s+([A-Za-z_][A-Za-z0-9_]*)=(.*)$", line)
        if m:
            out[m.group(1)] = m.group(2).strip().strip("'\"")
    return out


def read_json(path: Path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError, UnicodeDecodeError):
        return None


def write_private(path: Path, text: str) -> None:
    """For this user only, and never half written."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name("." + path.name + ".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fh:
        fh.write(text)
    os.chmod(tmp, 0o600)
    tmp.replace(path)


def write_share(name: str, obj) -> None:
    DIR.mkdir(parents=True, exist_ok=True)
    tmp = DIR / ("." + name + ".tmp")
    tmp.write_text(json.dumps(obj, indent=1) + "\n")
    tmp.replace(DIR / name)


# ---- status ------------------------------------------------------------------------------------------------------------
def claude_version() -> tuple[str | None, str]:
    """Where claude is and the version it reports ("" when it does not answer)."""
    path = shutil.which("claude", path=search_path())
    if not path:
        return None, ""
    try:
        # Omarchy's claude downloads Claude Code the first time it runs: that first answer takes its time
        r = subprocess.run([path, "--version"], capture_output=True, text=True, timeout=30, stdin=subprocess.DEVNULL,
                           env=dict(os.environ, PATH=search_path()))
        m = re.search(r"\d+\.\d+\.\d+[^\s]*", r.stdout)
        return path, m.group(0) if m else ""
    except (OSError, subprocess.SubprocessError):
        return path, ""


def alias_names() -> list[str]:
    try:
        lines = ALIASES_FILE.read_text().splitlines()
    except (OSError, UnicodeDecodeError):
        return []
    return [line[6:].split("=", 1)[0] for line in lines if line.startswith("alias ") and "=" in line]


def aliases_loaded() -> bool:
    """New terminals read the aliases: bash's own file has the line that loads them."""
    try:
        return ALIASLINE in (HOME / ".bashrc").read_text().splitlines()
    except (OSError, UnicodeDecodeError):
        return False


def accounts() -> list[dict]:
    names = set(alias_names())
    out = []
    for f in sorted(ACCOUNTS_DIR.glob("*.env")) if ACCOUNTS_DIR.is_dir() else []:
        if not ALIAS_RE.match(f.stem):
            continue
        env = exported(f)
        out.append({"alias": f.stem, "account": env.get("MYLINUX_CLAUDE_ACCOUNT", ""),
                    "token": bool(env.get("CLAUDE_CODE_OAUTH_TOKEN")), "aliasLine": f.stem in names})
    return out


def status_line() -> dict:
    script = ""
    try:
        script = STATUSLINE.read_text()
    except (OSError, UnicodeDecodeError):
        pass
    settings = read_json(SETTINGS)
    line = settings.get("statusLine") if isinstance(settings, dict) else None
    command = line.get("command", "") if isinstance(line, dict) else ""
    ours = {"~/.claude/statusline.sh", "$HOME/.claude/statusline.sh", str(STATUSLINE)}
    return {"script": bool(script), "showsAccount": "MYLINUX_CLAUDE_ACCOUNT" in script,
            "configured": isinstance(command, str) and command.split(" ")[0] in ours,
            "command": command if isinstance(command, str) else ""}


def status() -> dict:
    path, version = claude_version()
    default = exported(TOKEN_FILE)
    config = read_json(HOME / ".claude.json")
    return {
        "version": 1,
        "user": os.environ.get("USER") or HOME.name,
        "claude": {"installed": path is not None, "version": version,
                   "path": path.replace(str(HOME), "~", 1) if path else ""},
        # plain `claude` and the alias cc: a token every shell loads, or a login made in the browser
        "default": {"token": bool(default.get("CLAUDE_CODE_OAUTH_TOKEN")), "account": default.get("MYLINUX_CLAUDE_ACCOUNT", ""),
                    "browser": (HOME / ".claude/.credentials.json").is_file()},
        "accounts": accounts(),
        "aliases": {"names": alias_names(), "loaded": aliases_loaded()},
        "statusLine": status_line(),
        "apiKey": API_KEY_FILE.is_file() and API_KEY_FILE.stat().st_size > 0,
        "onboarded": isinstance(config, dict) and config.get("hasCompletedOnboarding") is True,
    }


# ---- apply -------------------------------------------------------------------------------------------------------------
class Progress:
    """The steps as they start and end, one JSON object a line, for the wizard to follow."""

    def __init__(self, ident: str, secrets: list[str]) -> None:
        self.path = DIR / f"progress-{ident}.jsonl"
        self.secrets = [s for s in secrets if s]
        self.steps: list[dict] = []
        DIR.mkdir(parents=True, exist_ok=True)
        self.path.write_text("")

    def scrub(self, text: str) -> str:
        for s in self.secrets:
            text = text.replace(s, "•••")
        return text

    def emit(self, step: str, title: str, state: str, detail: str = "") -> None:
        row = {"step": step, "title": title, "state": state, "detail": self.scrub(detail)}
        self.steps = [s for s in self.steps if s["step"] != step] + [row]
        with self.path.open("a") as fh:
            fh.write(json.dumps(row) + "\n")


def tail(text: str, lines: int = 12) -> str:
    """The end of a command's output, without the colours installers print."""
    clean = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", text).replace("\r", "\n")
    return "\n".join([line for line in clean.splitlines() if line.strip()][-lines:])


def run(script: str, env: dict[str, str] | None = None, timeout: int = 900) -> tuple[int, str]:
    """A shell script with nobody at the keyboard: its status and what it printed."""
    try:
        r = subprocess.run(["sh", "-c", script], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           text=True, errors="replace", timeout=timeout, cwd=str(HOME),
                           env=dict(os.environ, PATH=search_path(), **(env or {})))
        return r.returncode, r.stdout
    except subprocess.TimeoutExpired as e:
        out = e.stdout.decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
        return 124, out + f"\nstopped after {timeout // 60} minutes"
    except OSError as e:
        return 127, str(e)


def fetch_and_run(url: str, shell: str = "sh", env: dict[str, str] | None = None, timeout: int = 900) -> tuple[int, str]:
    """An installer downloaded whole, then run: never a script that arrived in part, and a download that fails is a
    failure (curl | sh ends well on an empty script)."""
    with tempfile.TemporaryDirectory() as d:
        inst = Path(d) / "install.sh"
        rc, out = run(f'curl -fsSL --retry 3 --connect-timeout 20 "{url}" -o "{inst}"', timeout=120)
        if rc != 0:
            return rc, f"could not download {url} (is the machine online?)\n" + tail(out)
        return run(f'{shell} "{inst}"', env=env, timeout=timeout)


def install_claude() -> tuple[bool, str]:
    """Anthropic's own installer, as claude-bootstrap runs it: by bash."""
    for tool in ("curl", "bash"):
        if not shutil.which(tool, path=search_path()):
            return False, f"{tool} is needed for Claude Code's installer: install it in a terminal (sudo pacman -S {tool}), then try again"
    rc, out = fetch_and_run(CLAUDE_INSTALLER, shell="bash")
    path, version = claude_version()
    if rc != 0 or path is None:
        return False, "Claude Code's installer did not finish\n" + tail(out)
    return True, version


def save_account(name: str, account: str, token: str) -> None:
    ACCOUNTS_DIR.mkdir(parents=True, exist_ok=True)
    os.chmod(ACCOUNTS_DIR, 0o700)
    write_private(ACCOUNTS_DIR / f"{name}.env", account_text(name, account, token))


def save_default(account: str, token: str) -> list[str]:
    """The token as the login of plain `claude` (and cc), where claude-bootstrap keeps it and as it loads it: the rc
    files that got the loader."""
    keep = [line for line in (TOKEN_FILE.read_text().splitlines() if TOKEN_FILE.is_file() else [])
            if line.startswith("export ") and not re.match(r"^export (CLAUDE_CODE_OAUTH_TOKEN|ANTHROPIC_API_KEY|MYLINUX_CLAUDE_ACCOUNT)=", line)]
    write_private(TOKEN_FILE, "\n".join([f"export CLAUDE_CODE_OAUTH_TOKEN='{token}'", f"export MYLINUX_CLAUDE_ACCOUNT='{account}'"] + keep) + "\n")
    added = []
    for rc in (HOME / ".profile", HOME / ".bashrc", HOME / ".zshrc"):
        if rc.name == ".zshrc" and not rc.exists() and not shutil.which("zsh"):
            continue
        text = rc.read_text() if rc.exists() else ""
        if str(TOKEN_FILE) in text:
            continue
        with rc.open("a") as fh:
            fh.write("\n# Claude Code (added by myLinux's Claude Install, as claude-bootstrap does)\n"
                     f'[ -f "{TOKEN_FILE}" ] && . "{TOKEN_FILE}"\n'
                     'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac\n')
        added.append("~/" + rc.name)
    return added


def write_aliases(defaults: list[dict]) -> list[str]:
    """Every saved subscription's alias in the aliases file, the other lines as they are; a file that is not there
    yet starts as myLinux Apps starts it, with the catalog's default aliases (cc, cx). The aliases written or changed."""
    fresh = not ALIASES_FILE.exists()
    lines = [ALIASES_HEADER] if fresh else ALIASES_FILE.read_text().splitlines()
    changed = []
    wanted = []
    if fresh:
        for a in defaults:
            if isinstance(a, dict) and ALIAS_RE.match(str(a.get("name", ""))) and isinstance(a.get("command"), str) and "\n" not in a["command"]:
                wanted.append((a["name"], a["command"]))
    wanted += [(a["alias"], account_command(a["alias"])) for a in accounts()]
    for name, command in wanted:
        line = f"alias {name}={quote_alias(command)}"
        at = [i for i, have in enumerate(lines) if have.startswith(f"alias {name}=")]
        if at and lines[at[0]] == line and len(at) == 1:
            continue
        lines = [have for i, have in enumerate(lines) if i not in at[1:]]
        if at:
            lines[at[0]] = line
        else:
            lines.append(line)
        changed.append(name)
    if changed or fresh:
        ALIASES_FILE.parent.mkdir(parents=True, exist_ok=True)
        tmp = ALIASES_FILE.with_suffix(".tmp")
        tmp.write_text("\n".join(lines) + "\n")
        tmp.replace(ALIASES_FILE)
    return changed


def write_rc_block() -> list[str]:
    """run.sh's marked block (the PATH of the installers, and the aliases file) in ~/.profile and ~/.bashrc, when a
    file lacks one of its lines: the files changed."""
    changed = []
    extra = ["export USE_BUILTIN_RIPGREP=0"] if shutil.which("apk") else []     # as run.sh on Alpine
    for rc in (HOME / ".profile", HOME / ".bashrc"):
        lines = rc.read_text().splitlines() if rc.exists() else []
        if PATHLINE in lines and ALIASLINE in lines:
            continue
        kept, inside = [], False
        for line in lines:
            if line == BLOCK_START:
                inside = True
            elif line == BLOCK_END and inside:
                inside = False
            elif not inside:
                kept.append(line)
        rc.write_text("\n".join(kept + [BLOCK_START, PATHLINE] + extra + [ALIASLINE, BLOCK_END]) + "\n")
        changed.append("~/" + rc.name)
    return changed


def mark_onboarded() -> None:
    """~/.claude.json says the first-run screens are done: the login is the token, so Claude Code starts straight in."""
    cfg = HOME / ".claude.json"
    try:
        data = json.loads(cfg.read_text()) if cfg.exists() and cfg.stat().st_size else {}
    except (OSError, ValueError):
        return                                    # not JSON (being written?): left alone, Claude Code asks once
    if not isinstance(data, dict) or data.get("hasCompletedOnboarding") is True:
        return
    data["hasCompletedOnboarding"] = True
    tmp = cfg.with_name(".claude.json.mylinux-tmp")
    tmp.write_text(json.dumps(data, indent=2) + "\n")
    os.chmod(tmp, (cfg.stat().st_mode & 0o777) if cfg.exists() else 0o600)
    tmp.replace(cfg)


def checked(request) -> tuple[dict, str | None]:
    """The request's fields as this script takes them, and what is wrong with them (None when nothing is)."""
    if not isinstance(request, dict):
        return {}, "the request is not what the launcher writes"
    text = lambda k: "".join(str(request.get(k) or "").split())
    r = {"alias": text("alias"), "account": text("account"), "token": text("token"), "apiKey": text("apiKey"),
         "makeDefault": request.get("makeDefault") is True, "statusLine": request.get("statusLine") is not False,
         "defaultAliases": request.get("defaultAliases") if isinstance(request.get("defaultAliases"), list) else []}
    reserved = {a.get("name") for a in r["defaultAliases"] if isinstance(a, dict)} | {"claude", "mylinux-apps"}
    if r["token"]:
        if not ALIAS_RE.match(r["alias"]):
            return r, "the alias is one word: letters, digits, - and _, starting with a letter"
        if r["alias"] in reserved:
            return r, f"{r['alias']} is one of myLinux Apps' own aliases: pick another name (cc1, cc2, …)"
        if not (ACCOUNTS_DIR / f"{r['alias']}.env").exists() and shutil.which(r["alias"], path=search_path()):
            return r, f"{r['alias']} is already a program on this machine: pick another name"
        if not ACCOUNT_RE.match(r["account"]):
            return r, "the account name is one word: letters, digits, . _ @ -"
        if not TOKEN_RE.match(r["token"]):
            return r, "that does not look like a token from claude setup-token (sk-ant-oat01-…)"
    if r["apiKey"] and not APIKEY_RE.match(r["apiKey"]):
        return r, "a myLinux API key starts with mlx_"
    return r, None


def apply(ident: str) -> dict:
    path = DIR / f"request-{ident}.json"
    request = read_json(path)
    try:
        path.unlink()                             # taken: the token is not left in the share
    except OSError:
        pass
    r, problem = checked(request)
    progress = Progress(ident, [r.get("token", ""), r.get("apiKey", "")])
    if problem:
        progress.emit("request", "Checking the request", "failed", problem)
        return {"ok": False, "steps": progress.steps}
    # one setup at a time in this home folder (the lock goes when this process ends)
    (HOME / ".config/mylinux").mkdir(parents=True, exist_ok=True)
    lock = open(HOME / ".config/mylinux/.claude-setup.lock", "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        progress.emit("request", "Checking the request", "failed", "another Claude setup is running in this machine: wait for it to finish")
        return {"ok": False, "steps": progress.steps}
    ok = True
    before = status()
    adding = bool(r["token"])

    # 1. Claude Code itself
    if before["claude"]["installed"]:
        progress.emit("claude", "Claude Code", "done", "already installed" + (f", version {before['claude']['version']}" if before["claude"]["version"] else ""))
    else:
        progress.emit("claude", "Installing Claude Code", "running")
        good, detail = install_claude()
        progress.emit("claude", "Installing Claude Code", "done" if good else "failed", f"version {detail}" if good and detail else detail)
        ok = ok and good

    # 2. the subscription: its token and name, then the aliases and the shells that load them
    try:
        if adding:
            progress.emit("account", f"Saving {r['account']} as {r['alias']}", "running")
            save_account(r["alias"], r["account"], r["token"])
            detail = f"~/.config/mylinux/claude-accounts/{r['alias']}.env, for you only"
            if r["makeDefault"]:
                save_default(r["account"], r["token"])
                detail += "; plain claude and cc use it too"
            progress.emit("account", f"Saving {r['account']} as {r['alias']}", "done", detail)
        if adding or before["accounts"]:
            progress.emit("aliases", "Aliases for new terminals", "running")
            names = write_aliases(r["defaultAliases"])
            files = write_rc_block()
            have = [a["alias"] for a in accounts()]
            progress.emit("aliases", "Aliases for new terminals", "done",
                          ", ".join(have) + (" (added " + ", ".join(names) + ")" if names else "") + (f"; loaded from {' and '.join(files)}" if files else ""))
        mark_onboarded()
    except OSError as e:
        progress.emit("account", "Saving the subscription", "failed", str(e))
        ok = False

    # 3. the status line: mylinux.app's, which shows the subscription's name
    line = status_line()
    if r["statusLine"] and not (line["script"] and line["showsAccount"] and line["configured"]):
        progress.emit("statusline", "Installing the status line", "running")
        rc, out = fetch_and_run(f"{SITE}/install/statusline", timeout=600)
        line = status_line()
        good = rc == 0 and line["script"] and line["configured"]
        progress.emit("statusline", "Installing the status line", "done" if good else "failed",
                      "folder, branch, context, limits, model and the account" if good else tail(out) or "it did not finish")
        ok = ok and good
    elif r["statusLine"]:
        progress.emit("statusline", "The status line", "done", "already shows the account")

    # 4. your skills, commands and CLAUDE.md from mylinux.app: with an API key, given now or saved here before
    if r["apiKey"] or (adding and status()["apiKey"]):
        progress.emit("skills", "Your skills from mylinux.app", "running")
        rc, out = fetch_and_run(f"{SITE}/install/skills", env={"MYLINUX_API_KEY": r["apiKey"]} if r["apiKey"] else None, timeout=600)
        # the subscription works without them: a failure here is told, and is not the setup's
        progress.emit("skills", "Your skills from mylinux.app", "done" if rc == 0 else "skipped",
                      "installed in ~/.claude" if rc == 0 else tail(out, 6) or "could not be installed")
    return {"ok": ok, "steps": progress.steps, "alias": r["alias"] if adding else "", "account": r["account"] if adding else "",
            "makeDefault": adding and r["makeDefault"], "status": status()}


def main(argv: list[str]) -> int:
    if len(argv) != 3 or argv[1] not in ("status", "apply") or not ID_RE.match(argv[2]):
        print(__doc__)
        return 64
    what, ident = argv[1], argv[2]
    if what == "status":
        write_share(f"status-{ident}.json", status())
        return 0
    try:
        result = apply(ident)
    except Exception as e:                        # whatever went wrong, the wizard is told
        result = {"ok": False, "steps": [{"step": "setup", "title": "Claude setup", "state": "failed", "detail": f"{type(e).__name__}: {e}"}]}
    write_share(f"result-{ident}.json", result)
    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
