#!/usr/bin/env bash
# Pre-flight check of a built image BEFORE it is written to any stick. Read-only.
#   sudo scripts/verify-image.sh [jetson-debian.img]
set -uo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root: sudo $0"; exit 1; }
IMG=${1:-$(cd "$(dirname "$0")/.." && pwd)/jetson-debian.img}
[ -f "$IMG" ] || { echo "no image: $IMG"; exit 1; }
FAIL=0; ok() { printf '  [ ok ] %s\n' "$*"; }; bad() { printf '  [FAIL] %s\n' "$*"; FAIL=1; }
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
LOOP=$(losetup --find --show --partscan -r "$IMG"); sleep 1
M=$(mktemp -d); E=$(mktemp -d)
cleanup() { umount "$E" "$M" 2>/dev/null; losetup -d "$LOOP" 2>/dev/null; rmdir "$E" "$M" 2>/dev/null; }; trap cleanup EXIT
echo "Image: $IMG"
chk "GPT with 2 partitions" "[ \$(sgdisk -p '$IMG' 2>/dev/null | grep -c '^ *[0-9]') -eq 2 ]"
chk "partition 1 is an EFI System partition (EF00)" "sgdisk -i 1 '$IMG' | grep -qi 'C12A7328'"
mount -o ro "${LOOP}p2" "$M"; mount -o ro "${LOOP}p1" "$E"
chk "ESP is FAT"                          "blkid -s TYPE -o value ${LOOP}p1 | grep -q vfat"
chk "ESP has EFI/BOOT/BOOTAA64.EFI"       "[ -s '$E/EFI/BOOT/BOOTAA64.EFI' ] || [ -s '$E/EFI/BOOT/bootaa64.efi' ]"
chk "root is ext4 and clean (e2fsck)"     "e2fsck -fn ${LOOP}p2"
chk "/boot/Image exists, >30 MB"          "[ \$(stat -c %s '$M/boot/Image') -gt 30000000 ]"
chk "/boot/initrd resolves"               "[ -s '$M/boot/initrd' ]"
chk "/boot/grub/grub.cfg exists"          "[ -s '$M/boot/grub/grub.cfg' ]"
PU=$(blkid -s PARTUUID -o value ${LOOP}p2); FU=$(blkid -s UUID -o value ${LOOP}p2)
chk "grub.cfg root=PARTUUID matches partition 2 ($PU)" "grep -q 'root=PARTUUID=$PU' '$M/boot/grub/grub.cfg'"
chk "grub.cfg searches the root fs UUID ($FU)"        "grep -q '$FU' '$M/boot/grub/grub.cfg'"
chk "kernel args include clk_ignore_unused"           "grep -q clk_ignore_unused '$M/boot/grub/grub.cfg'"
chk "kernel args include pd_ignore_unused"            "grep -q pd_ignore_unused '$M/boot/grub/grub.cfg'"
chk "fstab uses UUIDs (not device names)"             "grep -q '^UUID=$FU' '$M/etc/fstab'"
K=$(ls "$M/lib/modules" | head -1)
chk "kernel modules for $K present"                   "[ -d '$M/lib/modules/$K/kernel' ]"
if command -v lsinitramfs >/dev/null; then
  INITRD=$(readlink -f "$M/boot/initrd")
  L=$(lsinitramfs "$INITRD" 2>/dev/null)
  [ -n "$L" ] && ok "initrd readable ($(wc -l <<<"$L") entries)" || bad "initrd not readable"
  for mod in nvme uas; do   # storage drivers that are loadable modules in NVIDIA's kernel
    if grep -q "/$mod\.ko" <<<"$L"; then ok "initrd contains module $mod"; else bad "initrd lacks module $mod"; fi
  done
  for mod in ext4 usb-storage sd_mod xhci-tegra phy-tegra-xusb; do   # must be built into the kernel
    if grep -q "/$mod\.ko" "$M/lib/modules/$K/modules.builtin"; then ok "$mod is built into the kernel"
    elif grep -q "/$mod\.ko" <<<"$L"; then ok "initrd contains module $mod"
    else bad "$mod is neither built in nor in the initrd"; fi
  done
else
  echo "  [info] lsinitramfs not installed here; skipped ramdisk content checks"
fi
chk "systemd present as /sbin/init"      "[ -e '$M/sbin/init' ] || [ -L '$M/sbin/init' ]"
chk "user account exists"                "grep -q '^[a-z].*:x:10[0-9][0-9]:' '$M/etc/passwd'"
chk "SSH server enabled"                 "[ -e '$M/etc/systemd/system/multi-user.target.wants/ssh.service' ]"
chk "NVIDIA boot loader copy (BOOTAA64.efi) present for clean-drive installs" "[ -s '$M/usr/local/share/jetson-debian/BOOTAA64.efi' ]"
chk "install-to-nvme helper present"     "[ -x '$M/usr/local/sbin/install-to-nvme' ]"
chk "installer service enabled"          "[ -e '$M/etc/systemd/system/multi-user.target.wants/jetson-installer.service' ]"
chk "GRUB default entry is the installer"  "grep -q 'jetson.install' '$M/boot/grub/grub.cfg' && [ \"\$(grep -m1 -n '^menuentry' '$M/boot/grub/grub.cfg' | grep -c INSTALL)\" = 1 ]"
chk "graphical installer present"         "[ -x '$M/usr/local/sbin/jetson-install-gui' ] && [ -x '$M/usr/local/sbin/jetson-install-session' ]"
chk "graphical installer service enabled" "[ -e '$M/etc/systemd/system/multi-user.target.wants/jetson-installer-gui.service' ]"
chk "GRUB default entry is the graphical installer" "grep -m1 -A1 '^menuentry' '$M/boot/grub/grub.cfg' | grep -q . && awk '/^menuentry/{n++} n==1 && /jetson.install-gui/{f=1} END{exit !f}' '$M/boot/grub/grub.cfg'"
for t in Xorg xfwm4 dbus-run-session setxkbmap; do chk "graphical installer tool present: $t" "[ -x '$M/usr/bin/$t' ]"; done
chk "python3 venv available"             "[ -e '$M/usr/lib/python3.13/venv/__init__.py' ] || ls '$M'/usr/lib/python3*/venv/__init__.py"
chk "time zone database present"         "[ -f '$M/usr/share/zoneinfo/Europe/Helsinki' ]"
chk "console keymap tool present (console-setup)" "[ -x '$M/usr/bin/setupcon' ]"
chk "keyboard layout list present"       "[ -r '$M/usr/share/X11/xkb/rules/base.lst' ]"
for t in sgdisk sfdisk partprobe wipefs mkfs.ext4 mkfs.vfat rsync fdtget xxd blkid lsblk findmnt openssl awk ssh-keygen; do
  chk "installer tool present: $t" "[ -x '$M/usr/sbin/$t' ] || [ -x '$M/sbin/$t' ] || [ -x '$M/usr/bin/$t' ] || [ -x '$M/bin/$t' ]"
done
echo; [ $FAIL = 0 ] && echo "RESULT: all checks passed" || { echo "RESULT: FAILED - do not flash this image"; exit 1; }
