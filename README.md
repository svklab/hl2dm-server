# Half-Life 2 Deathmatch Server (2026-v1.0)

**HL2DM dedicated server** (Valve App ID `232370`) on **Debian 13 (trixie-slim)**.
Pull and play — no SteamCMD setup, no 32-bit library hunting, no multi-gigabyte
image download.

This is the `svk2907/hl2dm-server-2026-v1.0:latest` image. The launch principles,
layout, config handling, volume contract and the `SRCDS_*` interface are
**unchanged** from `2026-10-v1`; `server.cfg`, `mapcycle.txt` and `motd.txt` are
byte-identical to the previous image.

## Highlights

- **Fast container start** — the full SteamCMD self-update (~200 MB) is baked
  into the image at build time. Phase 1 is a version check (seconds), not a
  per-container download.
- **Updated base** — `apt-get upgrade` runs at build time, so the base packages
  (including the i386 multiarch libraries) are at the current trixie level.
- **No missing 32-bit libcurl** — `libcurl4t64:i386` and
  `libcurl3t64-gnutls:i386` are installed, so the crash reporter no longer prints
  `libcurl.so: cannot open shared object file` and `replay_srv.so` can load.
- **No ncurses loader warning** — `libtinfo6:i386` / `libncurses6:i386` plus
  `.so.5` compatibility symlinks satisfy the engine's older ncurses lookup.
- **Two-stage build** — SteamCMD is prepared in a builder stage. `curl` and the
  build-only tooling are not present in the runtime image.
- **Better health probe** — checks `srcds_linux` (and rejects zombies) plus the
  bound game UDP port on **IPv4 and IPv6**, matching only the local address.
- **Clean `docker stop` during a content download** — the signal trap is
  installed before the SteamCMD phases and terminates the whole SteamCMD process
  tree, not just the shell wrapper.
- **Graceful shutdown when serving** — `docker stop` → SIGINT → console `quit` →
  exit 0 in a few seconds (no SIGKILL, no exit 137).
- **Fail-fast validation** — ports, tickrate, player count and the `SRCDS_*`
  switches are validated before SteamCMD is contacted; a non-writable volume gets
  an actionable message instead of a confusing permission error.
- **Fully self-contained** — `server.cfg`, `mapcycle.txt` and `motd.txt` ship in
  the image and are deployed on every start. No config files to mount.
- **Non-root** — runs as user `steam` (UID/GID 1000).
- **8-map rotation configured** — 7 official DM maps plus custom `halls3`.
  The `halls3` `.bsp` is a custom map and is **not** shipped by SteamCMD; put it
  in `hl2mp/maps/` on the volume (the entrypoint warns if it is missing).
- **Reliable `SRCDS_MAPCYCLE`** — the generated mapcycle is written atomically,
  so a second start no longer fails on the read-only deployed `mapcycle.txt`.

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
  svk2907/hl2dm-server-2026-v1.0:latest
```

Or with Compose:

```bash
docker compose up -d
```

Connect your HL2DM client to the server IP on port **27015**.

> **The volume is not optional.** Without a mount at
> `/home/steam/hl2dm_server` the ~895 MB of game content lands in the
> container's writable layer and is re-downloaded from scratch every time the
> container is recreated.

## First start

Startup has two labelled phases:

| Phase | What happens | Size | Frequency |
|---|---|---|---|
| `SteamCMD 1/2: self-update` | version check (preloaded at build) | usually nothing | every container start |
| `SteamCMD 2/2: game content` | the HL2DM game content | ~895 MB | first install only |

```
[entrypoint] no game content found - phase 2 downloads ~895 MB, be patient
[entrypoint] SteamCMD 1/2: self-update check (baked into image at build time)
[entrypoint] SteamCMD 2/2: game content - update check (SRCDS_VALIDATE=0, manifest only)
[entrypoint] game content: 15s elapsed, game content 193 MB on disk
[entrypoint] game content: 45s elapsed, game content 768 MB on disk
[entrypoint] content ready: 895 MB at /home/steam/hl2dm_server
```

A warm start (content already on the volume) reaches `content ready` in well
under a minute and `healthy` shortly after. With `SRCDS_APP_UPDATE=0` and
content already on the volume the server is up in a few seconds and does not
touch the network at all.

## Ports

| Port | Protocol | Purpose |
|---|---|---|
| 27015 | UDP/TCP | Game traffic |
| 27005 | UDP | Client (voice) |

Only `27015/udp` is required; `27015/tcp` and `27005/udp` are optional but
recommended.

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
| `SRCDS_HOSTNAME` | `HL2DM Server -- Happy gaming` | non-ASCII and quotes are supported |
| `SRCDS_MAXPLAYERS` | `12` | validated 1–64 |
| `SRCDS_MAP` | `dm_overwatch` | starting map |
| `SRCDS_MAPCYCLE` | 8 maps above | `\|` separated; regenerates `cfg/mapcycle.txt` |
| `SRCDS_TICKRATE` | `66` | validated 10–1000 |
| `SRCDS_REGION` | `3` | `255` = world |
| `SRCDS_PASSWORD` | — | server password (quoted and escaped) |
| `SRCDS_RCON_PASSWORD` | — | needed for remote admin (quoted and escaped) |
| `SRCDS_PORT` | `27015` | game port |
| `SRCDS_CLIENT_PORT` | `27005` | client port |
| `SRCDS_IP` | `0.0.0.0` | bind address |
| `SRCDS_EXTRA_CVARS` | — | any convars, newline separated |
| `SRCDS_EXTRA_ARGS` | — | extra `srcds_run` arguments (word-split) |
| `SRCDS_VALIDATE` | `0` | `1` = full re-hash of all content on start |
| `SRCDS_APP_UPDATE` | `1` | `0` = skip Steam entirely, start in seconds |
| `SRCDS_STOP_TIMEOUT` | `8` | seconds to wait for the console `quit` |

## Health check and shutdown

The image includes a `HEALTHCHECK` that is healthy only when `srcds_linux` is
running and the game UDP port is bound:

```bash
docker inspect --format '{{.State.Health.Status}}' hl2dm-server
```

The start period is **1800 s** because a first install downloads ~895 MB. If your
Steam CDN is slower, override it:

```bash
docker run --health-start-period=3600s ...
```

or in Compose:

```yaml
healthcheck:
  start_period: 3600s
