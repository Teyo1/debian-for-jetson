#!/usr/bin/env bash
# Installs the RUNNING Debian system (booted from a USB stick) onto the internal NVMe, following the steps
# NVIDIA's own installer uses (see NOTES.md).
#
#   sudo install-to-nvme --dry-run   show the plan, change nothing
#   sudo install-to-nvme             WIPES THE WHOLE NVMe, creates NVIDIA's partition layout, installs. Back up first.
#   sudo install-to-nvme --keep-layout   expert: keep NVIDIA's existing layout and replace only partition "APP"
set -euo pipefail
DRY=0; KEEPLAYOUT=0; AUTO=0; GUI=0
for a in "$@"; do case "$a" in --dry-run) DRY=1;; --keep-layout) KEEPLAYOUT=1;; --auto) AUTO=1;; --gui) AUTO=1; GUI=1;; *) echo "unknown option $a"; exit 1;; esac; done
[ "$(id -u)" = 0 ] || { echo "run as root: sudo install-to-nvme"; exit 1; }
INSTALL_LOG=/run/jetson-install.log   # tmpfs: an open log file on the stick would keep it from being remounted read-only
[ $DRY = 1 ] || exec > >(tee -a "$INSTALL_LOG") 2>&1   # a copy goes to /var/log/jetson-install.log on the new system
G=781e084c-a330-417c-b678-38e696380cb9
LAUNCHER_SRC=/usr/local/share/jetson-debian/BOOTAA64.efi
say() { printf '\n==> %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# >>> identity
# apply_identity ROOT DEFUSER NEWUSER NEWPASS NEWHOST
# Renames the default account, sets its password, sets the hostname and gives the new system its OWN identity
# (fresh SSH host keys, empty machine-id that systemd fills in on first boot). Edits files directly under ROOT,
# so it also works while the default user is logged in on the stick.
apply_identity() {
  local R=$1 DEF=$2 NU=$3 NP=$4 NH=$5
  if [ "$NU" != "$DEF" ]; then
    sed -i "s/^$DEF:/$NU:/" "$R/etc/passwd" "$R/etc/shadow" "$R/etc/group" "$R/etc/gshadow"
    sed -i -E "s/([:,])$DEF(,|\$)/\1$NU\2/g" "$R/etc/group" "$R/etc/gshadow"
    sed -i -E "s#^($NU:[^:]*:[^:]*:[^:]*:[^:]*:)/home/$DEF:#\1/home/$NU:#" "$R/etc/passwd"
    sed -i "s/:$DEF,,,:/:$NU,,,:/" "$R/etc/passwd"
    if [ -d "$R/home/$DEF" ]; then mv "$R/home/$DEF" "$R/home/$NU"; fi
    { grep -rIl "/home/$DEF" "$R/home/$NU" 2>/dev/null || true; } | xargs -r sed -i "s#/home/$DEF#/home/$NU#g"
  fi
  if [ -n "$NP" ]; then
    local HASH; HASH=$(printf '%s' "$NP" | openssl passwd -6 -stdin)
    HASH="$HASH" awk -F: -v OFS=: -v u="$NU" -v d="$(( $(date +%s) / 86400 ))" \
      '$1==u { $2=ENVIRON["HASH"]; $3=d } { print }' "$R/etc/shadow" > "$R/etc/shadow.new"
    chmod --reference="$R/etc/shadow" "$R/etc/shadow.new"; mv "$R/etc/shadow.new" "$R/etc/shadow"
  fi
  echo "$NH" > "$R/etc/hostname"
  if grep -q '^127\.0\.1\.1' "$R/etc/hosts" 2>/dev/null; then sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$NH/" "$R/etc/hosts"
  else printf '127.0.1.1\t%s\n' "$NH" >> "$R/etc/hosts"; fi
  rm -f "$R"/etc/ssh/ssh_host_*; ssh-keygen -A -f "$R" >/dev/null
  : > "$R/etc/machine-id"
}
# <<< identity

# >>> devtools
# install_devtools ROOT "cuda cudnn tensorrt": optional NVIDIA developer packages, fetched from NVIDIA's apt repository.
# Never fatal: the system is already complete and bootable when this runs.
install_devtools() {
  local R=$1 W=$2 PK="" w
  for w in $W; do case "$w" in
    cuda) PK="$PK nvidia-cuda-dev";;
    cudnn) PK="$PK nvidia-cudnn";;
    tensorrt) PK="$PK nvidia-tensorrt libnvinfer-dev libnvinfer-plugin-dev libnvonnxparsers-dev libnvinfer-bin";;
  esac; done
  local HOWTO="sudo apt update && sudo apt install$PK"
  if ! curl -fsI --max-time 10 https://repo.download.nvidia.com/jetson/common/dists/r39.2/InRelease >/dev/null 2>&1; then
    echo "  [skipped] no internet connection. Add them later with:  $HOWTO"; return 0
  fi
  local RC; RC=$(cat "$R/etc/resolv.conf" 2>/dev/null || true)
  cp /etc/resolv.conf "$R/etc/resolv.conf" 2>/dev/null || true
  mount --bind /dev "$R/dev"; mount --bind /dev/pts "$R/dev/pts"; mount -t proc proc "$R/proc"; mount -t sysfs sys "$R/sys"
  if chroot "$R" apt-get update >/dev/null 2>&1 && chroot "$R" env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $PK; then
    case " $W " in *" cuda "*) printf 'export PATH=/usr/local/cuda/bin${PATH:+:$PATH}\n' > "$R/etc/profile.d/jetson-cuda.sh";; esac
    echo "  [ ok ] developer tools installed: $W"
  else
    echo "  [WARNING] the download did not finish. The system itself is fine. Add them later with:  $HOWTO"
  fi
  for d in sys proc dev/pts dev; do umount "$R/$d" 2>/dev/null || true; done
  printf '%s\n' "$RC" > "$R/etc/resolv.conf"
  chroot "$R" apt-get clean >/dev/null 2>&1 || true
}
# <<< devtools

