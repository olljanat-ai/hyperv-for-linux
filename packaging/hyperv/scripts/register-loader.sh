#!/bin/sh
# Register a boot loader entry that chainloads the Microsoft Hypervisor
# before the Linux kernel. Idempotent: safe to re-run from postinst.
#
# Today this only knows how to talk to systemd-boot. GRUB support is a TODO
# (drop a fragment into /etc/grub.d/ and regenerate). On a system with
# neither it logs and exits 0 — the user can wire it up by hand.

set -eu

ENTRY_ID="hyperv"
ENTRY_TITLE="Ubuntu with Microsoft Hypervisor"
HV_PATH="/usr/lib/hyperv/hvloader.efi"
ESP="$(bootctl --print-esp-path 2>/dev/null || true)"

log() { echo "hyperv-register-loader: $*" >&2; }

if [ ! -f "$HV_PATH" ]; then
    log "$HV_PATH missing — hyperv-hypervisor not installed?"
    exit 0
fi

if [ -z "$ESP" ] || [ ! -d "$ESP" ]; then
    log "no ESP detected via bootctl; skipping loader entry."
    exit 0
fi

if ! command -v bootctl >/dev/null 2>&1; then
    log "bootctl not available; skipping systemd-boot integration."
    exit 0
fi

# Copy the loader binary into the ESP so the firmware can read it without
# crossing filesystem boundaries during boot.
install -d "$ESP/EFI/hyperv"
install -m 0644 "$HV_PATH" "$ESP/EFI/hyperv/hvloader.efi"

# Drop a boot entry that points at it.
install -d "$ESP/loader/entries"
cat > "$ESP/loader/entries/${ENTRY_ID}.conf" <<EOF
title    ${ENTRY_TITLE}
efi      /EFI/hyperv/hvloader.efi
EOF

log "registered systemd-boot entry '${ENTRY_ID}' at $ESP/loader/entries/${ENTRY_ID}.conf"
