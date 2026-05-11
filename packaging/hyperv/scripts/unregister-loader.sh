#!/bin/sh
# Remove the boot loader entry installed by register-loader.sh. Only touches
# the entry we created; never deletes other entries or the ESP itself.

set -eu

ENTRY_ID="hyperv"
ESP="$(bootctl --print-esp-path 2>/dev/null || true)"

if [ -z "$ESP" ] || [ ! -d "$ESP" ]; then
    exit 0
fi

rm -f "$ESP/loader/entries/${ENTRY_ID}.conf"
rm -f "$ESP/EFI/hyperv/hvloader.efi"
rmdir "$ESP/EFI/hyperv" 2>/dev/null || true
