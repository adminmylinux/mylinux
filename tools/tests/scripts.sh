#!/bin/sh
# Behaviour tests for the host-side scripts. Everything runs against a scratch copy of the repository
# layout with fake tools on PATH (orb, curl, python3 where needed); nothing here touches out/ or a VM.
# Usage: sh tools/tests/scripts.sh
REPO=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/mylinux-scripts.XXXXXX")
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT
fails=0
ok() { echo "  ok   $1"; }
ko() { echo "  FAIL $1"; fails=$((fails + 1)); }
# assertions (no eval: paths contain spaces and apostrophes on purpose)
is_rc() { [ "$2" -eq "$3" ] && ok "$1" || ko "$1 (rc $2, wanted $3)"; }
not_rc0() { [ "$2" -ne 0 ] && ok "$1" || ko "$1 (rc 0)"; }
file_is() { [ -f "$2" ] && [ "$(cat "$2")" = "$3" ] && ok "$1" || ko "$1 ($2 is '$(cat "$2" 2>/dev/null)')"; }
file_exists() { [ -e "$2" ] && ok "$1" || ko "$1 ($2 missing)"; }
file_absent() { [ ! -e "$2" ] && ok "$1" || ko "$1 ($2 exists)"; }
has() { printf '%s' "$2" | grep -qF -- "$3" && ok "$1" || ko "$1 (no '$3' in output)"; }

# a scratch repo: the scripts plus an out/ with a known working pair, path with a space and an apostrophe
W="$T/my repo's copy"
mkdir -p "$W/out" "$W/tools" "$W/board/overlay/etc" "$W/bin"
cp "$REPO/build.sh" "$REPO/run.sh" "$REPO/run-omarchy.sh" "$W/"; cp "$REPO/tools/get-image.sh" "$REPO/tools/make-app-bundle.sh" "$REPO/tools/qemu-flavour.sh" "$REPO/tools/get-qemu-runtime.sh" "$REPO/tools/get-omarchy.sh" "$REPO/tools/qemu-runtime.version" "$W/tools/"
printf 'old kernel' > "$W/out/Image"; printf 'old rootfs' > "$W/out/rootfs.cpio.gz"
(cd "$W" && git init -q && git add . >/dev/null 2>&1 && git -c user.name=t -c user.email=t@t commit -qm init) 2>/dev/null

echo "build.sh"
# fake orb: 'orb run -m debian <shell> -c "<script>"'; make fails when FAKE_MAKE_FAILS=1; the cp step writes fake images
cat > "$W/bin/orb" <<'EOF'
#!/bin/sh
for last; do :; done
case "$last" in
  *"make -j"*) echo ">>> fake make"; [ "${FAKE_MAKE_FAILS:-0}" = 1 ] && { echo "make: *** Error 2"; exit 2; }; [ "${FAKE_MAKE_QUIET:-0}" = 1 ] && exit 0; echo "Error: matches the filter but the build succeeded"; exit 0 ;;
  *"cp "*) dest=$(printf '%s' "$last" | sed "s/^.* '\(.*\)\/'$/\1/"); printf 'new kernel' > "$dest/Image"; printf 'new rootfs' > "$dest/rootfs.cpio.gz"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$W/bin/orb"
(cd "$W" && PATH="$W/bin:$PATH" FAKE_MAKE_FAILS=1 sh build.sh >/dev/null 2>&1); rc=$?
not_rc0 "failed make returns nonzero" $rc
file_is "failed make keeps the old kernel" "$W/out/Image" "old kernel"
file_is "failed make keeps the old rootfs" "$W/out/rootfs.cpio.gz" "old rootfs"
(cd "$W" && PATH="$W/bin:$PATH" FAKE_MAKE_QUIET=1 sh build.sh >/dev/null 2>&1); rc=$?
is_rc "successful build with no filter matches returns zero" $rc 0
file_is "successful build promotes the new kernel" "$W/out/Image" "new kernel"
file_is "successful build keeps the previous kernel as .prev" "$W/out/Image.prev" "old kernel"
file_exists "image revision recorded" "$W/out/IMAGE-REVISION"
(cd "$W" && PATH="$W/bin:$PATH" sh build.sh >/dev/null 2>&1); rc=$?
is_rc "successful build whose output matches the error filter still returns zero" $rc 0

