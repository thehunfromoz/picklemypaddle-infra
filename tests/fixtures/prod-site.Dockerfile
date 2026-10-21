# Stand-in production "site" image for tests/production-update.test.sh. It answers where
# production/update.sh looks: /healthz, /version.txt (= the image's revision label),
# /robots.txt, the sitemap, /env.css, the home page and the security headers.
#   VERSION  what /version.txt and the home page say
#   HEALTH   status of /healthz (200 = healthy, 500 = never becomes healthy)
#   ORIGIN   the site address baked into canonical/robots/sitemap (the real build bakes SITE_URL)
#   SITEMAP  where the sitemap is: /sitemap.xml now (SCRUM-36), /sitemap-index.xml for older releases
FROM caddy:2-alpine
ARG VERSION=A
ARG HEALTH=200
ARG ORIGIN=https://www.picklemypaddle.com
ARG SITEMAP=/sitemap.xml
# Caddy's binary carries a file capability; exec of such a file fails in a container with all
# capabilities dropped. The stand-in doesn't need it (see Dockerfile next to this one).
RUN setcap -r /usr/bin/caddy
ENV XDG_CONFIG_HOME=/config XDG_DATA_HOME=/data VERSION=${VERSION} HEALTH=${HEALTH} ORIGIN=${ORIGIN} SITEMAP=${SITEMAP}
COPY prod-site.Caddyfile /etc/caddy/Caddyfile
