# Half-Life 2 Deathmatch Server (v1-latest)

**HL2DM dedicated server** (Valve App ID `232370`) on **Debian 13 (trixie-slim)**. Pull and
play — no SteamCMD setup, no 32-bit library hunting, no multi-gigabyte image download.

Rebuilt and hardened as `svk2907/hl2dm-server-2026-10-v1:latest`. Launch principles, layout,
config handling, the volume contract and the `SRCDS_*` interface are **unchanged** from
`2026-10-v1:old`; `server.cfg`, `mapcycle.txt` and `motd.txt` are byte-identical to the old
image.

## Highlights

- **Fast first start into a new container** — the SteamCMD self-update is baked into the image
  at build time. Phase 1 is a version check (seconds), not the old ~41 MB per-container
  download that could take up to several minutes
- **Updated base** — `apt-get upgrade` runs at build time, so all packages (including i386
  multiarch libs) are at the current trixie level, not pinned to whatever the base tag held
- **Slash-redundant 32-bit libs removed** — `lib32gcc-s1`/`lib32stdc++6` were aliases of the
  `:i386` packages already installed; only the i386 variants are now installed
- **Clean `docker stop` during a content download** — the signal trap is installed before the
  SteamCMD phases; stopping while steamcmd fetches content terminates steamcmd cleanly instead
  of killing PID 1 outright (verified: exit 130, ~3 s, interrupted download resumes fine)
- **Graceful shutdown when serving** — `docker stop` → SIGINT → console `quit` → exit 0 in
  ~2 s (no SIGKILL, no exit 137)
- **Health check** — healthy only when `srcds_linux` runs and the game UDP port is bound; start
  period raised to 900 s to cover first-run downloads on slow Steam CDNs
- **Fully self-contained** — `server.cfg`, `mapcycle.txt`, `motd.txt` ship in the image and are
  deployed on every start. No config files to mount
- **8 maps ready** — 7 official DM maps plus custom `halls3`, full rotation configured
- **Non-root** — runs as user `steam` (UID 1000)
- **Self-healing** — SteamCMD retries on failure and checks the manifest at every start
- **No special Docker flags** — works with the default seccomp profile

## Quick start

```bash
docker volume create hl2dm_data

docker run -d \
  --name hl2dm-server \
  --restart unless-stopped \
  -p 27015:27015/udp \
  -p 27015:27015/tcp \
  -p 27005:27005/udp \
  -v hl2dm_data:/home/steam/hl2dm_server \
  svk2907/hl2dm-server-2026-10-v1:latest
```

Connect your HL2DM client to the server IP on port **27015**.

> **The volume is not optional.** Without a mount at `/home/steam/hl2dm_server` the ~895 MB of
> game content lands in the container's writable layer and is re-downloaded from scratch every
> time the container is recreated.

## First start

Startup has two labelled phases, easy to tell apart in the log. Phase 1 is now a fast version
check thanks to the build-time bake:

| Phase | What happens | Size | Frequency |
|---|---|---|---|
| `SteamCMD 1/2: self-update` | version check (baked into image at build) | nothing, usually | every container start |
| `SteamCMD 2/2: game content` | the HL2DM game content | ~895 MB | first install only |

```
[entrypoint] no game content found - phase 2 downloads ~895 MB, be patient
[entrypoint] SteamCMD 1/2: self-update check (baked into image at build time)
[entrypoint] SteamCMD 2/2: game content - update check (SRCDS_VALIDATE=0, manifest only)
[entrypoint] game content: 15s elapsed, game content 193 MB on disk
[entrypoint] game content: 45s elapsed, game content 768 MB on disk
[entrypoint] content ready: 895 MB at /home/steam/hl2dm_server
```

A warm start (content on the volume) reaches `content ready` in well under a minute and
`healthy` shortly after. With `SRCDS_APP_UPDATE=0` and content already on the volume the server
is up in a few seconds and does not touch the network at all.

## Ports

| Port | Protocol | Purpose |
|---|---|---|
| 27015 | UDP/TCP | Game traffic |
| 27005 | UDP | Client (voice) |

Only `27015/udp` is required; `27015/tcp` and `27005/udp` are optional but recommended.

## Default settings

| Setting | Value |
|---|---|
| Hostname | `HL2DM Server -- Happy gaming` |
| Gamemode | Deathmatch, free-for-all (`mp_teamplay 0`) |
| Map / rotation | `dm_lockdown`, `dm_overwatch`, `dm_powerhouse`, `dm_resistance`, `dm_runoff`, `dm_steamlab`, `dm_underpass`, `halls3` |
| Starting map | `dm_overwatch` |
| Max players | 12 |
| Frag limit / time limit | 50 / 20 min |
| Region | Europe (`sv_region 3`) |
| RCON | Disabled (no password set) |

