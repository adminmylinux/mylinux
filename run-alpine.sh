#!/bin/sh
# An Alpine server machine: run-server.sh with DISTRO=alpine (its environment is described there).
DISTRO=alpine exec sh "$(dirname "$0")/run-server.sh" "$@"
