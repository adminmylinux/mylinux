#!/bin/sh
# A Debian server machine: run-server.sh with DISTRO=debian (its environment is described there).
DISTRO=debian exec sh "$(dirname "$0")/run-server.sh" "$@"
