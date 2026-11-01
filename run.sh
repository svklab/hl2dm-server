#!/bin/sh
# =============================================================================
#  HL2DM dedicated server - startup script (v1-latest)
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
#         check that downloads at most a delta - not the old ~41 MB every-
#         container fetch.
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

export STEAM_HOME
export HOME="${STEAM_HOME}"
export LD_LIBRARY_PATH="${HL2DM_INSTALL_DIR}/bin:/usr/lib/i386-linux-gnu:${LD_LIBRARY_PATH:-}"

DEFAULT_DIR="${HL2DM_DEFAULT_DIR:-/opt/hl2dm-defaults}"
STATE_FILE="${STEAM_HOME}/.hl2dm-state"

# ------------------------------------------------------------------ logging
log() { printf '[entrypoint] %s\n' "$*"; }
die() { printf '[entrypoint] FATAL: %s\n' "$*" >&2; exit 1; }

# The health probe reads this to tell "busy installing" from "should be serving".
# It lives outside the image so it works for any user/volume layout.
set_state() { printf '%s\n' "$1" > "$STATE_FILE"; }

set_state installing

# Escape a value for safe use as a sed replacement.
esc() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

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

# Kill the server tree outright - used only when the graceful quit timed out.
force_stop() {
    kill -TERM "$srv_pid" 2>/dev/null || true
    for c in /proc/[0-9]*/comm; do
        [ -r "$c" ] || continue
        case "$(cat "$c" 2>/dev/null || true)" in
            srcds_run|srcds_linux) ;;
            *) continue ;;
        esac
        p="${c#/proc/}"; p="${p%/comm}"
        kill -TERM "$p" 2>/dev/null || true
    done
    sleep 2
    kill -KILL "$srv_pid" 2>/dev/null || true
}

# ------------------------------------------------------------------ shutdown
# The trap is installed BEFORE the download phases so that `docker stop` is
# honoured while steamcmd is still fetching content, not just once the server
# is up: either the steamcmd child is terminated, or the graceful console 'quit'
# path runs. (In the old image a stop during phase 1/2 killed PID 1 outright.)
shutdown() {
    if [ -z "$srv_pid" ]; then
        # Still in a download/install phase: terminate the active steamcmd child.
        trap '' INT TERM
        log "stop requested during initialization - terminating steamcmd"
        if [ -n "$steamcmd_pid" ]; then
            kill -TERM "$steamcmd_pid" 2>/dev/null || true
            wait "$steamcmd_pid" 2>/dev/null || true
        fi
        rm -f "${STEAM_HOME}/.srcds-console.fifo" 2>/dev/null || true
        exit 130
    fi

    trap '' INT TERM            # ignore any further stop signals
    log "stop requested - asking the server to quit"
    printf 'quit\n' >&3 2>/dev/null || true

    waited=0
    while [ "$waited" -lt "${SRCDS_STOP_TIMEOUT:-8}" ]; do
        kill -0 "$srv_pid" 2>/dev/null || break
        sleep 1
        waited=$((waited + 1))
    done

    if kill -0 "$srv_pid" 2>/dev/null; then
        log "server did not quit within ${SRCDS_STOP_TIMEOUT:-8}s - terminating it"
        force_stop
    fi

    # Reap the server's real exit status (the interrupted `wait` did not) and
    # stop the entrypoint from here so the container exit code reflects it.
    rc=0
    if wait "$srv_pid" 2>/dev/null; then rc=0; else rc=$?; fi
    rm -f "${STEAM_HOME}/.srcds-console.fifo" 2>/dev/null || true
    log "server exited with code ${rc}"
    exit "$rc"
}
trap shutdown INT TERM

# ------------------------------------------------------------ 1. fetch content
# SteamCMD is run in two explicit phases so the log says plainly what is being
# downloaded:
#   phase 1 - SteamCMD self-update check. The full self-update done here was
#             baked into the image at build time; on a fresh container this is
#             a quick version check (delta download at most) instead of the old
#             ~41 MB per-container fetch.
#   phase 2 - the game content: ~895 MB on a first install, a few seconds of
#             manifest checking afterwards.
# Splitting them also warms the appinfo cache, which avoids the one-off
#     ERROR! Failed to install app '232370' (Missing configuration)
# a brand new cache can produce. The retry below stays as a safety net.
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