echo "tools/get-image.sh"
printf 'good kernel' > "$W/out/Image"; printf 'good rootfs' > "$W/out/rootfs.cpio.gz"; rm -f "$W/out/"*.prev
mkdir -p "$T/release"; printf 'v9 kernel' > "$T/release/Image"; printf 'v9 rootfs' > "$T/release/rootfs.cpio.gz"
(cd "$T/release" && shasum -a 256 Image rootfs.cpio.gz > SHA256SUMS)
# fake curl: the /releases/latest probe prints the redirect target; -o <file> <url> copies from the fake release
cat > "$W/bin/curl" <<EOF
#!/bin/sh
out=""; url=""
while [ \$# -gt 0 ]; do case "\$1" in -o) out="\$2"; shift ;; -w) shift ;; http*) url="\$1" ;; esac; shift; done
case "\$url" in */releases/latest) printf 'https://github.com/x/y/releases/tag/v9'; exit 0 ;; esac
f=\${url##*/}
[ "\${FAKE_CURL_FAIL:-}" = "\$f" ] && exit 22
cp "$T/release/\$f" "\$out"
EOF
chmod +x "$W/bin/curl"
(cd "$W" && PATH="$W/bin:$PATH" sh tools/get-image.sh >/dev/null 2>&1); rc=$?
is_rc "download resolves one release and succeeds" $rc 0
file_is "downloaded kernel promoted" "$W/out/Image" "v9 kernel"
file_is "release tag recorded" "$W/out/IMAGE-REVISION" "v9"
file_is "previous kernel kept as .prev" "$W/out/Image.prev" "good kernel"
printf 'corrupt' > "$T/release/rootfs.cpio.gz"
(cd "$W" && PATH="$W/bin:$PATH" sh tools/get-image.sh >/dev/null 2>&1); rc=$?
not_rc0 "checksum mismatch fails" $rc
file_is "checksum mismatch leaves the kernel" "$W/out/Image" "v9 kernel"
file_is "checksum mismatch leaves the rootfs" "$W/out/rootfs.cpio.gz" "v9 rootfs"
(cd "$W" && PATH="$W/bin:$PATH" FAKE_CURL_FAIL=Image sh tools/get-image.sh >/dev/null 2>&1); rc=$?
not_rc0 "failed download fails" $rc
file_is "failed download leaves the kernel" "$W/out/Image" "v9 kernel"
[ -z "$(ls -d "$W/out/.staging-"* 2>/dev/null)" ] && ok "no staging directory left behind" || ko "staging directory left behind"
printf 'v9 rootfs' > "$T/release/rootfs.cpio.gz"
G="$T/data dir"
(cd "$W" && PATH="$W/bin:$PATH" MYLINUX_OUT="$G" sh tools/get-image.sh >/dev/null 2>&1); rc=$?
is_rc "MYLINUX_OUT: download into another directory" $rc 0
file_is "MYLINUX_OUT: kernel lands there" "$G/Image" "v9 kernel"
file_is "MYLINUX_OUT: revision recorded there" "$G/IMAGE-REVISION" "v9"

echo "run.sh (DRYRUN)"
out=$(cd / && DRYRUN=1 SHARE_DIR="$T/my share" APPS_IMG="$T/app's disk.img" NAME="test vm" sh "$W/run.sh" -qmp none 2>&1); rc=$?
is_rc "runs from another directory" $rc 0
has "absolute share path with a space is passed intact" "$out" "path=$T/my share,mount_tag"
has "absolute disk path with an apostrophe is passed intact" "$out" "file=$T/app's disk.img,if=none"
has "extra QEMU arguments pass through" "$out" "none"
file_exists "creates the sparse apps disk at the given path" "$T/app's disk.img"
out=$(cd "$T" && DRYRUN=1 SHARE_DIR=relshare APPS_IMG=rel.img sh "$W/run.sh" 2>&1); rc=$?
is_rc "relative overrides accepted" $rc 0
has "relative share resolves against the caller's directory" "$out" "path=$T/relshare,"
file_exists "relative apps disk created in the caller's directory" "$T/rel.img"
out=$(cd "$W" && DRYRUN=1 RES=abc sh run.sh 2>&1); rc=$?
not_rc0 "malformed RES is refused" $rc
out=$(cd "$W" && DRYRUN=1 APPS_SIZE_GB=huge sh run.sh 2>&1); rc=$?
not_rc0 "malformed APPS_SIZE_GB is refused" $rc
out=$(cd "$W" && DRYRUN=1 GRAB=weird sh run.sh 2>&1); rc=$?
not_rc0 "unknown GRAB is refused" $rc
out=$(cd "$W" && DRYRUN=1 sh run.sh 2>&1); has "default pointer is the absolute tablet" "$out" "virtio-tablet-pci"
out=$(cd "$W" && DRYRUN=1 MOUSE=relative sh run.sh 2>&1); has "MOUSE=relative uses a relative mouse" "$out" "virtio-mouse-pci"
out=$(cd "$W" && DRYRUN=1 MOUSE=touch sh run.sh 2>&1); rc=$?
not_rc0 "unknown MOUSE is refused" $rc
mv "$W/out/Image" "$W/out/Image.away"
out=$(cd "$W" && DRYRUN=1 sh run.sh 2>&1); rc=$?
not_rc0 "missing image fails before anything starts" $rc
has "missing image is named" "$out" "missing"
mv "$W/out/Image.away" "$W/out/Image"
out=$(cd "$W" && DRYRUN=1 NAME='myLinux (test)' sh run.sh 2>&1)
has "instance name reaches QEMU" "$out" "myLinux (test)"
out=$(cd "$W" && DRYRUN=1 PLACER=0 sh run.sh 2>&1); rc=$?
is_rc "PLACER=0 accepted" $rc 0
out=$(cd "$W" && DRYRUN=1 FORWARD=15905:5905,12222:2222 sh run.sh 2>&1); has "FORWARD adds host forwards to the user netdev" "$out" "user,id=n0,hostfwd=tcp:127.0.0.1:15905-:5905,hostfwd=tcp:127.0.0.1:12222-:2222"
out=$(cd "$W" && DRYRUN=1 FORWARD=abc sh run.sh 2>&1); rc=$?
not_rc0 "malformed FORWARD is refused" $rc
D="$T/Application Support/myLinux"; mkdir -p "$D"; printf 'k' > "$D/Image"; printf 'r' > "$D/rootfs.cpio.gz"
out=$(cd / && DRYRUN=1 MYLINUX_OUT="$D" SHARE_DIR="$T/s" sh "$W/run.sh" 2>&1); rc=$?
is_rc "MYLINUX_OUT: images from another data directory" $rc 0
has "MYLINUX_OUT: kernel from the data directory" "$out" "$D/Image"
has "MYLINUX_OUT: default apps disk in the data directory" "$out" "file=$D/apps.img,if=none"
rm -f "$D/Image"
out=$(cd / && DRYRUN=1 MYLINUX_OUT="$D" SHARE_DIR="$T/s" sh "$W/run.sh" 2>&1); rc=$?
not_rc0 "MYLINUX_OUT: missing image in the data directory fails" $rc

echo "accelerated QEMU runtime (tools/get-qemu-runtime.sh, tools/qemu-flavour.sh, run.sh)"
out=$(cd "$W" && DRYRUN=1 sh run.sh 2>&1); has "without a runtime: Homebrew's QEMU" "$out" "QEMU=brew"
has "without a runtime: the plain GPU device" "$out" "virtio-gpu-pci,xres="
# a fake runtime archive: qemu is a script that answers the two questions the installer asks
F="$T/fake runtime"; mkdir -p "$F/qemu-runtime/bin" "$F/qemu-runtime/lib"
printf '#!/bin/sh\ncase "$*" in *"-device help"*) echo "name \"virtio-gpu-gl-pci\", bus PCI" ;; *) echo "QEMU emulator version fake" ;; esac\n' > "$F/qemu-runtime/bin/qemu-system-aarch64"
chmod +x "$F/qemu-runtime/bin/qemu-system-aarch64"; echo fake-1 > "$F/qemu-runtime/RUNTIME-REVISION"
A="$T/qemu-runtime-macos-arm64.tar.gz"
(cd "$F" && tar -czf "$A" qemu-runtime) && (cd "$T" && shasum -a 256 qemu-runtime-macos-arm64.tar.gz > "$A.sha256")
cp "$A" "$T/badsum.tar.gz"
echo "0000000000000000000000000000000000000000000000000000000000000000  qemu-runtime-macos-arm64.tar.gz" > "$T/badsum.tar.gz.sha256"
(cd "$W" && MYLINUX_RUNTIME_FILE="$T/badsum.tar.gz" sh tools/get-qemu-runtime.sh >/dev/null 2>&1); rc=$?
not_rc0 "a runtime with the wrong checksum is refused" $rc
file_absent "refused runtime: nothing installed" "$W/out/qemu-runtime"
E="$T/evil"; mkdir -p "$E/qemu-runtime" "$E/elsewhere"; echo x > "$E/elsewhere/file"
(cd "$E" && tar -czf "$T/evil.tar.gz" qemu-runtime elsewhere) && (cd "$T" && shasum -a 256 evil.tar.gz | sed 's/evil.tar.gz/qemu-runtime-macos-arm64.tar.gz/' > "$T/evil.tar.gz.sha256")
(cd "$W" && MYLINUX_RUNTIME_FILE="$T/evil.tar.gz" sh tools/get-qemu-runtime.sh >/dev/null 2>&1); rc=$?
not_rc0 "an archive with paths outside qemu-runtime/ is refused" $rc
file_absent "refused archive: nothing unpacked beside it" "$W/out/elsewhere"
(cd "$W" && MYLINUX_RUNTIME_FILE="$A" sh tools/get-qemu-runtime.sh >/dev/null 2>&1); rc=$?
is_rc "a good runtime installs" $rc 0
file_is "installed runtime records its revision" "$W/out/qemu-runtime/RUNTIME-REVISION" "fake-1"
file_absent "staging folder is gone" "$W/out/.staging-qemu-runtime"
out=$(cd "$W" && DRYRUN=1 sh run.sh 2>&1); has "with a runtime: run.sh uses it" "$out" "QEMU=runtime"
has "with a runtime: accelerated GPU device without a ROM file" "$out" "virtio-gpu-gl-pci,max_outputs=1,xres="
has "with a runtime: every PCI device without a ROM file" "$out" "virtio-net-pci,netdev=n0,romfile="
has "with a runtime: GICv3" "$out" "virt,gic-version=3"
has "with a runtime: GL display" "$out" "cocoa,gl=es,"
out=$(cd "$W" && DRYRUN=1 MYLINUX_QEMU=brew sh run.sh 2>&1); has "MYLINUX_QEMU=brew insists on Homebrew's" "$out" "QEMU=brew"
out=$(cd "$W" && DRYRUN=1 RENDER=soft sh run.sh 2>&1); has "RENDER=soft asks the guest for software GL" "$out" "mylinux.gl=soft"
out=$(cd "$W" && DRYRUN=1 RENDER=fast sh run.sh 2>&1); rc=$?
not_rc0 "unknown RENDER is refused" $rc
out=$(cd "$W" && DRYRUN=1 MYLINUX_QEMU=nonsense sh run.sh 2>&1); rc=$?
not_rc0 "unknown MYLINUX_QEMU is refused" $rc
echo "run-omarchy.sh (DRYRUN, with the fake runtime)"
out=$(cd / && DRYRUN=1 SCALE=1 RES=1600x1000 DISK="$T/om/omarchy.ext4" SHARE_DIR="$T/om/Mac Files" NAME="Omarchy test" sh "$W/run-omarchy.sh" -qmp none 2>&1); rc=$?
is_rc "dry run works from another directory" $rc 0
has "root disk path is passed intact" "$out" "file=$T/om/omarchy.ext4,format=raw"
has "the kernel comes from the machine's own boot folder" "$out" "$T/om/boot/vmlinuz-linux"
has "accelerated GPU at the asked size, no ROM" "$out" "virtio-gpu-gl-pci,max_outputs=1,xres=1600,yres=1000,romfile="
has "window fixed to the guest size" "$out" "zoom-to-fit=off"
o2=$(cd "$W" && DRYRUN=1 SCALE=2 RES=1600x1000 sh run-omarchy.sh 2>&1); has "Retina: the guest gets twice the points" "$o2" "xres=3200,yres=2000,romfile="
o2=$(cd "$W" && DRYRUN=1 SCALE=1 RES=9000x9000 sh run-omarchy.sh 2>&1); rc=$?
not_rc0 "a size beyond QEMU's range is refused" $rc
o2=$(cd "$W" && DRYRUN=1 SCALE=1 RES=8000x6000 sh run-omarchy.sh 2>&1); has "a size larger than the display is shrunk to fit" "$o2" "does not fit the display"
o2=$(cd "$W" && DRYRUN=1 SCALE=3 RES=1600x1000 sh run-omarchy.sh 2>&1); rc=$?
not_rc0 "unknown SCALE is refused" $rc
has "share exported for the guest's first user" "$out" "path=$T/om/Mac Files,security_model=none,multidevs=remap,guest_owner_uid=1000"
has "share name travels as URL-safe base64" "$out" "omarchy.shared_folder_name=TWFjIEZpbGVz"
has "extra QEMU arguments pass through" "$out" "none"
file_absent "a dry run creates no disk" "$T/om/omarchy.ext4"
out=$(cd "$W" && DRYRUN=1 RES=1600x1000 sh run-omarchy.sh 2>&1); case "$out" in *shared_folder_name*) ko "no share: nothing about one on the command line" ;; *) ok "no share: nothing about one on the command line" ;; esac
out=$(cd "$W" && DRYRUN=1 RES=1600x1000 QMP="$T/q.sock" sh run-omarchy.sh 2>&1); has "QMP socket for a clean stop" "$out" "unix:$T/q.sock,server=on,wait=off"
case "$out" in *audiodev*) ok "sound device by default" ;; *) ko "sound device by default" ;; esac
has "clipboard port for Omarchy's agent by default" "$out" "name=dev.tryomarchy.clipboard"
out=$(cd "$W" && DRYRUN=1 RES=1600x1000 CLIPBOARD=0 sh run-omarchy.sh 2>&1)
case "$out" in *tryomarchy.clipboard*) ko "CLIPBOARD=0 leaves the port out" ;; *) ok "CLIPBOARD=0 leaves the port out" ;; esac
out=$(cd "$W" && DRYRUN=1 SCALE=1 RES=1600x1000 SHARE_DIR="$T/om/Mac Files" sh run-omarchy.sh 2>&1); has "dry run: no session tools copied into the share" "$out" "DISK="
file_absent "dry run leaves the share alone" "$T/om/Mac Files/mylinux"
(sh "$REPO/tools/omarchy-session-mac.sh" "$T/om/Mac Files" interval 5 >/dev/null 2>&1); rc=$?
is_rc "omarchy-session-mac.sh drops a command file into the share" $rc 0
c=$(cat "$T/om/Mac Files/mylinux/control/"*.cmd 2>/dev/null); [ "$c" = "interval 5" ] && ok "the command file holds the words" || ko "the command file holds '$c'"
(sh "$REPO/tools/omarchy-session-mac.sh" "$T/om/Mac Files" reboot >/dev/null 2>&1); rc=$?
not_rc0 "unknown session commands are refused" $rc
(python3 "$REPO/omarchy/session/omarchy-session" --selftest >/dev/null 2>&1); rc=$?
is_rc "omarchy-session selftest (restore planning, terminal working directory)" $rc 0
(python3 "$REPO/tools/omarchy-clipboard.py" --selftest >/dev/null 2>&1); rc=$?
is_rc "omarchy-clipboard.py selftest (protocol, echo filtering)" $rc 0
out=$(cd "$W" && DRYRUN=1 RES=1600x1000 AUDIO=0 CPUS=2 SSH=1 FORWARD=2222:22 sh run-omarchy.sh 2>&1)
case "$out" in *audiodev*) ko "AUDIO=0 leaves the sound device out" ;; *) ok "AUDIO=0 leaves the sound device out" ;; esac
has "SSH=1 asks the guest for its SSH server" "$out" "tryomarchy.ssh_access=1"
has "and the port is forwarded on the loopback only" "$out" "hostfwd=tcp:127.0.0.1:2222-:22"
has "CPUS reaches QEMU" "$out" "CPUS=2"
out=$(cd "$W" && DRYRUN=1 RES=1600x1000 SHARE_DIR="$HOME" sh run-omarchy.sh 2>&1); rc=$?
not_rc0 "sharing the whole home folder is refused" $rc
out=$(cd "$W" && DRYRUN=1 RES=1600x1000 SHARE_DIR="$HOME/Library/Preferences" sh run-omarchy.sh 2>&1); rc=$?
not_rc0 "sharing a Library folder is refused" $rc
# the launcher's default: <Application Support>/myLinux/machines/<machine>/Mac (HOME is the scratch folder here, so nothing real is made)
out=$(cd "$W" && HOME="$T/home" DRYRUN=1 RES=1600x1000 SHARE_DIR="$T/home/Library/Application Support/myLinux/machines/omarchy/Mac" sh run-omarchy.sh 2>&1); rc=$?
is_rc "the launcher's machine folder under Application Support is shareable" $rc 0
out=$(cd "$W" && DRYRUN=1 RES=1600x1000 DISK_SIZE_GB=4 sh run-omarchy.sh 2>&1); rc=$?
not_rc0 "a disk smaller than the factory image is refused" $rc
out=$(cd "$W" && RES=1600x1000 DISK="$T/om2/omarchy.ext4" sh run-omarchy.sh 2>&1); rc=$?
not_rc0 "a new machine without the downloaded guest fails" $rc
has "and says how to get it" "$out" "get-omarchy.sh"
file_absent "and leaves no half-made disk" "$T/om2/omarchy.ext4"
out=$(cd "$W" && MYLINUX_QEMU=brew DRYRUN=1 RES=1600x1000 sh run-omarchy.sh 2>&1); has "Omarchy always uses the runtime" "$out" "virtio-gpu-gl-pci"
(cd "$W" && sh tools/get-omarchy.sh --remove >/dev/null 2>&1); rc=$?
is_rc "get-omarchy.sh --remove" $rc 0
(cd "$W" && MYLINUX_RUNTIME_FILE="$A" sh tools/get-qemu-runtime.sh >/dev/null 2>&1)
file_exists "a second install keeps the previous runtime" "$W/out/qemu-runtime.prev"
(cd "$W" && sh tools/get-qemu-runtime.sh --remove >/dev/null 2>&1); rc=$?
is_rc "--remove" $rc 0
file_absent "--remove: runtime gone" "$W/out/qemu-runtime"
file_absent "--remove: previous runtime gone too" "$W/out/qemu-runtime.prev"
out=$(cd "$W" && DRYRUN=1 MYLINUX_QEMU=runtime sh run.sh 2>&1); rc=$?
not_rc0 "MYLINUX_QEMU=runtime without a runtime is refused" $rc
out=$(cd "$W" && DRYRUN=1 RES=1600x1000 sh run-omarchy.sh 2>&1); rc=$?
not_rc0 "run-omarchy.sh without the runtime is refused" $rc
has "and names the fix" "$out" "get-qemu-runtime.sh"

