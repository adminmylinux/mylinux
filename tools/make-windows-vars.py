#!/usr/bin/env python3
"""Make windows/vars.fd.gz: the firmware settings a new Windows machine starts with (run-windows.sh unpacks it as the
machine's vars.fd), which differ from an empty one in one thing: the screen the firmware starts with is 1024x768 and
not 800x600. Windows Setup and Windows's first-run screens draw on that screen (the firmware's framebuffer, ramfb), and
1024x768 is the largest this firmware's ramfb driver has (its list is 640x480, 800x600, 1024x768; others fall back to
800x600).
How: the firmware is started alone (no disks, no window, its console on the serial port), its shell sets the variable
its own setup menu would (PlatformConfig: width and height as two 32-bit numbers; Device Manager > OVMF Platform
Configuration writes the same), and a second start checks the screen's size over QMP.
Needs the accelerated runtime (out/qemu-runtime) and the firmware (out/windows/edk2-aarch64-code.fd, tools/get-windows.sh
or tools/get-edk2.sh). The result is committed: run this again when the runtime's firmware changes.
Usage: tools/make-windows-vars.py [WxH]"""
import gzip, json, os, re, select, socket, struct, subprocess, sys, tempfile, time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.environ.get("MYLINUX_OUT", os.path.join(REPO, "out"))
QEMU = os.path.join(OUT, "qemu-runtime", "bin", "qemu-system-aarch64")
CODE = os.path.join(OUT, "windows", "edk2-aarch64-code.fd")
GUID = "7235c51c-0c80-4cab-87ac-3b084a6304b1"            # gOvmfPlatformConfigGuid
WIDTH, HEIGHT = (int(v) for v in (sys.argv[1] if len(sys.argv) > 1 else "1024x768").split("x"))


def firmware(vars_file, commands):
    """Start the firmware with that settings file, run the commands in its shell; what it said, and its screen's size."""
    sock = os.path.join(tempfile.gettempdir(), f"mylinux-fw-{os.getpid()}.sock")
    p = subprocess.Popen([QEMU, "-M", "virt,gic-version=3,highmem-mmio=off", "-accel", "hvf", "-cpu", "host", "-m", "1G",
                          "-drive", f"if=pflash,format=raw,readonly=on,file={CODE}", "-drive", f"if=pflash,format=raw,file={vars_file}",
                          "-nic", "none", "-device", "ramfb", "-display", "none", "-serial", "stdio", "-monitor", "none",
                          "-qmp", f"unix:{sock},server=on,wait=off"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, bufsize=0)
    out = b""

    def read_until(words, seconds):
        nonlocal out
        end = time.time() + seconds
        while time.time() < end:
            if select.select([p.stdout], [], [], 0.3)[0]:
                data = os.read(p.stdout.fileno(), 4096)
                if not data:
                    return False
                out += data
                if any(w in out for w in words):
                    return True
        return False

    def send(text):
        p.stdin.write(text.encode()); p.stdin.flush()

    try:
        read_until([b"Shell>", b"startup.nsh"], 60)
        if b"Shell>" not in out:
            send("\x1b"); read_until([b"Shell>"], 15)           # Esc: no wait for a start-up script
        if b"Shell>" not in out:
            sys.exit("the firmware's shell did not come up:\n" + out.decode("latin-1")[-600:])
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(sock); f = s.makefile("rw")

        def qmp(name, **arguments):
            s.sendall((json.dumps({"execute": name, "arguments": arguments}) + "\n").encode())
            while True:
                r = json.loads(f.readline())
                if "return" in r or "error" in r:
                    return r
        f.readline(); qmp("qmp_capabilities")
        ppm = vars_file + ".ppm"; qmp("screendump", filename=ppm, format="ppm"); time.sleep(0.4)
        with open(ppm, "rb") as fh:
            fh.readline(); screen = fh.readline().decode().strip()
        os.remove(ppm); s.close()
        said = []
        for c in commands:
            mark = len(out); send(c + "\r"); read_until([], 2.5)
            said.append(re.sub(r"\x1b\[[0-9;=?]*[A-Za-z]", "", out[mark:].decode("latin-1")).replace("\r", ""))
        return "\n".join(said), screen
    finally:
        time.sleep(0.5)
        if p.poll() is None:
            p.kill()
        if os.path.exists(sock):
            os.remove(sock)


for needed in (QEMU, CODE):
    if not os.path.exists(needed):
        sys.exit(f"{needed} is missing (tools/get-qemu-runtime.sh, tools/get-windows.sh)")
with tempfile.TemporaryDirectory() as tmp:
    made = os.path.join(tmp, "vars.fd")
    with open(made, "wb") as fh:
        fh.truncate(os.path.getsize(CODE))                   # a writable flash of the code flash's size, empty
    value = struct.pack("<II", WIDTH, HEIGHT).hex()
    said, before = firmware(made, [f"setvar PlatformConfig -guid {GUID} -bs -rt -nv ={value}", f"dmpstore PlatformConfig -guid {GUID}", "reset -s"])
    if "DataSize = 0x08" not in said:
        sys.exit("the firmware did not keep the setting:\n" + said)
    check = os.path.join(tmp, "check.fd")
    with open(made, "rb") as a, open(check, "wb") as b:
        b.write(a.read())
    _, after = firmware(check, [])
    if after != f"{WIDTH} {HEIGHT}":
        sys.exit(f"the firmware starts at {after.replace(' ', 'x')}, not {WIDTH}x{HEIGHT} (it was {before.replace(' ', 'x')} before): its ramfb driver has no such mode")
    target = os.path.join(REPO, "windows", "vars.fd.gz")
    with open(made, "rb") as a, open(target, "wb") as raw, gzip.GzipFile(filename="", mode="wb", fileobj=raw, compresslevel=9, mtime=0) as z:
        z.write(a.read())
    print(f"{os.path.relpath(target, REPO)}: the firmware starts at {WIDTH}x{HEIGHT} (it was {before.replace(' ', 'x')}), {os.path.getsize(target)} bytes")
