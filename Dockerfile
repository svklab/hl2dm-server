# syntax=docker/dockerfile:1
#
# HL2DM (Half-Life 2: Deathmatch) Dedicated Server - slim, runtime-download build (v1-latest)
#
# Base: debian:trixie-slim (Debian 13, glibc 2.41)
#   Debian trixie is the right base for the 32-bit Source engine: it ships a
#   modern glibc with an i386 multiarch layer. Alpine cannot run the glibc-based
#   srcds_linux (no glibc, gcompat is unreliable), and Ubuntu is both larger and
#   no newer than trixie. The base tag is left unpinned on purpose so that a
#   rebuild picks up Debian security updates; to make a build byte-for-byte
#   reproducible, override it with a digest, e.g.
#       docker build --build-arg BASE_IMAGE=debian:trixie-slim@sha256:a29215f6...
#
# What changed vs 2026-10-v1:old
#   - 'apt-get upgrade' now runs before everything else, so all base packages
#     are current at build time (the old build pinned whatever trixie-slim had).
#   - the SteamCMD self-update is baked into the image at build time instead of
#     being re-downloaded (~41 MB) by every freshly-created container. A new
#     container still checks the SteamCMD manifest, but the heavy fetch that
#     used to make phase 1 take minutes is gone.
#   - the redundant lib32gcc-s1/lib32stdc++6 packages are removed: the direct
#     i386 variants (libc6:i386, libstdc++6:i386, libgcc-s1:i386, zlib1g:i386)
#     are what the 32-bit engine actually links, and the lib32-* names are
#     aliases for the very same binaries.
#   - run.sh installs its signal trap before the download phases, so a
#     `docker stop` during a content download terminates steamcmd cleanly
#     instead of killing PID 1 outright (exit 130).
#   - healthcheck start-period raised 300s -> 900s (first-run downloads have
#     been observed to exceed 5 minutes on slow Steam CDNs).
#   - OCI labels now carry source / url / documentation pointers.
#
# Layout, launch principles and config handling are UNCHANGED from 2026-10-v1:
#   - non-root user 'steam' (UID/GID 1000)
#   - game content NOT baked in; SteamCMD fetches app 232370 into the mounted
#     volume on first start (~895 MB)
#   - server.cfg / mapcycle.txt / motd.txt ship read-only in /opt/hl2dm-defaults
#     and are deployed into the game directory on every start
#   - entrypoint /home/steam/run.sh with labelled SteamCMD 1/2 + 2/2 phases
#   - STOPSIGNAL SIGINT -> pty + console 'quit' -> graceful exit 0
#   - the SRCDS_* environment interface is unchanged
#
# Game content is NOT baked in. SteamCMD fetches app 232370 on first start into
# $HL2DM_INSTALL_DIR, which is expected to be a volume. This keeps the image
# small instead of multi-gigabyte, and makes game content replaceable without
# rebuilding the image.

ARG BASE_IMAGE=debian:trixie-slim
FROM ${BASE_IMAGE}

# --------------------------------------------------------------- OCI metadata
ARG VERSION=2026-10-v1
ARG REVISION=unknown
LABEL org.opencontainers.image.title="HL2DM dedicated server (slim, trixie, v1-latest)" \
      org.opencontainers.image.description="Half-Life 2 Deathmatch SRCDS on Debian 13 trixie-slim; game content fetched at runtime by SteamCMD" \
      org.opencontainers.image.base.name="debian:trixie-slim" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.licenses="Valve EULA" \
      org.opencontainers.image.source="https://github.com/svklab/hl2dm-server" \
      org.opencontainers.image.url="https://hub.docker.com/r/svk2907/hl2dm-server-2026-10-v1" \
      org.opencontainers.image.documentation="https://github.com/svklab/hl2dm-server"

# --------------------------------------------------------------------- env
# The engine and SteamCMD call setlocale() with the literal string
# "en_US.UTF-8" (not the value of LANG), so that locale must actually exist or
# both print
#   WARNING: setlocale('en_US.UTF-8') failed, using locale: 'C'.
# and non-ASCII characters (Cyrillic hostnames, nicknames) break. C.UTF-8 is
# built into glibc but does NOT satisfy that lookup - it was tried and reverted.
# Hence the 'locales' package and the locale-gen step below.
ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8 \
    TZ=Etc/UTC \
    STEAM_USER=steam \
    STEAM_UID=1000 \
    STEAM_GID=1000 \
    STEAM_HOME=/home/steam \
    STEAMCMD_DIR=/home/steam/steamcmd \
    HL2DM_INSTALL_DIR=/home/steam/hl2dm_server \
    HL2DM_DEFAULT_DIR=/opt/hl2dm-defaults \
    SRCDS_APP_ID=232370

