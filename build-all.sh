#!/usr/bin/env bash
# Runs the whole pipeline on a Jetson that already boots. Usage: sudo ./build-all.sh
set -euo pipefail
cd "$(dirname "$0")"
for s in 01-prepare-host 02-build-rootfs 03-add-nvidia 04-configure; do
  echo; echo "################ $s ################"
  scripts/$s.sh
done
echo; echo "BUILD COMPLETE: $(. ./config.env; echo "$ROOTFS")"
