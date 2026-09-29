"""myLinux speed test: the same JavaScript project (Excalidraw, one pinned commit: about 1,350 packages and 60,000
small files in node_modules) cloned, installed, scanned, deleted, installed again and built, on this machine's own disk.

Runs in a machine (myLinux Apps › Tools › Speed test) and on the Mac (python3 <share>/.mylinux/apps/speedtest.py), with
the same steps and the same tools (git, Bun, Node), so the times compare. Every run is added to speedtest.json beside
the app's folder in the Mac share, so the table at the end has the latest run of each machine and of the Mac.
    python3 speedtest.py            run it
    python3 speedtest.py --results  only the table
Standard library only, and Python 3.9 (the Mac's own /usr/bin/python3).
"""
from __future__ import annotations

import json
import os
import platform
import shlex
import shutil
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

REPO = "https://github.com/excalidraw/excalidraw.git"
COMMIT = "5a406e51875157bece389b9bc92d41ff241d5f3d"   # 2026-09-28; one commit, so every run builds the same thing
HERE = Path(__file__).resolve().parent
MAC = sys.platform == "darwin"
HOME = Path.home()
# the machine's own disk (never the Mac share, /mnt/mac, which is the Mac's disk seen through 9p)
BASE = HOME / ("Library/Caches" if MAC else ".cache") / "mylinux-speedtest"
# in the Mac share (<share>/.mylinux/apps): the results beside it, where the Mac and every machine find them
RESULTS = HERE.parent / "speedtest.json" if HERE.parent.name == ".mylinux" else BASE.parent / "mylinux-speedtest.json"
STEPS = [("clone", "git clone"), ("install", "bun install, downloading"), ("scan", "read every file's details"),
         ("delete", "rm -rf node_modules"), ("reinstall", "bun install, from its cache"), ("build", "vite build")]
# the table's columns: what the steps show about the disk (the clone and the first install are mostly the network)
COLUMNS = ["install", "scan", "delete", "reinstall", "build"]
BOLD, DIM, GREEN, RED, OFF = ("\033[1m", "\033[2m", "\033[32m", "\033[31m", "\033[0m") if sys.stdout.isatty() else ("",) * 5


def os_release() -> dict:
    info = {}
    try:
        for line in Path("/etc/os-release").read_text().splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                info[k] = v.strip().strip('"')
    except OSError:
        pass
    return info


def distro() -> str:
    """alpine, debian or arch (Omarchy), as myLinux Apps names them; mac on the Mac."""
    if MAC:
        return "mac"
    info = os_release()
    ids = [info.get("ID", "")] + info.get("ID_LIKE", "").split()
    return "alpine" if "alpine" in ids else "arch" if {"arch", "archarm", "omarchy"} & set(ids) else "debian"


def machine_name() -> str:
    """What the table calls this one: Mac, or the kind and the launcher's name for the machine."""
    if MAC:
        return "Mac"
    kind = {"alpine": "Alpine", "arch": "Omarchy", "debian": "Debian"}[distro()]
    try:
        name = json.loads((HERE.parent / "cloud.json").read_text()).get("machine", "")
    except (OSError, ValueError):
        name = ""
    return f"{kind} ({name})" if name and name.lower() != kind.lower() else kind


def mac_path() -> str:
    """This script as the Mac sees it (the launcher writes the machine's share folder into cloud.json)."""
    try:
        share = json.loads((HERE.parent / "cloud.json").read_text()).get("share", "")
    except (OSError, ValueError):
        share = ""
    return shlex.quote(f"{share}/.mylinux/apps/speedtest.py") if share else "<the machine's share folder>/.mylinux/apps/speedtest.py"


def filesystem(path: Path) -> str:
    if MAC:
        return "APFS"
    best, fs = "", "?"
    try:
        for line in Path("/proc/mounts").read_text().splitlines():
            parts = line.split()
            if len(parts) > 2 and str(path).startswith(parts[1].rstrip("/") + "/") and len(parts[1]) >= len(best):
                best, fs = parts[1], parts[2]
    except OSError:
        pass
    return fs


def search_path() -> str:
    extra = [HOME / ".bun/bin", HOME / ".local/bin", Path("/opt/homebrew/bin"), Path("/usr/local/bin")]
    # nvm's Node on the Mac (a shell function there, not on a script's PATH): the newest one
    nvm = sorted((HOME / ".nvm/versions/node").glob("v*/bin"), key=lambda p: [int(x) for x in p.parent.name[1:].split(".") if x.isdigit()])
    parts = os.environ.get("PATH", "").split(os.pathsep)
    return os.pathsep.join(parts + [str(p) for p in extra + nvm[-1:] if str(p) not in parts])


