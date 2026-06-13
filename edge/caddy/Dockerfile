# Caddy + caddy-docker-proxy + Cloudflare DNS module.
#
# caddy-docker-proxy turns Docker labels into Caddy config automatically (routes
# generate themselves as you label services). The Cloudflare DNS module lets
# Caddy solve ACME DNS-01 challenges, so it can issue ONE wildcard cert
# (*.${DOMAIN}) that covers every service — internal and external — with no
# per-host setup. Both modules aren't in the stock image, so we build them in.
FROM caddy:2-builder AS builder
RUN xcaddy build \
    --with github.com/lucaslorentz/caddy-docker-proxy/v2 \
    --with github.com/caddy-dns/cloudflare

FROM caddy:2-alpine
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
# caddy-docker-proxy mode: watch Docker, build config from labels.
CMD ["caddy", "docker-proxy"]
