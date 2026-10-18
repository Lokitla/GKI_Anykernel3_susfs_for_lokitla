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
  The three main variants (SukiSU / BakaSU / FinaSU) integrate SUSFS by different routes; see [Variants and SUSFS](#variants-and-susfs).
- SUSFS integration and patch adaptation, with optional patch export.
- ZRAM/LZ4KD optimization; Linux 6.12 uses patches maintained in this repository.
- Optional KPM, BBR and network configuration, Baseband Guard, Re-Kernel, NoMount, Droidspaces/NTSync, and GhostLock fixes.
- AnyKernel3 flashable packages. Full artifact mode also creates boot images in multiple compression formats.
- Build failure logs, rejected-patch summaries, and GitHub Actions summaries.

**Compatibility:** KPM is skipped automatically on Linux 6.10 and newer. For Linux 6.12, enable ZRAM as needed. Device ROMs and kernel configurations can vary; review the feature guide and build records before flashing.

## Variants and SUSFS

The three main variants integrate SUSFS by three different routes, and picking the wrong one either breaks the build or produces a kernel with non-functional hiding. The table reflects actual code behaviour in [`scripts/build_kernel.sh`](scripts/build_kernel.sh).

| Variant | How SUSFS is integrated | Manager source | Notes |
|---|---|---|---|
| **SukiSU** | Upstream KernelSU ships built-in SUSFS support; this repository only does UAPI alignment and context adaptation | [SukiSU-Ultra](https://github.com/SukiSU-Ultra/SukiSU-Ultra) Actions artifacts | With SUSFS enabled the `builtin` branch is selected automatically; the `main` branch conflicts with SUSFS and requires an explicit opt-in |
| **BakaSU** | Upstream KernelSU ships built-in SUSFS support, but upstream **suspends** SUSFS builds; this repository decides per tree based on in-tree evidence | [BakaSU](https://github.com/Baka-SU/BakaSU) Actions artifacts | The upstream `susfs_compat.mk` still carries an unconditional `$(error)`; support is decided after the patch lands by [`scripts/bakasu_compat/resume_susfs.sh`](scripts/bakasu_compat/resume_susfs.sh), and a failed decision aborts the build |
| **FinaSU** | Uses the **upstream KernelSU-side SUSFS patch plus a structural adaptation patch** from this repository (`scripts/finasu_compat/`), a different shape from the two above | Official [FinaSU](https://github.com/LyraVoid/FinaSU) release APK | Kernel and manager must align on the same release: the build clones FinaSU, checks out the commit behind that release, and installs the manager APK signing certificate into the kernel trust list — otherwise the manager cannot recognize the kernel |
| **Official / Next** | No built-in SUSFS; Official additionally needs the upstream `10_enable_susfs_for_ksu.patch` | [KernelSU](https://github.com/tiann/KernelSU) / [KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next) | KernelSU-Next `dev` has no `KSU_SUSFS_*` switches, so SUSFS cannot be enabled together with it |

Additional notes:

- **SUSFS patch source**: BakaSU and SukiSU clone `gki-<android>-<kernel>` from [simonpunk/susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu); SukiSU first tries the ShirkNeko fork and falls back to upstream when the branch is missing. The branch always tracks upstream instead of pinning a commit (pass `susfs_commit` to pin).
- **The BakaSU suspension is not caused by this repository**: upstream has disabled SUSFS builds since `48fa4bb`, waiting for simonpunk to sync the new `selinux_hide` model. This repository does not wave that through unconditionally — it inspects the real in-tree shape once the patch has landed (< 6.6 checks the manual hook and `should_check_current` in `hooks.c`; >= 6.6 checks the `_with_policy` model in `selinuxfs.c`, and a `backup_sepolicy` shape also qualifies) and fails loudly rather than producing a kernel that bypasses upstream caution.
- **FinaSU uses a different SELinux model**: upstream FinaSU removed `fake_state` in favour of `backup_sepolicy` plus `security_*_with_policy`. The SUSFS patch still references `fake_state`, so after the patch lands this repository rewrites those references (`adapt_finasu_selinux_hide_model` in [`scripts/susfs_fixes/apply.sh`](scripts/susfs_fixes/apply.sh)); if the rewrite does not match exactly once or leaves residue, the build aborts.
- **FinaSU's kernel-side integration script comes from [LingLuo17/AnyKernel3](https://github.com/LingLuo17/AnyKernel3)**: `scripts/finasu_compat/apply.sh` is ported from that repository's commit `d6255c5f44e3871743c7d1570436822227b4b2fd` (GPL-3.0-only), and `extract_manager_cert.py` from commit `fb8379aa781f9e94cabee2c12f543144035b5da3`. Source, licensing, and the changes made here are documented in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
- **Automatic trigger coverage**: `Auto_Trigger_BakaSU.yml` and `Auto_Trigger_SukiSU.yml` only track those two variants; FinaSU currently needs a manual build.

## Local build

Local builds require Linux. List available configurations and build one version:

```bash
python3 build.py --list-configs
python3 build.py --android android14 --kernel 6.1 --sub-level 124 --os-patch 2025-02
```

See [`docs/local-build-en.md`](docs/local-build-en.md) for prerequisites, options, resuming, and single-phase debugging.

## Upstream update checks

Scheduled workflows check for updates to SukiSU and BakaSU and can trigger builds according to their configuration. See `.github/workflows/Auto_Trigger_*.yml` for trigger scope, build options, and required repository permissions.

FinaSU is not wired into the scheduled triggers yet; run a build entry manually when needed. The SUSFS patch source and KernelSU variants are pulled at upstream head during each build, so the same entry can produce different SUSFS revisions on different days. Use the commit-hash input to pin the manager/kernel KernelSU commit when a reproducible artifact matters.

## Repository layout

| Path | Contents |
|---|---|
| `.github/workflows/` | Build, release, manager download, and data update workflows |
| `scripts/build_kernel.sh` | Build steps shared by Actions and the local CLI |
| `scripts/susfs_fixes/` | SUSFS main patch application and context adaptation (including SELinux model rewrites) |
| `scripts/bakasu_compat/` | BakaSU upstream SUSFS suspension decision and release |
| `scripts/finasu_compat/` | FinaSU structural adaptation patch and application |
| `scripts/sukisu_compat/` | SukiSU compatibility patches |
| `scripts/ksu_uapi_sync/` | Kernel-side KernelSU UAPI alignment |
| `scripts/get_manager.sh` | Manager and manager artifact retrieval (invoked by workflows) |
| `data/` | Android and kernel version data |
| `config/` | Kernel configuration fragments |
| `security_patch/` | Optional security fixes |
| `zram/` | ZRAM patches and related source |
| `docs/` | Local build and feature guides |
| `web/` | GitHub Pages source |

## Sources and licensing

This project includes code, patches, and configuration from multiple upstream projects and cannot be described by a single license. The current review found that the SUSFS kernel patches are marked GPL-3.0-or-later, while the Linux kernel is GPL-2.0-only. Combining them in one kernel build presents a license-compatibility risk. This repository's `LICENSE` and notices cannot remove that risk. See [NOTICE](NOTICE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Major upstream projects include [zzh20188/GKI_KernelSU_SUSFS](https://github.com/zzh20188/GKI_KernelSU_SUSFS), [LingLuo17/AnyKernel3](https://github.com/LingLuo17/AnyKernel3), [SukiSU-Ultra](https://github.com/SukiSU-Ultra/SukiSU-Ultra), [FinaSU](https://github.com/LyraVoid/FinaSU), [KernelSU](https://github.com/tiann/KernelSU), and [susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu). FinaSU is integrated into manager retrieval, kernel version alignment, and second signing-certificate trust configuration. See [NOTICE](NOTICE) for source and license information.
