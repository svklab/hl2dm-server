# Half-Life 2 Deathmatch Server

**HL2DM dedicated server** (Valve App ID `232370`) on **Debian 13 (trixie-slim)**. Pull and
play — no SteamCMD setup, no 32-bit library hunting, no multi-gigabyte image download.

## Highlights

- **~56 MB compressed** — the smallest HL2DM image around. Game content is *not* baked in;
  SteamCMD fetches app `232370` on first start (~895 MB) into a mounted volume
- **Fully self-contained** — `server.cfg`, `mapcycle.txt` and `motd.txt` ship in the image and
  are deployed on every start. No config files to mount
- **8 maps ready** — 7 official DM maps plus custom `halls3`, full rotation configured
- **Zero host dependencies** — SteamCMD and all i386 runtime libraries are baked in
- **Non-root** — runs as user `steam` (UID 1000)
- **Graceful shutdown** — `docker stop` sends `SIGINT`, the entrypoint issues the engine's
  console `quit`, and the server exits with code 0 in ~2 s (no `SIGKILL`, no exit 137)
- **Health check** — reports healthy only when `srcds_linux` runs **and** the game UDP port is
  bound, every 30 s, with a 300 s start period that covers the first download
- **Self-healing** — SteamCMD retries on failure and checks the manifest at every start
- **Fast warm start** — ~10–15 s to ready (manifest check only); `SRCDS_VALIDATE=1` forces a
  full re-hash
- **Honest, labelled startup** — the log separates `SteamCMD 1/2: self-update` (~41 MB) from
  `SteamCMD 2/2: game content` (~895 MB), so a slow start never looks like a hang
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

Startup has **two clearly labelled phases**, and they are easy to tell apart in the log:

| Phase | What is downloading | Size | Frequency |
|---|---|---|---|
| `SteamCMD 1/2: self-update` | SteamCMD updating **itself** | ~41 MB | every time a container is created |
| `SteamCMD 2/2: game content` | the HL2DM game content | ~895 MB | first install only |

```bash
docker logs -f hl2dm-server
```

```
[entrypoint] no game content found - phase 2 downloads ~895 MB, be patient
[entrypoint] SteamCMD 1/2: self-update (up to ~41 MB, happens once per container)
[entrypoint] SteamCMD self-update: 15s elapsed, game content 1 MB on disk
[entrypoint] SteamCMD 2/2: game content - update check (SRCDS_VALIDATE=0, manifest only)
[entrypoint] game content: 15s elapsed, game content 193 MB on disk
[entrypoint] game content: 45s elapsed, game content 768 MB on disk
[entrypoint] content ready: 895 MB at /home/steam/hl2dm_server
```

Later starts reuse the content on the volume and only check the manifest. Phase 1 still runs,
because SteamCMD's bootstrap lives in the image layer and refreshes itself per container:

```
[entrypoint] game content present (895 MB)
[entrypoint] SteamCMD 1/2: self-update (up to ~41 MB, happens once per container)
[entrypoint] SteamCMD 2/2: game content - update check (SRCDS_VALIDATE=0, manifest only)
[entrypoint] content ready: 895 MB at /home/steam/hl2dm_server
```

A warm start reaches `content ready` in roughly **10–15 s** and `healthy` shortly after. With
`SRCDS_APP_UPDATE=0` and content already on the volume the server is up in a few seconds and
does not touch the network at all.

### How long the download takes

Both phases are limited by **Steam's CDN and your network**, not by this image. Measured on one
and the same host:

| Measurement | Result |
|---|---|
| Game content, 895 MB | ~60 s (~15 MB/s) |
| SteamCMD self-update, 41 MB | ~40 s in one run, **~230 s (~0.2 MB/s)** in another |

So a first start can legitimately take anywhere from one minute to well over an hour, and the
same image that was fast yesterday can crawl today. A start is *not* stuck as long as the
elapsed-time lines keep appearing and the size keeps growing.

## Ports

| Port | Protocol | Purpose |
|------|----------|---------|
| 27015 | UDP/TCP | Game traffic |
| 27005 | UDP | Client (voice) |

