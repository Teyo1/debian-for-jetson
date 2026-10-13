#!/usr/bin/env bash
# Packs $ROOTFS into a bootable raw disk image:  GPT = [ FAT32 ESP with GRUB | ext4 Debian root ]
# Boot method is plain GRUB-EFI (what NVIDIA's own installer ISO uses); the Orin firmware boots it from USB.
# Only writes the image FILE; it never touches a disk.
#   sudo ROOTFS=/srv/debian-final scripts/06-make-image.sh [out.img]
. "$(dirname "$0")/lib.sh"
. "$HERE/files/kernel-args.env"
OUT=${1:-$HERE/jetson-debian.img}
EXTRA_MB=${EXTRA_MB:-1024}                   # free space left in the root partition
ESP_MB=256
USED_MB=$(du -sm "$ROOTFS" 2>/dev/null | tail -1 | cut -f1)
SIZE_MB=$(( USED_MB + EXTRA_MB + ESP_MB + 64 ))
for t in sgdisk mkfs.vfat mkfs.ext4 rsync losetup; do command -v $t >/dev/null || apt-get install -y --no-install-recommends gdisk dosfstools e2fsprogs rsync mount >/dev/null; done
[ -x "$ROOTFS/usr/sbin/grub-install" ] || { echo "grub-efi-arm64 is not installed in $ROOTFS (run 04-configure.sh)"; exit 1; }

log "image: $OUT (${SIZE_MB} MB; rootfs ${USED_MB} MB)"
rm -f "$OUT"; truncate -s "${SIZE_MB}M" "$OUT"
ROOT_PARTUUID=$(cat /proc/sys/kernel/random/uuid)
ROOT_FSUUID=$(cat /proc/sys/kernel/random/uuid)
sgdisk -o \
  -n 1:2048:+${ESP_MB}M -t 1:EF00 -c 1:ESP \
  -n 2:0:0              -t 2:8300 -c 2:APP -u 2:"$ROOT_PARTUUID" "$OUT" >/dev/null
LOOP=$(losetup --find --show --partscan "$OUT"); sleep 1
M=/mnt/jd-image
cleanup() { for d in dev/pts dev proc sys run boot/efi; do umount "$M/$d" 2>/dev/null || true; done; umount "$M" 2>/dev/null || true; losetup -d "$LOOP" 2>/dev/null || true; }
trap cleanup EXIT
mkfs.vfat -F32 -n ESP "${LOOP}p1" >/dev/null
mkfs.ext4 -q -L jetson-debian -U "$ROOT_FSUUID" "${LOOP}p2"
mkdir -p $M && mount "${LOOP}p2" $M
mkdir -p $M/boot/efi && mount "${LOOP}p1" $M/boot/efi

