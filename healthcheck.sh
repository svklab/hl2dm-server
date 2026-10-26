#!/bin/sh
# =============================================================================
#  HL2DM container health probe
#
#  Exit codes (as required by the Docker HEALTHCHECK contract):
#    0  healthy / ready to serve
#    1  unhealthy / not serving yet
#
#  The probe reports healthy only once srcds_linux is running AND the game UDP
#  port is actually bound. Checking the socket, not just the process, catches a
#  hung or zombie server that `pgrep` alone would call healthy. While the
#  entrypoint is still fetching or validating game content the container is
#  reported unhealthy; the image's start-period is large enough to cover a
#  normal first-run download so that does not flap.
#
#  Depends only on /bin/sh, cat and grep - no procps required.
# =============================================================================
set -u

STEAM_HOME="${STEAM_HOME:-/home/steam}"
STATE_FILE="${STEAM_HOME}/.hl2dm-state"
PORT="${SRCDS_PORT:-27015}"

state="$(cat "$STATE_FILE" 2>/dev/null || echo unknown)"
case "$state" in
    installing)
        echo "installing game content - not serving yet"
        exit 1
        ;;
    running)
        : # fall through to the liveness checks
        ;;
    *)
        echo "entrypoint has not reached the serving state yet (state=${state})"
        exit 1
        ;;
esac

# 1. the server process must exist (scan /proc, avoids a procps dependency)
found=1
for comm in /proc/[0-9]*/comm; do
    [ -r "$comm" ] || continue
    if [ "$(cat "$comm" 2>/dev/null || true)" = "srcds_linux" ]; then
        found=0
        break
    fi
done
if [ "$found" -ne 0 ]; then
    echo "srcds_linux is not running"
    exit 1
fi

# 2. the game UDP port must be bound; /proc/net/udp prints the port in hex.
hex="$(printf '%04X' "$PORT" 2>/dev/null || echo "")"
if [ -z "$hex" ] || ! grep -qi ":${hex} " /proc/net/udp; then
    echo "udp port ${PORT} is not bound"
    exit 1
fi

echo "healthy: srcds_linux running, udp/${PORT} bound"
exit 0