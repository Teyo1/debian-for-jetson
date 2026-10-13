#!/bin/sh
# Re-applies Debian-compat fixes to NVIDIA files. Safe to run repeatedly; also runs after every dpkg
# (see /etc/apt/apt.conf.d/99jetson-debian-fixups) because package upgrades overwrite these files.
IND=/usr/share/nvpmodel_indicator/nvpmodel_indicator.py
ICON=/usr/local/share/jetson-debian/icons/jetson-power-bolt.svg
if [ -f "$IND" ]; then
  # Debian 13 ships Ayatana AppIndicator instead of AppIndicator3
  sed -i 's/gi.require_version(.AppIndicator3., .0.1.)/gi.require_version("AyatanaAppIndicator3", "0.1")/;
          s/from gi.repository import AppIndicator3 as appindicator/from gi.repository import AyatanaAppIndicator3 as appindicator/' "$IND"
  # power-mode lightning bolt instead of the NVIDIA logo
  [ -f "$ICON" ] && sed -i "s#^ICON_DEFAULT = .*#ICON_DEFAULT = os.path.abspath('$ICON')#" "$IND"
fi
# autostart for XFCE (NVIDIA only lists GNOME/Unity/LXDE)
A=/etc/xdg/autostart/nvpmodel_indicator.desktop
[ -f "$A" ] && ! grep -q 'XFCE' "$A" && sed -i 's/^OnlyShowIn=.*/&XFCE;/' "$A"
# NVIDIA's skeleton ~/.xsessionrc is a bash script; Debian sources it with dash and the X session dies
rm -f /etc/skel/.xsessionrc
# Keep the boot ramdisk in step with the NVIDIA kernel. NVIDIA's kernel package drops /boot/Image and
# /lib/modules/<ver> but does not build an initrd for Debian. extlinux uses the stable names
# /boot/Image and /boot/initrd, so updates need no boot-menu edits.
if [ -d /lib/modules ] && [ -f /boot/Image ]; then
  K=$(ls /lib/modules 2>/dev/null | sort -V | tail -1)
  if [ -n "$K" ] && command -v update-initramfs >/dev/null 2>&1; then
    if [ ! -f "/boot/initrd.img-$K" ]; then update-initramfs -c -k "$K" >/dev/null 2>&1 || true
    elif [ /boot/Image -nt "/boot/initrd.img-$K" ]; then update-initramfs -u -k "$K" >/dev/null 2>&1 || true
    fi
    [ -f "/boot/initrd.img-$K" ] && ln -sf "initrd.img-$K" /boot/initrd
  fi
fi
exit 0