echo "tools/make-app-bundle.sh"
# fake qemu, failing brand-qemu (python3), no-op codesign/sips: the bundle must still get an (unbranded) binary
printf '#!/bin/sh\necho fake qemu\n' > "$W/bin/qemu-system-aarch64"; chmod +x "$W/bin/qemu-system-aarch64"
cat > "$W/bin/python3" <<'EOF'
#!/bin/sh
case "$*" in *brand-qemu*) echo "brand failed" >&2; exit 1 ;; *gen-icon*) for last; do :; done; : > "$last"; exit 0 ;; esac
exec /usr/bin/python3 "$@"
EOF
chmod +x "$W/bin/python3"; printf '#!/bin/sh\nexit 0\n' > "$W/bin/codesign"; printf '#!/bin/sh\nexit 0\n' > "$W/bin/sips"; chmod +x "$W/bin/codesign" "$W/bin/sips"
mkdir -p "$W/tools"; : > "$W/tools/brand-qemu.py"; : > "$W/tools/gen-icon.py"
(cd "$W" && PATH="$W/bin:$PATH" sh tools/make-app-bundle.sh >/dev/null 2>&1); rc=$?
is_rc "bundle prepared even when branding fails" $rc 0
[ -x "$W/out/myLinux.app/Contents/MacOS/qemu-myLinux" ] && ok "unbranded QEMU copy in place" || ko "no binary in the bundle"
head -1 "$W/out/myLinux.app/Contents/MacOS/myLinux" | grep -q '^#!/bin/sh' && ok "Dock entry point is the launcher hand-over script" || ko "no Dock entry script"
out=$(sh "$W/out/myLinux.app/Contents/MacOS/myLinux" -version 2>&1); has "entry script passes arguments to QEMU" "$out" "fake qemu"
(cd "$W" && PATH="$W/bin:$PATH" MYLINUX_OUT="$T/bundle dir" sh tools/make-app-bundle.sh >/dev/null 2>&1); rc=$?
is_rc "MYLINUX_OUT: bundle in another directory" $rc 0
[ -x "$T/bundle dir/myLinux.app/Contents/MacOS/qemu-myLinux" ] && ok "MYLINUX_OUT: QEMU copy in the data directory" || ko "MYLINUX_OUT: no binary in the data directory bundle"