# The hostname default mirrors the value already baked into server.cfg, so a
# container started with no SRCDS_* env vars deploys a byte-identical
# server.cfg / mapcycle.txt to the ones shipped in the image.
SRCDS_HOSTNAME_DEFAULT="HL2DM Server -- Happy gaming"

SRCDS_TICKRATE="${SRCDS_TICKRATE:-66}"
SRCDS_MAXPLAYERS="${SRCDS_MAXPLAYERS:-12}"
SRCDS_REGION="${SRCDS_REGION:-3}"

log "generating cfg/server.cfg from image default + environment"
cp -f "$DEFAULT_DIR/server.cfg" "$GAME_DIR/cfg/server.cfg"

set_convar "$GAME_DIR/cfg/server.cfg" hostname  "\"${SRCDS_HOSTNAME:-$SRCDS_HOSTNAME_DEFAULT}\""
set_convar "$GAME_DIR/cfg/server.cfg" sv_region "$SRCDS_REGION"

# Passwords are absent from the default cfg, so they are appended when set.
if [ -n "${SRCDS_PASSWORD:-}" ]; then
    set_convar "$GAME_DIR/cfg/server.cfg" sv_password "\"${SRCDS_PASSWORD}\""
fi
if [ -n "${SRCDS_RCON_PASSWORD:-}" ]; then
    set_convar "$GAME_DIR/cfg/server.cfg" rcon_password "\"${SRCDS_RCON_PASSWORD}\""
fi
if [ -n "${SRCDS_EXTRA_CVARS:-}" ]; then
    {
        printf '\n// from SRCDS_EXTRA_CVARS\n'
        printf '%s\n' "$SRCDS_EXTRA_CVARS"
    } >> "$GAME_DIR/cfg/server.cfg"
fi

if [ -n "${SRCDS_MAPCYCLE:-}" ]; then
    log "generating cfg/mapcycle.txt from SRCDS_MAPCYCLE"
    {
        printf '// Generated by run.sh from SRCDS_MAPCYCLE ("|" separated)\n'
        printf '%s' "$SRCDS_MAPCYCLE" | tr '|' '\n'
    } > "$GAME_DIR/cfg/mapcycle.txt"
else
    cp -f "$DEFAULT_DIR/mapcycle.txt" "$GAME_DIR/cfg/mapcycle.txt"
fi

# server.cfg does `exec banned_user.cfg` / `exec banned_ip.cfg`; without the
# files the console fills with "couldn't exec banned_user.cfg" errors.
for b in banned_user.cfg banned_ip.cfg; do
    [ -f "$GAME_DIR/cfg/$b" ] || : > "$GAME_DIR/cfg/$b"
done

# SteamCMD ships a crash reporter that the engine looks for next to the game
# binary. Without it every start logs "Could not find steamerrorreporter binary".
# Link it in so crash minidumps are actually captured.
if [ -x "$STEAMCMD_DIR/linux32/steamerrorreporter" ]; then
    for p in "$HL2DM_INSTALL_DIR/steamerrorreporter" "$HL2DM_INSTALL_DIR/bin/steamerrorreporter"; do
        [ -e "$p" ] || ln -sf "$STEAMCMD_DIR/linux32/steamerrorreporter" "$p" 2>/dev/null || true
    done
fi

# ------------------------------------------------------------- 3. run server
cd "$HL2DM_INSTALL_DIR"

SRCDS_PORT="${SRCDS_PORT:-27015}"
SRCDS_CLIENT_PORT="${SRCDS_CLIENT_PORT:-27005}"
SRCDS_MAP="${SRCDS_MAP:-dm_overwatch}"
SRCDS_IP="${SRCDS_IP:-0.0.0.0}"

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

CONSOLE_FIFO="${STEAM_HOME}/.srcds-console.fifo"
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
    log "WARNING: 'script' not found - graceful console quit is unavailable"
    sh -c "$SRCDS_CMD" <"$CONSOLE_FIFO" &
fi
srv_pid=$!

# Normal case: the server crashes or is stopped from the outside, so `wait`
# simply returns its status. A stop signal is handled entirely inside the
# shutdown trap above, which exits the script.
rc=0
while : ; do
    if wait "$srv_pid"; then rc=0; else rc=$?; fi
    kill -0 "$srv_pid" 2>/dev/null || break
done

rm -f "$CONSOLE_FIFO"
log "server exited with code ${rc}"
exit "$rc"
