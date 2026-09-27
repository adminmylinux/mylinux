# Saved downloads: sourced by tools/get-image.sh, get-omarchy.sh, get-debian.sh and get-alpine.sh.
# With MYLINUX_CACHE set (the Mac launcher sets it to ~/Library/Caches/dev.mylinux.downloads, which "Clear All Data"
# leaves in place), every download that installs is also kept there, one folder per kind with its revision file, and
# a later install of the same revision (a new machine after clearing everything, say) copies it from there instead of
# downloading it again. The copies are APFS clones: a saved download shares its blocks with the installed one.
#   <script> --check                prints "cached: <revision or none>" and "latest: <revision or unknown>", nothing else
#   MYLINUX_FROM_CACHE=1 <script>   installs the saved revision even when a newer one is out (the launcher asks first)
# Without MYLINUX_CACHE none of this happens, as before (a developer checkout's out/).
CACHE="${MYLINUX_CACHE:-}"

# the saved revision of a kind (the text of its revision file), or nothing
cache_rev() { [ -n "$CACHE" ] && cat "$CACHE/$1/$2" 2>/dev/null || true; }

# copy a file or folder, as a clone where the volume can (cp falls back to a plain copy where it cannot)
cache_clone() { cp -cR "$1" "$2"; }

# cache_store KIND DIR [FILE...]: keep DIR (or only these files of it) as the saved download of KIND. A failure to
# save never fails the install it follows.
cache_store() {
  [ -n "$CACHE" ] || return 0
  _k=$1; _d=$2; shift 2
  _new="$CACHE/.new-$_k"
  mkdir -p "$CACHE" && rm -rf "$_new" || return 0
  if [ $# = 0 ]; then
    cache_clone "$_d" "$_new" 2>/dev/null || { rm -rf "$_new"; echo "(could not save the download for later installs)"; return 0; }
  else
    mkdir -p "$_new"
    for _f; do cache_clone "$_d/$_f" "$_new/$_f" 2>/dev/null || { rm -rf "$_new"; echo "(could not save the download for later installs)"; return 0; }; done
  fi
  rm -rf "$CACHE/$_k" && mv "$_new" "$CACHE/$_k" && echo "saved for later installs"
  return 0
}

# check_report CACHED LATEST: the answer to --check
check_report() { echo "cached: ${1:-none}"; echo "latest: ${2:-unknown}"; }
