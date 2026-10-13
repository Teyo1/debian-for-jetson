# Technical notes

How the pieces fit, and the things that cost time to find out. For install and build instructions see the README.

## Design in one paragraph

A plain Debian 13 root file system is built natively on a Jetson (`debootstrap`, no emulation). NVIDIA's Jetson Linux
packages (kernel, open GPU driver, firmware, CUDA runtime, multimedia, `nvpmodel`, `nvfancontrol`) are added from NVIDIA's
apt repository (`repo.download.nvidia.com/jetson`, suite `r39.2`). The result is packed into a USB image (GPT: FAT ESP with
GRUB + ext4 root). Booted from that stick, an installer copies the running system to the internal NVMe and sets up NVIDIA's
own boot chain there, so the installed system boots exactly like one installed by NVIDIA's installer.

## Boot chain (installed system)

UEFI in QSPI -> L4TLauncher (`EFI/BOOT/BOOTAA64.efi` on the NVMe ESP, partition 10; the file comes from the
`nvidia-l4t-bootloader` package) -> `/boot/extlinux/extlinux.conf` -> `/boot/Image`, `/boot/initrd`,
`/boot/dtb/kernel_<board>.dtb` (the device tree matching the running board, chosen with `fdtget`).

The USB stick is different: plain GRUB-EFI on the removable path. The Orin firmware boots standard GRUB from removable
media, which is also what NVIDIA's own installer ISO does.

NVIDIA's 15-partition GPT is applied to the NVMe (`APP` = partition 1, ext4 root; `esp` = partition 10). Same numbers as
NVIDIA's `ptable.orin.nvme.dynamic`.

## UEFI variables and boot slots

GUID `781e084c-a330-417c-b678-38e696380cb9`, variables `RootfsStatusSlotA` / `RootfsStatusSlotB`. A healthy system has data
byte `00`. If `RootfsStatusSlotA` is `0xFF`, the firmware refuses the normal boot and falls into recovery ("Android image
header not seen"). Reinstalling does not clear it. Fix from the UEFI shell:

```
set g 781e084c-a330-417c-b678-38e696380cb9
setvar RootfsStatusSlotA -guid %g% -nv -rt -bs =0x00000000
```

`nv-l4t-bootloader-config.service` does the slot bookkeeping, and it needs `/etc/nv_boot_control.conf`. The file is
generated on first boot from the firmware's own variables by `files/gen-nv-boot-control.sh` (`TEGRA_BOOT_STORAGE`
differs for NVMe and USB, so the installer never copies the stick's file). Never mask that service.

## The installer

`scripts/install-to-nvme.sh` is the engine; the wizard and the text interface both drive it. Steps: pick the target drive
(never the disk the system runs from), apply the partition table, make the file systems, install L4TLauncher, copy the
running system with `rsync` (leaving out installer-only files and the stick's `nv_boot_control.conf`), set the identity,
write `extlinux.conf` and the device tree, verify the result, then optionally install developer tools. Modes: wipe
(default), `--keep-layout` (replace only the root partition), `--dry-run`.

**Identity per install.** The default account is renamed to the chosen one (`passwd`, `shadow`, `group`, `gshadow`, home
directory), the password is hashed with `openssl passwd -6`, the host name is set, fresh SSH host keys are generated
(`ssh-keygen -A -f ROOT`) and `/etc/machine-id` is emptied so the new system creates its own.

**Time zone and keyboard.** `/etc/localtime`, `/etc/timezone`, `/etc/default/keyboard` and an Xorg `00-keyboard.conf`.
`console-setup` turns the XKB layout into a console keymap on boot, so the text console follows the layout too. Layouts
that cannot type a Latin password (Arabic, Russian, Dzongkha and others) get US added as a second layout, Alt+Shift
switches; the chosen layout stays first.

**After the copy.** The installer ends by remounting the stick read-only and restarting the board through
`/proc/sysrq-trigger` (shell built-ins only), so the stick can be pulled safely. `systemctl reboot` is not used there: it
needs files on the stick that are gone by then.

**Optional developer tools.** `nvidia-cuda-dev`, `nvidia-cudnn`, TensorRT libraries and `libnvinfer-bin` (`trtexec`) are
fetched from NVIDIA's repository inside a chroot, after the base system has been verified. Failure is never fatal. The
availability check requests `.../jetson/common/dists/r39.2/InRelease`: the repository's root URL answers 404.

**Log.** Everything the installer prints is kept in `/var/log/jetson-install.log` on the new system.

## The graphical installer

`files/jetson-install-gui` (Python, GTK 3) collects the answers and runs the engine with `--gui`. The session is started by
`jetson-installer-gui.service` when the kernel command line has `jetson.install-gui`, and by nothing else. The service, the
session script and the wizard are left out of the copy, so the installed system contains no installer.

Things that had to be learned:

- **A bare X server needs a window manager.** Without one there is no keyboard focus, no highlighted control, the mouse can
  seem dead and the cursor can be invisible. The session starts `xfwm4` inside the same `dbus-run-session` as the wizard.
- **Display driver race.** On some boots Xorg starts before the NVIDIA display driver is ready ("Failed to initialize the NVIDIA
  graphics device"). The session waits for `/dev/dri/card*`, retries Xorg up to four times, and runs a watchdog that expects
  the wizard to report ready within 90 seconds. If everything fails it prints the X errors and starts the text installer.
- **Size.** With no window manager to do it, the window sizes itself to the monitor; fonts scale with the screen height.
- **Do not leave files open on the stick.** The installer log lives on `/run`, and X logs to `/run`, so the stick can be
  remounted read-only at the end.

## Debian versus Ubuntu userland

NVIDIA's packages target Ubuntu 24.04 (glibc 2.39), so Debian 13 is the oldest Debian that works. Fixed in `files/` and
`scripts/03`/`04`: `libpcre3` from the Debian 12 archive, the power-mode tray applet moved from AppIndicator3 to Ayatana
through a shim package, a bash-ism removed from `/etc/skel/.xsessionrc`. These are re-applied after every apt run.

Not installable on Debian 13 (checked with `apt-get -s`): the `nvidia-jetpack` meta packages, NVIDIA's TensorRT and VPI Python
bindings (need Python 3.12) and NVIDIA's OpenCV build (needs Ubuntu's ffmpeg 6 libraries).

## How NVIDIA's own installer works (for reference)

Read from the installer ISO. It is Ubuntu Server's Subiquity autoinstall: it keeps NVIDIA's 15-partition layout and formats
only partition 1, writes `/etc/nv_boot_control.conf`, installs Ubuntu packages from an offline pool, removes GRUB from the
installed system and puts L4TLauncher on the ESP, writes `extlinux.conf` and the device tree seed, and fixes the EFI boot
order. The live installer boots with `clk_ignore_unused pd_ignore_unused`; the installed system does not use them.
This project copies the boot-related steps and swaps the Ubuntu userland for Debian.

## Smaller gotchas

IPv4-only networks need `-4` for some downloads; `nspawn` needs a real `/tmp`; the UEFI shell's ext4 driver is read-only
(FAT is writable); the extlinux menu only shows for its `TIMEOUT`; the Orin Nano dev kit's USB-C port is a device port, so
use a USB-A port for the stick; `systemctl poweroff` on this board restarts instead of powering off in some situations.
After each reinstall the SSH host key changes: `ssh-keygen -R <address>`.

## Not done / ideas

A clickable time zone map; a netinstall mode; a firmware (QSPI) update helper (updates are deliberately manual); a build
mode for a PC; a licence (undecided).
