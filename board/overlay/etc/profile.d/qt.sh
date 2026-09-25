# Environment for the shell (compositor) and for shells on the serial console.
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
export XDG_RUNTIME_DIR=/run/user/0
export WAYLAND_DISPLAY=wayland-0
# --- compositor side: eglfs over KMS/GBM. Mesa renders on the Mac's GPU (virgl) when the virtio-gpu offers 3D,
#     which is the accelerated QEMU runtime with virtio-gpu-gl; the kernel creates a render node only then. On the
#     plain virtio-gpu (Homebrew's QEMU), or with mylinux.gl=soft on the kernel command line (RENDER=soft ./run.sh),
#     it is llvmpipe software GL into KMS dumb buffers. ---
export QT_QPA_PLATFORM=eglfs
export QT_QPA_EGLFS_INTEGRATION=eglfs_kms
export QT_QPA_EGLFS_ALWAYS_SET_MODE=1
if [ ! -e /dev/dri/renderD128 ] || grep -qw 'mylinux.gl=soft' /proc/cmdline 2>/dev/null; then
  export MESA_LOADER_DRIVER_OVERRIDE=kms_swrast
  export MYLINUX_GL=soft
else
  export MYLINUX_GL=virgl
fi
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
# Command history of the base shell (BusyBox ash) kept on the apps disk across terminals and reboots
export HISTFILE=/root/.ash_history HISTFILESIZE=2000 HISTSIZE=2000
# API keys from the Settings panel (~/.config/mylinux/secrets.env) for every interactive shell
export ENV=/etc/profile.d/secrets.sh
# apps-disk commands (see apps-path) live in /usr/local/bin, which Buildroot's profile leaves off the PATH
case ":$PATH:" in *:/usr/local/bin:*) ;; *) export PATH="$PATH:/usr/local/bin";; esac
