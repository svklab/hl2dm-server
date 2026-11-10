#!/bin/sh
# =============================================================================
#  HL2DM dedicated server - startup script (v1.0)
#
#  Game content is NOT baked into the image. On first start SteamCMD fetches
#  app 232370 into $HL2DM_INSTALL_DIR, which is expected to be a mounted
#  volume. That keeps the image small and makes the game content replaceable
#  without rebuilding the image.
#
#  All configuration lives inside the image - there is nothing to bind-mount.
#  server.cfg / mapcycle.txt / motd.txt ship read-only in /opt/hl2dm-defaults and
#  are deployed into the game directory on every start, with the SRCDS_* env vars
#  applied on top.
#
#  Configuration precedence, highest first:
#    1. Environment variables (SRCDS_HOSTNAME, SRCDS_MAXPLAYERS, ...)
#    2. The defaults baked into /opt/hl2dm-defaults
#
#  Startup phases, as printed in `docker logs`:
#    1/2  SteamCMD self-update check. The full self-update was baked into the
#         image at build time, so on a fresh container this is a quick version
#         check that downloads at most a delta.
#    2/2  The game content is fetched/checked: ~895 MB on a first install, a
#         manifest check of a few seconds afterwards.
#  Both are limited by Steam's CDN rather than by this image; observed speeds
#  range from ~0.2 MB/s to several MB/s depending on the network and time.
#
#  Useful environment variables:
#    SRCDS_VALIDATE=1    re-hash all game content on start (~50 s on 895 MB).
#                        Default 0: only the SteamCMD manifest is checked (~5 s),
#                        which still picks up updates but skips the full verify.
#    SRCDS_APP_UPDATE=0  skip SteamCMD entirely and use the content already on
#                        the volume (offline start; fails if none is present).
#    SRCDS_EXTRA_ARGS    extra command-line arguments passed to srcds_run.
# =============================================================================
set -eu

STEAM_HOME="${STEAM_HOME:-/home/steam}"
STEAMCMD_DIR="${STEAMCMD_DIR:-/home/steam/steamcmd}"
HL2DM_INSTALL_DIR="${HL2DM_INSTALL_DIR:-/home/steam/hl2dm_server}"
HL2DM_DEFAULT_DIR="${HL2DM_DEFAULT_DIR:-/opt/hl2dm-defaults}"
SRCDS_APP_ID="${SRCDS_APP_ID:-232370}"

export HOME="${STEAM_HOME}"
export LD_LIBRARY_PATH="${HL2DM_INSTALL_DIR}/bin:/usr/lib/i386-linux-gnu:${LD_LIBRARY_PATH:-}"

DEFAULT_DIR="${HL2DM_DEFAULT_DIR}"
STATE_FILE="${STEAM_HOME}/.hl2dm-state"
CONSOLE_FIFO="${STEAM_HOME}/.srcds-console.fifo"

# ------------------------------------------------------------------ logging
log() { printf '[entrypoint] %s\n' "$*"; }
warn() { printf '[entrypoint] WARNING: %s\n' "$*" >&2; }
die() { printf '[entrypoint] FATAL: %s\n' "$*" >&2; exit 1; }

# The health probe reads this to tell "busy installing" from "should be serving".
set_state() { printf '%s\n' "$1" > "$STATE_FILE"; }

set_state installing

# --------------------------------------------------------------- validation
is_uint() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    return 0
}

# check_uint <name> <value> <min> <max>
check_uint() {
    _name="$1"; _value="$2"; _min="$3"; _max="$4"
    is_uint "$_value" || die "${_name} must be a number, got '${_value}'"
    [ "$_value" -ge "$_min" ] && [ "$_value" -le "$_max" ] \
        || die "${_name} must be between ${_min} and ${_max}, got '${_value}'"
}

# A newline in a quoted cvar value would end the quoted string and could inject
# another convar into server.cfg. Passwords, hostnames and other quoted values
# are therefore rejected if they span more than one line.
check_no_newline() {
    _name="$1"; _value="$2"
    case "$_value" in
        *"
"*) die "${_name} must not contain a newline" ;;
    esac
}

