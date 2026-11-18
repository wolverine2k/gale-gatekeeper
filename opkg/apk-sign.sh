#!/bin/sh
set -eu
[ "$#" -ge 1 ] || exit 1
tool=$1
shift
if [ "$tool" = "${GATEKEEPER_APK:-}" ] && [ "${1:-}" = mkpkg ]; then
    [ -f "${GATEKEEPER_SIGNING_KEY:-}" ] || exit 1
    exec "$tool" "$@" --sign-key "$GATEKEEPER_SIGNING_KEY"
fi
exec "$tool" "$@"
