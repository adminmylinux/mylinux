"""myLinux Apps: find, run and install programs on a Debian or Alpine machine, in the terminal.

Apps… in the launcher's CMD menu copies this folder from the public repository (adminmylinux/mylinux, main) into
the machine's Mac share and runs run.sh, which starts this with the distribution's Textual (py3-textual on Alpine,
python3-textual on Debian; written for Textual 2.1 and later). What can be installed, and how, is catalog.json
beside it. Running a program or an install hands the terminal over to it (App.suspend) and comes back after.
Cloud drives: the Mac's Dropbox, OneDrive, iCloud Drive and Google Drive, as the launcher wrote them beside this folder
(../cloud.json); adding or taking one away writes ../cloud-request.json, which the launcher takes: it saves the choice
and restarts the machine to attach the folder, which then is ~/Dropbox and so on.
"""
from __future__ import annotations

import json
import os
import shlex
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.screen import ModalScreen
from textual.widgets import Button, DataTable, Footer, Header, Input, Static

HOME = Path.home()
# where the installers put things, found also when the shell's PATH does not have them yet
EXTRA_PATH = [HOME / ".local/bin", HOME / ".bun/bin", HOME / ".npm-global/bin", HOME / ".cargo/bin", Path("/usr/local/bin")]


def distribution() -> str:
    """alpine or debian, from /etc/os-release (a Debian derivative counts as debian)."""
    info = {}
    try:
        for line in Path("/etc/os-release").read_text().splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                info[k] = v.strip().strip('"')
    except OSError:
        pass
    ids = [info.get("ID", "")] + info.get("ID_LIKE", "").split()
    if "alpine" in ids:
        return "alpine"
    return "debian"


def search_path() -> str:
    parts = os.environ.get("PATH", "").split(os.pathsep)
    return os.pathsep.join(parts + [str(p) for p in EXTRA_PATH if str(p) not in parts])


@dataclass
class AppEntry:
    id: str
    name: str
    category: str
    description: str
    bins: list[str]
    run: str
    packages: list[str]
    steps: list[str]
    env: dict[str, str] = field(default_factory=dict)
    found: str | None = None          # the program found on the PATH, when installed
    cloud: dict | None = None         # a cloud drive: {"id", "title", "guest", "onMac"}
    chosen: bool = False              # a cloud drive the machine has (attached at its start)

    @property
    def installable(self) -> bool:
        if self.cloud is not None:
            return bool(self.cloud.get("onMac")) or self.chosen
        return bool(self.packages or self.steps)

    @property
    def installed(self) -> bool:
        return self.found is not None

    def command(self) -> str:
        """The run command, with {bin} as the program that was found (fd is fdfind on Debian)."""
        return self.run.replace("{bin}", self.found or (self.bins[0] if self.bins else ""))


def load_catalog(path: Path, distro: str) -> list[AppEntry]:
    data = json.loads(path.read_text())
    pkg_key, root = ("apk", "doas") if distro == "alpine" else ("apt", "sudo")
    apps = []
    for a in data["apps"]:
        packages = list(a.get(pkg_key, []))
        steps = list(a.get("script", [])) + list(a.get(distro, []))
        # the distribution's own lines come after the shared ones, except its packages, which come first
        apps.append(AppEntry(id=a["id"], name=a["name"], category=a.get("category", "Other"),
                             description=a.get("description", ""), bins=list(a.get("bin", [])),
                             run=a.get("run", a["id"]), packages=packages, steps=steps,
                             env=dict(a.get("env", {})) | dict(a.get(f"{distro}_env", {}))))
    return apps


def load_cloud(state: Path) -> tuple[list[AppEntry], str]:
    """The cloud drives the launcher wrote (none from a launcher before them), and the machine's name."""
    try:
        data = json.loads(state.read_text())
    except (OSError, ValueError):
        return [], ""
    chosen = set(data.get("selected", []))
    drives = []
    for f in data.get("folders", []):
        drives.append(AppEntry(id="cloud:" + f["id"], name=f["title"], category="Cloud drives", description="",
                               bins=[], run=f"cd ~/{f['guest']} && ls", packages=[], steps=[],
                               cloud=f, chosen=f["id"] in chosen))
    return drives, data.get("machine", "")