SRCDS_PORT="${SRCDS_PORT:-27015}"
SRCDS_CLIENT_PORT="${SRCDS_CLIENT_PORT:-27005}"
SRCDS_MAXPLAYERS="${SRCDS_MAXPLAYERS:-12}"
SRCDS_TICKRATE="${SRCDS_TICKRATE:-66}"
SRCDS_REGION="${SRCDS_REGION:-3}"
SRCDS_MAP="${SRCDS_MAP:-dm_overwatch}"
SRCDS_IP="${SRCDS_IP:-0.0.0.0}"
SRCDS_STOP_TIMEOUT="${SRCDS_STOP_TIMEOUT:-8}"

check_uint SRCDS_PORT "$SRCDS_PORT" 1 65535
check_uint SRCDS_CLIENT_PORT "$SRCDS_CLIENT_PORT" 1 65535
check_uint SRCDS_MAXPLAYERS "$SRCDS_MAXPLAYERS" 1 64
check_uint SRCDS_TICKRATE "$SRCDS_TICKRATE" 10 1000
check_uint SRCDS_REGION "$SRCDS_REGION" 0 255
check_uint SRCDS_STOP_TIMEOUT "$SRCDS_STOP_TIMEOUT" 1 300

[ -n "$SRCDS_MAP" ] || die "SRCDS_MAP must not be empty"
[ -n "$SRCDS_IP" ] || die "SRCDS_IP must not be empty"

case "${SRCDS_APP_UPDATE:-1}" in
    0|1) ;;
    *) die "SRCDS_APP_UPDATE must be 0 or 1, got '${SRCDS_APP_UPDATE}'" ;;
esac
case "${SRCDS_VALIDATE:-0}" in
    0|1) ;;
    *) die "SRCDS_VALIDATE must be 0 or 1, got '${SRCDS_VALIDATE}'" ;;
esac

# Reject multi-line quoted values before the (potentially long) content
# download, not after it.
[ -z "${SRCDS_HOSTNAME:-}" ] || check_no_newline SRCDS_HOSTNAME "$SRCDS_HOSTNAME"
[ -z "${SRCDS_PASSWORD:-}" ] || check_no_newline SRCDS_PASSWORD "$SRCDS_PASSWORD"
[ -z "${SRCDS_RCON_PASSWORD:-}" ] || check_no_newline SRCDS_RCON_PASSWORD "$SRCDS_RCON_PASSWORD"

# ------------------------------------------------------------ filesystem checks
# A bind-mounted host directory is owned by the host UID, not by the image's
# steam user. Fail early with an actionable message instead of letting SteamCMD
# or the engine produce a confusing "permission denied" later.
[ -r "$DEFAULT_DIR/server.cfg" ] || die "default server.cfg not found in ${DEFAULT_DIR}"
[ -r "$DEFAULT_DIR/mapcycle.txt" ] || die "default mapcycle.txt not found in ${DEFAULT_DIR}"
[ -r "$DEFAULT_DIR/motd.txt" ] || die "default motd.txt not found in ${DEFAULT_DIR}"

if [ ! -d "$HL2DM_INSTALL_DIR" ]; then
    mkdir -p "$HL2DM_INSTALL_DIR" 2>/dev/null \
        || die "cannot create ${HL2DM_INSTALL_DIR}"
fi
[ -w "$HL2DM_INSTALL_DIR" ] \
    || die "${HL2DM_INSTALL_DIR} is not writable by uid $(id -u). If you bind-mount a host directory, chown it to ${STEAM_UID:-1000}:${STEAM_GID:-1000}."

if [ "${SRCDS_APP_UPDATE:-1}" = "1" ]; then
    [ -d "$STEAMCMD_DIR" ] || die "SteamCMD directory ${STEAMCMD_DIR} is missing"
    [ -x "$STEAMCMD_DIR/steamcmd.sh" ] || die "SteamCMD not found at ${STEAMCMD_DIR}/steamcmd.sh"
    [ -w "$STEAMCMD_DIR" ] \
        || die "${STEAMCMD_DIR} is not writable by uid $(id -u); SteamCMD needs to update itself."
else
    [ -x "$HL2DM_INSTALL_DIR/srcds_run" ] \
        || die "SRCDS_APP_UPDATE=0 but ${HL2DM_INSTALL_DIR}/srcds_run is missing; remove the variable or mount the volume with game content."
fi

# Escape a value for safe use as a sed replacement.
esc() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

# Quote a cvar value for the Source config parser. This keeps a quote or a
# backslash in a hostname/password from terminating the value early.
cvar_quote() {
    _q=$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
    printf '"%s"' "$_q"
}