log "copying rootfs"
rsync -aHAX --numeric-ids --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' --exclude='/run/*' --exclude='/tmp/*' \
      --exclude='/boot/efi/*' --exclude='/var/cache/apt/archives/*.deb' "$ROOTFS"/ $M/
mkdir -p $M/{proc,sys,dev,run,tmp,mnt}; chmod 1777 $M/tmp

ESP_UUID=$(blkid -s UUID -o value "${LOOP}p1")
cat > $M/etc/fstab <<EOT
UUID=$ROOT_FSUUID  /          ext4  defaults,rw        0  1
UUID=$ESP_UUID     /boot/efi  vfat  umask=0077,nofail  0  2
EOT

log "GRUB (removable EFI path /EFI/BOOT/BOOTAA64.EFI)"
mount --bind /dev $M/dev; mount --bind /dev/pts $M/dev/pts; mount -t proc proc $M/proc; mount -t sysfs sys $M/sys; mount --bind /run $M/run
chroot $M grub-install --target=arm64-efi --efi-directory=/boot/efi --boot-directory=/boot --removable --no-nvram --no-floppy 2>&1 | tail -3

# One-Enter installer: the first GRUB entry boots with jetson.install and this unit runs the installer on tty1.
cat > $M/etc/systemd/system/jetson-installer.service <<'EOT'
[Unit]
Description=Install Debian onto the NVMe (only when booted with jetson.install)
ConditionKernelCommandLine=jetson.install
After=systemd-user-sessions.service
Conflicts=getty@tty1.service
After=getty@tty1.service

[Service]
Type=simple
StandardInput=tty-force
StandardOutput=tty
StandardError=tty
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
ExecStart=/bin/bash -c '/usr/local/sbin/install-to-nvme --auto || { echo; echo "The install did not finish (see above). Press Enter for a shell."; read -r _; exec /bin/bash -l; }'

[Install]
WantedBy=multi-user.target
EOT
mkdir -p $M/etc/systemd/system/multi-user.target.wants && ln -sf ../jetson-installer.service $M/etc/systemd/system/multi-user.target.wants/jetson-installer.service

# Graphical installer: the first GRUB entry boots to a bare X session (no desktop, no login) running the wizard.
# If X or the wizard cannot start, the session falls back to the text installer on the same console.
install -D -m755 "$HERE/files/jetson-install-gui" $M/usr/local/sbin/jetson-install-gui
cat > $M/usr/local/sbin/jetson-install-session <<'EOT'
#!/bin/bash
# Started by jetson-installer-gui.service (kernel flag jetson.install-gui). Not part of the installed system.
export HOME=/run/installer-home; mkdir -p "$HOME"
cat > /run/installer-xinitrc <<'XEOT'
#!/bin/sh
xsetroot -cursor_name left_ptr
# Focus, the mouse and the highlighted control are a window manager's job: it must be running inside the same
# dbus session before the wizard starts.
exec dbus-run-session -- sh -c 'xfwm4 --compositor=off >/dev/null 2>&1 & for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do pgrep -x xfwm4 >/dev/null && break; sleep 0.25; done; sleep 0.5; exec /usr/local/sbin/jetson-install-gui'
XEOT
chmod +x /run/installer-xinitrc
# The display driver is loaded by nv-load-display-modules.service; starting Xorg before it exists fails.
for i in $(seq 1 120); do ls /dev/dri/card* >/dev/null 2>&1 && break; sleep 0.5; done
rc=99
for try in 1 2 3 4; do
  rm -f /tmp/.X11-unix/X0 /tmp/.X0-lock
  /usr/bin/Xorg :0 vt1 -logfile /run/installer-X.log -nolisten tcp -quiet &
  XPID=$!
  for i in $(seq 1 40); do [ -S /tmp/.X11-unix/X0 ] && break; kill -0 $XPID 2>/dev/null || break; sleep 0.5; done
  if [ -S /tmp/.X11-unix/X0 ]; then
    # Watchdog: the wizard writes /run/installer-gui-ready once its window is up; if that does not happen, try again.
    rm -f /run/installer-gui-ready
    DISPLAY=:0 sh /run/installer-xinitrc & CPID=$!
    for i in $(seq 1 90); do [ -e /run/installer-gui-ready ] && break; kill -0 $CPID 2>/dev/null || break; sleep 1; done
    if [ -e /run/installer-gui-ready ]; then wait $CPID; rc=$?; kill $XPID 2>/dev/null; wait $XPID 2>/dev/null; break; fi
    pkill -P $CPID 2>/dev/null; kill $CPID 2>/dev/null; wait $CPID 2>/dev/null; rc=98
  fi
  kill $XPID 2>/dev/null; wait $XPID 2>/dev/null; sleep 3
done
[ $rc = 0 ] && exit 0
echo; echo "The graphical installer did not run (code $rc). Last lines of the X log:"; grep -E "\(EE\)" /run/installer-X.log 2>/dev/null | tail -8; echo "Starting the text installer instead."; sleep 3
exec /usr/local/sbin/install-to-nvme --auto
EOT
chmod 755 $M/usr/local/sbin/jetson-install-session
cat > $M/etc/systemd/system/jetson-installer-gui.service <<'EOT'
[Unit]
Description=Graphical installer (only when booted with jetson.install-gui)
ConditionKernelCommandLine=jetson.install-gui
After=systemd-user-sessions.service nv-load-display-modules.service
Conflicts=getty@tty1.service
After=getty@tty1.service

[Service]
Type=simple
StandardInput=tty-force
StandardOutput=tty
StandardError=tty
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
ExecStart=/bin/bash -c '/usr/local/sbin/jetson-install-session || { echo; echo "The install did not finish (see above). Press Enter for a shell."; read -r _; exec /bin/bash -l; }'

[Install]
WantedBy=multi-user.target
EOT
ln -sf ../jetson-installer-gui.service $M/etc/systemd/system/multi-user.target.wants/jetson-installer-gui.service
K=$(ls $M/lib/modules | head -1)
cat > $M/boot/grub/grub.cfg <<EOT
set default=0
set timeout=10
insmod part_gpt
insmod ext2
search --no-floppy --fs-uuid --set=root $ROOT_FSUUID

menuentry "INSTALL Debian 13 to the NVMe  (graphical; asks before it erases anything)" {
    linux /boot/Image root=PARTUUID=$ROOT_PARTUUID rw rootwait rootfstype=ext4 $KARGS_COMMON systemd.unit=multi-user.target jetson.install-gui nvme.use_threaded_interrupts=1 pci=pcie_bus_perf
    initrd /boot/initrd
}
submenu "Advanced options" {
    menuentry "INSTALL Debian 13 to the NVMe  (text mode; ERASES the whole NVMe; asks before it does)" {
        linux /boot/Image root=PARTUUID=$ROOT_PARTUUID rw rootwait rootfstype=ext4 $KARGS_COMMON systemd.unit=multi-user.target jetson.install nvme.use_threaded_interrupts=1 pci=pcie_bus_perf
        initrd /boot/initrd
    }
    menuentry "INSTALL Debian 13  (text mode, screen rotated 90 degrees: sideways monitor A)" {
        linux /boot/Image root=PARTUUID=$ROOT_PARTUUID rw rootwait rootfstype=ext4 $KARGS_COMMON systemd.unit=multi-user.target jetson.install fbcon=rotate:1 nvme.use_threaded_interrupts=1 pci=pcie_bus_perf
        initrd /boot/initrd
    }
    menuentry "INSTALL Debian 13  (text mode, screen rotated 270 degrees: sideways monitor B)" {
        linux /boot/Image root=PARTUUID=$ROOT_PARTUUID rw rootwait rootfstype=ext4 $KARGS_COMMON systemd.unit=multi-user.target jetson.install fbcon=rotate:3 nvme.use_threaded_interrupts=1 pci=pcie_bus_perf
        initrd /boot/initrd
    }
    menuentry "Rescue shell (from the USB stick)" {
        linux /boot/Image root=PARTUUID=$ROOT_PARTUUID rw rootwait rootfstype=ext4 $KARGS_COMMON systemd.unit=rescue.target
        initrd /boot/initrd
    }
    menuentry "Debug shell in the ramdisk" {
        linux /boot/Image root=PARTUUID=$ROOT_PARTUUID rw rootwait rootfstype=ext4 $KARGS_COMMON rootdelay=30 break=premount
        initrd /boot/initrd
    }
}
menuentry "UEFI Firmware Settings" {
    fwsetup
}
EOT
install -D -m755 "$HERE/scripts/install-to-nvme.sh" $M/usr/local/sbin/install-to-nvme
sync
log "done: $(ls -lh "$OUT" | awk '{print $5}')  $OUT   (kernel $K)"
