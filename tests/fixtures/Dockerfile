# Stand-in "site" image for the updater tests: answers /healthz with HEALTH and
# every other path with "version $VERSION".
FROM caddy:2-alpine
ARG VERSION=A
ARG HEALTH=200
RUN printf '{\n\tadmin off\n}\n:80 {\n\trespond /healthz "health %s" %s\n\trespond "version %s" 200\n}\n' \
      "$HEALTH" "$HEALTH" "$VERSION" > /etc/caddy/Caddyfile
