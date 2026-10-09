# The size of a desktop machine's window and of the picture in it: sourced by run-omarchy.sh (Omarchy, Arch, Kali) and
# run-windows.sh. In: RES (WxH in points, or empty), SCALE (1, 2 or empty), ME (the script's name, for messages) and
# die(). Out: RES, XRES, YRES (points), SCALE, GX, GY (the guest's pixels), TITLE (the title bar's height), SW, SH (the
# display's usable size, empty when it could not be told), and MYLINUX_WINDOW_DISPLAY exported for the window.
# ---- window size and guest resolution -----------------------------------------------------------------------
# RES is the window's size in points (default: the whole display where the window will open, below the menu bar and
# beside the Dock, so the window fills it as its Fill Screen button would, from the first boot screen on: Cocoa puts a
# new app's window on the display of the frontmost app's window, the launcher's or the terminal's). That display's
# backing scale decides the guest's pixels:
# the display maps guest pixels onto backing pixels, so on a Retina display (two per point) the guest gets twice RES
# and Hyprland scales by two: a sharp picture in a window of the size that was asked for. SCALE=1|2 overrides.
# The window starts fixed (zoom-to-fit=off) at exactly the guest's size, because the display code scales a text
# console wrongly whenever window and guest mode differ, which would garble Omarchy's first-boot setup screen; the
# launcher's menu bar item turns Zoom To Fit on and resizes it later, and the guest then follows the window.
SCREEN=$(osascript -l JavaScript -e '
  ObjC.import("AppKit"); ObjC.import("CoreGraphics");
  // the display of the frontmost app'"'"'s front window (the launcher, or the terminal this runs from): where Cocoa
  // opens a new app'"'"'s window; the primary display when that cannot be told
  const all = $.NSScreen.screens; let s = all.objectAtIndex(0);
  try {
    const pid = $.NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    const wins = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0)));
    const w = wins.filter(x => x.kCGWindowOwnerPID == pid && x.kCGWindowLayer == 0 && x.kCGWindowBounds.Height > 100)[0];
    if (w) {
      const mainH = all.objectAtIndex(0).frame.size.height;
      const cx = w.kCGWindowBounds.X + w.kCGWindowBounds.Width / 2, cy = mainH - (w.kCGWindowBounds.Y + w.kCGWindowBounds.Height / 2);
      for (let i = 0; i < all.count; i++) { const f = all.objectAtIndex(i).frame;
        if (cx >= f.origin.x && cx < f.origin.x + f.size.width && cy >= f.origin.y && cy < f.origin.y + f.size.height) s = all.objectAtIndex(i); }
    }
  } catch (e) {}
  const v = s.visibleFrame;
  // the height of the machine window title bar with its toolbar, measured on a window like it that is never shown
  // (40 points on macOS 26, where a plain title bar has 32): the picture gets what is left of the screen below it
  let chrome = 0;
  try {
    const w = $.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer($.NSMakeRect(0, 0, 800, 600), 15, 2, false);
    const t = $.NSToolbar.alloc.initWithIdentifier("mylinux-probe"); t.displayMode = 2;
    w.toolbarStyle = 4; w.toolbar = t; w.layoutIfNeeded;
    chrome = Math.ceil(w.frame.size.height - w.contentLayoutRect.size.height);
  } catch (e) {}
  [Math.round(v.size.width), Math.round(v.size.height), Math.round(s.backingScaleFactor),
   ObjC.unwrap(s.deviceDescription.objectForKey("NSScreenNumber")) || 0, chrome].join(" ")' 2>/dev/null || true)
SW=${SCREEN%% *}; REST=${SCREEN#* }; SH=${REST%% *}; REST=${REST#* }; DETECTED=${REST%% *}; REST=${REST#* }; DISPLAY_ID=${REST%% *}; CHROME=${REST#* }
case "$SW$SH$DETECTED" in ''|*[!0-9]*) SW=""; SH=""; DETECTED=1; DISPLAY_ID="" ;; esac
case "$DISPLAY_ID" in ''|*[!0-9]*|0) DISPLAY_ID="" ;; esac
# the window opens on that display (the runtime's QEMU places it there), whichever one macOS would have picked
[ -z "$DISPLAY_ID" ] || export MYLINUX_WINDOW_DISPLAY="$DISPLAY_ID"
SCALE="${SCALE:-$DETECTED}"
case "$SCALE" in 1|2) ;; *) die "SCALE must be 1 or 2" ;; esac
# the title bar carries a toolbar (the Session menu and the size buttons): its height as measured above, or 52 points
# (more than it is on any macOS so far) when that did not work
case "${CHROME:-}" in ''|*[!0-9]*) TITLE=52 ;; *) if [ "$CHROME" -ge 20 ] && [ "$CHROME" -le 120 ]; then TITLE=$CHROME; else TITLE=52; fi ;; esac
# the guest's width is a whole multiple of 8 pixels (the kernel rounds a mode's width to that), its height even
ALIGN=$(( 8 / SCALE ))
if [ -z "${RES:-}" ]; then
  if [ -n "$SW" ] && [ "$SW" -gt 800 ]; then RES="$(( SW / ALIGN * ALIGN ))x$(( (SH - TITLE) / 2 * 2 ))"; else RES=1600x1000; fi
fi
case "$RES" in [0-9]*x[0-9]*) XRES="${RES%x*}"; YRES="${RES#*x}" ;; *) die "RES must look like 1920x1200 (got '$RES')" ;; esac
[ "$XRES" -ge 640 ] && [ "$XRES" -le 8192 ] && [ "$YRES" -ge 480 ] && [ "$YRES" -le 8192 ] || die "RES out of range: $RES"
# a chosen size larger than the display would put the window's bottom off screen: keep it inside
if [ -n "$SW" ] && [ "$SW" -gt 800 ]; then
  MAXW=$(( SW / ALIGN * ALIGN )); MAXH=$(( (SH - TITLE) / 2 * 2 ))
  [ "$XRES" -le "$MAXW" ] || XRES=$MAXW; [ "$YRES" -le "$MAXH" ] || YRES=$MAXH
  [ "$RES" = "${XRES}x${YRES}" ] || { echo "$ME: $RES does not fit the display, using ${XRES}x${YRES}" >&2; RES="${XRES}x${YRES}"; }
fi
GX=$(( XRES * SCALE )); GY=$(( YRES * SCALE ))
[ "$GX" -le 8192 ] && [ "$GY" -le 8192 ] || die "RES $RES is too large for a Retina display (the guest would need ${GX}x${GY})"
