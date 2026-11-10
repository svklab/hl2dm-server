IMAGE   ?= svk2907/hl2dm-server-2026-v1.0
TAG     ?= latest
VERSION ?= 2026-v1.0
REVISION ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
CREATED  ?= $(shell date -u +%Y-%m-%dT%H:%M:%SZ)

.PHONY: build test run push clean

# --pull makes the build pick up the latest debian:trixie-slim and then
# `apt-get upgrade` brings the installed packages to the current trixie level.
build:
	docker build --pull --platform linux/amd64 \
		--build-arg VERSION="$(VERSION)" \
		--build-arg REVISION="$(REVISION)" \
		--build-arg CREATED="$(CREATED)" \
		-t "$(IMAGE):$(TAG)" .

test:
	docker run --rm --entrypoint /bin/sh "$(IMAGE):$(TAG)" -c '\
		set -e; \
		sh -n /home/steam/run.sh; \
		sh -n /home/steam/healthcheck.sh; \
		id steam >/dev/null; \
		locale -a | grep -qi "en_US.utf8"; \
		test -x /home/steam/steamcmd/steamcmd.sh; \
		test -e /usr/lib/i386-linux-gnu/libcurl.so.4; \
		test -e /usr/lib/i386-linux-gnu/libcurl-gnutls.so.4; \
		test -e /usr/lib/i386-linux-gnu/libtinfo.so.5; \
		test -e /usr/lib/i386-linux-gnu/libncurses.so.5; \
		test -r /opt/hl2dm-defaults/server.cfg; \
		test -r /opt/hl2dm-defaults/mapcycle.txt; \
		test -r /opt/hl2dm-defaults/motd.txt; \
		echo "smoke test OK"'

run:
	docker run --rm -it --name hl2dm-server \
		-p 27015:27015/udp -p 27015:27015/tcp -p 27005:27005/udp \
		-v hl2dm_data:/home/steam/hl2dm_server \
		"$(IMAGE):$(TAG)"

push:
	docker push "$(IMAGE):$(TAG)"
	docker tag "$(IMAGE):$(TAG)" "$(IMAGE):$(VERSION)"
	docker push "$(IMAGE):$(VERSION)"

clean:
	-docker rmi "$(IMAGE):$(TAG)" "$(IMAGE):$(VERSION)"