def version(tool: str, env: dict) -> str:
    try:
        out = subprocess.run([tool, "--version"], env=env, capture_output=True, text=True, timeout=20).stdout.strip()
        return out.splitlines()[0].lstrip("v") if out else "?"
    except (OSError, subprocess.SubprocessError):
        return "?"


def install_tools(missing: list[str], env: dict) -> bool:
    """git, Node and Bun, from the distribution (and Bun's installer), after asking."""
    kind = distro()
    packages = {"alpine": "git nodejs npm curl bash unzip libgcc libstdc++", "debian": "git nodejs curl unzip ca-certificates",
                "arch": "git nodejs curl unzip"}[kind]
    lines = {"alpine": [f"doas apk add {packages}"],
             "debian": ["sudo apt-get update -q", f"sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q {packages}"],
             "arch": [f"sudo pacman -S --needed --noconfirm {packages} || sudo pacman -Sy --needed --noconfirm {packages}"]}[kind]
    if "bun" in missing:
        lines.append("curl -fsSL https://bun.sh/install | bash")
    print(f"The speed test needs {', '.join(missing)}. Installed with:")
    for l in lines:
        print(f"  {DIM}{l}{OFF}")
    try:
        if input("Install now? [Y/n] ").strip().lower() not in ("", "y", "yes"):
            return False
    except (EOFError, KeyboardInterrupt):
        return False
    for l in lines:
        if subprocess.call(["sh", "-c", l], env=env) != 0:
            print(f"{RED}That did not work.{OFF}")
            return False
    return True


def fmt(seconds: float | None) -> str:
    if seconds is None:
        return "–"
    return f"{seconds:.2f} s" if seconds < 10 else f"{seconds:.1f} s" if seconds < 100 else f"{seconds / 60:.1f} min"


def load_results() -> list[dict]:
    try:
        runs = json.loads(RESULTS.read_text())
        return runs if isinstance(runs, list) else []
    except (OSError, ValueError):
        return []


def latest_per_machine(runs: list[dict]) -> list[dict]:
    latest: dict[str, dict] = {}
    for r in runs:
        latest[r.get("machine", "?")] = r
    # the Mac first, then the machines in the order they were first tested
    return sorted(latest.values(), key=lambda r: (r.get("machine") != "Mac", runs.index(r)))


def table(runs: list[dict]) -> str:
    rows = latest_per_machine(runs)
    if not rows:
        return "No results yet."
    mac = next((r for r in rows if r.get("machine") == "Mac"), None)
    width = max(12, *(len(r.get("machine", "")) for r in rows))
    heads = {"install": "install", "scan": "scan", "delete": "delete", "reinstall": "reinstall", "build": "build"}
    out = [f"{'':{width}}  " + "  ".join(f"{heads[c]:>12}" for c in COLUMNS)]
    for r in rows:
        t = r.get("times", {})
        out.append(f"{r.get('machine', '?'):{width}}  " + "  ".join(f"{fmt(t.get(c)):>12}" for c in COLUMNS))
        if mac is not None and r is not mac:
            m = mac.get("times", {})
            cells = []
            for c in COLUMNS:
                a, b = m.get(c), t.get(c)
                cells.append(f"{a / b:.1f}× faster" if a and b and a / b >= 1.05 else f"{b / a:.1f}× slower" if a and b and b / a >= 1.05 else "same" if a and b else "")
            out.append(f"{DIM}{'  vs the Mac':{width}}  " + "  ".join(f"{c:>12}" for c in cells) + OFF)
    notes = [f"{r.get('machine')}: {r.get('fs', '?')}, {r.get('cpus', '?')} CPUs, {r.get('memory_gb', '?')} GB, "
             f"Bun {r.get('bun', '?')}, Node {r.get('node', '?')}, {r.get('files', '?'):,} files, {r.get('when', '')[:16].replace('T', ' ')}"
             for r in rows if isinstance(r.get("files"), int)]
    return "\n".join(out + [""] + [f"{DIM}{n}{OFF}" for n in notes])


def memory_gb() -> float | None:
    try:
        if MAC:
            return round(int(subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True, text=True).stdout) / 2**30, 1)
        for line in Path("/proc/meminfo").read_text().splitlines():
            if line.startswith("MemTotal:"):
                return round(int(line.split()[1]) / 2**20, 1)
    except (OSError, ValueError):
        pass
    return None


def count_files(root: Path) -> int:
    n, stack = 0, [str(root)]
    while stack:
        with os.scandir(stack.pop()) as it:
            for e in it:
                if e.is_dir(follow_symlinks=False):
                    stack.append(e.path)
                else:
                    e.stat(follow_symlinks=False)
                    n += 1
    return n