## Customising

| Variable | Default | Notes |
|---|---|---|
| `SRCDS_HOSTNAME` | `HL2DM Server -- Happy gaming` | non-ASCII supported |
| `SRCDS_MAXPLAYERS` | `12` | |
| `SRCDS_MAP` | `dm_overwatch` | starting map |
| `SRCDS_MAPCYCLE` | 8 maps above | `\|` separated; regenerates `cfg/mapcycle.txt` |
| `SRCDS_TICKRATE` | `66` | |
| `SRCDS_REGION` | `3` | `255` = world |
| `SRCDS_PASSWORD` | — | server password |
| `SRCDS_RCON_PASSWORD` | — | needed for remote admin |
| `SRCDS_PORT` | `27015` | |
| `SRCDS_CLIENT_PORT` | `27005` | |
| `SRCDS_IP` | `0.0.0.0` | bind address |
| `SRCDS_EXTRA_CVARS` | — | any convars, newline separated |
| `SRCDS_EXTRA_ARGS` | — | extra `srcds_run` arguments |
| `SRCDS_VALIDATE` | `0` | `1` = full re-hash of all content on start |
| `SRCDS_APP_UPDATE` | `1` | `0` = skip Steam entirely, start in seconds |
| `SRCDS_STOP_TIMEOUT` | `8` | seconds to wait for the console `quit` |

## Image details

| | |
|---|---|
| Base image | `debian:trixie-slim` (Debian 13), all packages upgraded at build |
| Architecture | `linux/amd64` |
| SteamCMD | updated (self-update baked into the image, not re-downloaded per container) |
| Game content | ~895 MB, downloaded at runtime |
| Steam App ID | `232370` |
| Runs as | `steam` (UID 1000, non-root) |
| Data directory | `/home/steam/hl2dm_server` |
| Entrypoint | `/home/steam/run.sh` |
| Stop signal | `SIGINT` → console `quit` → exit 0 |
| Health check | `srcds_linux` running **and** UDP port bound, every 30 s, 900 s start period |

## What changed in v1-latest

| | `2026-10-v1` (`:old`) | `2026-10-v1:latest` |
|---|---|---|
| SteamCMD update | re-downloaded ~41 MB by every new container (up to minutes) | baked into the image at build time; phase 1 = fast version check |
| Base packages | pinned to whatever `trixie-slim` held at build | `apt-get upgrade` runs at build, all packages current |
| 32-bit libs | `libc6:i386` + `libstdc++6:i386` + `zlib1g:i386` + `lib32gcc-s1` + `lib32stdc++6` | i386 variants only (`libgcc-s1:i386` instead of the `lib32-*` aliases) |
| `docker stop` during install | killed PID 1 outright (raw SIGINT) | terminates steamcmd cleanly, exit 130, download resumes on restart |
| Healthcheck start period | 300 s | 900 s |
| OCI labels | no source/url | `source`, `url`, `documentation` pointers added |

## Notes

- Requires an `amd64` (x86-64) host — the 32-bit Source engine binary is not available for arm64.
- Allow ~1.5 GB free disk for the image plus the game content volume.
- Shutdown is graceful by design: `STOPSIGNAL SIGINT`, so a plain `docker stop` is enough.
  `SRCDS_STOP_TIMEOUT` (default 8 s) is the knob that matters; after it the process is killed as
  a last resort.
- The image contains no plugin framework. MetaMod / SourceMod can be unpacked into
  `/home/steam/hl2dm_server/hl2mp/addons` on the volume.
- `cfg/mapcycle.txt` is regenerated from the image default on every start; to add a map copy the
  `.bsp` into `hl2mp/maps/` and list it in `SRCDS_MAPCYCLE`.
- The console prints `Unknown command` four times for legacy convars (`sv_maxunlag`,
  `sv_unlag`, `sv_instancebaselines`, `sv_hltv`) inherited from Valve's stock `server.cfg` —
  harmless.
- At shutdown the engine's crash reporter may print
  `error: libcurl.so: cannot open shared object file` — the 32-bit `libcurl` is not installed
  (same as the old image), dumps are still written locally under `/tmp/dumps`. Cosmetic, not a
  regression.

- Half-Life 2 and HL2DM are trademarks of Valve Corporation. This project is not affiliated
  with or endorsed by Valve. Game content is downloaded anonymously via SteamCMD at runtime and
  requires no host game licence.
