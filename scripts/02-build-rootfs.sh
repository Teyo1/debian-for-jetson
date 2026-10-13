#!/usr/bin/env bash
# Pure Debian base system (debootstrap). Nothing from Ubuntu/Canonical.
. "$(dirname "$0")/lib.sh"
[ -e "$ROOTFS/etc/debian_version" ] && { echo "$ROOTFS already exists; remove it first"; exit 1; }
mkdir -p "$ROOTFS"
INCLUDE=systemd-sysv,udev,dbus,kmod,sudo,locales,ca-certificates,openssh-server,network-manager,initramfs-tools,e2fsprogs,dosfstools,parted,curl,wget,gnupg,nano,less,iproute2,iputils-ping,pciutils,usbutils,wpasupplicant,bluez,xz-utils,zstd,firmware-linux-free,nvme-cli,rsync,gdisk,fdisk,xxd,python3-venv,python3-pip,console-setup,keyboard-configuration
log "debootstrap $DEBIAN_SUITE -> $ROOTFS"
debootstrap --arch=arm64 --variant=minbase --include="$INCLUDE" "$DEBIAN_SUITE" "$ROOTFS" "$DEBIAN_MIRROR"
echo 'Acquire::ForceIPv4 "true";' > "$ROOTFS/etc/apt/apt.conf.d/99ipv4"
log "base system: $(du -sh "$ROOTFS" 2>/dev/null | cut -f1)"
