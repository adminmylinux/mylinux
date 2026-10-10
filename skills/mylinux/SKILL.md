---
name: mylinux
description: Create, start, stop, inspect and use virtual machines in myLinux Launcher on this Mac (Tiny Alpine, Alpine, Debian, Omarchy, Arch Linux, Kali, Windows). Use when the user says /mylinux, or asks to install, create, make, start, stop, restart, list or delete a machine or VM, wants a throwaway Linux box to try or test something in, or wants a command run inside one of their machines.
---

# myLinux Launcher

myLinux Launcher runs virtual machines on this Mac. This is its command:

    {{MYLINUX}}

Call it with that full path, in quotes (it has a space in it). Every answer is JSON on standard output, except
`ssh` (the command's own output and exit status) and `help` (text). The exit status is 0 when it went well;
otherwise the JSON has `"ok": false` and an `"error"` in plain words: tell the user that error, do not guess around
it. A machine that failed answers `status`, `start` and `wait` that way too, with the machine in `"machine"`.
`{{MYLINUX}} help` lists every command. The launcher is started when it is not running; the first time on a Mac
that can take a minute, and the command says so and waits.

## From what the user says to a command

| The user says | Run |
| --- | --- |
| install tiny alpine 1gb/20gb called tester1 | `create tiny --name tester1 --memory 1 --disk 20 --wait` |
| make me a debian box named build with 4 GB | `create debian --name build --memory 4 --wait` |
| install omarchy | `create omarchy --wait --timeout 3600`, and tell them its first-start questions wait in its window |
| install omarchy, user viktor, password … (or: unattended, without the questions) | `create omarchy --unattended --password … --user viktor --wait --timeout 3600` |
| what machines do I have | `list` |
| start / stop / restart tester1 | `start tester1 --wait` / `stop tester1 --wait` / `restart tester1` |
| is tester1 up | `status tester1` |
| run `uname -a` in tester1 | `ssh tester1 -- uname -a` |
| install tiny alpine 1/20 called tester1 and install claude code on it | the `create` above, then "Claude Code in a server" below |
| delete tester1 | `delete tester1 --yes` (see the rules below) |
| erase all machines | `erase machines --yes` (see the rules below) |
| erase everything, make the launcher like a new install | `erase everything --yes` (see the rules below) |
| install windows (and nothing about the licence) | `create windows` and tell them it waits for their answers in its window |
| install windows unattended, I accept Microsoft's licence terms, user viktor | `create windows --unattended --accept-microsoft-license --user viktor --wait --timeout 3600` |

"1gb/20gb" is memory, then disk. Sizes are whole gigabytes. A size the user did not give is left out: the launcher
has a good default for each kind. A name with spaces goes in quotes. A name the user did not give is left out too:
the launcher names the machine after its kind (Omarchy, Omarchy 2) and the answer says the name; tell the user.
When the user names no machine ("start it", "stop the server"), look at `list`: one machine that fits is the one,
otherwise ask which.

More that `create` takes: `--cpus N`, `--ssh-port PORT` (a server gets a free one by itself), `--no-start` (made, not
started), and for a desktop `--keys all|mac|none` (every key to the machine, ⌘ kept by the Mac, or as typed).
`--keys all` is what a new Omarchy or Windows has, and it needs macOS's Accessibility permission for myLinux
Launcher: without it the start fails with an error that says so. Tell the user to allow it in System Settings ›
Privacy & Security › Accessibility and `start` the machine again, or make the machine with `--keys mac`.

## Kinds

`{{MYLINUX}} kinds` says what each kind is, its default sizes, and whether it is downloaded already.

- `tiny` (Tiny Alpine): the smallest server. 18 MB to download, starts in seconds, runs well in 1 GB. The one to
  pick for "a small Linux to test something in".
- `alpine`, `debian`: servers with a cloud image. No desktop: a shell over SSH.
- `omarchy`, `arch`, `kali`, `mylinux`: Linux desktops, each in its own window. Downloads of 1 to 2 GB the first time.
- A new `omarchy` asks a person its first-start questions in its window (keyboard, account, password, host name, time
  zone), unless they are answered beforehand:
  `create omarchy --unattended --password PW [--user NAME] [--keyboard Norwegian|nb-NO] [--timezone Europe/Oslo]
  [--hostname NAME] [--full-name "NAME"] [--email ADDRESS]` goes straight to the desktop, in about a minute after the
  download. What is left out is as on the Mac (its user name, keyboard and time zone; the host name from the
  machine's name); the name and e-mail address are for git and can be left out. Omarchy takes no blank password, and
  the password (for signing in and for sudo) is the user's to choose: if they asked for this without giving one, ask
  them for it, or whether they would rather answer in the machine's window. Never invent a password, and do not
  repeat one back.
- `windows`: Windows 11 for Arm. The ISO is the user's to download from Microsoft (pass it once with `--iso FILE`;
  `kinds` says whether it is there). Then one of two ways:
  - `create windows`: Windows Setup and its first-run screens are answered by a person in the machine's window,
    Microsoft's licence terms among them. Create it, tell the user it is waiting for them there, and do not wait
    for it unless they ask.
  - `create windows --unattended --accept-microsoft-license [--user NAME] [--password PW] [--edition pro|home]
    [--keyboard nb-NO]`: Windows installs itself with no question asked, 15 to 40 minutes, and restarts into the
    finished machine. This accepts Microsoft's licence terms (https://www.microsoft.com/useterms) for the user, so
    pass `--accept-microsoft-license` **only when the user has said in this conversation that they accept them**; if
    they asked for an unattended install without saying so, ask them. The account is a local administrator: `--user`
    (default: their Mac user name), `--password` only if the user gave one (without one Windows signs in by itself;
    tell them it has none). Never invent a password, and do not repeat one back.

## Waiting

`create` and `start` answer at once; `--wait` holds on until the machine is `ready` (a server: its SSH answers; a
desktop: it is running; an Omarchy made with `--unattended`: its desktop is up; Windows: installed and signed in). The default is 900 seconds; a first Omarchy, Arch or Kali
needs a download and an unattended Windows installs for a while, so give those `--timeout 3600`. When the wait runs out (exit status 4) nothing is wrong: the work
goes on. Look at `status` (`job` says what is being downloaded and how far it is), tell the user, and `wait` again.
`wait NAME [--timeout SECONDS]` is the same wait as a command of its own.

A machine's `state` is one of `stopped`, `downloading` (what it needs is fetched and unpacked first; `job` says
what), `starting`, `running`, `stopping`, `failed` (with `error`). `ready` is the word to go by: a machine can be
`running` and not ready yet. A start can also wait for the user: `job.what` says so when macOS is asking them
something on the Mac's screen (the microphone, for a desktop's first start).

