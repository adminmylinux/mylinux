# More Mac folders for a machine: the launcher's cloud folders (Dropbox, OneDrive, iCloud Drive, Google Drive).
# Sourced by run-server.sh, run-omarchy.sh and run.sh once their QEMU arguments are in "$@", which it extends.
# EXTRA_SHARES: one "tag=path" per line; each folder becomes a 9p device with that mount tag, which the machine
# mounts at /mnt/<tag> (the launcher's mount commands, CloudFolder.mountScript). Uses the caller's die, ROM (",romfile="
# for the runtime) and OWNER (the 9p owner mapping, or empty); ME names the caller in notes.
# Cloud folders live in ~/Library (CloudStorage, Mobile Documents), which is
# otherwise refused; a folder that is not there (the cloud app signed out) is left out with a note.
if [ -n "${EXTRA_SHARES:-}" ]; then
  n=0
  NL='
'
  OLDIFS=$IFS; IFS=$NL
  for entry in $EXTRA_SHARES; do
    IFS=$OLDIFS
    tag=${entry%%=*}; dir=${entry#*=}
    case "$tag" in ''|*[!a-z0-9-]*) die "EXTRA_SHARES: '$tag' is not a mount tag (a-z, 0-9, -)" ;; esac
    case "$dir" in /*) ;; *) die "EXTRA_SHARES: $tag needs an absolute path" ;; esac
    case "$dir" in *,*) die "EXTRA_SHARES: the path for $tag must not contain a comma" ;; esac
    case "$dir" in
      "$HOME/Library/CloudStorage"/?*|"$HOME/Library/Mobile Documents/com~apple~CloudDocs"|"$HOME/Library/Mobile Documents/com~apple~CloudDocs"/*) ;;
      /|/Users|/private|/tmp|/private/tmp|/System|/Library|/Applications|/Volumes|"$HOME"|"$HOME/Library"|"$HOME/Library"/*) die "refusing to share $dir (a system folder, the home folder or the Library)" ;;
    esac
    if [ -d "$dir" ]; then
      n=$((n + 1))
      set -- "$@" -fsdev "local,id=extra$n,path=$dir,security_model=none,multidevs=remap$OWNER" \
        -device "virtio-9p-pci,fsdev=extra$n,mount_tag=$tag$ROM"
    else
      echo "$ME: $dir is not there; $tag is not shared this time" >&2
    fi
    IFS=$NL
  done
  IFS=$OLDIFS
fi
