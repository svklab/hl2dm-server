# syntax=docker/dockerfile:1
#
# HL2DM (Half-Life 2: Deathmatch) dedicated server - Debian 13 trixie
#
# Image: svk2907/hl2dm-server-2026-v1.0:latest
# Source: https://github.com/svklab/hl2dm-server
#
# Layout, launch principles and the SRCDS_* interface are UNCHANGED from
# 2026-10-v1: non-root user steam (UID/GID 1000), game content fetched by
# SteamCMD into the mounted volume, configs deployed from /opt/hl2dm-defaults,
# entrypoint /home/steam/run.sh, STOPSIGNAL SIGINT -> console quit.
#
# What is different in v1.0:
#   - two-stage build: SteamCMD is prepared in a builder stage, so the runtime
#     image does not contain curl or the build-only tooling;
#   - the 32-bit libcurl runtime is installed, which removes the
#     "libcurl.so: cannot open shared object file" message from the crash
#     reporter and makes replay_srv.so loadable;
#   - the health probe understands IPv4 and IPv6 sockets, matches only the
#     local address, and rejects zombie servers;
#   - run.sh validates ports/numbers and the volume before touching SteamCMD,
#     escapes quoted cvar values, and terminates the whole SteamCMD process
#     tree on a stop during installation;
#   - packages are fully upgraded at build time and the OCI labels carry
#     version, revision, creation time, source and documentation pointers.
#
# The base image is deliberately not pinned so a rebuild picks up Debian
# security updates. For a reproducible build, pass a digest:
#     docker build --build-arg BASE_IMAGE=debian:trixie-slim@sha256:... .
#
# Game content is NOT baked in. SteamCMD fetches app 232370 on first start
# into $HL2DM_INSTALL_DIR, which is expected to be a volume.

ARG BASE_IMAGE=debian:trixie-slim

# =============================================================================
# Stage 1 - SteamCMD
#
# SteamCMD is bootstrapped and self-updated here. The full self-update is
# ~200 MB and would otherwise be re-downloaded by every new container; baking
# it into the image keeps phase 1/2 at startup a fast version check. Only the
# resulting /home/steam/steamcmd and /home/steam/.steam trees are copied into
# the final image; curl, the i386 toolchain and the apt lists stay behind.
# =============================================================================
FROM ${BASE_IMAGE} AS steamcmd

ARG DEBIAN_FRONTEND=noninteractive
ENV HOME=/home/steam \
    STEAMCMD_DIR=/home/steam/steamcmd

# The 32-bit SteamCMD binary is what steamcmd.sh selects on x86-64, so the
# i386 runtime libraries are needed in the builder as well as in the runtime.
# The locale is generated here too: SteamCMD calls setlocale("en_US.UTF-8")
# with that literal string and would otherwise print a warning. The apt and
# locale-gen commands run under LANG=C so they do not warn about the locale
# before it exists; only SteamCMD itself gets en_US.UTF-8.
RUN set -eux; \
    export LANG=C LC_ALL=C; \
    dpkg --add-architecture i386; \
    apt-get -o Acquire::Retries=3 update; \
    apt-get -y install --no-install-recommends \
        ca-certificates \
        curl \
        locales \
        libc6:i386 \
        libstdc++6:i386 \
        libgcc-s1:i386 \
        zlib1g:i386; \
    sed -i 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen; \
    locale-gen en_US.UTF-8; \
    mkdir -p "${STEAMCMD_DIR}" "${HOME}/.steam/sdk32"; \
    tmp="$(mktemp -d)"; \
    curl -fsSL --retry 5 --retry-delay 2 \
         -o "${tmp}/steamcmd_linux.tar.gz" \
         "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz"; \
    tar -xzf "${tmp}/steamcmd_linux.tar.gz" -C "${STEAMCMD_DIR}"; \
    rm -rf "${tmp}"; \
    chmod +x "${STEAMCMD_DIR}/steamcmd.sh"; \
    LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
        "${STEAMCMD_DIR}/steamcmd.sh" +login anonymous +quit \
        || echo "warning: steamcmd self-update at build time failed; runtime will retry"; \
    ln -sfn "${STEAMCMD_DIR}/linux32/steamclient.so" "${HOME}/.steam/sdk32/steamclient.so"; \
    rm -rf "${HOME}/.steam/steam/logs" "${STEAMCMD_DIR}/linux32/logs"; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# =============================================================================
# Stage 2 - runtime image
# =============================================================================
FROM ${BASE_IMAGE}

ARG BASE_IMAGE
ARG VERSION=2026-v1.0
ARG REVISION=unknown
ARG CREATED=1970-01-01T00:00:00Z

LABEL org.opencontainers.image.title="HL2DM dedicated server 2026-v1.0" \
      org.opencontainers.image.description="Half-Life 2 Deathmatch dedicated server (SRCDS) on Debian 13 trixie-slim; SteamCMD preloaded, game content fetched at runtime" \
      org.opencontainers.image.base.name="${BASE_IMAGE}" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.created="${CREATED}" \
      org.opencontainers.image.licenses="Valve EULA" \
      org.opencontainers.image.source="https://github.com/svklab/hl2dm-server" \
      org.opencontainers.image.url="https://hub.docker.com/r/svk2907/hl2dm-server-2026-v1.0" \
      org.opencontainers.image.documentation="https://github.com/svklab/hl2dm-server" \
      org.opencontainers.image.authors="svklab" \
      org.opencontainers.image.vendor="svklab"