mkdir -p "$T/rt out/qemu-runtime/bin" "$T/rt out/qemu-runtime/lib"; printf '#!/bin/sh\necho runtime qemu\n' > "$T/rt out/qemu-runtime/bin/qemu-system-aarch64"; chmod +x "$T/rt out/qemu-runtime/bin/qemu-system-aarch64"
(cd "$W" && PATH="$W/bin:$PATH" MYLINUX_OUT="$T/rt out" sh tools/make-app-bundle.sh >/dev/null 2>&1); rc=$?
is_rc "with a runtime: bundle prepared" $rc 0
out=$("$T/rt out/myLinux.app/Contents/MacOS/qemu-myLinux" 2>&1); has "with a runtime: the bundle's QEMU is the runtime's" "$out" "runtime qemu"
[ -d "$T/rt out/myLinux.app/Contents/lib/" ] && ok "with a runtime: Contents/lib points at its libraries" || ko "with a runtime: no Contents/lib"
rm -rf "$T/rt out/qemu-runtime"
(cd "$W" && PATH="$W/bin:$PATH" MYLINUX_OUT="$T/rt out" sh tools/make-app-bundle.sh >/dev/null 2>&1)
out=$("$T/rt out/myLinux.app/Contents/MacOS/qemu-myLinux" 2>&1); has "runtime removed: the bundle goes back to Homebrew's QEMU" "$out" "fake qemu"
file_absent "runtime removed: no dangling Contents/lib" "$T/rt out/myLinux.app/Contents/lib"

echo "tools/host-window.sh"
out=$(sh "$REPO/tools/host-window.sh" bogus 2>&1); rc=$?
not_rc0 "rejects commands outside the allowlist" $rc

if [ $fails -eq 0 ]; then echo "scripts: all passed"; else echo "scripts: $fails failed"; fi
exit $fails