## Using a server

`{{MYLINUX}} ssh NAME -- COMMAND` runs one command in a `tiny`, `alpine` or `debian` machine and gives back its
output and exit status. The account is `alpine` in tiny and alpine (root with `doas`), `debian` in debian (root with
`sudo`). Quote a command that has pipes or `&&` as one word: `ssh tester1 -- 'apk add git && git --version'`.
Files go in and out through the machine's Mac folder: `status` gives `folder`; its `Mac` subfolder is `~/Mac` inside.

## Claude Code in a server

To install Claude Code in a `tiny`, `alpine` or `debian` machine, run these with `ssh NAME --` (each as one quoted
word). It installs; signing in is the user's (last step).

1. What it needs. Alpine and tiny: `doas apk add libgcc libstdc++ ripgrep curl bash`. Debian: `sudo apt-get install -y curl`.
2. Anthropic's installer, downloaded whole and then run:
   `curl -fsSL https://claude.ai/install.sh -o /tmp/claude-install.sh && bash /tmp/claude-install.sh; rm -f /tmp/claude-install.sh`
3. New terminals must find it. If `~/.profile` has no line with `.local/bin`, add
   `export PATH="$HOME/.local/bin:$PATH"` to `~/.profile` and `~/.bashrc`, and on Alpine and tiny also
   `export USE_BUILTIN_RIPGREP=0`.
4. Check from a login shell: `sh -lc "claude --version"`, and tell the user the version.
5. Tell the user how to sign in, and do not do it for them: in the machine's terminal, `claude` (it shows a link to
   open on the Mac), or `curl -fsSL https://mylinux.app/claude | sh`, which asks for a token from `claude setup-token`.
   Never ask the user to paste a token to you.

Claude Code wants memory: in 1 GB it runs, and 2 GB or more is better. Say so if the user asked for 1 GB.

## Rules

- Use the name the user gave. If a machine with that name is there already, say so and ask; do not make a second
  one under another name.
- Delete only a machine the user named in this conversation and asked you to delete. `delete NAME --yes` moves it
  and its disk to the Trash; say that it can be put back from there. A machine that is running is refused: add
  `--stop`, which shuts it down first. Being asked to delete that machine covers shutting it down.
- Do not stop or restart a machine you did not start unless the user asks: they may be working in it.
- `erase machines --yes` moves **every** machine and its disk to the Trash. `erase everything --yes` makes the
  launcher as on a new Mac: the machines, the downloaded systems, the settings, the saved remote passwords and
  macOS's permissions for it are gone, its data folder is in the Trash, and it starts again. Run either only when
  the user asked for exactly that in this conversation, in words that leave no doubt ("erase all my machines",
  "reset the launcher like a new install"); if they named one machine, that is `delete`. Without `--yes` the command
  says what would go: show the user that when you are not sure. If machines are running the command refuses and
  names them: ask the user before adding `--stop`, which shuts them down first. Afterwards say what went and that
  it can be put back from the Trash until the Trash is emptied.
- Report what the JSON says: the machine's name, its state, and for a server how to reach it
  (`{{MYLINUX}} ssh NAME`). The JSON names the machine's SSH key file, for tools: do not print that path, or the
  key, unless asked.
