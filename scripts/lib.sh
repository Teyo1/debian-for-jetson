# shared helpers; sourced by every script
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/config.env"
[ "$(id -u)" = 0 ] || { echo "run as root: sudo $0"; exit 1; }
[ "$(uname -m)" = aarch64 ] || { echo "must run natively on an arm64 Jetson"; exit 1; }
# run a command inside the rootfs (--pipe: no tty needed, works over ssh)
inchroot() { systemd-nspawn --pipe -q -D "$ROOTFS" "$@" < /dev/null; }
# run a script from stdin inside the rootfs
inchroot_sh() { systemd-nspawn --pipe -q -D "$ROOTFS" /bin/bash -s; }
kver() { ls "$ROOTFS/lib/modules" | head -1; }
log() { printf '\n==> %s\n' "$*"; }
