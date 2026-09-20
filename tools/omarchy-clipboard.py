#!/usr/bin/env python3
"""The Mac side of Omarchy's clipboard bridge: two-way text and PNG between the Mac pasteboard and the guest.

Omarchy's image runs an agent (omarchy-native-clipboard-bridge, from the Try Omarchy project) as soon as a virtio
serial port named dev.tryomarchy.clipboard exists. run-omarchy.sh backs that port with a unix socket and starts this
beside QEMU. One JSON object per line travels each way:

    {"type": "clipboard", "format": "text/plain;charset=utf-8" | "image/png", "data": "<base64>"}

and the guest asks {"type": "sync"} for the Mac's clipboard when it comes up. Echoes (the other side announcing what
it was just given) are recognised by fingerprint, the same way the guest does it. The pasteboard is watched and
written through osascript's JavaScript with the AppKit bridge, which is on every Mac.
Usage: omarchy-clipboard.py <socket>       exits when QEMU closes the socket or the process that started it is gone
       omarchy-clipboard.py --selftest
"""
import base64, hashlib, json, os, select, socket, subprocess, sys, time

TEXT, PNG = "text/plain;charset=utf-8", "image/png"
FORMATS = (TEXT, PNG)
MAX_PAYLOAD = 16 * 1024 * 1024
MAX_LINE = MAX_PAYLOAD * 4 // 3 + 4096
ECHO_WINDOW = 2.0

# watches the pasteboard: one "mime\tbase64" line per change (PNG when there is an image, TIFF converted, else text)
WATCHER = r'''
ObjC.import('AppKit'); ObjC.import('Foundation');
const pb = $.NSPasteboard.generalPasteboard, out = $.NSFileHandle.fileHandleWithStandardOutput;
function emit(s) { out.writeData($(s).dataUsingEncoding($.NSUTF8StringEncoding)); }
function b64(d) { return ObjC.unwrap(d.base64EncodedStringWithOptions(0)); }
let last = -1;
while (true) {
  const c = pb.changeCount;
  if (c !== last) {
    last = c;
    let png = pb.dataForType('public.png');
    if ((!png || png.isNil() || !png.length) && pb.dataForType('public.tiff') && !pb.dataForType('public.tiff').isNil()) {
      const rep = $.NSBitmapImageRep.imageRepWithData(pb.dataForType('public.tiff'));
      if (rep && !rep.isNil()) png = rep.representationUsingTypeProperties($.NSBitmapImageFileTypePNG, $());
    }
    if (png && !png.isNil() && png.length) { emit('image/png\t' + b64(png) + '\n'); }
    else {
      const s = pb.stringForType('public.utf8-plain-text');
      if (s && !s.isNil()) { const t = ObjC.unwrap(s); if (t.length) emit('text/plain;charset=utf-8\t' + b64($(t).dataUsingEncoding($.NSUTF8StringEncoding)) + '\n'); }
    }
  }
  delay(0.25);
}
'''
# sets the pasteboard from stdin: first line the mime, the rest base64
SETTER = r'''
ObjC.import('AppKit'); ObjC.import('Foundation');
const input = ObjC.unwrap($.NSString.alloc.initWithDataEncoding($.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile, $.NSUTF8StringEncoding));
const nl = input.indexOf('\n'), mime = input.slice(0, nl), b64 = input.slice(nl + 1).trim();
const data = $.NSData.alloc.initWithBase64EncodedStringOptions(b64, 0);
const pb = $.NSPasteboard.generalPasteboard; pb.clearContents;   // JXA calls a method without arguments by naming it
if (mime === 'image/png') pb.setDataForType(data, 'public.png');
else pb.setStringForType(ObjC.unwrap($.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding)), 'public.utf8-plain-text');
'''

def log(m): print(f"omarchy-clipboard: {m}", file=sys.stderr, flush=True)
def fingerprint(mime, payload):
    h = hashlib.sha256(); h.update(mime.encode()); h.update(b"\0"); h.update(payload); return h.hexdigest()
def encode(mime, payload):
    return json.dumps({"type": "clipboard", "format": mime, "data": base64.b64encode(payload).decode("ascii")}, separators=(",", ":"), sort_keys=True).encode() + b"\n"

def decode(line):
    """(mime, payload) for a guest clipboard line, "sync" for a sync request, None for anything to ignore."""
    m = json.loads(line)
    if not isinstance(m, dict): return None
    if m.get("type") == "sync": return "sync"
    if m.get("type") != "clipboard" or set(m) != {"type", "format", "data"}: return None
    mime, data = m["format"], m["data"]
    if mime not in FORMATS or not isinstance(data, str): return None
    try: payload = base64.b64decode(data, validate=True)
    except ValueError: return None
    if not payload or len(payload) > MAX_PAYLOAD: return None
    if mime == TEXT:
        try: payload.decode("utf-8")
        except UnicodeDecodeError: return None
    return mime, payload

