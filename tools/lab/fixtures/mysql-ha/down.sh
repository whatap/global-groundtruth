#!/bin/bash
# down.sh -> manual escape hatch. The lab is permanent (user decision
# 2026-09-27); do not run this as part of a test.
#   down.sh          stop the three containers (data kept, up.sh restarts them)
#   down.sh --rm     remove containers and network (data lost; images and the
#                    secrets file kept, up.sh recreates and reseeds)
set -u
. "$(dirname "$0")/common.sh"
if [ "${1:-}" = --rm ]; then
    docker rm -f $ALL_CONTAINERS 2>/dev/null; docker network rm "$NET" 2>/dev/null; true
else
    docker stop $ALL_CONTAINERS 2>/dev/null; true
fi