Only `27015/udp` is required; `27015/tcp` and `27005/udp` are optional but recommended.

## Default settings

Everything is configured in the image, so no environment variables are needed:

| Setting | Value |
|---|---|
| Hostname | `HL2DM Server -- Happy gaming` |
| Gamemode | Deathmatch, free-for-all (`mp_teamplay 0`) |
| Map / rotation | `dm_lockdown`, `dm_overwatch`, `dm_powerhouse`, `dm_resistance`, `dm_runoff`, `dm_steamlab`, `dm_underpass`, `halls3` |
| Starting map | `dm_overwatch` |
| Max players | 12 |
| Frag limit / time limit | 50 / 20 min |
| Region | Europe (`sv_region 3`) |
| Friendly fire / fall damage | Off / 5 |
| Respawn — weapon / item | 5s / 10s |
| Voice | All-talk on, `vaudio_miles` |
| Gravity / max speed | 450 / 320 |
| RCON | Disabled (no password set) |

## Customising

Add any of these `-e` flags to override the defaults above:

```bash
docker run -d \
  --name hl2dm-server \
  --restart unless-stopped \
  -p 27015:27015/udp -p 27015:27015/tcp -p 27005:27005/udp \
  -v hl2dm_data:/home/steam/hl2dm_server \
  -e SRCDS_HOSTNAME="My HL2DM Server" \
  -e SRCDS_MAXPLAYERS=16 \
  -e SRCDS_MAP=dm_lockdown \
  -e SRCDS_MAPCYCLE="dm_c4|dm_killbox" \
  -e SRCDS_RCON_PASSWORD='change-me' \
  svk2907/hl2dm-server-2026-10-v1:latest
```

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

## Adding a custom map

`cfg/mapcycle.txt` is regenerated from the image default on every start, so editing it inside
the container does **not** survive a restart. Copy the map and add it to `SRCDS_MAPCYCLE`:

```bash
docker cp ./mymap.bsp hl2dm-server:/home/steam/hl2dm_server/hl2mp/maps/

# include the new map in the rotation (this is what makes it permanent)
docker run -d ... \
  -e SRCDS_MAPCYCLE="dm_lockdown|dm_overwatch|dm_powerhouse|dm_resistance|dm_runoff|dm_steamlab|dm_underpass|halls3|mymap" \
  svk2907/hl2dm-server-2026-10-v1:latest
```

## Updating

Game content is checked against Valve's manifest on every start, so an update normally requires
nothing. To force a full re-verify or repair a damaged install either start with
`SRCDS_VALIDATE=1`, or do it in a running container:

```bash
docker exec hl2dm-server \
  /home/steam/steamcmd/steamcmd.sh \
  +force_install_dir /home/steam/hl2dm_server \
  +login anonymous +app_update 232370 validate +quit
docker restart hl2dm-server
```

Image updates are independent of content updates — pull the image, then recreate the container
against the same volume.

## docker compose

```yaml
services:
  hl2dm:
    image: svk2907/hl2dm-server-2026-10-v1:latest
    container_name: hl2dm-server
    restart: unless-stopped
    stop_signal: SIGINT
    stop_grace_period: 15s
    ports:
      - "27015:27015/udp"
      - "27015:27015/tcp"
      - "27005:27005/udp"
    volumes:
      - hl2dm_data:/home/steam/hl2dm_server
    environment:
      SRCDS_VALIDATE: "0"
      # SRCDS_APP_UPDATE: "0"   # no network, fastest start

volumes:
  hl2dm_data:
```

## Image details

| | |
|---|---|
| Base image | `debian:trixie-slim` (Debian 13) |
| Architecture | `linux/amd64` |
| Compressed size | ~56 MB |
| Uncompressed size | ~221 MB |
| Game content | ~895 MB, downloaded at runtime |
| Steam App ID | `232370` |
| Runs as | `steam` (UID 1000, non-root) |
| Data directory | `/home/steam/hl2dm_server` |
| Entrypoint | `/home/steam/run.sh` |
| Stop signal | `SIGINT` → console `quit` → exit 0 |
| Health check | `srcds_linux` running **and** UDP port bound, every 30 s |

