#!/usr/bin/env python3
"""Drive QEMU over QMP with a sequence of ops:
   qmp.py <qmp.sock> move X Y | down | up | click X Y | shot FILE | sleep S | type TEXT | key QCODE ...   (screen coords; SCREEN=WxH env, default 1920x1200)"""
import socket, json, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(sys.argv[1]); f = s.makefile('rw')
def cmd(name, **args):
    s.sendall((json.dumps({"execute": name, "arguments": args}) + "\n").encode())
    while True:
        r = json.loads(f.readline())
        if "return" in r or "error" in r:
            if "error" in r: print(r)
            return r
f.readline(); cmd("qmp_capabilities")
import os
W, H = (int(v) for v in os.environ.get("SCREEN", "1920x1200").split("x"))   # guest resolution (RES in run.sh)
def move(x, y): cmd("input-send-event", events=[{"type":"abs","data":{"axis":"x","value":int(x*32767/W)}},{"type":"abs","data":{"axis":"y","value":int(y*32767/H)}}])
def btn(down): cmd("input-send-event", events=[{"type":"btn","data":{"button":"left","down":down}}])
QCODES = {" ": "spc", "\n": "ret", "-": "minus", "/": "slash", ".": "dot", ",": "comma", "=": "equal", ";": "semicolon", "'": "apostrophe"}
SHIFTED = {"_": "minus", "|": "backslash", ":": "semicolon", '"': "apostrophe", "~": "grave_accent", "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0", "?": "slash", "<": "comma", ">": "dot", "+": "equal", "{": "bracket_left", "}": "bracket_right"}
def key(ch):
    shift = False
    if ch.isalpha() and ch.isupper(): shift, q = True, ch.lower()
    elif ch in SHIFTED: shift, q = True, SHIFTED[ch]
    elif ch in QCODES: q = QCODES[ch]
    else: q = ch
    keys = ([{"type": "qcode", "data": "shift"}] if shift else []) + [{"type": "qcode", "data": q}]
    cmd("send-key", keys=keys)
def type_text(t):
    for ch in t: key(ch); time.sleep(0.04)
a = sys.argv[2:]; i = 0
while i < len(a):
    op = a[i]
    if op == "move": move(int(a[i+1]), int(a[i+2])); i += 3
    elif op == "down": btn(True); i += 1
    elif op == "up": btn(False); i += 1
    elif op == "click": move(int(a[i+1]), int(a[i+2])); time.sleep(0.15); btn(True); time.sleep(0.1); btn(False); i += 3
    elif op == "shot": cmd("screendump", filename=a[i+1], format="png"); i += 2
    elif op == "sleep": time.sleep(float(a[i+1])); i += 2
    elif op == "type": type_text(a[i+1]); i += 2          # literal text, use "\n" for Enter
    elif op == "key": cmd("send-key", keys=[{"type": "qcode", "data": a[i+1]}]); i += 2
    elif op == "combo": cmd("send-key", keys=[{"type": "qcode", "data": k} for k in a[i+1].split("-")]); i += 2   # e.g. meta_l-w
    else: sys.exit("bad op " + op)
    time.sleep(0.15)
