---
name: mylinux
description: Create, start, stop, inspect and use virtual machines in myLinux Launcher on this Mac (Tiny Alpine, Alpine, Debian, Omarchy, Arch Linux, Kali, Windows). Use when the user says /mylinux, or asks to install, create, make, start, stop, restart, list or delete a machine or VM, wants a throwaway Linux box to try or test something in, or wants a command run inside one of their machines.
---

# myLinux Launcher

myLinux Launcher runs virtual machines on this Mac. This is its command:

    {{MYLINUX}}

Call it with that full path, in quotes (it has a space in it). Every answer is JSON on standard output. The exit
status is 0 when it went well; otherwise the JSON has `"ok": false` and an `"error"` in plain words: tell the user
that error, do not guess around it. `{{MYLINUX}} help` lists every command.

## From what the user says to a command

| The user says | Run |
| --- | --- |
| install tiny alpine 1gb/20gb called tester1 | `create tiny --name tester1 --memory 1 --disk 20 --wait` |
| make me a debian box named build with 4 GB | `create debian --name build --memory 4 --wait` |
| install omarchy | `create omarchy --wait --timeout 3600` |
| what machines do I have | `list` |
| start / stop / restart tester1 | `start tester1 --wait` / `stop tester1 --wait` / `restart tester1` |
| is tester1 up | `status tester1` |
| run `uname -a` in tester1 | `ssh tester1 -- uname -a` |
| delete tester1 | `delete tester1 --yes` (see the rules below) |

"1gb/20gb" is memory, then disk. Sizes are whole gigabytes. A size the user did not give is left out: the launcher
has a good default for each kind. A name with spaces goes in quotes.

## Kinds

`{{MYLINUX}} kinds` says what each kind is, its default sizes, and whether it is downloaded already.

- `tiny` (Tiny Alpine): the smallest server. 18 MB to download, starts in seconds, runs well in 1 GB. The one to
  pick for "a small Linux to test something in".
- `alpine`, `debian`: servers with a cloud image. No desktop: a shell over SSH.
- `omarchy`, `arch`, `kali`, `mylinux`: Linux desktops, each in its own window. Downloads of 1 to 2 GB the first time.
- `windows`: Windows 11 for Arm. Two things are the user's, not yours: the ISO, which they download from Microsoft
  (pass it once with `--iso FILE`), and Windows Setup with its first-run screens, which a person answers in the
  machine's window (Microsoft's licence terms are among them). Create it, tell the user it is waiting for them in its
  window, and do not wait for it unless they ask.

## Waiting

`create` and `start` answer at once; `--wait` holds on until the machine is `ready` (a server: its SSH answers; a
desktop: it is running; Windows: installed and signed in). The default is 900 seconds; a first Omarchy, Arch or Kali
needs a download, so give those `--timeout 3600`. When the wait runs out (exit status 4) nothing is wrong: the work
goes on. Look at `status` (`job` says what is being downloaded and how far it is), tell the user, and `wait` again.

## Using a server

`{{MYLINUX}} ssh NAME -- COMMAND` runs one command in a `tiny`, `alpine` or `debian` machine and gives back its
output and exit status. The account is `alpine` in tiny and alpine (root with `doas`), `debian` in debian (root with
`sudo`). Quote a command that has pipes or `&&` as one word: `ssh tester1 -- 'apk add git && git --version'`.
Files go in and out through the machine's Mac folder: `status` gives `folder`; its `Mac` subfolder is `~/Mac` inside.

## Rules

- Use the name the user gave. If a machine with that name is there already, say so and ask; do not make a second
  one under another name.
- Delete only a machine the user named in this conversation and asked you to delete. `delete` moves it and its disk
  to the Trash; say that it can be put back from there.
- Do not stop or restart a machine you did not start unless the user asks: they may be working in it.
- Report what the JSON says: the machine's name, its state, and for a server how to reach it
  (`{{MYLINUX}} ssh NAME`). Do not print the path of its SSH key unless asked.