# Replace the value of a convar line, or append the convar if it is absent.
# $1=file  $2=convar key  $3=new value
# Note: the sed path needs the escaped value, the append path needs the raw one.
set_convar() {
    _f="$1"; _k="$2"; _raw="$3"; _v=$(esc "$_raw"); _t="${_f}.tmp"
    if grep -qE "^[[:space:]]*${_k}[[:space:]]" "$_f"; then
        sed -E "s|^([[:space:]]*${_k}[[:space:]]+).*|\1${_v}|" "$_f" > "$_t"
    else
        cp "$_f" "$_t"
        printf '%s %s\n' "$_k" "$_raw" >> "$_t"
    fi
    mv -f "$_t" "$_f"
}

# ------------------------------------------------------------ PID bookkeeping
# Track the child of each phase so a stop-signal that arrives mid-download can
# terminate exactly that process (and its tree) instead of killing PID 1.
srv_pid=""
steamcmd_pid=""

# Terminate the active SteamCMD process and any steamcmd/steamerrorreporter
# children. steamcmd.sh runs the real client as a child, so killing only the
# shell wrapper can leave the download running.
kill_steamcmd_tree() {
    _pid="${1:-}"
    if [ -n "$_pid" ]; then
        kill -TERM "$_pid" 2>/dev/null || true
    fi
    for _c in /proc/[0-9]*/comm; do
        [ -r "$_c" ] || continue
        case "$(cat "$_c" 2>/dev/null || true)" in
            steamcmd|steamerrorreporter) ;;
            *) continue ;;
        esac
        _p="${_c#/proc/}"; _p="${_p%/comm}"
        kill -TERM "$_p" 2>/dev/null || true
    done
    sleep 1
    if [ -n "$_pid" ]; then
        kill -KILL "$_pid" 2>/dev/null || true
    fi
    for _c in /proc/[0-9]*/comm; do
        [ -r "$_c" ] || continue
        case "$(cat "$_c" 2>/dev/null || true)" in
            steamcmd|steamerrorreporter) ;;
            *) continue
        esac
        _p="${_c#/proc/}"; _p="${_p%/comm}"
        kill -KILL "$_p" 2>/dev/null || true
    done
}

# Kill the server tree outright - used only when the graceful quit timed out.
force_stop() {
    log "server did not quit in time - terminating it"
    [ -n "$srv_pid" ] && kill -TERM "$srv_pid" 2>/dev/null || true
    for _c in /proc/[0-9]*/comm; do
        [ -r "$_c" ] || continue
        case "$(cat "$_c" 2>/dev/null || true)" in
            srcds_run|srcds_linux|script) ;;
            *) continue ;;
        esac
        _p="${_c#/proc/}"; _p="${_p%/comm}"
        kill -TERM "$_p" 2>/dev/null || true
    done
    sleep 2
    [ -n "$srv_pid" ] && kill -KILL "$srv_pid" 2>/dev/null || true
    for _c in /proc/[0-9]*/comm; do
        [ -r "$_c" ] || continue
        case "$(cat "$_c" 2>/dev/null || true)" in
            srcds_run|srcds_linux) ;;
            *) continue
        esac
        _p="${_c#/proc/}"; _p="${_p%/comm}"
        kill -KILL "$_p" 2>/dev/null || true
    done
}

# ------------------------------------------------------------------ shutdown
# The trap is installed BEFORE the download phases so that `docker stop` is
# honoured while steamcmd is still fetching content, not just once the server
# is up.
shutdown() {
    trap '' INT TERM

    if [ -z "$srv_pid" ]; then
        # Still in a download/install phase: terminate the active steamcmd tree.
        log "stop requested during initialization - terminating steamcmd"
        kill_steamcmd_tree "${steamcmd_pid:-}"
        rm -f "$CONSOLE_FIFO" 2>/dev/null || true
        exit 130
    fi

    log "stop requested - asking the server to quit"
    printf 'quit\n' >&3 2>/dev/null || true

    _waited=0
    while [ "$_waited" -lt "$SRCDS_STOP_TIMEOUT" ]; do
        kill -0 "$srv_pid" 2>/dev/null || break
        sleep 1
        _waited=$((_waited + 1))
    done

    if kill -0 "$srv_pid" 2>/dev/null; then
        force_stop
    fi

    # Reap the server's real exit status (the interrupted `wait` did not) and
    # stop the entrypoint from here so the container exit code reflects it.
    _rc=0
    if wait "$srv_pid" 2>/dev/null; then _rc=0; else _rc=$?; fi
    rm -f "$CONSOLE_FIFO" 2>/dev/null || true
    log "server exited with code ${_rc}"
    exit "$_rc"
}
trap shutdown INT TERM

