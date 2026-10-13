# Third-party software

The code in this repository is GPL-3.0 (see `LICENSE`). A built image also contains software from others,
each under its own licence:

- **Debian 13 (trixie)** packages, mostly under the GPL and other free licences. Licence texts are in
  `/usr/share/doc/*/copyright` inside the image. Source code for every Debian package is available at
  https://deb.debian.org/debian (`deb-src`) and https://sources.debian.org.
- **NVIDIA Jetson Linux (L4T) R39.2.1**: the Linux kernel (GPL-2.0; source from NVIDIA's Jetson Linux source
  release), the open GPU kernel modules, and NVIDIA's proprietary user-space libraries, firmware and CUDA
  runtime, which are under NVIDIA's own licence terms. They are downloaded from
  https://repo.download.nvidia.com/jetson at build time.

This project is unofficial and is not affiliated with, endorsed by or supported by NVIDIA or Debian.
"NVIDIA", "Jetson" and "CUDA" are trademarks of NVIDIA Corporation. "Debian" is a registered trademark of
Software in the Public Interest, Inc.