# The engine and SteamCMD call setlocale() with the literal string
# "en_US.UTF-8" (not the value of LANG), so that locale must actually exist or
# both print
#   WARNING: setlocale('en_US.UTF-8') failed, using locale: 'C'.
# and non-ASCII characters (Cyrillic hostnames, nicknames) break. C.UTF-8 is
# built into glibc but does NOT satisfy that lookup, hence the 'locales'
# package and the locale-gen step below.
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

# Runtime libraries for the 32-bit Source engine:
#   libc6:i386, libstdc++6:i386, libgcc-s1:i386, zlib1g:i386
# The libcurl packages are not required to start srcds_linux, but the engine's
# crash reporter and replay_srv.so link against them; without them the console
# prints "libcurl.so: cannot open shared object file" at shutdown.
#
# The engine also asks for libtinfo.so.5 / libncurses.so.5. Debian trixie only
# ships the ncurses 6 ABI; the compatibility symlinks below keep the loader
# warning out of the console. The server itself links no ncurses symbols.
#
# The base is fully upgraded here so the image contains the current trixie
# packages, not whatever the base tag happened to hold at build time.
ARG DEBIAN_FRONTEND=noninteractive
RUN set -eux; \
    export LANG=C LC_ALL=C; \
    dpkg --add-architecture i386; \
    apt-get -o Acquire::Retries=3 update; \
    apt-get -y upgrade; \
    apt-get -y install --no-install-recommends \
        ca-certificates \
        tzdata \
        locales \
        libc6:i386 \
        libstdc++6:i386 \
        libgcc-s1:i386 \
        zlib1g:i386 \
        libcurl4t64:i386 \
        libcurl3t64-gnutls:i386 \
        libtinfo6:i386 \
        libncurses6:i386; \
    ln -sfn libtinfo.so.6 /usr/lib/i386-linux-gnu/libtinfo.so.5; \
    ln -sfn libncurses.so.6 /usr/lib/i386-linux-gnu/libncurses.so.5; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# ----------------------------------------------------------------- locale
RUN set -eux; \
    export LANG=C LC_ALL=C; \
    sed -i 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen; \
    locale-gen en_US.UTF-8; \
    update-locale LANG=en_US.UTF-8

# ---------------------------------------------------------------- steam user
RUN set -eux; \
    groupadd -g "${STEAM_GID}" "${STEAM_USER}"; \
    useradd --uid "${STEAM_UID}" --gid "${STEAM_GID}" \
            --create-home --home-dir "${STEAM_HOME}" \
            --shell /bin/bash "${STEAM_USER}"; \
    mkdir -p "${STEAM_HOME}/.steam/sdk32" \
             "${STEAM_HOME}/.steam/steam/userdata/0/config" \
             "${HL2DM_INSTALL_DIR}" \
             "${HL2DM_DEFAULT_DIR}"; \
    chown -R "${STEAM_USER}:${STEAM_USER}" "${STEAM_HOME}"

# ------------------------------------------------------- default configs (ro)
# Deployed into the game directory by run.sh on every start, with SRCDS_* env
# vars applied on top. Copied as root and made read-only for everyone: the
# running server must not be able to rewrite its own defaults, and a compromise
# of the game process must not be able to persist there.
#
# server.cfg, mapcycle.txt and motd.txt are UNCHANGED from 2026-10-v1.
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

# ------------------------------------------------------- preloaded SteamCMD
# Copied from the builder stage with the runtime UID/GID. The SteamCMD tree is
# writable by steam because steamcmd self-updates on every start.
COPY --from=steamcmd --chown=steam:steam /home/steam/steamcmd/ ${STEAMCMD_DIR}/
COPY --from=steamcmd --chown=steam:steam /home/steam/.steam/ ${STEAM_HOME}/.steam/
RUN set -eux; \
    mkdir -p "${STEAM_HOME}/.steam/sdk32"; \
    ln -sfn "${STEAMCMD_DIR}/linux32/steamclient.so" \
            "${STEAM_HOME}/.steam/sdk32/steamclient.so"; \
    chown -h "${STEAM_USER}:${STEAM_USER}" "${STEAM_HOME}/.steam/sdk32/steamclient.so"

USER ${STEAM_USER}
WORKDIR ${STEAM_HOME}

EXPOSE 27015/udp 27015/tcp 27005/udp

# The Source engine ignores SIGTERM and its own SIGINT handler does not actually
# terminate it. The entrypoint keeps PID 1 and translates the signal into the
# console command 'quit' on a FIFO, which the engine does honour - see run.sh.
STOPSIGNAL SIGINT

# A first install downloads ~895 MB. 30 minutes covers ~0.5 MB/s; a slower CDN
# can be accommodated with `docker run --health-start-period=...` or the
# compose healthcheck override. The probe is only healthy once srcds_linux is
# running AND the game UDP port is bound.
HEALTHCHECK --interval=30s --timeout=5s --start-period=1800s --retries=3 \
    CMD ["/home/steam/healthcheck.sh"]

ENTRYPOINT ["/home/steam/run.sh"]
