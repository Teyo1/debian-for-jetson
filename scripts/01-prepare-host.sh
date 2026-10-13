#!/usr/bin/env bash
# Prepare the build Jetson (must already boot, e.g. NVIDIA's stock Ubuntu image).
. "$(dirname "$0")/lib.sh"
log "installing build tools"
apt-get install -y debootstrap systemd-container debian-archive-keyring
# Many home networks have a broken IPv6 route to deb.debian.org -> 2 minute timeouts per file.
log "forcing IPv4 for apt/wget"
echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99ipv4
grep -q inet4_only /etc/wgetrc || echo "inet4_only = on" >> /etc/wgetrc
echo "inet4_only = on" > /root/.wgetrc
apt-get install -y curl gnupg rsync
log "done"