# >>> prefs
# apply_prefs ROOT TIMEZONE KEYBOARD_LAYOUT
apply_prefs() {
  local R=$1 TZN=$2 KB=$3
  if [ -n "$TZN" ]; then ln -sf "/usr/share/zoneinfo/$TZN" "$R/etc/localtime"; echo "$TZN" > "$R/etc/timezone"; fi
  if [ -n "$KB" ]; then
    # Non-Latin layouts: the chosen layout stays first and active; US is added as a second one, Alt+Shift switches.
    local LAYOUTS=$KB OPTS=""
    case " am ara bd bg bt by ge gr il in ir iq kg kh kz la lk mk mm mn mv np pk ru rs sy th tj ua uz af et ma " in
      *" $KB "*) LAYOUTS="$KB,us"; OPTS="grp:alt_shift_toggle";; esac
    mkdir -p "$R/etc/default"
    printf 'XKBMODEL="pc105"\nXKBLAYOUT="%s"\nXKBVARIANT=""\nXKBOPTIONS="%s"\n\nBACKSPACE="guess"\n' "$LAYOUTS" "$OPTS" > "$R/etc/default/keyboard"
    mkdir -p "$R/etc/X11/xorg.conf.d"
    { printf 'Section "InputClass"\n        Identifier "system-keyboard"\n        MatchIsKeyboard "on"\n        Option "XkbLayout" "%s"\n        Option "XkbModel" "pc105"\n' "$LAYOUTS"
      [ -z "$OPTS" ] || printf '        Option "XkbOptions" "%s"\n' "$OPTS"
      printf 'EndSection\n'; } > "$R/etc/X11/xorg.conf.d/00-keyboard.conf"
  fi
}
# <<< prefs
for t in sgdisk sfdisk partprobe wipefs mkfs.ext4 mkfs.vfat rsync fdtget xxd blkid lsblk findmnt openssl awk ssh-keygen; do
  command -v $t >/dev/null 2>&1 || die "missing tool: $t (sudo apt install gdisk fdisk parted e2fsprogs dosfstools rsync device-tree-compiler xxd)"
