# Stand-in "site" image for the updater tests: answers /healthz with HEALTH and
# every other path with "version $VERSION".
FROM caddy:2-alpine
ARG VERSION=A
ARG HEALTH=200
ARG LISTEN=80
# Where Caddy may write (the containers are read-only apart from their tmpfs mounts).
ARG STATE_PREFIX=/
# Caddy's binary carries a file capability (bind low ports); exec of such a file fails in
# a container with all capabilities dropped (like the integrations service). The
# stand-in doesn't need it: root plus the container's own cap_add is enough on :80.
RUN setcap -r /usr/bin/caddy
ENV XDG_CONFIG_HOME=${STATE_PREFIX}config XDG_DATA_HOME=${STATE_PREFIX}data
RUN printf '{\n\tadmin off\n}\n:%s {\n\trespond /healthz "health %s" %s\n\trespond "version %s" 200\n}\n' \
      "$LISTEN" "$HEALTH" "$HEALTH" "$VERSION" > /etc/caddy/Caddyfile
