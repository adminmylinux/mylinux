#!/bin/sh
# Act on the QEMU window on the Mac, using macOS's own Window menu commands.
# Usage: tools/host-window.sh fit|center|fullscreen|native
# "fit"  = macOS Window > Fill (screen minus the system margins), "center" = Window > Center.
# Needs Accessibility permission for your terminal app (System Settings > Privacy & Security >
# Accessibility); macOS asks the first time.
menu_click() {   # $1 = menu title, $2 = item title
    osascript - "$1" "$2" <<'AS'
on run argv
  tell application "System Events"
    tell process "myLinux"
      set frontmost to true
      click menu item (item 2 of argv) of menu (item 1 of argv) of menu bar 1
    end tell
  end tell
end run
AS
}
case "$1" in
  fit)        menu_click "Window" "Fill" ;;
  center)     menu_click "Window" "Center" ;;
  fullscreen) menu_click "View" "Enter Full Screen" || menu_click "Window" "Enter Full Screen" ;;
  native)     osascript <<'AS'
tell application "System Events"
  tell process "myLinux"
    set frontmost to true
    set position of window 1 to {60, 60}
    set size of window 1 to {1920, 1200 + 28}
  end tell
end tell
AS
  ;;
  *) echo "usage: $0 fit|center|fullscreen|native"; exit 2 ;;
esac
