#!/bin/sh
# Act on one myLinux window on the Mac, using macOS's own Window menu commands.
# Usage: tools/host-window.sh fit|center|fullscreen|native [window title]
# The window is found by its title (default "myLinux"), never by process: several myLinux instances
# share one app bundle, and System Events mixes them up when addressed by process.
# Needs Accessibility permission for your terminal app (System Settings > Privacy & Security >
# Accessibility); macOS asks the first time.
CMD="${1:-}"; NAME="${2:-myLinux}"
case "$CMD" in fit|center|fullscreen|native) ;; *) echo "usage: $0 fit|center|fullscreen|native [title]" >&2; exit 2 ;; esac
osascript - "$CMD" "$NAME" <<'AS'
on run argv
  set {cmd, nm} to {item 1 of argv, item 2 of argv}
  tell application "System Events"
    repeat with pr in (every process whose bundle identifier is "dev.mylinux.vm")
      repeat with win in windows of pr
        set t to name of win
        if t is nm or t starts with (nm & " - (Press") then
          set frontmost of pr to true
          if cmd is "fit" then
            click menu item "Fill" of menu "Window" of menu bar 1 of pr
          else if cmd is "center" then
            click menu item "Center" of menu "Window" of menu bar 1 of pr
          else if cmd is "fullscreen" then
            try
              click menu item "Enter Full Screen" of menu "View" of menu bar 1 of pr
            on error
              click menu item "Enter Full Screen" of menu "Window" of menu bar 1 of pr
            end try
          else if cmd is "native" then
            set position of win to {60, 60}
            set size of win to {1920, 1200 + 28}
          end if
          return "ok"
        end if
      end repeat
    end repeat
    return "no window titled " & nm
  end tell
end run
AS
