# Tang server (network-bound disk encryption) from the Debian package.
FROM debian:trixie-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends tang-common curl \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --home-dir /var/lib/tang --shell /usr/sbin/nologin tang \
 && install -d -o tang -g tang -m 0700 /var/lib/tang
COPY --chmod=0755 entrypoint.sh /entrypoint.sh
USER tang
VOLUME /var/lib/tang
ENV TANG_PORT=7500
EXPOSE 7500
HEALTHCHECK --interval=30s --timeout=5s CMD curl -fsS "http://127.0.0.1:${TANG_PORT}/adv" >/dev/null || exit 1
ENTRYPOINT ["/entrypoint.sh"]
