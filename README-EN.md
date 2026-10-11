> **AI-assisted changes:** Recent changes were made with AI assistance and have not completed human review. Licensing, compatibility, and build results have not been fully audited. **Forking this repository and using or redistributing builds produced from it are not recommended.**

<div align="center">

# GKI KernelSU SUSFS

**Automated Android GKI kernel builds with KernelSU and SUSFS**

[![Release](https://img.shields.io/github/v/release/Lokitla/GKI_SUKISU_SUSFS_for_Lokita?label=Release&style=flat-square&logo=github&logoColor=white&color=2ea44f)](https://github.com/Lokitla/GKI_SUKISU_SUSFS_for_Lokita/releases)
[![KernelSU](https://img.shields.io/badge/KernelSU-Supported-5AA300?style=flat-square)](https://kernelsu.org/)
[![SUSFS](https://img.shields.io/badge/SUSFS-Integrated-E67E22?style=flat-square)](https://gitlab.com/simonpunk/susfs4ksu)

English | [简体中文](README.md)

</div>

---

## About

This repository builds Android GKI kernels with KernelSU and SUSFS. It is based on [zzh20188/GKI_KernelSU_SUSFS](https://github.com/zzh20188/GKI_KernelSU_SUSFS) and covers Android 12–16 with Linux 5.10, 5.15, 6.1, 6.6, and 6.12.

This is an unofficial derivative project. Changes, build configuration, and releases are maintained here; please report issues to this repository. See [NOTICE](NOTICE) and [FUSION.md](FUSION.md) for source and attribution details.

Before flashing a third-party kernel, confirm that it matches your device and kernel version, and back up the stock boot image. An incompatible image may prevent the device from booting or cause data loss.

## Quick links

| Topic | Link |
|---|---|
| Build artifacts | [Releases](https://github.com/Lokitla/GKI_SUKISU_SUSFS_for_Lokita/releases) |
| Local builds | [docs/local-build-en.md](docs/local-build-en.md) |
| Feature details | [docs/advanced-features-en.md](docs/advanced-features-en.md) |
| Device and kernel lookup | [Project pages](https://lokitla.github.io/GKI_SUKISU_SUSFS_for_Lokita/) |
| Beginner guide | [GitHub Pages](https://lokitla.github.io/GKI_SUKISU_SUSFS_for_Lokita/guide.html) |
| Sources and licensing | [NOTICE](NOTICE) · [LICENSE](LICENSE) · [FUSION.md](FUSION.md) |

## Build options

Builds can be started with GitHub Actions or the local `build.py` CLI. Both use the build steps in [`scripts/build_kernel.sh`](scripts/build_kernel.sh).

| Entry point | Purpose |
|---|---|
| `Build kernels` (`main.yml`) | Builds common versions from the compact matrix |
| Android 12–16 workflows | Manually builds the full matrix for an Android version |
| `kernel-custom.yml` | Selects a kernel and sublevel to build |
| `build.py` | Builds one version, a matrix, or all versions locally; see the CLI guide |

The current matrix is summarized below. See [`matrix.json`](.github/workflows/config/matrix.json) and [`data/`](data/) for the exact entries.

| Matrix | 5.10 | 5.15 | 6.1 | 6.6 | 6.12 | Total | Used for |
|---|---:|---:|---:|---:|---:|---:|---|
| `auto` | 5 | 6 | 5 | 3 | — | 19 | Automatic triggers and compact builds |
| `full` | 22 | 20 | 25 | 17 | 7 | 91 | Full version lists in individual workflows |
| Monthly entries in `data/` | 36 | 35 | 32 | 17 | 8 | 128 | Local CLI version data (LTS entries are additional) |

Linux 6.12 is not included in the `auto` matrix. To build it, run the Android 16 (6.12) workflow manually or use the custom build entry. The data update workflow also refreshes the full matrix.

## Features

Optional features are controlled by workflow inputs or local CLI flags. Available options vary by entry point; see the [local build guide](docs/local-build-en.md) and the relevant workflow for details.

- KernelSU variants: SukiSU, BakaSU, FinaSU, Official, Next, and retained legacy SukiSU builds.
- SUSFS integration and patch adaptation, with optional patch export.
- ZRAM/LZ4KD optimization; Linux 6.12 uses patches maintained in this repository.
- Optional KPM, BBR and network configuration, Baseband Guard, Re-Kernel, NoMount, Droidspaces/NTSync, and GhostLock fixes.
- AnyKernel3 flashable packages. Full artifact mode also creates boot images in multiple compression formats.
- Build failure logs, rejected-patch summaries, and GitHub Actions summaries.

**Compatibility:** KPM is skipped automatically on Linux 6.10 and newer. For Linux 6.12, enable ZRAM as needed. Device ROMs and kernel configurations can vary; review the feature guide and build records before flashing.

## Local build

Local builds require Linux. List available configurations and build one version:

```bash
python3 build.py --list-configs
python3 build.py --android android14 --kernel 6.1 --sub-level 124 --os-patch 2025-02
```

See [`docs/local-build-en.md`](docs/local-build-en.md) for prerequisites, options, resuming, and single-phase debugging.

## Upstream update checks

Scheduled workflows check for updates to SukiSU and BakaSU and can trigger builds according to their configuration. See `.github/workflows/Auto_Trigger_*.yml` for trigger scope, build options, and required repository permissions.

## Repository layout

| Path | Contents |
|---|---|
| `.github/workflows/` | Build, release, manager download, and data update workflows |
| `scripts/build_kernel.sh` | Build steps shared by Actions and the local CLI |
| `scripts/susfs_fixes/` | SUSFS patch adaptation scripts |
| `data/` | Android and kernel version data |
| `config/` | Kernel configuration fragments |
| `security_patch/` | Optional security fixes |
| `zram/` | ZRAM patches and related source |
| `docs/` | Local build and feature guides |
| `web/` | GitHub Pages source |

## Sources and licensing

This project includes code, patches, and configuration from multiple upstream projects and cannot be described by a single license. The current review found that the SUSFS kernel patches are marked GPL-3.0-or-later, while the Linux kernel is GPL-2.0-only. Combining them in one kernel build presents a license-compatibility risk. This repository's `LICENSE` and notices cannot remove that risk. See [NOTICE](NOTICE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Major upstream projects include [zzh20188/GKI_KernelSU_SUSFS](https://github.com/zzh20188/GKI_KernelSU_SUSFS), [LingLuo17/AnyKernel3](https://github.com/LingLuo17/AnyKernel3), [SukiSU-Ultra](https://github.com/SukiSU-Ultra/SukiSU-Ultra), [FinaSU](https://github.com/LyraVoid/FinaSU), [KernelSU](https://github.com/tiann/KernelSU), and [susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu). FinaSU is integrated into manager retrieval, kernel version alignment, and second signing-certificate trust configuration. See [NOTICE](NOTICE) for source and license information.