def describe_cloud(a: AppEntry) -> str:
    f = a.cloud or {}
    if a.chosen and a.installed:
        return f"Your Mac's {f['title']}, in ~/{f['guest']}"
    if a.chosen:
        return "Chosen: attached at the machine's next start"
    if f.get("onMac"):
        return f"Your Mac's {f['title']} folder, as ~/{f['guest']} (restarts the machine)"
    return "Not on this Mac"


def install_script(app: AppEntry, distro: str) -> str:
    lines = []
    if app.packages:
        pk = " ".join(shlex.quote(p) for p in app.packages)
        if distro == "alpine":
            lines += ["doas apk update -q", f"doas apk add {pk}"]
        else:
            lines += ["sudo apt-get update -q", f"sudo DEBIAN_FRONTEND=noninteractive apt-get install -y {pk}"]
    return "\n".join(lines + app.steps)


def remove_script(app: AppEntry, distro: str) -> str | None:
    """Only a program that is just its packages is removed here; an installer's own files are left alone."""
    if app.steps or not app.packages:
        return None
    pk = " ".join(shlex.quote(p) for p in app.packages)
    return f"doas apk del {pk}" if distro == "alpine" else f"sudo apt-get remove -y {pk}"


def refresh(apps: list[AppEntry]) -> None:
    path = search_path()
    for a in apps:
        if a.cloud is not None:
            mp = f"/mnt/{a.cloud['id']}"
            a.found = f"~/{a.cloud['guest']}" if os.path.ismount(mp) else None
            a.description = describe_cloud(a)
        else:
            a.found = next((b for b in a.bins if shutil.which(b, path=path)), None)


class Confirm(ModalScreen[bool]):
    """What is about to run, and Install / Cancel."""
    BINDINGS = [Binding("escape", "cancel", "Cancel"), Binding("enter", "ok", "OK", show=False)]
    DEFAULT_CSS = """
    Confirm { align: center middle; }
    #box { width: 90; max-width: 95%; height: auto; max-height: 90%; border: round $accent; background: $surface; padding: 1 2; }
    #title { text-style: bold; margin-bottom: 1; }
    #script { color: $text-muted; margin-bottom: 1; }
    #buttons { height: auto; align-horizontal: right; }
    #buttons Button { margin-left: 2; }
    """

    def __init__(self, title: str, script: str, ok: str) -> None:
        super().__init__()
        self.title_text, self.script, self.ok_label = title, script, ok

    def compose(self) -> ComposeResult:
        with Vertical(id="box"):
            yield Static(self.title_text, id="title")
            yield Static(self.script, id="script", markup=False)
            with Horizontal(id="buttons"):
                yield Button("Cancel", id="cancel")
                yield Button(self.ok_label, id="ok", variant="primary")

    def on_mount(self) -> None:
        self.query_one("#ok", Button).focus()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        self.dismiss(event.button.id == "ok")

    def action_cancel(self) -> None:
        self.dismiss(False)

    def action_ok(self) -> None:
        self.dismiss(True)