```

`STOPSIGNAL` is `SIGINT`. The entrypoint translates the stop signal into the
console command `quit` on a pseudo-terminal; after `SRCDS_STOP_TIMEOUT` seconds
the process tree is terminated. Compose uses `stop_grace_period: 15s`.

## Volumes and permissions

The named volume is created with the ownership of the image directory, so the
default `steam` user (UID/GID 1000) can write to it. If you use a bind mount
instead, make the host directory writable by UID/GID 1000:

```bash
mkdir -p /srv/hl2dm
sudo chown -R 1000:1000 /srv/hl2dm

docker run -d \
  --name hl2dm-server \
  --restart unless-stopped \
  -p 27015:27015/udp -p 27015:27015/tcp -p 27005:27005/udp \
  -v /srv/hl2dm:/home/steam/hl2dm_server \
  svk2907/hl2dm-server-2026-v1.0:latest
```

The entrypoint checks this up front and prints the exact `chown` UID/GID if the
directory is not writable.

## Security

- Runs as the non-root `steam` user (UID/GID 1000).
- The default configs are root-owned and read-only (`0444`) in
  `/opt/hl2dm-defaults`; the game process cannot modify its own defaults.
- The runtime image does not contain `curl` (it is only used in the builder
  stage) or a compiler toolchain.
- `docker-compose.yml` sets `no-new-privileges:true`. You can additionally drop
  capabilities; the server needs none for port 27015:
  `--cap-drop=ALL`.
- No secrets are baked into the image.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `permission denied` on the volume | Bind mount not writable by UID/GID 1000; `chown -R 1000:1000` the host directory. |
| `no game content found` and a long download | First install; ~895 MB. Watch `docker logs -f hl2dm-server`. |
| Container `unhealthy` for a long time | First install still running, or the CDN is very slow; raise `--health-start-period`. |
| `unknown command "sv_maxunlag"` etc. | Four legacy convars inherited from Valve's stock `server.cfg`; harmless. |
| `Couldn't exec banned_user.cfg` | `run.sh` creates empty ban files on every start; if you see this, the volume is read-only. |
| `libcurl.so: cannot open shared object file` | Fixed in this image; you are probably running `2026-10-v1`. |
| `WARNING: Failed to load 32-bit libtinfo.so.5 or libncurses.so.5` | Fixed in this image with ncurses 6 compatibility symlinks; you are probably running `2026-10-v1`. |
| `Error loading cfg/vscript_convar_allowlist.txt` | The game content does not ship that file; VScript still starts and maps load normally. |
| `map <name>.bsp not found` | The map is not in the volume or a VPK. Add the `.bsp` to `hl2mp/maps` or remove it from `SRCDS_MAPCYCLE`. |
| `cannot create .../mapcycle.txt: Permission denied` | Fixed in this image (atomic mapcycle replace); you are probably running `2026-10-v1`. |
| `srcds_linux is not running` | Check the log above; a bad `SRCDS_MAP` or a crash can stop the server. |
| `setlocale('en_US.UTF-8') failed` | Not expected: `en_US.UTF-8` is generated in the image. |
| `assert_*.dmp` / `Trying to close low level socket support` at shutdown | Source engine shutdown noise; the server still exits 0 and the dumps are written to `/tmp/dumps`. |
| Server exits 130 during install | Expected after `docker stop` while SteamCMD is downloading. Restart resumes. |

## Build from source

```bash
docker build --pull --platform linux/amd64 \
  --build-arg VERSION=2026-v1.0 \
  --build-arg REVISION="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" \
  --build-arg CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  -t svk2907/hl2dm-server-2026-v1.0:latest .
```

Or:

```bash
make build
make test
```

The base image is deliberately unpinned so a rebuild picks up Debian security
updates. For a reproducible build, pass a digest:

```bash
docker build --build-arg BASE_IMAGE=debian:trixie-slim@sha256:... .
```