### What changed in v1

| | `2026-10-trixie` | `2026-10-v1` |
|---|---|---|
| `docker stop` | engine ignored `SIGTERM`, killed after timeout (exit 137) | pty + console `quit`, exit 0 in ~2 s |
| Warm start | full 895 MB re-hash (~50 s) | manifest check only, ~10–15 s; `SRCDS_VALIDATE=1` to re-hash |
| Health check | `pgrep srcds_linux` | process **and** bound UDP port, 30 s, 300 s start period |
| Startup log | unlabelled `downloading, N MB of ~895 MB` counter | labelled `SteamCMD 1/2` and `SteamCMD 2/2` phases |
| Package set | `wget`, `iproute2`, `procps`, i386 ncurses/tinfo | trimmed to what the server and entrypoint actually use |
| Size | 232 MB / ~59 MB compressed | 221 MB / ~56 MB compressed |

## Notes

- Requires an `amd64` (x86-64) host — the 32-bit Source engine binary is not available for arm64.
- Allow ~1.4 GB of free disk for the image plus the game content volume.
- Shutdown is graceful by design: the image sets `STOPSIGNAL SIGINT`, so a plain `docker stop`
  is enough. Do **not** raise `--stop-timeout` expecting a cleaner exit — `SRCDS_STOP_TIMEOUT`
  (default 8 s) is the knob that matters, and after it the process is killed as a last resort.
- The image contains no plugin framework. MetaMod / SourceMod can be unpacked into
  `/home/steam/hl2dm_server/hl2mp/addons` on the volume.
- A first `app_update` on a brand-new SteamCMD cache can fail once with `Missing configuration`;
  the entrypoint retries automatically, no action needed.
- SteamCMD sometimes logs `Update state (0x0) : Timed out waiting for update to start, bailing.`
  when its CDN is slow. It retries on its own and the line is followed by
  `Success! App '232370' fully installed.` — harmless.
- The console prints `Unknown command` four times for `sv_maxunlag`, `sv_unlag`,
  `sv_instancebaselines` and `sv_hltv` — legacy convars inherited from Valve's stock
  `server.cfg` that do not exist in HL2DM. Harmless.

### Log noise you can ignore

| Line | Why |
|---|---|
| `Please install (lib32tinfo5 / ncurses-libs.i686 / equivalent) to enable readline.` | SteamCMD wants the pre-trixie `libtinfo5`/`ncurses5` for its interactive console. Debian 13 no longer ships them; only SteamCMD's own readline is affected, never the game server. |
| `ILocalize::AddFile() failed to load file "public/steambootstrapper_english.txt".` | SteamCMD cosmetic, printed by its bootstrapper on every run. |
| `[S_API FAIL] Tried to access Steam interface ... before SteamAPI_Init succeeded.` | Source engine cosmetic, present for years on dedicated servers. |
| `WARNING: setlocale('en_US.UTF-8') failed, using locale: 'C'.` | Would mean the `en_US.UTF-8` locale is missing — this image generates it, so you should not see this line. |

### Troubleshooting

**"It downloads ~900 MB on every single start."**
The game volume is not mounted (or is empty). Check that the run command has
`-v hl2dm_data:/home/steam/hl2dm_server` and that the log says
`game content present (895 MB)`.

**"The download is very slow."**
That is Steam's CDN, not the image. Wait it out, or — once the content is on the volume — skip
networking entirely with `-e SRCDS_APP_UPDATE=0`. The server then starts in a few seconds.

**"Phase 1 takes minutes every restart."**
Expected: SteamCMD re-downloads its own ~41 MB update in every new container. Restarting the
*same* container (`docker restart`) reuses the updated SteamCMD and is fast.

- Half-Life 2 and HL2DM are trademarks of Valve Corporation. This project is not affiliated
  with or endorsed by Valve. Game content is downloaded anonymously via SteamCMD at runtime and
  requires no host game licence.
