# claude-bootstrap

Set up [Claude Code](https://claude.com/claude-code) on a new Debian, Alpine or Omarchy machine (or any Linux or
macOS box) in one line, without the browser login.

## 1. Once, on a machine where you are already logged in

```bash
claude setup-token
```

This opens the browser once and prints a long-lived token (`sk-ant-oat…`, valid about a year, needs a Claude
subscription). Keep it somewhere safe, a password manager for instance.

## 2. On each new machine

```bash
curl -fsSL https://mylinux.app/claude | sh
```

(`https://mylinux.app/claude` forwards to this file on GitHub:
`https://raw.githubusercontent.com/adminmylinux/mylinux/main/claude-bootstrap/install.sh`.)

Paste the token when asked. The script:

- on Alpine adds what Claude Code needs there (`bash`, `libgcc`, `libstdc++`, `ripgrep`, with `doas` or `sudo`)
  and makes it use the system ripgrep; on Debian and Arch it only makes sure `curl` is there
- saves the token in `~/.config/claude/oauth-token.sh` (mode 600) and loads it from `~/.profile`, `~/.bashrc` and
  `~/.zshrc`
- installs Claude Code with the official installer (skipped when `claude` is already there)
- marks onboarding as done in `~/.claude.json`, so the first-run screens are skipped
- starts `claude`

It is plain `sh`, so it also runs on a fresh Alpine, which has no bash until the script adds it.

With your key saved at mylinux.app instead (the account's **API** tab: save the token under *Saved keys*, make an
*API key*), nothing needs pasting but that API key, once per machine:

```bash
curl -fsSL https://mylinux.app/install/claude | sh
```

It fetches the saved Claude Code token (or, when there is none, a saved Anthropic API key, which this script then
approves ahead in `~/.claude.json` so Claude Code does not ask about it) and runs this script with it.

Without questions, for automation:

```bash
curl -fsSL https://mylinux.app/claude | CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-... CLAUDE_BOOTSTRAP_NO_START=1 sh
```

Running it again is safe: it reuses the saved token and does not reinstall.

## Security

Anyone with the token can use your Claude subscription. It is stored only on the target machine, in a file only
you can read. Revoke it in your claude.ai account settings if it leaks. As with any `curl | sh`, read
[`install.sh`](install.sh) before running it. The script holds no secrets; never commit a token here.
