#!/usr/bin/env python3
"""Copy a disk image so that runs of zeros become holes: `sparse-copy.py <source> <target> [<size in GB>]`.

A raw disk that came out of an archive is written in full, zeros included; on APFS this copy takes only the
space of the data. With a size the target is also grown to that many GB (never shrunk), which the guest's
cloud-init turns into a bigger root filesystem on its next boot.
"""
import os
import sys

BLOCK = 1 << 20


def main(argv):
    if len(argv) not in (3, 4):
        print(__doc__.strip().splitlines()[0], file=sys.stderr)
        return 64
    source, target = argv[1], argv[2]
    size = int(argv[3]) << 30 if len(argv) == 4 else 0
    zero = bytes(BLOCK)
    tmp = target + ".new"
    with open(source, "rb") as src, open(tmp, "wb") as dst:
        total = 0
        while True:
            chunk = src.read(BLOCK)
            if not chunk:
                break
            if chunk == zero[:len(chunk)]:
                dst.seek(len(chunk), os.SEEK_CUR)     # a hole
            else:
                dst.write(chunk)
            total += len(chunk)
        dst.truncate(max(total, size))
    os.replace(tmp, target)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
