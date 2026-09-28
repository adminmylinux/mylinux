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
from textual.widgets import Button, DataTable, Footer, Header, Input, OptionList, Static
from rich.markup import escape
from rich.text import Text

HOME = Path.home()
# where the installers put things, found also when the shell's PATH does not have them yet
EXTRA_PATH = [HOME / ".local/bin", HOME / ".bun/bin", HOME / ".npm-global/bin", HOME / ".cargo/bin", Path("/usr/local/bin")]

# ---- the look: Nerd Font symbols, which Ghostty has built in (MYLINUX_APPS_PLAIN=1 for a terminal without them) ------
PLAIN = os.environ.get("MYLINUX_APPS_PLAIN") == "1"
GLYPHS = {
    "search": "f002", "run": "f04b", "install": "f019", "remove": "f1f8", "update": "f021", "add": "f0c2",
    "installed": "f058", "available": "f10c", "unavailable": "f05e", "pending": "f017",
    "All": "f00a", "Installed": "f058", "Aliases": "f0c1", "Cloud drives": "f0c2", "Agents": "f06a9", "System": "f0e4", "Terminal": "f120",
    "Files": "f07c", "Editors": "f040", "Code": "f121", "Tools": "f0ad", "Other": "f013",
}
PLAIN_GLYPHS = {"installed": "●", "available": "○", "unavailable": "–", "pending": "◐", "run": "▶", "install": "↓",
                "remove": "✕", "update": "↻", "add": "+", "search": "›"}
CATEGORIES = ["All", "Installed", "Aliases", "Cloud drives", "Agents", "System", "Terminal", "Files", "Editors", "Code", "Tools"]
ACCENT, MUTED, GOOD, WAIT = "#2563eb", "#94a3b8", "#22c55e", "#eab308"


def glyph(name: str | None, code: str = "") -> str:
    """A symbol by its name (or an app's own code point, hex), or in plain mode a simple character."""
    if PLAIN:
        return PLAIN_GLYPHS.get(name or "", "")
    code = code or GLYPHS.get(name or "", "")
    return chr(int(code, 16)) if code else ""


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
    if "arch" in ids or "archarm" in ids or "omarchy" in ids:
        return "arch"
    return "debian"


DISTRO_NAMES = {"alpine": "Alpine", "debian": "Debian", "arch": "Omarchy"}
PACKAGE_KEYS = {"alpine": "apk", "debian": "apt", "arch": "pacman"}
ROOT = {"alpine": "doas", "debian": "sudo", "arch": "sudo"}


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
    icon: str = ""                    # its own Nerd Font symbol (hex), else its category's
    cloud: dict | None = None         # a cloud drive: {"id", "title", "guest", "onMac"}
    alias: dict | None = None         # an alias: {"name", "command", "app", "description"}
    enabled: bool = False             # an alias that is on (in ~/.config/mylinux/aliases.sh)
    chosen: bool = False              # a cloud drive the machine has (attached at its start)
    attached: bool = False            # its share is there (mounting it is all that is left)

    @property
    def special(self) -> bool:
        """An alias or a cloud drive: listed on top, not a program."""
        return self.cloud is not None or self.alias is not None

    @property
    def installable(self) -> bool:
        if self.alias is not None:
            return True
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
    pkg_key = PACKAGE_KEYS[distro]
    apps = []
    for a in data["apps"]:
        packages = list(a.get(pkg_key, []))
        steps = list(a.get("script", [])) + list(a.get(distro, []))
        # the distribution's own lines come after the shared ones, except its packages, which come first
        apps.append(AppEntry(id=a["id"], name=a["name"], category=a.get("category", "Other"),
                             description=a.get("description", ""), bins=list(a.get("bin", [])),
                             run=a.get("run", a["id"]), packages=packages, steps=steps,
                             env=dict(a.get("env", {})) | dict(a.get(f"{distro}_env", {})), icon=a.get("icon", "")))
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
        icons = {"dropbox": "f16b", "onedrive": "f03ca", "icloud": "f179", "googledrive": "f02b6"}
        drives.append(AppEntry(id="cloud:" + f["id"], name=f["title"], category="Cloud drives", description="",
                               bins=[], run=f"cd ~/{f['guest']} && ls", packages=[], steps=[],
                               cloud=f, chosen=f["id"] in chosen, icon=icons.get(f["id"], "")))
    return drives, data.get("machine", "")


