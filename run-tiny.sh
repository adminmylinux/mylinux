#!/bin/sh
# A Tiny Alpine server machine: run-server.sh with DISTRO=tiny (its environment is described there).
DISTRO=tiny exec sh "$(dirname "$0")/run-server.sh" "$@"