done
ROOTDEV=$(findmnt -n -o SOURCE /)
ROOTDISK=$(lsblk -no PKNAME "$ROOTDEV" 2>/dev/null | head -1)
CANDS=(); for d in /dev/nvme[0-9]*n1; do [ -b "$d" ] && [ "$(basename "$d")" != "$ROOTDISK" ] && CANDS+=("$d"); done
[ ${#CANDS[@]} -gt 0 ] || die "no NVMe drive to install to (none found, or the system is running from the only one; boot from the USB stick)"
NVME=${JETSON_TARGET:-}
if [ -z "$NVME" ]; then
  if [ ${#CANDS[@]} -eq 1 ]; then NVME=${CANDS[0]}
  elif [ -t 0 ]; then
    echo "NVMe drives found:"; i=1
    for d in "${CANDS[@]}"; do echo "  $i) $d  $(lsblk -dno SIZE,MODEL "$d")"; i=$((i+1)); done
    while :; do read -r -p "Install to which drive? [1-${#CANDS[@]}]: " N
      [[ $N =~ ^[0-9]+$ ]] && [ "$N" -ge 1 ] && [ "$N" -le ${#CANDS[@]} ] && break; done
    NVME=${CANDS[$((N-1))]}
  else die "several NVMe drives found; set JETSON_TARGET=/dev/nvmeXn1"; fi
fi
[ -b "$NVME" ] || die "no $NVME found"
case " ${CANDS[*]} " in *" $NVME "*) ;; *) die "$NVME cannot be used (it is not an NVMe drive, or it is the drive this system runs from)";; esac

# --- NVIDIA's partition table for the Orin NVMe (sectors of 512 B). Same numbers as NVIDIA's installer. ---
ptable() { cat <<'PT'
label: gpt
unit: sectors
first-lba: 40
sector-size: 512

start=3131968,                 type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name="APP"
start=40,      size=262144,    type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name="A_kernel"
start=262184,  size=1536,      type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name="A_kernel-dtb"
start=263720,  size=64768,     type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name="reserved_for_chain_A_user"
start=328488,  size=262144,    type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name="B_kernel"
start=590632,  size=1536,      type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name="B_kernel-dtb"
start=592168,  size=64768,     type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name="reserved_for_chain_B_user"
start=656936,  size=204800,    type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name="recovery"
start=861736,  size=1024,      type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name="recovery-dtb"
start=862760,  size=131072,    type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="esp"
start=993832,  size=204800,    type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name="recovery_alt"
start=1198632, size=1024,      type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name="recovery-dtb_alt"
start=1199656, size=131072,    type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name="esp_alt"
start=1330752, size=819200,    type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name="UDA"
start=2149952, size=982016,    type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name="reserved"
PT
}

# --- decide the mode ---
APP=$(lsblk -nrpo NAME,PARTLABEL "$NVME" | awk '$2=="APP"{print $1}')
ESP=$(lsblk -nrpo NAME,PARTLABEL "$NVME" | awk '$2=="esp"{print $1}')
MODE=wipe
if [ $KEEPLAYOUT = 1 ]; then
  [ -b "${APP:-}" ] && [ -b "${ESP:-}" ] || die "--keep-layout needs NVIDIA's layout on the NVMe (partitions APP and esp); run without it to wipe and create it"
  MODE=app
fi
[ -s "$LAUNCHER_SRC" ] || [ $MODE = app ] || die "$LAUNCHER_SRC missing (needed to make a clean drive bootable); rebuild the image with the current scripts"

# --- device tree matching this board (L4TLauncher needs /boot/dtb/kernel_<board>.dtb) ---
RC=$(tr '\0' ' ' </proc/device-tree/compatible | xargs); RM=$(tr '\0' ' ' </proc/device-tree/model | xargs)
DTB=""
for f in /boot/*-nv*.dtb; do
  [ -e "$f" ] || continue
  if [ "$(fdtget "$f" / compatible | xargs)" = "$RC" ] && [ "$(fdtget "$f" / model | xargs)" = "$RM" ]; then DTB="$f"; break; fi
done
[ -n "$DTB" ] || die "no matching board .dtb in /boot for: $RM"

echo "Running system : $ROOTDEV"
echo "NVMe           : $NVME $(lsblk -dno SIZE,MODEL $NVME)"
lsblk -o NAME,SIZE,FSTYPE,PARTLABEL "$NVME"
echo
if [ $MODE = app ]; then
  echo "Mode           : REPLACE the system partition only"
  echo "Will ERASE     : $APP  (partition APP)"
  echo "Will NOT touch : the other partitions, incl. firmware/recovery and the EFI partition $ESP"
else
  echo "Mode           : WIPE THE WHOLE DRIVE and create NVIDIA's partition layout"
  echo "Will ERASE     : EVERYTHING on $NVME  (back up anything you need before continuing)"
fi
echo "Board device tree : $(basename "$DTB")"
SA=$(xxd -p -s4 -l1 /sys/firmware/efi/efivars/RootfsStatusSlotA-$G 2>/dev/null || echo "??")
echo "RootfsStatusSlotA : 0x$SA  ($([ "$SA" = 00 ] && echo healthy || echo "NOT 00 - the board may refuse to boot; see NOTES.md"))"
if [ $MODE = app ]; then
  M=$(mktemp -d); mount -o ro "$ESP" "$M"
  if [ -s "$M/EFI/BOOT/BOOTAA64.efi" ] || [ -s "$M/EFI/BOOT/bootaa64.efi" ]; then echo "EFI partition  : NVIDIA boot loader present"; else
    umount "$M"; rmdir "$M"; [ -s "$LAUNCHER_SRC" ] || die "EFI partition has no boot loader and none is bundled; rebuild the image and run without --keep-layout"
    echo "EFI partition  : boot loader missing; will be restored from $LAUNCHER_SRC"; M=""; fi
  [ -n "$M" ] && { umount "$M"; rmdir "$M"; }
fi
[ $DRY = 1 ] && { echo; echo "(dry run: nothing was changed)"; exit 0; }

# --- account for the new system: asked before the erase confirmation, so that confirmation is the last prompt ---
DEFUSER=$(getent passwd 1000 | cut -d: -f1)
NEWUSER=${JETSON_USER:-$DEFUSER}; NEWHOST=${JETSON_HOSTNAME:-$(cat /etc/hostname)}; NEWPASS=${JETSON_PASSWORD:-}
NEWTZ=${JETSON_TIMEZONE:-}; NEWKBD=${JETSON_KEYBOARD:-}
NEWSSH=${JETSON_SSH:-0}              # remote login over SSH: off unless asked for
NEWDEV=${JETSON_DEVTOOLS:-}          # any of: cuda cudnn tensorrt (downloaded from NVIDIA, needs internet)
if [ -t 0 ] && [ -z "${JETSON_USER:-}${JETSON_PASSWORD:-}" ]; then
  echo; echo "Account for the new system (press Enter to keep the value in brackets)"
  while :; do
    read -r -p "  Username [$DEFUSER]: " A; A=${A:-$DEFUSER}
    if ! [[ $A =~ ^[a-z_][a-z0-9_-]{0,30}$ ]]; then echo "  Use lowercase letters, digits, - and _, starting with a letter."
    elif [ "$A" != "$DEFUSER" ] && getent passwd "$A" >/dev/null; then echo "  That name is already used by the system."
    else break; fi
  done; NEWUSER=$A
  while :; do
    read -r -s -p "  Password (at least 8 characters): " P1; echo
    read -r -s -p "  Repeat the password: " P2; echo
    [ "$P1" = "$P2" ] && [ ${#P1} -ge 8 ] && break
    echo "  The passwords differ or are shorter than 8 characters."
  done; NEWPASS=$P1
  while :; do
    read -r -p "  Hostname [$NEWHOST]: " H; H=${H:-$NEWHOST}
    [[ $H =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] && break
    echo "  Use letters, digits and - only."
  done; NEWHOST=$H
  DEFTZ=$(cat /etc/timezone 2>/dev/null || echo Etc/UTC)
  while :; do
    read -r -p "  Time zone, e.g. Europe/Helsinki [$DEFTZ]: " Z; Z=${Z:-$DEFTZ}
    [ -f "/usr/share/zoneinfo/$Z" ] && break
    echo "  Unknown time zone. Use the form Region/City (list: ls /usr/share/zoneinfo)."
  done; NEWTZ=$Z
  DEFKB=$(sed -n 's/^XKBLAYOUT="\(.*\)"/\1/p' /etc/default/keyboard 2>/dev/null | head -1); DEFKB=${DEFKB:-us}
  while :; do
    read -r -p "  Keyboard layout, e.g. us, fi, se, de, gb [$DEFKB]: " K; K=${K:-$DEFKB}
    if [ -r /usr/share/X11/xkb/rules/base.lst ]; then
      awk -v L="$K" '/^! layout/{f=1;next} /^!/{f=0} f && $1==L {ok=1} END{exit !ok}' /usr/share/X11/xkb/rules/base.lst && break
    else [[ $K =~ ^[a-z]{2,10}$ ]] && break; fi
    echo "  Unknown layout code (list: /usr/share/X11/xkb/rules/base.lst, section 'layout')."
  done; NEWKBD=$K
  read -r -p "  Allow remote login over the network (SSH)? [y/N]: " Y; case "$Y" in [yY]*) NEWSSH=1;; *) NEWSSH=0;; esac
  echo "  Optional NVIDIA developer tools, downloaded during the install (needs internet):"
  echo "    cuda = CUDA compiler and libraries (about 3.3 GB), cudnn = cuDNN (0.4 GB), tensorrt = TensorRT (4.5 GB)"
  read -r -p "  Which ones? e.g. cuda cudnn  [Enter for none]: " NEWDEV
fi
for w in $NEWDEV; do case "$w" in cuda|cudnn|tensorrt) ;; *) die "unknown developer tool '$w' (use: cuda cudnn tensorrt)";; esac; done
if [ -z "$NEWPASS" ]; then echo "Account        : $NEWUSER, default password (you must change it at first login)"
else echo "Account        : $NEWUSER, hostname $NEWHOST"; fi
echo "Remote login   : $([ "$NEWSSH" = 1 ] && echo 'SSH on' || echo 'SSH off')    Developer tools: ${NEWDEV:-none}"

echo
if [ $MODE = wipe ]; then WORD="ERASE-ALL"; else WORD="ERASE"; fi
if [ $GUI = 1 ]; then
  : # the graphical wizard has already asked
elif [ $AUTO = 1 ]; then
  echo; echo "  This will ERASE EVERYTHING on the NVMe. To cancel, switch the Jetson off now."
  read -r -p "  Press Enter to ERASE the NVMe and install Debian: " _ANS
else
  read -r -p "Type $WORD to continue: " ANS; [ "$ANS" = "$WORD" ] || { echo aborted; exit 1; }
fi

# --- 1. partitions ---
if [ $MODE = wipe ]; then
  say "creating NVIDIA's partition layout on $NVME"
  wipefs -a "$NVME" >/dev/null; sgdisk -Z "$NVME" >/dev/null 2>&1 || true
  ptable | sfdisk "$NVME" >/dev/null
  partprobe "$NVME"; sleep 3
  APP=${NVME}p1; ESP=${NVME}p10
  [ "$(lsblk -no PARTLABEL "$APP")" = APP ] && [ "$(lsblk -no PARTLABEL "$ESP")" = esp ] || die "partition table was not created as expected; do not reboot, tell the developer"
  mkfs.vfat -F32 -n ESP "$ESP" >/dev/null
fi
say "formatting $APP"
PN=$(echo "$APP" | grep -o '[0-9]*$')
NEWGUID=$(cat /proc/sys/kernel/random/uuid)
sgdisk -u "$PN":"$NEWGUID" "$NVME" >/dev/null; partprobe "$NVME"; sleep 2
mkfs.ext4 -q -F -L APP "$APP"
FSUUID=$(blkid -s UUID -o value "$APP"); ESPUUID=$(blkid -s UUID -o value "$ESP")
T=/mnt/nvme-target; mkdir -p $T; mount "$APP" $T
trap 'umount $T/boot/efi 2>/dev/null; umount $T 2>/dev/null' EXIT

# --- 2. EFI partition: NVIDIA's boot loader ---
mkdir -p $T/boot/efi; mount "$ESP" $T/boot/efi
if ! { [ -s $T/boot/efi/EFI/BOOT/BOOTAA64.efi ] || [ -s $T/boot/efi/EFI/BOOT/bootaa64.efi ]; }; then
  say "installing NVIDIA's boot loader (L4TLauncher) on the EFI partition"
  mkdir -p $T/boot/efi/EFI/BOOT; cp -f "$LAUNCHER_SRC" $T/boot/efi/EFI/BOOT/BOOTAA64.efi
fi
umount $T/boot/efi

# --- 3. copy the system ---
say "copying the system (several minutes)"
rsync -aHAX --numeric-ids --info=progress2 \
  --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' --exclude='/run/*' --exclude='/tmp/*' \
  --exclude='/mnt/*' --exclude='/boot/efi/*' --exclude='/boot/grub' --exclude='/lost+found' --exclude='/etc/nv_boot_control.conf' --exclude='/etc/systemd/system/jetson-installer.service' --exclude='/etc/systemd/system/multi-user.target.wants/jetson-installer.service' --exclude='/etc/systemd/system/jetson-installer-gui.service' --exclude='/etc/systemd/system/multi-user.target.wants/jetson-installer-gui.service' --exclude='/usr/local/sbin/jetson-install-gui' --exclude='/usr/local/sbin/jetson-install-session' / $T/
mkdir -p $T/{proc,sys,dev,run,tmp,mnt,boot/efi}; chmod 1777 $T/tmp

# --- 4. fstab ---
cat > $T/etc/fstab <<EOT
UUID=$FSUUID  /          ext4  defaults,rw        0  1
UUID=$ESPUUID /boot/efi  vfat  umask=0077,nofail  0  2
EOT

say "setting up the account and the identity of the new system"
apply_identity "$T" "$DEFUSER" "$NEWUSER" "$NEWPASS" "$NEWHOST"
apply_prefs "$T" "$NEWTZ" "$NEWKBD"
if [ "$NEWSSH" != 1 ]; then
  systemctl --root="$T" disable ssh.service >/dev/null 2>&1 || rm -f "$T/etc/systemd/system/multi-user.target.wants/ssh.service"
fi

# --- 5. boot config exactly as NVIDIA's installer writes it ---
say "boot configuration"
mkdir -p $T/boot/extlinux $T/boot/dtb
cat > $T/boot/extlinux/extlinux.conf <<EOT
TIMEOUT 30
DEFAULT primary

MENU TITLE L4T boot options

LABEL primary
      MENU LABEL primary kernel
      LINUX /boot/Image
      INITRD /boot/initrd
      APPEND \${cbootargs} root=PARTUUID=$NEWGUID rw rootwait rootfstype=ext4 mminit_loglevel=4 console=ttyTCU0,115200 firmware_class.path=/etc/firmware fbcon=map:0 video=efifb:off efi_pstore.pstore_disable=1 pstore.backend=ramoops efi=runtime pci=pcie_bus_perf nvme.use_threaded_interrupts=1
EOT
cp -f "$DTB" "$T/boot/dtb/kernel_$(basename "$DTB")"

# --- 6. sanity check before finishing ---
say "checking the result"
BAD=0
chkf() { if [ -e "$1" ] || [ -L "$1" ]; then printf '  [ ok ] %s\n' "${1#$T/}"; else printf '  [FAIL] %s\n' "${1#$T/}"; BAD=1; fi; }
for f in boot/Image boot/initrd boot/extlinux/extlinux.conf "boot/dtb/kernel_$(basename "$DTB")" sbin/init etc/fstab; do chkf "$T/$f"; done
[ -s "$T/boot/initrd" ] || { echo "  [FAIL] initrd link is broken"; BAD=1; }
mount "$ESP" $T/boot/efi; chkf "$T/boot/efi/EFI/BOOT/BOOTAA64.efi"; umount $T/boot/efi
[ $BAD = 0 ] || die "the new system is incomplete; do NOT reboot, tell the developer"
if [ -n "$NEWDEV" ]; then say "developer tools from NVIDIA (several minutes; needs internet)"; install_devtools "$T" "$NEWDEV"; fi
mkdir -p "$T/var/log"; tr '\r' '\n' < "$INSTALL_LOG" | grep -v "xfr#" > "$T/var/log/jetson-install.log" 2>/dev/null || true
sync; umount $T; trap - EXIT
echo; echo "Done. The system is installed on the NVMe."
[ $AUTO = 1 ] || echo "Shut down (sudo poweroff), REMOVE the USB stick, then power on: the Jetson boots Debian from the NVMe."
if [ $AUTO = 1 ]; then
  # The installer runs from the USB stick, so after the stick is pulled nothing may be read from disk.
  # Make the stick read-only, silence kernel messages, and restart through the kernel (shell builtins only).
  mount -o remount,ro / 2>/dev/null || true
  echo 1 > /proc/sys/kernel/printk 2>/dev/null || true
  if [ $GUI = 1 ]; then echo "INSTALL-COMPLETE"; exit 0; fi   # the wizard asks to remove the stick and restarts the board
  echo; read -r -p "Remove the USB stick now, then press Enter to restart into the new system: " _ANS
  echo 1 > /proc/sys/kernel/sysrq 2>/dev/null || true
  echo b > /proc/sysrq-trigger 2>/dev/null || true
  echo "Could not restart automatically. Remove the stick and switch the Jetson off and on."
  while true; do read -r -t 3600 _ANS || true; done
fi
echo "If it does not boot: put the stick back, boot from it via the firmware Boot Manager, and ask for help."