def attached_tags() -> set[str]:
    """The 9p shares the machine has (a cloud drive is attached when the machine starts)."""
    tags = set()
    for f in Path("/sys/bus/virtio/drivers/9pnet_virtio").glob("*/mount_tag"):
        try:
            tags.add(f.read_text().strip("\0\n "))
        except OSError:
            pass
    return tags


MOUNT_TEMPLATE = """R=; [ "$(id -u)" = 0 ] || R="@ROOT@"
want="@WANT@"; changed=
for pair in @ALL@; do
  tag=${pair%%:*}; name=${pair#*:}; mp=/mnt/$tag
  case " $want " in
    *" $pair "*)
      $R mkdir -p "$mp"
      grep -q "^$tag $mp " /etc/fstab || { echo "$tag $mp 9p trans=virtio,version=9p2000.L,msize=512000,nofail,_netdev 0 0" | $R tee -a /etc/fstab >/dev/null; changed=1; }
      mountpoint -q "$mp" || $R mount "$mp" 2>/dev/null || echo "could not mount $tag (restart the machine to attach it)"
      if [ ! -e "$HOME/$name" ] || [ -L "$HOME/$name" ]; then ln -sfn "$mp" "$HOME/$name"; fi
      ! mountpoint -q "$mp" || echo "~/$name is ready" ;;
    *)
      if grep -q "^$tag $mp " /etc/fstab; then
        ! mountpoint -q "$mp" || $R umount "$mp"
        $R sed -i "\\#^$tag $mp #d" /etc/fstab; changed=1
      fi
      # only the link this made, and only a link: unlink cannot take a folder
      if [ -L "$HOME/$name" ] && [ "$(readlink "$HOME/$name")" = "$mp" ]; then unlink "$HOME/$name"; fi ;;
  esac
done
[ -z "$changed" ] || ! command -v systemctl >/dev/null || $R systemctl daemon-reload 2>/dev/null || true"""


def cloud_mount_script(want: list[str], drives: list[dict], root: str) -> str:
    """Mount the wanted cloud drives at /mnt/<tag> through /etc/fstab (so they come back at every start) and link them
    as ~/<name>; take out the others. The launcher's CloudFolder.mountScript, for a machine it cannot reach as root
    (Omarchy): run here, where sudo can ask for the password."""
    pairs = lambda ds: " ".join(f"{d['id']}:{d['guest']}" for d in ds)
    return (MOUNT_TEMPLATE.replace("@ROOT@", root).replace("@WANT@", pairs([d for d in drives if d["id"] in want]))
            .replace("@ALL@", pairs(drives)))


def in_fstab(tag: str) -> bool:
    try:
        return any(line.split()[:1] == [tag] for line in Path("/etc/fstab").read_text().splitlines())
    except OSError:
        return False


def describe_cloud(a: AppEntry) -> str:
    f = a.cloud or {}
    if a.chosen and a.installed:
        return f"Your Mac's {f['title']}, in ~/{f['guest']}"
    if a.chosen and a.attached:
        return f"Your Mac's {f['title']}: Enter mounts it as ~/{f['guest']}"
    if a.chosen:
        return f"Your Mac's {f['title']}, at the next start"
    if f.get("onMac"):
        return f"Your Mac's {f['title']}, as ~/{f['guest']}"
    return f"Sign in to {f['title']} on the Mac first"


# ---- aliases: short names for commands, on in every new shell (run.sh's block in ~/.profile and ~/.bashrc sources the file)
ALIASES_FILE = HOME / ".config/mylinux/aliases.sh"


def quote_alias(command: str) -> str:
    return "'" + command.replace("'", "'\\''") + "'"


def aliases_on(catalog_aliases: list[dict]) -> set[str]:
    """The names turned on: from the file, or the catalog's defaults before there is one (written then)."""
    if not ALIASES_FILE.exists():
        on = {a["name"] for a in catalog_aliases if a.get("default")}
        write_aliases(catalog_aliases, on)
        return on
    on = set()
    for line in ALIASES_FILE.read_text().splitlines():
        if line.startswith("alias ") and "=" in line:
            on.add(line[6:].split("=", 1)[0])
    return on


