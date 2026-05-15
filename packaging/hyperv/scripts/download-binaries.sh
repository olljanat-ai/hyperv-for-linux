#!/bin/sh
# Download the Microsoft Hypervisor RPMs pinned in sources.conf and
# extract them onto the running system. Idempotent: re-running overwrites
# the same files.
#
# Why this script exists: redistributing Microsoft's closed-source bits
# inside our own .deb would violate their license. Instead, the .deb is a
# meta-package that ships only this downloader + a pinned URL manifest;
# the end-user is the one who actually fetches the binaries, on their own
# machine, accepting Microsoft's license at install time.

set -eu

SOURCES_CONF="/usr/lib/hyperv/sources.conf"

log() { echo "hyperv-download-binaries: $*" >&2; }

if [ ! -r "$SOURCES_CONF" ]; then
    log "$SOURCES_CONF missing — package is broken."
    exit 1
fi

for tool in curl bsdtar; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        log "$tool not installed — fix dependencies and reconfigure."
        exit 1
    fi
done

WORK_DIR="$(mktemp -d /tmp/hyperv-install.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT INT TERM

while IFS= read -r url; do
    case "$url" in
        ""|\#*) continue ;;
    esac
    fname="$(basename "$url")"
    log "downloading $fname"
    if ! curl -fsSL --retry 4 --retry-delay 2 \
              -o "$WORK_DIR/$fname" "$url"; then
        log "download failed for $url"
        exit 1
    fi
done < "$SOURCES_CONF"

# RPMs from packages.microsoft.com use absolute paths under /usr — extract
# straight onto the root filesystem so files land where register-loader.sh
# expects them.
for rpm in "$WORK_DIR"/*.rpm; do
    log "extracting $(basename "$rpm")"
    bsdtar -xf "$rpm" -C /
done

if ! find /usr -name 'HvLoader.efi' -type f 2>/dev/null | grep -q .; then
    log "HvLoader.efi not present after extraction — RPM layout changed?"
    exit 1
fi

log "binaries installed."