class Sync:
    """Echo-safe two-way state, the mirror image of the guest agent's: a marker protects only content still on the
    other side, so accepting a change in one direction clears the other direction's marker; a short expiry backs it up."""
    def __init__(self, send, copy, clock=time.monotonic):
        self.send, self.copy, self.clock = send, copy, clock
        self.last_from_guest = self.last_from_mac = None
        self.mac_now = None                      # what the Mac holds, for a sync request
    @staticmethod
    def _echo(marker, key, now): return marker is not None and marker[0] == key and now - marker[1] <= ECHO_WINDOW
    def mac_changed(self, mime, payload):
        if mime not in FORMATS or not payload or len(payload) > MAX_PAYLOAD: return False
        self.mac_now = (mime, payload)
        key, now = fingerprint(mime, payload), self.clock()
        if self._echo(self.last_from_guest, key, now): return False
        self.last_from_mac = (key, now); self.last_from_guest = None
        self.send(encode(mime, payload)); return True
    def guest_changed(self, mime, payload):
        key, now = fingerprint(mime, payload), self.clock()
        if self._echo(self.last_from_mac, key, now): return False
        self.last_from_guest = (key, now); self.last_from_mac = None
        self.copy(mime, payload); return True
    def sync_requested(self):
        if self.mac_now: self.send(encode(*self.mac_now)); return True
        return False

def set_pasteboard(mime, payload):
    subprocess.run(["osascript", "-l", "JavaScript", "-e", SETTER], input=mime.encode() + b"\n" + base64.b64encode(payload),
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20, check=False)

def parse_watch_line(line):
    mime, sep, enc = line.partition(b"\t")
    if not sep: return None
    try: payload = base64.b64decode(enc, validate=True)
    except ValueError: return None
    mime = mime.decode("ascii", "replace")
    return (mime, payload) if mime in FORMATS and payload else None

def connect(path, parent, deadline=120):
    end = time.monotonic() + deadline
    while time.monotonic() < end:
        if os.getppid() != parent: raise RuntimeError("the machine ended before its clipboard port appeared")
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try: s.connect(path); return s
        except OSError: s.close(); time.sleep(0.5)
    raise RuntimeError("no clipboard port after two minutes")

def main(path):
    parent = os.getppid()
    sock = connect(path, parent)
    sock.setblocking(False)
    watcher = subprocess.Popen(["osascript", "-l", "JavaScript", "-e", WATCHER], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    wfd = watcher.stdout.fileno(); os.set_blocking(wfd, False)
    def send(data):
        sock.setblocking(True)
        try: sock.sendall(data)
        finally: sock.setblocking(False)
    sync = Sync(send, set_pasteboard)
    sbuf, wbuf = bytearray(), bytearray()
    try:
        while True:
            ready, _, _ = select.select([sock, wfd], [], [], 1.0)
            if os.getppid() != parent: return 0                       # QEMU is gone
            if watcher.poll() is not None: raise RuntimeError("the pasteboard watcher exited")
            if sock in ready:
                chunk = sock.recv(65536)
                if not chunk: return 0                                 # QEMU closed the port
                sbuf.extend(chunk)
                if len(sbuf) > MAX_LINE: raise RuntimeError("guest clipboard message exceeds the size limit")
                while b"\n" in sbuf:
                    line, _, rest = sbuf.partition(b"\n"); sbuf = bytearray(rest)
                    try: d = decode(line)
                    except ValueError: log("ignoring an invalid line from the guest"); continue
                    if d == "sync": sync.sync_requested()
                    elif d: sync.guest_changed(*d)
            if wfd in ready:
                try: chunk = os.read(wfd, 65536)
                except BlockingIOError: chunk = b""
                if chunk:
                    wbuf.extend(chunk)
                    if len(wbuf) > MAX_LINE: log("Mac clipboard exceeds the size limit; skipping"); wbuf = bytearray()
                    while b"\n" in wbuf:
                        line, _, rest = wbuf.partition(b"\n"); wbuf = bytearray(rest)
                        p = parse_watch_line(line)
                        if p: sync.mac_changed(*p)
    finally:
        if watcher.poll() is None: watcher.terminate()
        sock.close()
        try: os.unlink(path)
        except OSError: pass

def selftest():
    sent, copied = [], []
    t = [100.0]
    s = Sync(lambda d: sent.append(json.loads(d)), lambda m, p: copied.append((m, p)), clock=lambda: t[0])
    assert s.mac_changed(TEXT, b"hello") and sent[-1] == {"type": "clipboard", "format": TEXT, "data": base64.b64encode(b"hello").decode()}
    assert not s.guest_changed(TEXT, b"hello"), "the guest re-announcing what it was given is an echo"
    assert s.guest_changed(TEXT, b"from omarchy") and copied[-1] == (TEXT, b"from omarchy")
    assert not s.mac_changed(TEXT, b"from omarchy"), "the Mac re-announcing what it was given is an echo"
    t[0] += 3
    assert s.mac_changed(TEXT, b"from omarchy"), "the same text copied again later is a real change"
    assert s.guest_changed(PNG, b"\x89PNG...") and copied[-1][0] == PNG
    assert s.sync_requested() and sent[-1]["format"] == TEXT, "sync answers with what the Mac holds"
    assert decode(b'{"type":"sync"}') == "sync"
    assert decode(encode(PNG, b"\x89PNG")) == (PNG, b"\x89PNG")
    assert decode(b'{"type":"clipboard","format":"text/html","data":"aGk="}') is None, "unknown formats are ignored"
    assert decode(b'{"type":"clipboard","format":"text/plain;charset=utf-8","data":"/w=="}') is None, "invalid UTF-8 text is ignored"
    assert parse_watch_line(b"image/png\t" + base64.b64encode(b"x")) == (PNG, b"x") and parse_watch_line(b"nope") is None
    print("omarchy-clipboard selftest ok")

if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--selftest": selftest(); sys.exit(0)
    if len(sys.argv) != 2: print(__doc__, file=sys.stderr); sys.exit(64)
    try: sys.exit(main(sys.argv[1]))
    except (OSError, RuntimeError) as e: log(str(e)); sys.exit(1)
