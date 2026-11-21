#!/bin/sh
# Generate the Tang keys on first start, then serve them on $TANG_PORT.
set -eu
port="${TANG_PORT:-7500}"
if ! ls /var/lib/tang/*.jwk >/dev/null 2>&1; then
    /usr/libexec/tangd-keygen /var/lib/tang
    echo "tang: generated new keys in /var/lib/tang -- back them up" >&2
fi
exec /usr/libexec/tangd -l -p "$port" /var/lib/tang