def write_aliases(catalog_aliases: list[dict], on: set[str]) -> None:
    ALIASES_FILE.parent.mkdir(parents=True, exist_ok=True)
    lines = ["# myLinux Apps: the aliases turned on in it (Aliases, at the top); it rewrites this file"]
    lines += [f"alias {a['name']}={quote_alias(a['command'])}" for a in catalog_aliases if a["name"] in on]
    tmp = ALIASES_FILE.with_suffix(".tmp")
    tmp.write_text("\n".join(lines) + "\n")
    tmp.replace(ALIASES_FILE)


def load_aliases(path: Path) -> tuple[list[AppEntry], list[dict]]:
    catalog_aliases = json.loads(path.read_text()).get("aliases", [])
    on = aliases_on(catalog_aliases) if catalog_aliases else set()
    entries = [AppEntry(id="alias:" + a["name"], name=a["name"], category="Aliases", description=a.get("description", ""),
                        bins=[], run=a["command"], packages=[], steps=[], alias=a, enabled=a["name"] in on)
               for a in catalog_aliases]
    return entries, catalog_aliases


def install_script(app: AppEntry, distro: str) -> str:
    lines = []
    if app.packages:
        pk = " ".join(shlex.quote(p) for p in app.packages)
        if distro == "alpine":
            lines += ["doas apk update -q", f"doas apk add {pk}"]
        elif distro == "arch":
            # from the package lists as they are; when those are too old for the mirrors (a 404), synced first. Not a
            # full upgrade: Try Omarchy holds back its kernel and Hyprland (IgnorePkg), so one would stop there
            lines += [f"sudo pacman -S --needed --noconfirm {pk} || sudo pacman -Sy --needed --noconfirm {pk}"]
        else:
            lines += ["sudo apt-get update -q", f"sudo DEBIAN_FRONTEND=noninteractive apt-get install -y {pk}"]
    return "\n".join(lines + app.steps)


def remove_script(app: AppEntry, distro: str) -> str | None:
    """Only a program that is just its packages is removed here; an installer's own files are left alone."""
    if app.steps or not app.packages:
        return None
    pk = " ".join(shlex.quote(p) for p in app.packages)
    return {"alpine": f"doas apk del {pk}", "arch": f"sudo pacman -Rs --noconfirm {pk}"}.get(distro, f"sudo apt-get remove -y {pk}")


def refresh(apps: list[AppEntry]) -> None:
    path = search_path()
    tags = attached_tags() if any(a.cloud is not None for a in apps) else set()
    for a in apps:
        if a.alias is not None:
            a.found = a.name if a.enabled else None
            continue
        if a.cloud is not None:
            mp = f"/mnt/{a.cloud['id']}"
            a.attached = a.cloud["id"] in tags
            a.found = f"~/{a.cloud['guest']}" if os.path.ismount(mp) else None
            a.description = describe_cloud(a)
        else:
            a.found = next((b for b in a.bins if shutil.which(b, path=path)), None)


class Confirm(ModalScreen[bool]):
    """What is about to happen, and OK / Cancel."""
    BINDINGS = [Binding("escape", "cancel", "Cancel"), Binding("enter", "ok", "OK", show=False)]
    DEFAULT_CSS = f"""
    Confirm {{ align: center middle; background: #0b1220 70%; }}
    #box {{ width: 90; max-width: 95%; height: auto; max-height: 90%; border: round {ACCENT}; background: #182235; padding: 1 2; }}
    #title {{ text-style: bold; margin-bottom: 1; }}
    #script {{ color: {MUTED}; margin-bottom: 1; }}
    #buttons {{ height: auto; align-horizontal: right; }}
    #buttons Button {{ margin-left: 2; border: none; height: 1; min-width: 12; background: #243247; }}
    #buttons Button:hover {{ background: #334155; }}
    #buttons #ok {{ background: {ACCENT}; color: #ffffff; text-style: bold; }}
    """

    def __init__(self, title: str, script: str, ok: str) -> None:
        super().__init__()
        self.title_text, self.script, self.ok_label = title, script, ok

    def compose(self) -> ComposeResult:
        with Vertical(id="box"):
            yield Static(self.title_text, id="title", markup=False)
            yield Static(self.script, id="script", markup=False)
            with Horizontal(id="buttons"):
                yield Button("Cancel", id="cancel")
                yield Button(self.ok_label, id="ok")

    def on_mount(self) -> None:
        self.query_one("#ok", Button).focus()       # Enter confirms, Escape cancels

    def on_button_pressed(self, event: Button.Pressed) -> None:
        self.dismiss(event.button.id == "ok")

    def action_cancel(self) -> None:
        self.dismiss(False)

    def action_ok(self) -> None:
        self.dismiss(True)


