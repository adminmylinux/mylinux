# Environment for the shell (compositor) and for shells on the serial console.
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
export XDG_RUNTIME_DIR=/run/user/0
export WAYLAND_DISPLAY=wayland-0
# --- compositor side: eglfs over KMS/GBM, Mesa llvmpipe software GL ---
export QT_QPA_PLATFORM=eglfs
export QT_QPA_EGLFS_INTEGRATION=eglfs_kms
export QT_QPA_EGLFS_ALWAYS_SET_MODE=1
export MESA_LOADER_DRIVER_OVERRIDE=kms_swrast
# Input: libinput (via eudev). It classifies the QEMU virtio tablet correctly and maps the Super/Cmd
# key to Qt's Meta modifier, which the old evdev plugins could not. Keyboard layout via xkbcommon:
export XKB_DEFAULT_LAYOUT=us
export QT_QPA_EGLFS_HIDECURSOR=0
# Native (hinted, per-pixel) glyph rendering instead of distance fields: much crisper at small sizes
export QT_QUICK_DEFAULT_TEXT_RENDER_TYPE=native
# --- client side (what the shell's Launcher sets for apps; handy for manual tests) ---
# QT_QPA_PLATFORM=wayland WAYLAND_DISPLAY=wayland-0 myapp

# busybox init starts services with HOME=/; the desktop and everything it launches must use the
# real (persistent, apps-disk backed) home so downloads and settings survive a reboot.
export HOME=/root
# API keys from the Settings panel (~/.config/mylinux/secrets.env) for every interactive shell
export ENV=/etc/profile.d/secrets.sh
# apps-disk commands (see apps-path) live in /usr/local/bin, which Buildroot's profile leaves off the PATH
case ":$PATH:" in *:/usr/local/bin:*) ;; *) export PATH="$PATH:/usr/local/bin";; esac
