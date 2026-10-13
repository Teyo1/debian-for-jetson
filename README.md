# Debian 13 on Jetson Orin Nano (NVMe, no Ubuntu)

Builds a **plain Debian 13 (trixie)** system that runs NVIDIA's own Jetson Linux kernel,
open GPU driver and CUDA runtime (L4T R39.2.1), and installs it onto the internal NVMe
from a USB stick with a graphical installer. No Ubuntu or Canonical packages end up on the
final system, and no SD card or Ubuntu host PC is needed.

Tested on: **Jetson Orin Nano Developer Kit Super (P3767/P3768, 8 GB)** with a 1 TB NVMe,
firmware already updated to the R39 line (the one NVIDIA's own installer ISO installs).
That is one board: see "Tested and not tested" below.

> Unofficial. Not affiliated with or supported by NVIDIA. The installer **wipes the whole NVMe**.

## What you get

- Debian 13 arm64, XFCE desktop, LightDM, NetworkManager, zram swap
- NVIDIA kernel (6.8.12-tegra), open GPU driver, firmware, CUDA runtime libraries, `nvpmodel`,
  `nvfancontrol`, the power-mode tray icon (patched for Debian and XFCE)
- GStreamer with NVIDIA's hardware decoder (the Orin Nano has no hardware video *encoder*)
- NVIDIA's boot chain, laid out exactly like NVIDIA's installer: L4TLauncher on the ESP,
  `extlinux.conf`, NVIDIA's 15-partition GPT. Boot-slot bookkeeping
  (`nv-l4t-bootloader-config`) works.
- Your own account, computer name, time zone and keyboard layout: there is no default password.
- SSH server installed but **off** unless you tick it in the installer.
- Optional NVIDIA developer tools (see below), downloaded during the install if you ask for them.

## Install

1. Write the image to a USB stick of at least 8 GB: **Raspberry Pi Imager** ("Use custom", pick
   `jetson-debian.img.xz`) or `xz -dc jetson-debian.img.xz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress`.
   Check the device name with `lsblk` first. `dd` overwrites whatever is on the target.
2. Plug the stick into a USB-A port of the Jetson (the USB-C port is a device port, not a host port).
3. **Power the Jetson off completely, then power it on.** With the stick in, it boots the stick and shows the
   GRUB menu. If you *restart* a running Jetson instead, it goes through the UEFI menu: pick the USB stick there.
4. Leave the first GRUB entry, **INSTALL Debian 13 (graphical)**, to start by itself. The wizard asks:
   country (sets the time zone), keyboard layout, username and password, computer name, and the options page
   (SSH, developer tools). The last page lists everything and needs a tick before it erases the drive.
5. When it says the system is installed, **pull the USB stick, then press Restart.** The Jetson boots Debian
   from the NVMe and asks nothing more.

If several NVMe drives are present, the wizard asks which one to use (none is pre-selected).

### Optional NVIDIA developer tools

On the options page you can add, downloaded from NVIDIA's package server during the install (needs internet):

| Option | Download | What it gives you |
|---|---|---|
| CUDA | about 3.3 GB | `nvcc`, CUDA libraries and headers (in `/usr/local/cuda`, on the PATH of login shells) |
| cuDNN | about 0.4 GB | cuDNN 9 |
| TensorRT | about 4.5 GB | TensorRT libraries, headers, `trtexec` |

If the download fails or there is no internet, the install still finishes and boots; the installer prints the
exact command to run later, for example `sudo apt update && sudo apt install nvidia-cuda-dev`. A plain
`apt upgrade` never adds these on its own.

NVIDIA builds some JetPack parts for Ubuntu 24.04, so **the `nvidia-jetpack` meta package does not install on
Debian 13**. Not available here: NVIDIA's TensorRT and VPI Python bindings and NVIDIA's OpenCV build.
(Debian's own OpenCV works without GPU support; PyTorch wheels bring their own CUDA runtime.)

### Text-mode installer (fallback)

If the graphical session cannot start, the stick falls back to the text installer by itself. You can also choose it
under **Advanced options** in the GRUB menu, together with the text installer rotated by 90 or 270 degrees (monitor on
its side), a rescue shell and a debug shell. From a shell on the stick,
`sudo install-to-nvme --dry-run` shows what it would do and changes nothing. Settings can also be passed as
environment variables: `JETSON_USER`, `JETSON_PASSWORD`, `JETSON_HOSTNAME`, `JETSON_TIMEZONE`, `JETSON_KEYBOARD`,
`JETSON_TARGET` (e.g. `/dev/nvme1n1`), `JETSON_SSH` (`1` to enable SSH) and `JETSON_DEVTOOLS`
(any of `cuda cudnn tensorrt`).

### Reporting a problem

The installer keeps its log on the new system: `/var/log/jetson-install.log`. Attach it to a bug report together
with your board, NVMe model and firmware version.

## Build (on the Jetson itself, natively; no emulation)

Needs an Orin running any Debian/Ubuntu-style system with network, about 20 GB free, and root.

```
sudo ./build-all.sh                                              # rootfs in /srv/debian-trixie
sudo ROOTFS=/srv/debian-trixie scripts/06-make-image.sh ~/jetson-debian.img
sudo scripts/verify-image.sh ~/jetson-debian.img                 # read-only checks, must say "all checks passed"
```

`build-all.sh` runs `scripts/01..04`: host prep, `debootstrap`, NVIDIA's apt repo
(`repo.download.nvidia.com/jetson`, key fingerprint checked) and Debian-compatibility fixes,
then system configuration. The stick's own login (used only for rescue shells) is set in `config.env`.

A rebuild gives the same recipe, but not a byte-identical image: package versions and timestamps change, so
its checksum will differ from the one of the published release.

## Layout of this repository

| Path | Purpose |
|---|---|
| `config.env` | suite, mirror, L4T release, hostname, locale |
| `build-all.sh`, `scripts/01-04` | build the rootfs |
| `scripts/06-make-image.sh` | USB image: GPT, ESP, root, GRUB (removable), installer session |
| `scripts/verify-image.sh` | read-only pre-flight checks on an image |
| `scripts/install-to-nvme.sh` | the installer engine shipped inside the image |
| `files/jetson-install-gui` | the graphical wizard (Python, GTK 3) |
| `files/` | boot-control generator, fixups, kernel arguments, tray icon |
| `docs/NOTES.md` | everything learned: boot chain, UEFI variables, failures and fixes |

## Tested and not tested

Tested on hardware (one Jetson Orin Nano Developer Kit Super 8 GB, R39.2.1): clean and previously used NVMe,
graphical and text installers, cold boot and restart paths, several countries and keyboard layouts (the layout
reaches the desktop, the login screen and the text console), SSH on and off, optional CUDA/cuDNN/TensorRT
download, boot from the NVMe after install, GPU compute with a CUDA program.

Not tested: two NVMe drives in one machine, other monitors and resolutions, most keyboard layouts and
countries, other Jetson models.

## Things worth knowing

- **Boot slots.** If the UEFI variables `RootfsStatusSlotA/B` hold `0xFF`, the firmware refuses
  the normal boot and falls into recovery ("Android image header not seen"). Fix from the UEFI shell
  with `setvar`; see `docs/NOTES.md`. After a healthy boot both read `0`.
- **`/etc/nv_boot_control.conf`** is generated on first boot from the firmware's own variables.
  Do not mask `nv-l4t-bootloader-config`.
- **Firmware (QSPI) updates** are deliberately not applied by apt here. NVIDIA ships them as capsule
  files inside `nvidia-l4t-bootloader`; update the firmware only on purpose, using NVIDIA's own
  procedure.
- **Debian vs. Ubuntu userland.** NVIDIA's packages target Ubuntu 24.04 (glibc 2.39), so Debian 13 is the
  oldest Debian that works. `libpcre3` comes from the Debian 12 archive and the tray applet is moved
  from AppIndicator3 to Ayatana through a shim package. These fixes are re-applied after every apt run.
- **Network for the installer.** The base install does not need the network. Only the optional developer
  tools do, and the installed system needs it for updates.

## Licence

The scripts and the installer in this repository are free software under the **GNU GPL v3**
(see `LICENSE`). Copyright (C) 2026 Teyo1.

This covers only the code here. Software that the build downloads or that is inside a built image
(Debian packages, NVIDIA's Jetson Linux kernel, GPU driver, CUDA and other NVIDIA packages) keeps its own
licence (see `NOTICE.md`). Contributions (issues, fixes, pull requests) are welcome.
