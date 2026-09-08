#!/usr/bin/env python3
"""Copy qemu-system-aarch64 into the myLinux app bundle with the visible "QEMU" strings renamed.

QEMU's Cocoa UI hardcodes the window title ("QEMU <name>") and the app-menu items ("About QEMU",
"Hide QEMU", "Quit QEMU") as NSString constants. We copy the binary, write replacement strings into
the zero padding at the end of the __TEXT segment, repoint the four CFString constants at them
(their data pointers are dyld chained fixups: the low 36 bits are the file offset, the rest is
chain metadata we keep) and fix their lengths. Then re-sign ad hoc with QEMU's own entitlements
(com.apple.security.hypervisor is needed for HVF).  Usage: brand-qemu.py <qemu binary> <dest> [name]
"""
import re, struct, subprocess, sys, os, shutil, tempfile

src, dst = sys.argv[1], sys.argv[2]
name = sys.argv[3] if len(sys.argv) > 3 else "myLinux"
d = bytearray(open(src, "rb").read())
lc = subprocess.run(["otool", "-l", src], capture_output=True, text=True).stdout

def section(seg, sect):
    m = re.search(r"sectname %s\n\s+segname %s\n\s+addr (0x[0-9a-f]+)\n\s+size (0x[0-9a-f]+)\n\s+offset (\d+)" % (re.escape(sect), seg), lc)
    return int(m.group(1), 16), int(m.group(2), 16), int(m.group(3))
def segment(seg):
    m = re.search(r"segname %s\n\s+vmaddr (0x[0-9a-f]+)\n\s+vmsize (0x[0-9a-f]+)\n\s+fileoff (\d+)\n\s+filesize (\d+)" % seg, lc)
    return int(m.group(1), 16), int(m.group(2), 16), int(m.group(3)), int(m.group(4))

cs_addr, cs_size, cs_off = section("__TEXT", "__cstring")
cf_addr, cf_size, cf_off = section("__DATA_CONST", "__cfstring") if "segname __DATA_CONST\n" in lc and re.search(r"sectname __cfstring\n\s+segname __DATA_CONST", lc) else section("__DATA", "__cfstring")
t_addr, t_vmsize, t_off, t_fsize = segment("__TEXT")
assert t_off == 0 and t_fsize == t_vmsize, "unexpected __TEXT layout"
# free zero padding after the last __TEXT section
last_end = max(int(a, 16) + int(s, 16) for a, s in re.findall(r"segname __TEXT\n\s+addr (0x[0-9a-f]+)\n\s+size (0x[0-9a-f]+)", lc))
gap, gap_end = last_end - t_addr, t_vmsize
assert all(b == 0 for b in d[gap:gap_end]), "padding not empty"

def cfstring_entry(file_off):
    for e in range(cf_off, cf_off + cf_size, 32):
        isa, flags, ptr, ln = struct.unpack_from("<QQQQ", d, e)
        if (ptr & 0xFFFFFFFFF) == file_off: return e, ptr
    return None, None

replacements = {b"QEMU %s": "%s", b"About QEMU": "About " + name, b"Hide QEMU": "Hide " + name, b"Quit QEMU": "Quit " + name}
cur = gap; done = 0
for old, new in replacements.items():
    off = d.find(old + b"\0", cs_off, cs_off + cs_size)
    if off < 0: print("not found:", old); continue
    e, ptr = cfstring_entry(off)
    if e is None: print("no CFString constant for", old); continue
    nb = new.encode() + b"\0"
    assert cur + len(nb) <= gap_end, "out of padding"
    d[cur:cur + len(nb)] = nb
    struct.pack_into("<QQ", d, e + 16, (ptr & ~0xFFFFFFFFF) | cur, len(new))
    cur += len(nb); done += 1
os.makedirs(os.path.dirname(dst), exist_ok=True)
open(dst, "wb").write(d); os.chmod(dst, 0o755)
# re-sign with the original entitlements
ent = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", src], capture_output=True).stdout
with tempfile.NamedTemporaryFile(suffix=".plist", delete=False) as f: f.write(ent); entf = f.name
subprocess.run(["codesign", "--force", "--sign", "-", "--entitlements", entf, dst], check=True, capture_output=True)
os.unlink(entf)
print("branded %d strings, wrote %s" % (done, dst))