class MyLinuxApps(App):
    TITLE = "myLinux Apps"
    CSS = """
    #search { margin: 0 1; }
    DataTable { height: 1fr; margin: 0 1; }
    #detail { height: auto; min-height: 2; margin: 0 1; padding: 0 1; color: $text-muted; }
    """
    # the search field keeps the keyboard: arrows move in the list, Enter runs or installs, Ctrl chords do the rest
    BINDINGS = [
        Binding("down", "down", "Down", show=False, priority=True),
        Binding("up", "up", "Up", show=False, priority=True),
        Binding("pagedown", "page_down", "Page down", show=False, priority=True),
        Binding("pageup", "page_up", "Page up", show=False, priority=True),
        Binding("ctrl+u", "install", "Update", priority=True),
        Binding("ctrl+r", "remove", "Remove", priority=True),
        Binding("escape", "clear", "Clear / Quit", priority=True),
        Binding("ctrl+q", "quit", "Quit", priority=True),
    ]

    def __init__(self, catalog: Path) -> None:
        super().__init__()
        self.distro = distribution()
        self.cloud_state = catalog.parent.parent / "cloud.json"
        self.cloud_request = catalog.parent.parent / "cloud-request.json"
        drives, self.machine = load_cloud(self.cloud_state)
        self.apps = drives + load_catalog(catalog, self.distro)
        refresh(self.apps)
        self.shown: list[AppEntry] = []
        self.sub_title = f"{'Alpine' if self.distro == 'alpine' else 'Debian'} · {os.uname().nodename}"

    def compose(self) -> ComposeResult:
        yield Header()
        yield Input(placeholder="Search apps (claude, editor, git…)", id="search")
        yield DataTable(id="apps", cursor_type="row", zebra_stripes=True)
        yield Static("", id="detail")
        yield Footer()

    def on_mount(self) -> None:
        table = self.query_one(DataTable)
        table.add_columns("", "App", "Category", "What it is")
        self.fill()
        self.query_one(Input).focus()

    # ---- the list ----------------------------------------------------------------------------------------------------
    def matches(self, a: AppEntry, q: str) -> bool:
        return not q or any(q in s.lower() for s in (a.name, a.id, a.category, a.description, " ".join(a.bins)))

    def fill(self, keep: str | None = None) -> None:
        q = self.query_one(Input).value.strip().lower()
        table = self.query_one(DataTable)
        table.clear()
        # the cloud drives on top; then installed, then what can be installed here, then the rest; by category and name
        order = lambda a: (-1 if a.cloud is not None else 0 if a.installed else 1 if a.installable else 2, a.category, a.name.lower())
        self.shown = sorted((a for a in self.apps if self.matches(a, q)), key=order)
        for a in self.shown:
            if a.cloud is not None and a.chosen and not a.installed:
                mark = "[yellow]◐[/]"
            else:
                mark = "[green]●[/]" if a.installed else ("○" if a.installable else "[dim]–[/]")
            name = a.name if a.installable or a.installed else f"[dim]{a.name}[/]"
            table.add_row(mark, name, a.category, a.description, key=a.id)
        if keep and any(a.id == keep for a in self.shown):
            table.move_cursor(row=[a.id for a in self.shown].index(keep))
        self.show_detail()

    def current(self) -> AppEntry | None:
        table = self.query_one(DataTable)
        if not self.shown or table.cursor_row is None or table.cursor_row >= len(self.shown):
            return None
        return self.shown[table.cursor_row]

    def show_detail(self) -> None:
        a = self.current()
        programs = [x for x in self.apps if x.cloud is None]
        head = f"{sum(1 for x in programs if x.installed)} of {len(programs)} installed"
        if a is None:
            text = f"{head} · nothing matches"
        elif a.cloud is not None:
            text = f"{head} · " + ("Enter takes it away" if a.chosen else "Enter adds it" if a.installable else "sign in to it on the Mac first")
        elif a.installed:
            text = f"{head} · Enter runs: {a.command()}" + (" · Ctrl-R removes" if remove_script(a, self.distro) else "")
        elif a.installable:
            text = f"{head} · Enter installs {a.name}"
        else:
            text = f"{head} · {a.name} is not packaged for {'Alpine' if self.distro == 'alpine' else 'Debian'}"
        self.query_one("#detail", Static).update(text)

    def on_input_changed(self, event: Input.Changed) -> None:
        self.fill()

    def on_input_submitted(self, event: Input.Submitted) -> None:
        self.action_open()

    def on_data_table_row_highlighted(self, event: DataTable.RowHighlighted) -> None:
        self.show_detail()

    def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
        self.action_open()

    def action_down(self) -> None:
        self.query_one(DataTable).action_cursor_down()

    def action_up(self) -> None:
        self.query_one(DataTable).action_cursor_up()

    def action_page_down(self) -> None:
        self.query_one(DataTable).action_page_down()

    def action_page_up(self) -> None:
        self.query_one(DataTable).action_page_up()

    def action_clear(self) -> None:
        field = self.query_one(Input)
        if field.value:
            field.value = ""
        else:
            self.exit()
        field.focus()

    # ---- run, install, remove ------------------------------------------------------------------------------------------
    def action_open(self) -> None:
        a = self.current()
        if a is None:
            return
        if a.cloud is not None:
            self.toggle_cloud(a)
        elif a.installed:
            self.run_app(a)
        elif a.installable:
            self.action_install()
        else:
            self.notify(f"{a.name} is not packaged for this distribution.", severity="warning")

    def toggle_cloud(self, a: AppEntry) -> None:
        """Adds or takes away a cloud drive: the launcher restarts the machine to attach or detach it."""
        if not a.installable:
            self.notify(f"{a.name} is not on this Mac: install it there and sign in, then open Apps… again.", severity="warning")
            return
        f = a.cloud or {}
        machine = self.machine or "this machine"
        chosen = [x.cloud["id"] for x in self.apps if x.cloud is not None and x.chosen]
        if a.chosen:
            chosen.remove(f["id"])
            title, body, ok = f"Take {a.name} away?", f"~/{f['guest']} goes away; the files stay in your Mac's {a.name}.", "Take Away"
        else:
            chosen.append(f["id"])
            title, body, ok = f"Add {a.name}?", f"Your Mac's {a.name} folder shows up as ~/{f['guest']}; the Mac's {a.name} app keeps it in sync.", "Add and Restart"
        body += f"\n\n{machine} restarts to attach it (about half a minute): this terminal closes and opens again."

        def answered(yes: bool | None) -> None:
            if not yes:
                return
            tmp = self.cloud_request.with_suffix(".tmp")
            try:
                tmp.write_text(json.dumps({"folders": chosen}))
                tmp.replace(self.cloud_request)
            except OSError as e:
                self.notify(f"Could not ask the launcher: {e}", severity="error")
                return
            self.exit(message=f"myLinux Apps: {machine} restarts for {a.name}; the terminal opens again when it is back.")
        self.push_screen(Confirm(title, body, ok), answered)

    def action_install(self) -> None:
        a = self.current()
        if a is None or not a.installable or a.cloud is not None:
            return
        script = install_script(a, self.distro)
        verb = "Reinstall" if a.installed else "Install"

        def answered(ok: bool | None) -> None:
            if ok:
                self.hand_over(script, f"{verb}ing {a.name}", wait=True)
                refresh(self.apps)
                self.fill(keep=a.id)
                self.notify(f"{a.name} is installed." if a.installed else f"{a.name} did not install; see the output above.",
                            severity="information" if a.installed else "error")
        self.push_screen(Confirm(f"{verb} {a.name}?", script, verb), answered)

    def action_remove(self) -> None:
        a = self.current()
        if a is not None and a.cloud is not None and a.chosen:
            self.toggle_cloud(a)
            return
        if a is None or not a.installed:
            return
        script = remove_script(a, self.distro)
        if script is None:
            self.notify(f"{a.name} came from its own installer; remove it the way its docs say.", severity="warning")
            return

        def answered(ok: bool | None) -> None:
            if ok:
                self.hand_over(script, f"Removing {a.name}", wait=True)
                refresh(self.apps)
                self.fill(keep=a.id)
        self.push_screen(Confirm(f"Remove {a.name}?", script, "Remove"), answered)

    def run_app(self, a: AppEntry) -> None:
        self.hand_over(a.command(), None, wait=False, env=a.env)

    def hand_over(self, script: str, banner: str | None, wait: bool, env: dict[str, str] | None = None) -> int:
        """Gives the terminal to a shell running `script`, and takes it back after (App.suspend)."""
        shell = "/bin/bash" if Path("/bin/bash").exists() else "/bin/sh"
        run_env = dict(os.environ, PATH=search_path(), **(env or {}))
        with self.suspend():
            print("\033[2J\033[H", end="")
            if banner:
                print(f"\033[1m== {banner}\033[0m\n{script}\n", flush=True)
            started = time.monotonic()
            opts = ["-e"] if banner else []
            rc = subprocess.call([shell, *opts, "-c", script], env=run_env)
            # an install, a failure, or a program that ended at once (a version, a status) printed something to read
            quick = time.monotonic() - started < 5
            if wait or rc != 0 or quick:
                state = "done" if rc == 0 else f"ended with status {rc}"
                try:
                    input(f"\n\033[1m{state}\033[0m · Return goes back to myLinux Apps ")
                except (EOFError, KeyboardInterrupt):
                    pass
        return rc


def main() -> None:
    here = Path(__file__).resolve().parent
    catalog = Path(sys.argv[1]) if len(sys.argv) > 1 else here / "catalog.json"
    MyLinuxApps(catalog).run()


if __name__ == "__main__":
    main()