def run_test() -> int:
    env = dict(os.environ, PATH=search_path(), BUN_INSTALL_CACHE_DIR=str(BASE / "bun-cache"))
    env.pop("NODE_OPTIONS", None)
    missing = [t for t in ("git", "bun", "node") if not shutil.which(t, path=env["PATH"])]
    if missing:
        if MAC:
            print(f"The speed test needs {', '.join(missing)} on the Mac: Bun from https://bun.sh, Node from https://nodejs.org or nvm.")
            return 1
        if not install_tools(missing, env):
            return 1
        env["PATH"] = search_path()
        missing = [t for t in ("git", "bun", "node") if not shutil.which(t, path=env["PATH"])]
        if missing:
            print(f"{RED}Still not found: {', '.join(missing)}.{OFF}")
            return 1
    BASE.mkdir(parents=True, exist_ok=True)
    free = shutil.disk_usage(BASE).free / 2**30
    if free < 3:
        print(f"{RED}The speed test needs about 3 GB free on this disk; {free:.1f} GB is.{OFF}")
        return 1
    name = machine_name()
    print(f"{BOLD}myLinux speed test · {name}{OFF}")
    print(f"{DIM}Excalidraw ({COMMIT[:9]}) in {BASE} ({filesystem(BASE)}); results in {RESULTS}{OFF}\n")
    work, log = BASE / "excalidraw", BASE / "speedtest.log"
    # a fresh start: the project and Bun's cache from an earlier run go (the first install downloads, every time)
    subprocess.call(["rm", "-rf", "excalidraw", "bun-cache"], cwd=BASE)
    times: dict[str, float | None] = {}
    files = None
    steps = {
        "clone": (["sh", "-c", f"git init -q excalidraw && cd excalidraw && git fetch -q --depth 1 {REPO} {COMMIT} && git checkout -q FETCH_HEAD"], BASE),
        "install": (["bun", "install"], work),
        "delete": (["rm", "-rf", "node_modules"], work),
        "reinstall": (["bun", "install"], work),
        "build": (["node", "../node_modules/vite/bin/vite.js", "build"], work / "excalidraw-app"),
    }
    with open(log, "w") as out:
        for step, words in STEPS:
            print(f"  {words:<30} ", end="", flush=True)
            started = time.monotonic()
            if step == "scan":
                try:
                    files = count_files(work / "node_modules")
                    ok = True
                except OSError as e:
                    out.write(f"scan: {e}\n")
                    ok = False
            else:
                cmd, cwd = steps[step]
                out.write(f"\n== {step}: {' '.join(cmd)}\n"); out.flush()
                try:
                    ok = subprocess.call(cmd, cwd=cwd, env=env, stdout=out, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, timeout=1800) == 0
                except (OSError, subprocess.TimeoutExpired) as e:
                    out.write(f"{e}\n")
                    ok = False
            seconds = time.monotonic() - started
            times[step] = seconds if ok else None
            extra = f"  {DIM}{files:,} files{OFF}" if step == "scan" and files else ""
            print(f"{GREEN}{fmt(seconds)}{OFF}{extra}" if ok else f"{RED}failed{OFF} {DIM}(after {fmt(seconds)}; {log}){OFF}")
            if not ok and step in ("clone", "install"):
                print(f"\n{DIM}" + "".join(open(log).readlines()[-12:]) + OFF)
                return 1
            if not ok and step == "build" and (memory_gb() or 0) < 3.5:
                print(f"  {DIM}(the build needs memory: this one has {memory_gb()} GB; give the machine 4 GB or more){OFF}")
    runs = load_results()
    runs.append({"when": datetime.now().isoformat(timespec="seconds"), "machine": name, "host": platform.node(),
                 "system": platform.platform(terse=True) if MAC else os_release().get("PRETTY_NAME", "Linux"),
                 "fs": filesystem(BASE), "cpus": os.cpu_count(), "memory_gb": memory_gb(), "files": files,
                 "bun": version("bun", env), "node": version("node", env), "commit": COMMIT, "times": times})
    try:
        RESULTS.write_text(json.dumps(runs[-50:], indent=1) + "\n")
    except OSError as e:
        print(f"{RED}Could not save the result in {RESULTS}: {e}{OFF}")
    # the 850 MB it made go again
    subprocess.call(["rm", "-rf", "excalidraw", "bun-cache"], cwd=BASE)
    print(f"\n{BOLD}The latest run of each{OFF}\n")
    print(table(runs))
    if not MAC:
        print(f"\n{DIM}The same test on the Mac, in its Terminal:{OFF}\n  python3 {mac_path()}")
    return 0


def main() -> int:
    if "--results" in sys.argv[1:]:
        print(table(load_results()))
        return 0
    try:
        return run_test()
    except KeyboardInterrupt:
        print("\nStopped.")
        return 130


if __name__ == "__main__":
    sys.exit(main())
