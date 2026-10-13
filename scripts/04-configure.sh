#!/usr/bin/env bash
# Desktop (XFCE), user, services, Debian-compat fixes, initramfs.
. "$(dirname "$0")/lib.sh"
log "installing fixes and icon into the rootfs"
install -D -m755 "$HERE/files/jetson-debian-fixups.sh" "$ROOTFS/usr/local/sbin/jetson-debian-fixups"
install -D -m644 "$HERE/files/jetson-power-bolt.svg" "$ROOTFS/usr/local/share/jetson-debian/icons/jetson-power-bolt.svg"
echo 'DPkg::Post-Invoke { "/usr/local/sbin/jetson-debian-fixups || true"; };' > "$ROOTFS/etc/apt/apt.conf.d/99jetson-debian-fixups"
install -D -m755 "$HERE/files/gen-nv-boot-control.sh" "$ROOTFS/usr/local/sbin/gen-nv-boot-control"
cat > "$ROOTFS/etc/systemd/system/nv-boot-control-gen.service" <<'UEOF'
[Unit]
Description=Generate /etc/nv_boot_control.conf from firmware variables
ConditionPathExists=!/etc/nv_boot_control.conf
Before=nv-l4t-bootloader-config.service
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/gen-nv-boot-control

[Install]
WantedBy=multi-user.target
UEOF

log "desktop, user, services"
inchroot_sh <<EOT
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get install -y --no-install-recommends xfce4 xfce4-terminal xfce4-notifyd lightdm lightdm-gtk-greeter \
  xserver-xorg-core xserver-xorg-input-libinput x11-xserver-utils network-manager-gnome mousepad thunar \
  dbus-x11 fonts-dejavu-core firefox-esr librsvg2-common \
  systemd-timesyncd avahi-daemon libnss-mdns udisks2 gvfs thunar-volman systemd-zram-generator \
  pipewire pipewire-pulse pipewire-alsa wireplumber alsa-utils pavucontrol xfce4-pulseaudio-plugin \
  wireless-regdb rfkill grub-efi-arm64-bin grub2-common
# GRUB's own tools are only used by 06-make-image.sh with a static grub.cfg; auto-regeneration would
# overwrite it with entries that don't know NVIDIA's /boot/Image, so remove the kernel hooks.
rm -f /etc/kernel/postinst.d/zz-update-grub /etc/kernel/postrm.d/zz-update-grub
groupadd -rf debug
cat > /etc/systemd/zram-generator.conf <<ZEOF
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
ZEOF
/usr/local/sbin/jetson-debian-fixups
echo "$NEW_HOSTNAME" > /etc/hostname
grep -q "$NEW_HOSTNAME" /etc/hosts || echo "127.0.1.1 $NEW_HOSTNAME" >> /etc/hosts
echo "$LOCALE UTF-8" > /etc/locale.gen && locale-gen
groupadd -f -r i2c; groupadd -f -r gpio
id $NEW_USER >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo,video,audio,render,plugdev,netdev,i2c,gpio $NEW_USER
echo "$NEW_USER:$NEW_PASSWORD" | chpasswd && chage -d 0 $NEW_USER
systemctl enable ssh NetworkManager lightdm systemd-timesyncd avahi-daemon
# nv-l4t-bootloader-config does the boot-slot bookkeeping ("last boot was OK"). Leave it enabled; it needs
# /etc/nv_boot_control.conf, which nv-boot-control-gen.service creates from the firmware on first boot.
systemctl enable nv-boot-control-gen.service
EOT

log "default power mode: MAXN_SUPER (full 67 TOPS)"
mkdir -p "$ROOTFS/var/lib/nvpmodel"
printf 'pmode:0002' > "$ROOTFS/var/lib/nvpmodel/status"

log "initramfs for kernel $(kver)"
inchroot update-initramfs -c -k "$(kver)" 2>&1 | grep -v 'Possible missing firmware' || true
inchroot /usr/local/sbin/jetson-debian-fixups   # creates the stable /boot/initrd symlink
ls -la "$ROOTFS/boot" | grep -E 'Image|initrd'