# ------------------------------------------------------------ 1. fetch content
# SteamCMD is run in two explicit phases so the log says plainly what is being
# downloaded:
#   phase 1 - SteamCMD self-update check (the heavy part is baked into the
#             image; on a fresh container this is a quick version check);
#   phase 2 - the game content: ~895 MB on a first install, a few seconds of
#             manifest checking afterwards.
#
# force_install_dir MUST precede login, otherwise SteamCMD aborts with
# "Please use force_install_dir before logon!" and downloads nothing.
max_attempts=3

# Run steamcmd with the given arguments, retrying a few times. SteamCMD streams
# its progress with carriage returns, which look like one frozen line in
# `docker logs`, so it runs in the background and the entrypoint reports elapsed
# time (and the size of the game directory) on a timer instead - that makes an
# active transfer obvious and tells it apart from a hang. A short sleep keeps the
# detection of a finished step snappy, the 15 s cadence is only for logging.
#   $1 = human readable phase label, remaining arguments are passed to steamcmd
run_steamcmd() {
    _label="$1"; shift
    _attempt=1
    while : ; do
        "$STEAMCMD_DIR/steamcmd.sh" "$@" &
        steamcmd_pid=$!
        _pid=$!

        _ticks=0
        while sleep 3; do
            kill -0 "$_pid" 2>/dev/null || break
            _ticks=$((_ticks + 1))
            [ $((_ticks % 5)) -eq 0 ] || continue
            _mb=$(du -sm "$HL2DM_INSTALL_DIR" 2>/dev/null | cut -f1)
            log "${_label}: $((_ticks * 3))s elapsed, game content ${_mb:-?} MB on disk"
        done

        if wait "$_pid"; then
            steamcmd_pid=""
            return 0
        fi

        steamcmd_pid=""
        _attempt=$((_attempt + 1))
        if [ "$_attempt" -gt "$max_attempts" ]; then
            die "SteamCMD failed during ${_label} after ${max_attempts} attempts"
        fi
        log "SteamCMD failed during ${_label}, retrying ($((_attempt - 1))/${max_attempts}) in 5s..."
        sleep 5
    done
}

if [ "${SRCDS_APP_UPDATE:-1}" = "1" ]; then
    if [ -x "$HL2DM_INSTALL_DIR/srcds_run" ]; then
        log "game content present ($(du -sm "$HL2DM_INSTALL_DIR" 2>/dev/null | cut -f1) MB)"
    else
        log "no game content found - phase 2 downloads ~895 MB, be patient"
    fi

    log "SteamCMD 1/2: self-update check (baked into image at build time)"
    run_steamcmd "SteamCMD self-update" +login anonymous +quit

    if [ "${SRCDS_VALIDATE:-0}" = "1" ]; then
        log "SteamCMD 2/2: game content - full validation (SRCDS_VALIDATE=1, ~50 s)"
        run_steamcmd "game content" \
            +force_install_dir "$HL2DM_INSTALL_DIR" \
            +login anonymous \
            +app_update "$SRCDS_APP_ID" validate \
            +quit
    else
        log "SteamCMD 2/2: game content - update check (SRCDS_VALIDATE=0, manifest only)"
        run_steamcmd "game content" \
            +force_install_dir "$HL2DM_INSTALL_DIR" \
            +login anonymous \
            +app_update "$SRCDS_APP_ID" \
            +quit
    fi
else
    log "SRCDS_APP_UPDATE=0 - not contacting Steam, using content already on disk"
fi

GAME_DIR="$HL2DM_INSTALL_DIR/hl2mp"
[ -x "$HL2DM_INSTALL_DIR/srcds_run" ] || die "$HL2DM_INSTALL_DIR/srcds_run missing"
[ -d "$GAME_DIR" ] || die "game content is incomplete: ${GAME_DIR} missing"
mkdir -p "$GAME_DIR/cfg" "$GAME_DIR/logs"

log "content ready: $(du -sm "$HL2DM_INSTALL_DIR" 2>/dev/null | cut -f1) MB at $HL2DM_INSTALL_DIR"

