#!/usr/bin/env bash
# NVIDIA L4T kernel, open GPU driver, firmware, CUDA/GL/Vulkan userspace, multimedia, camera.
. "$(dirname "$0")/lib.sh"
log "adding NVIDIA apt repository"
mkdir -p "$ROOTFS/etc/apt/keyrings" "$ROOTFS/etc/apt/sources.list.d"
curl -4 -sfL -o "$ROOTFS/etc/apt/keyrings/nvidia-jetson.asc" https://repo.download.nvidia.com/jetson/jetson-ota-public.asc
# sanity check: NVIDIA's Jetson signing key (fingerprint 3C6D1FF3100C8C3ABB0869C0E6543461A9996195)
gpg --show-keys --with-colons "$ROOTFS/etc/apt/keyrings/nvidia-jetson.asc" | grep -q 3C6D1FF3100C8C3ABB0869C0E6543461A9996195 \
  || { echo "unexpected NVIDIA key fingerprint, aborting"; exit 1; }
cat > "$ROOTFS/etc/apt/sources.list.d/nvidia-l4t.sources" <<EOT
Types: deb
URIs: https://repo.download.nvidia.com/jetson/common https://repo.download.nvidia.com/jetson/som
Suites: $L4T_REPO_REL
Components: main
Architectures: arm64
Signed-By: /etc/apt/keyrings/nvidia-jetson.asc
EOT
cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf" 2>/dev/null || true

log "libpcre3 (needed by NVIDIA multimedia, dropped from Debian 13; taken unmodified from Debian's archive)"
curl -4 -sfL -o "$ROOTFS/var/tmp/libpcre3.deb" http://deb.debian.org/debian/pool/main/p/pcre3/libpcre3_8.39-15_arm64.deb

log "shim: NVIDIA's tray tools depend on the old AppIndicator3 name; Debian 13 ships Ayatana"
cat > "$ROOTFS/var/tmp/shim.ctl" <<'EOT'
Section: misc
Priority: optional
Standards-Version: 4.6.0
Package: gir1.2-appindicator3-0.1
Version: 99:0.5-jetson-debian-shim
Depends: gir1.2-ayatanaappindicator3-0.1
Description: Shim: old AppIndicator3 name -> Ayatana (jetson-debian)
EOT

# NVIDIA's kernel-dtbs postinst refuses to run without a Jetson boot config unless this flag exists
mkdir -p "$ROOTFS/opt/nvidia/l4t-packages"
touch "$ROOTFS/opt/nvidia/l4t-packages/.nv-l4t-disable-boot-fw-update-in-preinstall"

PKGS_CORE="nvidia-l4t-core nvidia-l4t-kernel nvidia-l4t-kernel-dtbs nvidia-l4t-kernel-oot-modules nvidia-l4t-display-kernel nvidia-l4t-kernel-nvgpu nvidia-l4t-kernel-openrm nvidia-l4t-kernel-module-configs nvidia-l4t-firmware nvidia-l4t-firmware-nvgpu nvidia-l4t-firmware-openrm nvidia-l4t-init nvidia-l4t-init-openrm nvidia-l4t-cuda nvidia-l4t-cuda-nvgpu nvidia-l4t-cuda-openrm nvidia-l4t-cuda-utils nvidia-l4t-3d-core nvidia-l4t-gbm nvidia-l4t-wayland nvidia-l4t-x11 nvidia-l4t-libvulkan nvidia-l4t-nvpmodel nvidia-l4t-tools nvidia-l4t-usb-service nvidia-l4t-nvfancontrol nvidia-l4t-configs nvidia-l4t-nvsci nvidia-l4t-pva nvidia-l4t-optee nvidia-l4t-openwfd"
PKGS_MEDIA="nvidia-l4t-multimedia nvidia-l4t-multimedia-nvgpu nvidia-l4t-multimedia-openrm nvidia-l4t-multimedia-utils nvidia-l4t-video-codec-openrm nvidia-l4t-camera nvidia-l4t-gstreamer"
PKGS_EXTRA="nvidia-l4t-jetson-io nvidia-l4t-nvpmodel-gui-tools nvidia-l4t-jetsonpower-gui-tools python3-jetson-gpio jetson-gpio-common nvidia-container-toolkit"
PKGS_DEB="gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gir1.2-ayatanaappindicator3-0.1 gir1.2-notify-0.7 gir1.2-gtk-3.0 python3-gi polkitd pkexec lxpolkit equivs cuda-nvrtc-13-2"

log "installing NVIDIA + supporting packages"
inchroot_sh <<EOT
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y /var/tmp/libpcre3.deb
apt-get install -y --no-install-recommends equivs gir1.2-ayatanaappindicator3-0.1
cd /var/tmp && equivs-build shim.ctl >/dev/null && dpkg -i gir1.2-appindicator3-0.1_*.deb
apt-get install -y --no-install-recommends $PKGS_CORE $PKGS_MEDIA $PKGS_EXTRA $PKGS_DEB
# NVIDIA's boot loader (L4TLauncher) for the EFI partition of a clean NVMe. Extracted from the package, NOT installed
# (installing it would stage firmware updates).
cd /var/tmp && apt-get download nvidia-l4t-bootloader
mkdir -p /usr/local/share/jetson-debian
dpkg-deb --fsys-tarfile nvidia-l4t-bootloader_*.deb | tar -xO ./opt/ota_package/t23x/BOOTAA64.efi > /usr/local/share/jetson-debian/BOOTAA64.efi
rm -f /var/tmp/nvidia-l4t-bootloader_*.deb
test -s /usr/local/share/jetson-debian/BOOTAA64.efi
dpkg --audit
EOT
log "NVIDIA stack installed: $(inchroot dpkg -l | grep -c '^ii  nvidia-l4t') nvidia-l4t packages, kernel $(kver)"