`steamcmd.sh` is 32-bit on x86-64, hence the i386 multiarch libraries in both
build stages. At runtime the game modules need the i386 C++ runtime, libgcc,
zlib and libcurl.

## Image details

| | |
|---|---|
| Image | `svk2907/hl2dm-server-2026-v1.0:latest` |
| Image size | ~528 MB on disk / ~160 MB compressed (SteamCMD preloaded) |
| Base | `debian:trixie-slim` (Debian 13), packages upgraded at build |
| Architecture | `linux/amd64` |
| Build | two-stage: SteamCMD builder + runtime |
| SteamCMD | preloaded and self-updated at build |
| Game content | ~895 MB, downloaded at runtime into the volume |
| Steam App ID | `232370` |
| Runs as | `steam` (UID/GID 1000, non-root) |
| Data directory | `/home/steam/hl2dm_server` |
| Defaults | `/opt/hl2dm-defaults` (read-only) |
| Entrypoint | `/home/steam/run.sh` |
| Stop signal | `SIGINT` → console `quit` → exit 0 |
| Health check | `srcds_linux` + bound UDP port, IPv4/IPv6, 30 s interval, 1800 s start period |
| Extra 32-bit libs | `libcurl4t64:i386`, `libcurl3t64-gnutls:i386`, `libtinfo6:i386`, `libncurses6:i386` |

## What changed in 2026-v1.0

| | `2026-10-v1:latest` | `2026-v1.0` |
|---|---|---|
| Image name | `hl2dm-server-2026-10-v1` | `hl2dm-server-2026-v1.0` |
| Build | single stage, `curl` in runtime | two stages, no `curl`/build tools in runtime |
| Base packages | `apt-get upgrade` at build | `apt-get upgrade` at build from the current base (`--pull` / `pull: true`) |
| 32-bit libcurl | missing (crash-reporter warning, `replay_srv.so` incomplete) | `libcurl4t64:i386` + `libcurl3t64-gnutls:i386` |
| ncurses/tinfo | not installed (`Failed to load ... libtinfo.so.5` warning) | `libtinfo6`/`libncurses6` + `.so.5` compatibility symlinks |
| Healthcheck | IPv4 only, matches local or remote port, no zombie check, 900 s | IPv4+IPv6, local address only, zombie check, 1800 s |
| `run.sh` validation | none | ports/tickrate/players/region/flags validated |
| Volume check | no | clear fail-fast message with UID/GID |
| Cvar quoting | raw double quotes | escaped quotes/backslashes |
| Stop during install | kills the steamcmd PID | kills the whole SteamCMD tree |
| Map check | none | warns for the starting map and for any map in `cfg/mapcycle.txt` that is missing |
| `SRCDS_MAPCYCLE` | wrote into the deployed 0444 `mapcycle.txt`; a second start failed with `Permission denied` | written atomically through a temp file; works on every start |
| OCI labels | source/url/documentation | + version, revision, created, authors, vendor, base name |
| Documentation | v1-latest, stale size claims | v1.0, measured sizes and troubleshooting |

`server.cfg`, `mapcycle.txt` and `motd.txt` are unchanged. The launch command,
volume contract, port layout, `SRCDS_*` variables and graceful-stop behaviour are
unchanged.

## Upgrading from 2026-10-v1

The game content volume is compatible; both images use Steam App ID `232370` and
the same `/home/steam/hl2dm_server` path.

```bash
docker stop hl2dm-server
docker rm hl2dm-server
docker pull svk2907/hl2dm-server-2026-v1.0:latest

docker run -d \
  --name hl2dm-server \
  --restart unless-stopped \
  -p 27015:27015/udp -p 27015:27015/tcp -p 27005:27005/udp \
  -v hl2dm_data:/home/steam/hl2dm_server \
  svk2907/hl2dm-server-2026-v1.0:latest
```

The entrypoint redeploys `server.cfg`, `mapcycle.txt` and `motd.txt` from the
image on every start (same content as before), so no manual config migration is
needed. The old `svk2907/hl2dm-server-2026-10-v1:latest` image remains
available.

## Notes

- Requires an `amd64` (x86-64) host — the 32-bit Source engine binary is not
  available for arm64.
- Allow ~1.5 GB free disk for the image plus the game content volume. The image
  is large mainly because the ~200 MB SteamCMD self-update is preloaded; the
  game content is on the volume.
- The image contains no plugin framework. MetaMod / SourceMod can be unpacked
  into `/home/steam/hl2dm_server/hl2mp/addons` on the volume.
- `cfg/mapcycle.txt` is regenerated from the image default on every start; to
  add a map copy the `.bsp` into `hl2mp/maps/` and list it in `SRCDS_MAPCYCLE`.
- `motd.txt` contains third-party widgets (a Bitcoin chart and a visitor
  counter) from the original configuration. They are unchanged.
- Half-Life 2 and HL2DM are trademarks of Valve Corporation. This project is not
  affiliated with or endorsed by Valve. Game content is downloaded anonymously
  via SteamCMD at runtime and requires no host game licence.