# ------------------------------------------- 2. build the effective cfg files
# Everything is baked into the image and deployed from there on every start.
# No config files need to be mounted by the user.
#
# The engine reads the game root for motd.txt by default; keep a copy in cfg/
# too, since some admin tooling looks there.
cp -f "$DEFAULT_DIR/motd.txt" "$GAME_DIR/motd.txt"
cp -f "$DEFAULT_DIR/motd.txt" "$GAME_DIR/cfg/motd.txt"
chmod u+w "$GAME_DIR/motd.txt" "$GAME_DIR/cfg/motd.txt" 2>/dev/null || true

# The hostname default mirrors the value already baked into server.cfg, so a
# container started with no SRCDS_* env vars deploys a byte-identical
# server.cfg / mapcycle.txt to the ones shipped in the image.
SRCDS_HOSTNAME_DEFAULT="HL2DM Server -- Happy gaming"

log "generating cfg/server.cfg from image default + environment"
cp -f "$DEFAULT_DIR/server.cfg" "$GAME_DIR/cfg/server.cfg"
# The defaults are 0444; the deployed copies must be writable by steam because
# set_convar and SRCDS_EXTRA_CVARS modify them in place.
chmod u+w "$GAME_DIR/cfg/server.cfg" 2>/dev/null || true

set_convar "$GAME_DIR/cfg/server.cfg" hostname "$(cvar_quote "${SRCDS_HOSTNAME:-$SRCDS_HOSTNAME_DEFAULT}")"
set_convar "$GAME_DIR/cfg/server.cfg" sv_region "$SRCDS_REGION"

# Passwords are absent from the default cfg, so they are appended when set.
if [ -n "${SRCDS_PASSWORD:-}" ]; then
    set_convar "$GAME_DIR/cfg/server.cfg" sv_password "$(cvar_quote "$SRCDS_PASSWORD")"
fi
if [ -n "${SRCDS_RCON_PASSWORD:-}" ]; then
    set_convar "$GAME_DIR/cfg/server.cfg" rcon_password "$(cvar_quote "$SRCDS_RCON_PASSWORD")"
fi
if [ -n "${SRCDS_EXTRA_CVARS:-}" ]; then
    {
        printf '\n// from SRCDS_EXTRA_CVARS\n'
        printf '%s\n' "$SRCDS_EXTRA_CVARS"
    } >> "$GAME_DIR/cfg/server.cfg"
fi

if [ -n "${SRCDS_MAPCYCLE:-}" ]; then
    log "generating cfg/mapcycle.txt from SRCDS_MAPCYCLE"
    _mc_tmp="$GAME_DIR/cfg/.mapcycle.txt.tmp"
    {
        printf '// Generated by run.sh from SRCDS_MAPCYCLE ("|" separated)\n'
        printf '%s\n' "$SRCDS_MAPCYCLE" | tr '|' '\n'
    } > "$_mc_tmp"
    # Atomic replace: the previously deployed mapcycle.txt is 0444, so a plain
    # ">" redirect would fail with "Permission denied" on the second start.
    mv -f "$_mc_tmp" "$GAME_DIR/cfg/mapcycle.txt"
else
    cp -f "$DEFAULT_DIR/mapcycle.txt" "$GAME_DIR/cfg/mapcycle.txt"
    chmod u+w "$GAME_DIR/cfg/mapcycle.txt" 2>/dev/null || true
fi

# server.cfg does `exec banned_user.cfg` / `exec banned_ip.cfg`; without the
# files the console fills with "couldn't exec banned_user.cfg" errors.
for _b in banned_user.cfg banned_ip.cfg; do
    [ -f "$GAME_DIR/cfg/$_b" ] || : > "$GAME_DIR/cfg/$_b"
done

# SteamCMD ships a crash reporter that the engine looks for next to the game
# binary. Without it every start logs "Could not find steamerrorreporter binary".
# Link it in so crash minidumps are actually captured.
if [ -x "$STEAMCMD_DIR/linux32/steamerrorreporter" ]; then
    for _p in "$HL2DM_INSTALL_DIR/steamerrorreporter" "$HL2DM_INSTALL_DIR/bin/steamerrorreporter"; do
        [ -e "$_p" ] || ln -sf "$STEAMCMD_DIR/linux32/steamerrorreporter" "$_p" 2>/dev/null || true
    done
fi

# A missing map is a common mistake after a custom map was removed from the
# volume (halls3 is a custom map and is not shipped by SteamCMD). Warn instead
# of failing: the engine may still find a map inside a VPK.
if [ ! -f "$GAME_DIR/maps/${SRCDS_MAP}.bsp" ]; then
    warn "starting map ${SRCDS_MAP}.bsp not found in ${GAME_DIR}/maps - the server may fail to start"
