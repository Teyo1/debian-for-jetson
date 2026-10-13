#!/bin/sh
# Generates /etc/nv_boot_control.conf from the board's own firmware variables, as NVIDIA's installer does.
# Needed by nv-l4t-bootloader-config (boot-slot bookkeeping, "last boot was OK"). Runs on first boot only.
OUT=${1:-/etc/nv_boot_control.conf}
G=781e084c-a330-417c-b678-38e696380cb9
EV=/sys/firmware/efi/efivars
rd() { [ -r "$EV/$1-$G" ] && dd if="$EV/$1-$G" bs=1 skip=4 status=none | tr -d '\000'; }
TNSPEC=$(rd TegraPlatformSpec); COMPAT=$(rd TegraPlatformCompatSpec)
[ -n "$TNSPEC" ] && [ -n "$COMPAT" ] || { echo "gen-nv-boot-control: firmware spec variables not readable" >&2; exit 1; }
ROOTDEV=$(findmnt -n -o SOURCE / | sed 's#/dev/##; s#p\?[0-9]*$##')
CHIP=$(cat /sys/devices/soc0/soc_id 2>/dev/null)
printf 'TNSPEC %s\nCOMPATIBLE_SPEC %s\nTEGRA_BOOT_STORAGE %s\nTEGRA_CHIPID 0x%x\nTEGRA_OTA_BOOT_DEVICE /dev/mtdblock0\nTEGRA_OTA_GPT_DEVICE /dev/mtdblock0\n' \
  "$TNSPEC" "$COMPAT" "$ROOTDEV" "${CHIP:-35}" > "$OUT"