# ------------------------------------------------------- system (i386) files
# srcds_linux is a 32-bit binary (verified: it links only libc, libdl and
# libpthread for i386); the engine/server .so modules pull in the 32-bit C++
# runtime, libgcc and zlib. wget, iproute2 and the i386 ncurses/tinfo pair that
# earlier builds carried are not used by the server or the entrypoint and are
# gone. lib32gcc-s1 / lib32stdc++6 are not installed: they are aliases of the
# :i386 packages that are already listed below.
#
# 'apt-get upgrade' is NOT skipped here: an image upgrade brings the whole base
# (including security point-releases of glibc etc.) to the current level of
# trixie, which is exactly what a fresh `FROM debian:trixie-slim` pin would not.
ARG DEBIAN_FRONTEND=noninteractive
RUN set -eux; \
    dpkg --add-architecture i386; \
    apt-get update; \
    apt-get upgrade -y; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        tzdata \
        locales \
        libc6:i386 \
        libstdc++6:i386 \
        libgcc-s1:i386 \
        zlib1g:i386; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/*

# ----------------------------------------------------------------- locale
# Required by the engine/SteamCMD as explained above.
RUN set -eux; \
    sed -i 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen; \
    locale-gen en_US.UTF-8; \
    update-locale LANG=en_US.UTF-8

# ---------------------------------------------------------------- steam user
RUN set -eux; \
    groupadd -g "${STEAM_GID}" "${STEAM_USER}"; \
    useradd --uid "${STEAM_UID}" --gid "${STEAM_GID}" \
            --create-home --home-dir "${STEAM_HOME}" \
            --shell /bin/bash "${STEAM_USER}"; \
    mkdir -p "${STEAMCMD_DIR}" \
             "${STEAM_HOME}/.steam/sdk32" \
             "${STEAM_HOME}/.steam/steam/userdata/0/config" \
             "${HL2DM_INSTALL_DIR}" \
             "${HL2DM_DEFAULT_DIR}"; \
    chown -R "${STEAM_USER}:${STEAM_USER}" "${STEAM_HOME}"

# ------------------------------------------------------- default configs (ro)
# Deployed into the game directory by run.sh on every start, with SRCDS_* env
# vars applied on top. Copied as root and made read-only for everyone: the
# running server must not be able to rewrite its own defaults, and a compromise
# of the game process must not be able to persist there.
COPY cfg/ ${HL2DM_DEFAULT_DIR}/
RUN set -eux; \
    chown -R root:root "${HL2DM_DEFAULT_DIR}"; \
    find "${HL2DM_DEFAULT_DIR}" -type d -exec chmod 0755 {} +; \
    find "${HL2DM_DEFAULT_DIR}" -type f -exec chmod 0444 {} +

# ----------------------------------------------- entrypoint + health probe (ro)
COPY run.sh healthcheck.sh ${STEAM_HOME}/
RUN set -eux; \
    chown root:root "${STEAM_HOME}/run.sh" "${STEAM_HOME}/healthcheck.sh"; \
    chmod 0755 "${STEAM_HOME}/run.sh" "${STEAM_HOME}/healthcheck.sh"

USER ${STEAM_USER}
WORKDIR ${STEAM_HOME}

# ------------------------------------------------------------- install steamcmd
# Download to a file before extracting and use -f/--retry so a CDN error page or
# a flaky mirror fails loudly instead of feeding garbage to tar.
#
# After extracting the bootstrap tarball the self-update is run here, at build
# time, so the updated SteamCMD (~200 MB on disk) becomes part of the image
# instead of being re-fetched by every fresh container. At start time phase 1
# still runs (a manifest/version check in seconds) - this preserves the
# documented "SteamCMD 1/2" phase and the warm-appcache behaviour, while the
# multi-minute ~41 MB download that used to hit every new container is gone.
# If the CDN is unreachable during the build the step simply uses the
# bootstrapped binary - run.sh still re-checks at every start.
RUN set -eux; \
    tmp="$(mktemp -d)"; \
    curl -fsSL --retry 5 --retry-delay 2 \
         -o "${tmp}/steamcmd_linux.tar.gz" \
         "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz"; \
    tar -xzf "${tmp}/steamcmd_linux.tar.gz" -C "${STEAMCMD_DIR}"; \
    rm -rf "${tmp}"; \
    ln -sf "${STEAMCMD_DIR}/linux32/steamclient.so" \
           "${STEAM_HOME}/.steam/sdk32/steamclient.so"; \
    chmod +x "${STEAMCMD_DIR}/steamcmd.sh"; \
    "${STEAMCMD_DIR}/steamcmd.sh" +login anonymous +quit \
        || echo "warning: steamcmd self-update at build time failed; runtime will retry"

EXPOSE 27015/udp 27015/tcp 27005/udp

# The Source engine ignores SIGTERM and its own SIGINT handler does not actually
# terminate it (both were tested). The entrypoint therefore keeps PID 1 and
# translates the signal into the console command 'quit' on a FIFO, which the
# engine does honour - see run.sh. SIGINT is still what Docker is asked to send,
# matching the documented behaviour of srcds_run.
STOPSIGNAL SIGINT

# healthcheck.sh is only healthy once srcds_linux is running AND the game UDP
# port is actually bound - a hung process that still exists is not healthy. The
# start-period covers the first-run download (which has been observed to take
# more than 5 minutes on slow Steam CDNs, hence 900s) so the container is not
# reported unhealthy while it is legitimately installing content.
HEALTHCHECK --interval=30s --timeout=5s --start-period=900s --retries=3 \
    CMD ["/home/steam/healthcheck.sh"]

ENTRYPOINT ["/home/steam/run.sh"]