fi
# The shipped mapcycle.txt is CRLF (Valve's file); strip CR so the names match
# the .bsp files. A temp file keeps this out of the mapcycle itself.
_mapcycle_check="$GAME_DIR/cfg/.mapcycle.check"
tr -d '\r' < "$GAME_DIR/cfg/mapcycle.txt" > "$_mapcycle_check"
while IFS= read -r _map; do
    case "$_map" in
        ''|//*) continue ;;
    esac
    [ -f "$GAME_DIR/maps/${_map}.bsp" ] \
        || warn "map ${_map}.bsp from cfg/mapcycle.txt not found in ${GAME_DIR}/maps - the rotation will skip/fail on it"
done < "$_mapcycle_check"
rm -f "$_mapcycle_check"

# ------------------------------------------------------------- 3. run server
cd "$HL2DM_INSTALL_DIR"

log "hostname     : ${SRCDS_HOSTNAME:-$SRCDS_HOSTNAME_DEFAULT}"
log "map / cycle  : ${SRCDS_MAP} (see cfg/mapcycle.txt)"
log "tickrate     : ${SRCDS_TICKRATE}   max players: ${SRCDS_MAXPLAYERS}"
log "ports        : ${SRCDS_PORT} (udp+tcp), client ${SRCDS_CLIENT_PORT}"
log "locale       : ${LANG:-unset}"

# NOTE 1: the port must be passed with "-port", not "+port". "+port" is not a
# convar and the server answers "Unknown command \"port\"" on every start.
# NOTE 2: do NOT pass "-steam_dir" here. srcds_run then also demands
# "-steamcmd_script" and aborts with
#   "ERROR: You must set both the steam_dir and steamcmd_script."
# We never want the engine to drive its own SteamCMD, because updates are
# already handled above.
# NOTE 3: the engine ignores SIGINT/SIGQUIT and only handles SIGTERM as an
# immediate kill, so a signal cannot shut it down cleanly. What does work is the
# console command 'quit' - but the engine only reads its stdin when that stdin is
# a terminal (verified: a plain pipe is silently ignored). This script therefore
# keeps PID 1, runs the server under a pseudo-terminal (`script`, from the
# always-present bsdutils) whose input comes from a FIFO, and on SIGINT/SIGTERM
# writes 'quit' into that FIFO. The engine exits cleanly (exit code 0, logs
# closed) and `docker stop` no longer ends in a SIGKILL. If the engine does not
# quit within SRCDS_STOP_TIMEOUT seconds it is terminated the hard way.
set_state running

rm -f "$CONSOLE_FIFO"
mkfifo "$CONSOLE_FIFO"
# Opened read-write so that opening it never blocks and the child never sees EOF.
exec 3<>"$CONSOLE_FIFO"

# shellcheck disable=SC2086
SRCDS_CMD="stty -onlcr 2>/dev/null || true; exec ./srcds_run -game hl2mp -console -usercon \
-port ${SRCDS_PORT} -clientport ${SRCDS_CLIENT_PORT} \
-tickrate ${SRCDS_TICKRATE} -maxplayers ${SRCDS_MAXPLAYERS} \
+ip ${SRCDS_IP} +hostport ${SRCDS_PORT} +clientport ${SRCDS_CLIENT_PORT} \
+motdfile motd.txt +exec server.cfg +mapcyclefile cfg/mapcycle.txt \
+map ${SRCDS_MAP} +mp_teamplay 0 ${SRCDS_EXTRA_ARGS:-}"

srv_pid=""
if command -v script >/dev/null 2>&1; then
    script -q -c "$SRCDS_CMD" /dev/null <"$CONSOLE_FIFO" &
else
    # No pty available: the server still runs, but only a forced stop is possible.
    warn "'script' not found - graceful console quit is unavailable"
    sh -c "$SRCDS_CMD" <"$CONSOLE_FIFO" &
fi
srv_pid=$!

# Normal case: the server crashes or is stopped from the outside, so `wait`
# simply returns its status. A stop signal is handled entirely inside the
# shutdown trap above, which exits the script.
_rc=0
while : ; do
    if wait "$srv_pid"; then _rc=0; else _rc=$?; fi
    kill -0 "$srv_pid" 2>/dev/null || break
done

rm -f "$CONSOLE_FIFO"
log "server exited with code ${_rc}"
exit "$_rc"
