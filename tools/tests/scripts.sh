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
cp "$REPO/build.sh" "$REPO/run.sh" "$W/"; cp "$REPO/tools/get-image.sh" "$REPO/tools/make-app-bundle.sh" "$W/tools/"
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
mv "$W/out/Image" "$W/out/Image.away"
out=$(cd "$W" && DRYRUN=1 sh run.sh 2>&1); rc=$?
not_rc0 "missing image fails before anything starts" $rc
has "missing image is named" "$out" "missing"
mv "$W/out/Image.away" "$W/out/Image"
out=$(cd "$W" && DRYRUN=1 NAME='myLinux (test)' sh run.sh 2>&1)
has "instance name reaches QEMU" "$out" "myLinux (test)"

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
[ -x "$W/out/myLinux.app/Contents/MacOS/myLinux" ] && ok "unbranded QEMU copy in place" || ko "no binary in the bundle"

echo "tools/host-window.sh"
out=$(sh "$REPO/tools/host-window.sh" bogus 2>&1); rc=$?
not_rc0 "rejects commands outside the allowlist" $rc

if [ $fails -eq 0 ]; then echo "scripts: all passed"; else echo "scripts: $fails failed"; fi
exit $fails
