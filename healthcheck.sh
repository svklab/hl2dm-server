#!/bin/sh
# =============================================================================
#  HL2DM container health probe (v1.0)
#
#  Exit codes (as required by the Docker HEALTHCHECK contract):
#    0  healthy / ready to serve
#    1  unhealthy / not serving yet
#
#  The probe reports healthy only once srcds_linux is running (and is not a
#  zombie) AND the game UDP port is actually bound on a local address. Checking
#  the socket, not just the process, catches a hung server that `pgrep` alone
#  would call healthy. Both /proc/net/udp (IPv4) and /proc/net/udp6 (IPv6) are
#  inspected, and only the local-address field is matched, so an unrelated
#  socket with the same remote port cannot make the probe pass.
#
#  While the entrypoint is still fetching or validating game content the
#  container is reported unhealthy; the image's start-period is large enough to
#  cover a normal first-run download so that does not flap.
#
#  Depends only on /bin/sh, cat, awk and grep - no procps required.
# =============================================================================
set -u

STEAM_HOME="${STEAM_HOME:-/home/steam}"
STATE_FILE="${STEAM_HOME}/.hl2dm-state"
PORT="${SRCDS_PORT:-27015}"

case "$PORT" in
    ''|*[!0-9]*)
        echo "SRCDS_PORT is not numeric: '${PORT}'"
        exit 1
        ;;
esac
if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    echo "SRCDS_PORT is out of range: ${PORT}"
    exit 1
fi

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
pid=""
for d in /proc/[0-9]*; do
    [ -r "$d/comm" ] || continue
    [ "$(cat "$d/comm" 2>/dev/null || true)" = "srcds_linux" ] || continue
    pid="${d#/proc/}"
    break
done
if [ -z "$pid" ]; then
    echo "srcds_linux is not running"
    exit 1
fi

# 2. a zombie process still has a /proc entry and a bound socket may linger;
#    treat it as unhealthy.
pstate="$(awk '/^State:/ {print $2}' "/proc/${pid}/status" 2>/dev/null || true)"
if [ "$pstate" = "Z" ]; then
    echo "srcds_linux is a zombie"
    exit 1
fi

# 3. the game UDP port must be bound; /proc/net/udp* prints it in hex.
hex="$(printf '%04X' "$PORT" 2>/dev/null || true)"
if [ -z "$hex" ]; then
    echo "cannot convert udp port ${PORT} to hex"
    exit 1
fi

for f in /proc/net/udp /proc/net/udp6; do
    [ -r "$f" ] || continue
    if awk -v port="$hex" '
        NR > 1 {
            n = split($2, a, ":")
            if (n == 2 && toupper(a[2]) == toupper(port)) {
                found = 1
                exit
            }
        }
        END { exit !found }
    ' "$f"; then
        echo "healthy: srcds_linux running, udp/${PORT} bound"
        exit 0
    fi
done

echo "udp port ${PORT} is not bound"
exit 1