class MyLinuxApps(App):
    TITLE = "myLinux Apps"
    CSS = f"""
    Screen {{ background: #111827; color: #e5e7eb; }}
    Header {{ background: #182235; color: #e5e7eb; }}
    Footer {{ background: #182235; }}
    #body {{ height: 1fr; }}
    #sidebar {{ width: 26; height: 1fr; background: #182235; border: none; padding: 1 1; }}
    #sidebar:focus {{ border: none; }}
    #sidebar > .option-list--option-highlighted {{ background: {ACCENT}; color: #ffffff; text-style: bold; }}
    #sidebar > .option-list--option-hover {{ background: #243247; }}
    #main {{ width: 1fr; height: 1fr; padding: 0 1; }}
    #search {{ margin: 1 0; border: round #334155; background: #111827; }}
    #search:focus {{ border: round {ACCENT}; }}
    #apps {{ height: 1fr; background: #111827; overflow-x: hidden; }}
    #apps > .datatable--cursor {{ background: {ACCENT}; color: #ffffff; }}
    #apps > .datatable--header {{ background: #111827; color: {MUTED}; }}
    #apps > .datatable--hover {{ background: #1f2a3d; }}
    #details {{ width: 46; height: 1fr; border: round #334155; padding: 1 2; margin: 1 1 1 0; background: #111827; }}
    #info {{ height: 1fr; }}
    #actions {{ height: auto; }}
    #actions Button {{ border: none; height: 1; min-width: 10; margin: 0 1 0 0; background: #243247; color: #e5e7eb; }}
    #actions Button:hover {{ background: #334155; }}
    #actions .primary {{ background: {ACCENT}; color: #ffffff; text-style: bold; }}
    #status {{ height: 1; padding: 0 2; background: #111827; color: {MUTED}; }}
    """
    # the search field keeps the keyboard: ↑↓ move in the list, ←→ change the category, Enter runs or installs
    BINDINGS = [
        Binding("down", "down", "Down", show=False, priority=True),
        Binding("up", "up", "Up", show=False, priority=True),
        Binding("right", "category(1)", "Category", show=False, priority=True),
        Binding("left", "category(-1)", "Category", show=False, priority=True),
        Binding("pagedown", "page_down", "Page down", show=False, priority=True),
        Binding("pageup", "page_up", "Page up", show=False, priority=True),
        Binding("enter", "open", "Run / Install", priority=True),
        Binding("ctrl+u", "install", "Update", priority=True),
        Binding("ctrl+r", "remove", "Remove", priority=True),
        Binding("escape", "clear", "Clear / Quit", priority=True),
        Binding("ctrl+q", "quit", "Quit", priority=True),
    ]

    ENABLE_COMMAND_PALETTE = False
    MAIN_KEYS = {"down", "up", "category", "page_down", "page_up", "open", "install", "remove", "clear"}

    def check_action(self, action: str, parameters: tuple) -> bool | None:
        # with a dialog open, its own keys (Enter, Escape) are its own
        if action in self.MAIN_KEYS and isinstance(self.screen, ModalScreen):
            return False
        return True

    def __init__(self, catalog: Path, query: str = "") -> None:
        super().__init__()
        self.query0 = query
        self.distro = distribution()
        self.cloud_state = catalog.parent.parent / "cloud.json"
        self.cloud_request = catalog.parent.parent / "cloud-request.json"
        drives, self.machine = load_cloud(self.cloud_state)
        aliases, self.catalog_aliases = load_aliases(catalog)
        self.apps = aliases + drives + load_catalog(catalog, self.distro)
        refresh(self.apps)
        self.shown: list[AppEntry] = []
        self.categories = [c for c in CATEGORIES if c in ("All", "Installed") or any(a.category == c for a in self.apps)]
        self.category = "All"
        self.sub_title = f"{DISTRO_NAMES[self.distro]} · {os.uname().nodename}"

    def compose(self) -> ComposeResult:
        yield Header()
        with Horizontal(id="body"):
            yield OptionList(id="sidebar")
            with Vertical(id="main"):
                yield Input(value=self.query0, placeholder="Search apps: claude, editor, git…", id="search")
                yield DataTable(id="apps", cursor_type="row", show_header=False)
            with Vertical(id="details"):
                yield Static("", id="info")
                with Horizontal(id="actions"):
                    yield Button("", id="run")
                    yield Button("", id="install")
                    yield Button("", id="remove")
        yield Static("", id="status")
        yield Footer()

    def on_mount(self) -> None:
        # the list, the categories and the buttons answer the mouse; the keyboard stays in the search field
        for w in (self.query_one("#apps", DataTable), self.query_one("#sidebar", OptionList), *self.query("#actions Button")):
            w.can_focus = False
        self.query_one("#apps", DataTable).add_columns("state", "app", "what")
        self.fill_sidebar()
        self.fill()
        self.query_one(Input).focus()
        self.fit(self.size.width)

    # ---- narrow terminals: the details, then the categories, fold away -------------------------------------------
    def on_resize(self, event) -> None:
        self.fit(event.size.width)

    def fit(self, width: int) -> None:
        self.query_one("#details").display = width >= 110
        self.query_one("#sidebar").display = width >= 74

    # ---- the categories ------------------------------------------------------------------------------------------
    def count(self, category: str) -> int:
        return sum(1 for a in self.apps if self.in_category(a, category))

    def in_category(self, a: AppEntry, category: str) -> bool:
        if category == "All":
            return True
        if category == "Installed":
            return a.installed and not a.special
        return a.category == category

    def fill_sidebar(self) -> None:
        side = self.query_one("#sidebar", OptionList)
        keep = self.categories.index(self.category)
        side.clear_options()
        for c in self.categories:
            label = Text.assemble((f"{glyph(c)}  " if glyph(c) else "", ""), (f"{c:<14}", "bold" if c == self.category else ""),
                                  (f"{self.count(c):>3}", MUTED))
            side.add_option(label)
        side.highlighted = keep

    def action_category(self, step: int) -> None:
        i = (self.categories.index(self.category) + step) % len(self.categories)
        self.set_category(self.categories[i])

    def set_category(self, category: str) -> None:
        if category != self.category:
            self.category = category
            self.fill_sidebar()
            self.fill()

    def on_option_list_option_highlighted(self, event: OptionList.OptionHighlighted) -> None:
        if event.option_list.id == "sidebar" and event.option_index is not None and event.option_index < len(self.categories):
            self.set_category(self.categories[event.option_index])

    def on_option_list_option_selected(self, event: OptionList.OptionSelected) -> None:
        self.on_option_list_option_highlighted(event)

    # ---- the list ----------------------------------------------------------------------------------------------------
    def matches(self, a: AppEntry, q: str) -> bool:
        return not q or any(q in s.lower() for s in (a.name, a.id, a.category, a.description, " ".join(a.bins)))

    def app_of(self, a: AppEntry) -> AppEntry | None:
        """The program an alias runs."""
        return next((x for x in self.apps if a.alias and x.id == a.alias.get("app")), None)

    def state(self, a: AppEntry) -> tuple[str, str, str]:
        """Its state: symbol name, colour, words."""
        if a.alias is not None:
            app = self.app_of(a)
            if a.enabled and app is not None and not app.installed:
                return "pending", WAIT, f"On; {app.name} is not installed yet"
            return ("installed", GOOD, "On in new shells") if a.enabled else ("available", "", "Off")
        if a.cloud is not None:
            if a.chosen and a.installed:
                return "installed", GOOD, f"In ~/{a.cloud['guest']}"
            if a.chosen and a.attached:
                return "pending", WAIT, "Attached, not mounted yet"
            if a.chosen:
                return "pending", WAIT, "Attached at the next start"
            return ("available", "", "On your Mac") if a.installable else ("unavailable", MUTED, "Not on this Mac")
        if a.installed:
            return "installed", GOOD, "Installed"
        if a.installable:
            return "available", "", "Not installed"
        return "unavailable", MUTED, f"Not packaged for {DISTRO_NAMES[self.distro]}"

    def fill(self, keep: str | None = None) -> None:
        q = self.query_one(Input).value.strip().lower()
        table = self.query_one("#apps", DataTable)
        current = self.current()
        keep = keep or (current.id if current else None)
        table.clear()
        # the cloud drives on top; then installed, then what can be installed here, then the rest; by category and name
        # the aliases, then the cloud drives, on top; then installed programs, then installable ones, then the rest
        order = lambda a: (-2 if a.alias is not None else -1 if a.cloud is not None else 0 if a.installed else 1 if a.installable else 2,
                           a.category, a.name.lower())
        # a search looks in every category
        self.shown = sorted((a for a in self.apps if (q or self.in_category(a, self.category)) and self.matches(a, q)), key=order)
        for a in self.shown:
            name_style = "bold" if a.installable or a.installed else f"bold {MUTED}"
            sym, colour, _ = self.state(a)
            icon = glyph(None, a.icon) or glyph(a.category)
            table.add_row(Text(glyph(sym), style=colour or "#e5e7eb"),
                          Text.assemble((f"{icon}  " if icon else "", MUTED if not (a.installable or a.installed) else ""), (a.name, name_style)),
                          Text(a.description, style=MUTED), key=a.id)
        ids = [a.id for a in self.shown]
        if keep in ids:
            table.move_cursor(row=ids.index(keep))
        self.show_detail()

    def current(self) -> AppEntry | None:
        table = self.query_one("#apps", DataTable)
        if not self.shown or table.cursor_row is None or table.cursor_row >= len(self.shown):
            return None
        return self.shown[table.cursor_row]

    def show_detail(self) -> None:
        a = self.current()
        programs = [x for x in self.apps if not x.special]
        head = f"{sum(1 for x in programs if x.installed)} of {len(programs)} installed"
        run, install, remove = (self.query_one(f"#{i}", Button) for i in ("run", "install", "remove"))
        for b in (run, install, remove):
            b.display = False
            b.remove_class("primary")
        if a is None:
            self.query_one("#info", Static).update(f"[{MUTED}]Nothing matches “{escape(self.query_one(Input).value)}”.[/]")
            self.query_one("#status", Static).update(f"{head} · nothing matches")
            return
        sym, colour, words = self.state(a)
        icon = glyph(None, a.icon) or glyph(a.category)
        lines = [f"[b]{icon}  {escape(a.name)}[/b]" if icon else f"[b]{escape(a.name)}[/b]",
                 f"[{MUTED}]{glyph(a.category)}  {escape(a.category)}[/]", "",
                 f"[{colour or '#e5e7eb'}]{glyph(sym)}  {escape(words)}[/]"]
        lines += ["", escape(a.description), ""] if a.cloud is None else [""]
        if a.alias is not None:
            app = self.app_of(a)
            lines += [f"[{MUTED}]Runs[/]", f"  {escape(a.alias['command'])}", "",
                      f"[{MUTED}]Typed as [b]{escape(a.name)}[/b] in a new shell (after leaving Apps, or in a new terminal)."
                      f" Kept in ~/.config/mylinux/aliases.sh.[/]"]
            if a.enabled and (app is None or app.installed):
                run.label = f"{glyph('run')}  Run"; run.display = True; run.add_class("primary")
            if a.enabled:
                remove.label = f"{glyph('remove')}  Turn Off"; remove.display = True
            else:
                install.label = f"{glyph('add')}  Turn On"; install.display = True; install.add_class("primary")
            if app is not None and not app.installed:
                install.label = f"{glyph('install')}  Install {app.name}"; install.display = True
                if not a.enabled:
                    install.remove_class("primary")
            hint = ("Enter runs " + a.name if a.enabled and (app is None or app.installed)
                    else f"Enter turns {a.name} on" if not a.enabled else f"install {app.name} first")
        elif a.cloud is not None:
            f = a.cloud
            lines += [f"[{MUTED}]Your Mac's {escape(f['title'])} folder as ~/{escape(f['guest'])}; the Mac keeps it in sync."
                      f" Adding or taking it away restarts the machine.[/]"]
            if a.chosen and a.attached and not a.installed:
                install.label = f"{glyph('add')}  Mount"; install.display = True; install.add_class("primary")
                remove.label = f"{glyph('remove')}  Take Away"; remove.display = True
            elif a.chosen:
                remove.label = f"{glyph('remove')}  Take Away"; remove.display = True
            elif a.installable:
                install.label = f"{glyph('add')}  Add"; install.display = True; install.add_class("primary")
            hint = ("Enter mounts it" if a.chosen and a.attached and not a.installed else "Enter takes it away" if a.chosen
                    else "Enter adds it" if a.installable else "sign in to it on the Mac first")
        else:
            if a.installed:
                lines += [f"[{MUTED}]Runs[/]", f"  {escape(a.command())}", ""]
            if a.installable:
                lines += [f"[{MUTED}]{'Updates' if a.installed else 'Installs'} with[/]"]
                lines += [f"  [{MUTED}]{escape(l)}[/]" for l in install_script(a, self.distro).splitlines()]
            if a.installed:
                run.label = f"{glyph('run')}  Run"; run.display = True; run.add_class("primary")
                if a.installable:
                    install.label = f"{glyph('update')}  Update"; install.display = True
                if remove_script(a, self.distro):
                    remove.label = f"{glyph('remove')}  Remove"; remove.display = True
                hint = f"Enter runs {a.command()}" + (" · ^R removes" if remove_script(a, self.distro) else "")
            elif a.installable:
                install.label = f"{glyph('install')}  Install"; install.display = True; install.add_class("primary")
                hint = f"Enter installs {a.name}"
            else:
                hint = words
        self.query_one("#info", Static).update("\n".join(lines))
        where = f" · {self.category}" if not self.query_one(Input).value.strip() else " · all categories"
        self.query_one("#status", Static).update(f"{head}{where} · {escape(hint)}")

    def move_to(self, a: AppEntry) -> None:
        """Puts the cursor on another row (the search is cleared when it hides that row)."""
        if a not in self.shown:
            self.query_one(Input).value = ""
            self.set_category("All")
            self.fill()
        self.query_one("#apps", DataTable).move_cursor(row=self.shown.index(a))

    def on_button_pressed(self, event: Button.Pressed) -> None:
        a = self.current()
        if a is None:
            return
        if event.button.id == "run":
            self.hand_over(a.alias["command"], None, wait=False) if a.alias is not None else self.run_app(a)
        elif event.button.id == "install":
            self.toggle_cloud(a) if a.cloud is not None else self.action_install()
        elif event.button.id == "remove":
            self.action_remove()
        self.query_one(Input).focus()

    def on_input_changed(self, event: Input.Changed) -> None:
        self.fill()

    def on_data_table_row_highlighted(self, event: DataTable.RowHighlighted) -> None:
        self.show_detail()

    def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
        self.action_open()

    def action_down(self) -> None:
        self.query_one("#apps", DataTable).action_cursor_down()

    def action_up(self) -> None:
        self.query_one("#apps", DataTable).action_cursor_up()

    def action_page_down(self) -> None:
        self.query_one("#apps", DataTable).action_page_down()

    def action_page_up(self) -> None:
        self.query_one("#apps", DataTable).action_page_up()

    def action_clear(self) -> None:
        field = self.query_one(Input)
        if field.value:
            field.value = ""
        elif self.category != "All":
            self.set_category("All")
        else:
            self.exit()
        field.focus()

    # ---- run, install, remove ------------------------------------------------------------------------------------------
    def action_open(self) -> None:
        a = self.current()
        if a is None:
            return
        if a.alias is not None:
            app = self.app_of(a)
            if not a.enabled:
                self.set_alias(a, True)
            elif app is not None and not app.installed:
                self.notify(f"{a.name} runs {app.name}, which is not installed yet: Install {app.name} does that.", severity="warning")
            else:
                self.hand_over(a.alias["command"], None, wait=False)
        elif a.cloud is not None:
            self.toggle_cloud(a)
        elif a.installed:
            self.run_app(a)
        elif a.installable:
            self.action_install()
        else:
            self.notify(f"{a.name} is not packaged for this distribution.", severity="warning")

    def drives(self) -> list[dict]:
        return [x.cloud for x in self.apps if x.cloud is not None]

    def mount_cloud(self, a: AppEntry) -> None:
        """An attached cloud drive the launcher could not mount (Omarchy: no way in as root): mounted here, with fstab."""
        chosen = [x.cloud["id"] for x in self.apps if x.cloud is not None and x.chosen]
        script = cloud_mount_script(chosen, self.drives(), ROOT[self.distro])

        def answered(yes: bool | None) -> None:
            if yes:
                self.hand_over(script, f"Mounting {a.name}", wait=True)
                refresh(self.apps); self.fill_sidebar(); self.fill(keep=a.id)
        self.push_screen(Confirm(f"Mount {a.name}?", f"~/{a.cloud['guest']} becomes your Mac's {a.name} folder, now and at every "
                                 f"start (a line in /etc/fstab). {ROOT[self.distro]} may ask for your password.", "Mount"), answered)

    def set_alias(self, a: AppEntry, on: bool) -> None:
        a.enabled = on
        write_aliases(self.catalog_aliases, {x.name for x in self.apps if x.alias is not None and x.enabled})
        refresh(self.apps); self.fill_sidebar(); self.fill(keep=a.id)
        self.notify(f"{a.name} is {'on' if on else 'off'} in new shells (this terminal's, once you leave Apps).")

    def toggle_cloud(self, a: AppEntry) -> None:
        """Enter on a cloud drive: an attached one is mounted, a chosen one taken away, another added."""
        if a.chosen and a.attached and not a.installed:
            self.mount_cloud(a)
        elif a.chosen:
            self.take_away(a)
        else:
            self.change_cloud(a, add=True)

    def take_away(self, a: AppEntry) -> None:
        self.change_cloud(a, add=False)

    def change_cloud(self, a: AppEntry, add: bool) -> None:
        """Adds or takes away a cloud drive: the launcher restarts the machine to attach or detach it."""
        if add and not a.installable:
            self.notify(f"{a.name} is not on this Mac: install it there and sign in, then open Apps… again.", severity="warning")
            return
        f = a.cloud or {}
        machine = self.machine or "this machine"
        chosen = [x.cloud["id"] for x in self.apps if x.cloud is not None and x.chosen and x.cloud["id"] != f["id"]]
        if add:
            chosen.append(f["id"])
            title, body, ok = f"Add {a.name}?", f"Your Mac's {a.name} folder shows up as ~/{f['guest']}; the Mac's {a.name} app keeps it in sync.", "Add and Restart"
        else:
            title, body, ok = f"Take {a.name} away?", f"~/{f['guest']} goes away; the files stay in your Mac's {a.name}.", "Take Away"
        # a desktop's terminal does not come back by itself after the restart: Apps… again mounts what was added
        after = ("then Apps… (⇧⌘A) again mounts it" if add else "") if self.distro == "arch" else "this terminal closes and opens again"
        body += f"\n\n{machine} restarts to {'attach' if add else 'detach'} it (about half a minute)" + (f": {after}." if after else ".")

        def answered(yes: bool | None) -> None:
            if not yes:
                return
            # taken away: its mount and fstab line go first (where the launcher does not do that itself)
            if not add and in_fstab(f["id"]):
                self.hand_over(cloud_mount_script(chosen, self.drives(), ROOT[self.distro]), f"Taking {a.name} away", wait=False)
            tmp = self.cloud_request.with_suffix(".tmp")
            try:
                tmp.write_text(json.dumps({"folders": chosen}))
                tmp.replace(self.cloud_request)
            except OSError as e:
                self.notify(f"Could not ask the launcher: {e}", severity="error")
                return
            self.exit(message=f"myLinux Apps: {machine} restarts for {a.name}" + (f"; {after}." if after else "."))
        self.push_screen(Confirm(title, body, ok), answered)

    def action_install(self) -> None:
        a = self.current()
        if a is not None and a.alias is not None:
            app = self.app_of(a)
            if app is not None and not app.installed:
                self.move_to(app)          # the program's own row: its install, with its commands shown
                self.action_install()
            elif not a.enabled:
                self.set_alias(a, True)
            return
        if a is None or not a.installable or a.special:
            return
        script = install_script(a, self.distro)
        verb = "Reinstall" if a.installed else "Install"

        def answered(ok: bool | None) -> None:
            if ok:
                self.hand_over(script, f"{verb}ing {a.name}", wait=True)
                refresh(self.apps)
                self.fill_sidebar()
                self.fill(keep=a.id)
                self.notify(f"{a.name} is installed." if a.installed else f"{a.name} did not install; see the output above.",
                            severity="information" if a.installed else "error")
        self.push_screen(Confirm(f"{verb} {a.name}?", script, verb), answered)

    def action_remove(self) -> None:
        a = self.current()
        if a is not None and a.alias is not None:
            if a.enabled:
                self.set_alias(a, False)
            return
        if a is not None and a.cloud is not None and a.chosen:
            self.take_away(a)
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
                self.fill_sidebar()
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
    # mylinux-apps claude: starts with that search
    MyLinuxApps(catalog, " ".join(sys.argv[2:])).run()


if __name__ == "__main__":
    main()
