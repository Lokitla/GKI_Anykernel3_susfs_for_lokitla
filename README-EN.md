> ## ⚠️ Read this first
>
> - **This is a personal, self-use kernel build repository.** It is not an official project and is not released for public consumption. No support of any kind is promised.
> - **Much of this repository was generated or modified with AI assistance and has not been human-reviewed.** Licensing, compatibility, and build results have not been fully audited; documentation drifting out of sync with code is a known risk.
> - **Forking this repository is not recommended**, and neither is using or redistributing any artifact it produces.
> - **Flashing a third-party kernel is at your own risk.** It may leave the device unable to boot, lose data, or brick it. Back up `boot`, `vendor_boot`, `init_boot` (depending on the device), and keep a known-good stock image before flashing. **The author accepts no liability for any direct or indirect damage.**
> - If you still choose to use it: **audit the source yourself, verify the artifacts yourself, and accept the consequences yourself.**

<div align="center">

# GKI KernelSU SUSFS

**Automated Android GKI kernel builds with KernelSU and SUSFS**

[![Release](https://img.shields.io/github/v/release/Lokitla/GKI_SUKISU_SUSFS_for_Lokita?label=Release&style=flat-square&logo=github&logoColor=white&color=2ea44f)](https://github.com/Lokitla/GKI_SUKISU_SUSFS_for_Lokita/releases)
[![KernelSU](https://img.shields.io/badge/KernelSU-Supported-5AA300?style=flat-square)](https://kernelsu.org/)
[![SUSFS](https://img.shields.io/badge/SUSFS-Integrated-E67E22?style=flat-square)](https://gitlab.com/simonpunk/susfs4ksu)

English | [简体中文](README.md)

</div>

---

## 📦 Sources and acknowledgements

This is **not a from-scratch implementation**. It assembles code, patches, and configuration from several upstream projects into its own build pipeline. Every entry below can be traced to `NOTICE` or to a script in this repository.

### Primary upstreams

| Upstream | Role in this repository | License |
|---|---|---|
| [zzh20188/GKI_KernelSU_SUSFS](https://github.com/zzh20188/GKI_KernelSU_SUSFS) | **The base of this repository**: build pipeline, configuration, and some patches; `hmbird_patch.c` is also fetched from its `dev` branch | GPL-2.0 |
| [AOSP kernel/common](https://android.googlesource.com/kernel/common/) / Linux | The GKI kernel baseline that gets modified and built | Kernel is GPL-2.0-only overall, with individual files carrying compatible notices |
| [tiann/KernelSU](https://github.com/tiann/KernelSU) | KernelSU implementation for the `Official` variant | GPL-2.0 (per file headers under `kernel/`) |
| [KernelSU-Next/KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next) | KernelSU implementation for the `Next` variant (`dev` branch) | Per upstream file headers |
| [SukiSU-Ultra/SukiSU-Ultra](https://github.com/SukiSU-Ultra/SukiSU-Ultra) | `SukiSU` variant (`main` / `builtin` branches) and its manager | Per upstream file headers |
| [Baka-SU/BakaSU](https://github.com/Baka-SU/BakaSU) (formerly ReSukiSU) | Kernel and manager for the `BakaSU` variant | Kernel directory GPL-2.0-only; other code GPL-3.0-or-later; icons and artwork under separate terms |
| [LyraVoid/FinaSU](https://github.com/LyraVoid/FinaSU) | Kernel source and official release APK for the `FinaSU` variant | Repository marked GPL-3.0 |
| [simonpunk/susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu) | SUSFS main patches, cloned per `gki-<android>-<kernel>` branch | GPL-3.0-or-later |
| [ShirkNeko/susfs4ksu](https://github.com/ShirkNeko/susfs4ksu) | susfs4ksu fork tried first by the `SukiSU` variant, falling back to upstream when the branch is missing | Same as above |

### Components fetched during a build

| Upstream | Purpose | License / status |
|---|---|---|
| [WildKernels/AnyKernel3](https://github.com/WildKernels/AnyKernel3) | Produces the AnyKernel3 flashable package | Per the checked-out revision's file headers and `LICENSE` |
| [LingLuo17/AnyKernel3](https://github.com/LingLuo17/AnyKernel3) / [osm0sis/AnyKernel3](https://github.com/osm0sis/AnyKernel3) | Source of the ported FinaSU kernel-side integration scripts and the BakaSU SUSFS gate (commits `d6255c5f`, `fb8379aa`, `6db3a675`) | GPL-3.0-only (full text shipped as `LICENSE-GPL-3.0.txt`) |
| [SukiSU-Ultra/SukiSU_patch](https://github.com/SukiSU-Ultra/SukiSU_patch) | Prebuilt `patch_linux` (KPM image patching), ZRAM/LZ4KD patches, `10_enable_susfs_for_ksu.patch` | `patch_linux` **has no clear license** |
| [WildKernels/kernel_patches](https://github.com/WildKernels/kernel_patches) | Optional Samsung `min_kdp.c` source | **No license declared upstream** |
| [Numbersf/Action-Build](https://github.com/Numbersf/Action-Build) | Unicode fix patch | Custom terms, not a standard GPL license |
| [maxsteeel/nomount](https://github.com/maxsteeel/nomount) | Optional NoMount kernel source | GPL-3.0 |
| [Sakion-Team/Re-Kernel](https://github.com/Sakion-Team/Re-Kernel) | Optional Re-Kernel driver | Per the pinned upstream commit and file headers here |
| [ravindu644/Droidspaces-OSS](https://github.com/ravindu644/Droidspaces-OSS) | Optional Droidspaces container support | Same as above |
| [Goldzxcbug/Droidspaces_Kernel_patch](https://github.com/Goldzxcbug/Droidspaces_Kernel_patch) | NTSync base and per-version patches | **No clear license, and not listed in `NOTICE`**; check before enabling |
| [vc-teahouse/Baseband-guard](https://github.com/vc-teahouse/Baseband-guard) | Optional BBG baseband protection | Per the pinned upstream commit and file headers here |
| [sidex15/susfs4ksu-module](https://github.com/sidex15/susfs4ksu-module) | Standalone userspace SUSFS module ZIP | AGPL-3.0 (packaged separately, never compiled into the kernel) |
| [lz4/lz4](https://github.com/lz4/lz4) (Yann Collet) | LZ4 implementation under `zram/lz4/` | BSD-2-Clause (stated in the headers of `zram/lz4/lz4.c` and friends; `NOTICE` does not list this tree separately) |
| Huawei EROFS | arm64 NEON decompression under `zram/lz4/lz4armv8/` | Header comment says it derives from Huawei EROFS; **the files carry no license of their own** and `NOTICE` does not cover them — a known gap |

### Maintained by this repository

- The `*.sh` and `*.py` files under `scripts/` (including `build_kernel.sh`, `get_manager.sh`, `susfs_fixes/`, `bakasu_compat/`, `sukisu_compat/`, `ksu_uapi_sync/`, `susfs_probe/`), plus `build.py`, `zram_patch/6.12/`, and the driver scripts in `security_patch/`, are **maintained by this repository's author, belong to no upstream project, and come with no warranty either**.
- Among them, `scripts/finasu_compat/apply.sh`, `scripts/finasu_compat/extract_manager_cert.py`, and `scripts/bakasu_compat/resume_susfs.sh` are **ported from LingLuo17/AnyKernel3 and rewritten for this repository's layout**; their provenance and GPL-3.0-only terms are kept — see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
- The root `LICENSE` (GPL-2.0) covers only original material here and **cannot override or relicense any third-party terms**.

> The complete component list, the licensing rationale, and known risks are in [NOTICE](NOTICE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). This repository **cannot be described by a single license**.

## About

This repository builds Android GKI kernels with KernelSU and SUSFS, based on [zzh20188/GKI_KernelSU_SUSFS](https://github.com/zzh20188/GKI_KernelSU_SUSFS). It covers Android 12–16 with Linux 5.10, 5.15, 6.1, 6.6, and 6.12.

It is an **unofficial derivative project maintained for the author's own use**. Changes, build configuration, and releases are maintained here, but **they do not represent any upstream project**.

## Quick links

| Topic | Link |
|---|---|
| Build artifacts | [Releases](https://github.com/Lokitla/GKI_SUKISU_SUSFS_for_Lokita/releases) |
| Local builds | [docs/local-build-en.md](docs/local-build-en.md) |
| Feature details | [docs/advanced-features-en.md](docs/advanced-features-en.md) |
| Device and kernel lookup | [Project pages](https://lokitla.github.io/GKI_SUKISU_SUSFS_for_Lokita/) |
| Beginner guide | [GitHub Pages](https://lokitla.github.io/GKI_SUKISU_SUSFS_for_Lokita/guide.html) |
| Sources and licensing | [NOTICE](NOTICE) · [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) · [LICENSE](LICENSE) · [LICENSE-GPL-3.0.txt](LICENSE-GPL-3.0.txt) |
| Upstream integration log | [FUSION.md](FUSION.md) |

## Build entry points

Builds can be started from GitHub Actions or the local `build.py` CLI; both drive the 53 build phases in [`scripts/build_kernel.sh`](scripts/build_kernel.sh).

| Entry point | Purpose |
|---|---|
| `main.yml` (`构建内核`) | Builds common versions from the compact matrix; its `workflow_dispatch` input slots are used up (see the comments inside `main.yml`), so the `Next` variant is not offered here |
| Android 12–16 workflows | Manually builds the full matrix for one Android version (`kernel-a12-5-10.yml` and four siblings) |
| `kernel-custom.yml` (`Android 内核构建-自定义`) | **The custom build entry**: pick one kernel version, sublevel, and variant; offers the most inputs (including `Next`) |
| `build.py` | Builds one version, a matrix, or everything locally; see the [local build guide](docs/local-build-en.md) |

The current matrix is summarized below; see [`matrix.json`](.github/workflows/config/matrix.json) and [`data/`](data/) for exact entries.

| Matrix | 5.10 | 5.15 | 6.1 | 6.6 | 6.12 | Total | Used for |
|---|---:|---:|---:|---:|---:|---:|---|
| `auto` | 5 | 6 | 5 | 3 | — | 19 | Automatic triggers and compact builds |
| `full` | 22 | 20 | 25 | 17 | 7 | 91 | Full version lists in the individual workflows |
| Monthly entries in `data/` | 36 | 35 | 32 | 17 | 8 | 128 | Local CLI version data (LTS entries are additional) |

Linux 6.12 is not part of the `auto` matrix. To build it, run the Android 16 (6.12) workflow manually or use `kernel-custom.yml`.

The repository currently holds 15 workflow files; `scripts/build_kernel.sh` is 4673 lines and `build.yml` has 21 steps.

## Features

Optional features are controlled by workflow inputs or local CLI flags. Available options differ slightly per entry point; see the [local build guide](docs/local-build-en.md) and the relevant workflow for details.

- KernelSU variants: SukiSU, SukiSU(40726), SukiSU(40548), BakaSU, FinaSU, Official, and Next — seven in total, per `KSU_VARIANTS` in `build.py`.
  Note: `main.yml` does not offer `Next` (that entry targets the stable matrix and has run out of input slots); use `kernel-custom.yml` for `Next`.
- SUSFS integration and patch adaptation, with optional export of the integration patches.
- ZRAM/LZ4KD optimization; Linux 6.12 uses patches maintained in this repository (`zram_patch/6.12/`).
- Optional KPM, network enhancement (IPSet + BBR + FQ/FQ_CODEL + IPv6 NAT), Baseband Guard, Re-Kernel, NoMount, Droidspaces/NTSync, OnePlus 8E support, and the CVE-2026-43499/53163 fixes.
- AnyKernel3 flashable packages; full artifact mode also produces boot images in several compression formats.
- Build failure logs, rejected-patch summaries, and GitHub Actions summaries.

### ⚠️ KPM compatibility (much narrower than the version number suggests)

KPM requires **all** of the following:

1. **The variant ships KPM** — only the SukiSU family (including `SukiSU(40726)` and `SukiSU(40548)`). The kernels of `BakaSU`, `FinaSU`, `Official`, and `Next` **have no `config KPM`**; requesting KPM there is skipped with a warning (`scripts/build_kernel.sh:1541-1542`).
2. **Kernel ≤ 6.6** — 6.10 and newer turn it off automatically (`kpm/super_access.c` uses `netlink_kernel_cfg.cb_mutex`, which newer kernels removed).
3. **Kernel ≠ 6.6** — 6.6 is a special case: the build still writes `CONFIG_KPM=y` but **skips the Image patch**, so the module cannot load; the log prints the Chinese message 「6.6 内核不支持 KPM 镜像修补」 (`scripts/build_kernel.sh:3761`).

**So the only combination that can actually load KPM today is: SukiSU family + kernel ≤ 6.1.**

## Variants and SUSFS

Each variant integrates SUSFS by a different route; picking the wrong one either breaks the build or produces a kernel with non-functional hiding. The table reflects actual code behaviour in [`scripts/build_kernel.sh`](scripts/build_kernel.sh).

| Variant | How SUSFS is integrated | Manager source | Notes |
|---|---|---|---|
| **SukiSU** | Upstream KernelSU ships built-in SUSFS support; this repository only does UAPI alignment and context adaptation | [SukiSU-Ultra](https://github.com/SukiSU-Ultra/SukiSU-Ultra) Actions artifacts | With SUSFS enabled the `builtin` branch is selected automatically. `main` conflicts with SUSFS (`main` rewrites at runtime through `ksu_patch_text` while the SUSFS patch substitutes `my_*`; the two overwrite each other), guarded by **two lines of defence**: ① only `ALLOW_SUSFS_WITH_MAIN=1` lets it through; ② after the patch lands the build greps for `ksu_patch_text` and blocks again. CI entries do not expose that variable, so Actions can only use `builtin` |
| **BakaSU** | Upstream KernelSU ships built-in SUSFS support, but upstream **suspends** SUSFS builds; this repository decides per in-tree evidence | [BakaSU](https://github.com/Baka-SU/BakaSU) Actions artifacts | The upstream `susfs_compat.mk` still carries an unconditional `$(error)`; [`scripts/bakasu_compat/resume_susfs.sh`](scripts/bakasu_compat/resume_susfs.sh) decides once the patch has landed and aborts if it fails. **See the commit-pinning warning below** |
| **FinaSU** | Uses the upstream KernelSU-side SUSFS patch plus a structural adaptation patch from this repository (`scripts/finasu_compat/`) | Official [FinaSU](https://github.com/LyraVoid/FinaSU) release APK | Kernel and manager must align on the same release: the build checks out that release's commit and installs the manager APK signing certificate into the kernel trust list, otherwise the manager cannot recognize the kernel |
| **Official / Next** | No built-in SUSFS; Official additionally needs the upstream `10_enable_susfs_for_ksu.patch` | [KernelSU](https://github.com/tiann/KernelSU) / [KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next) | KernelSU-Next `dev` has no `KSU_SUSFS_*` switches, so **SUSFS cannot be enabled with it** (the script errors out) |

### ⚠️ BakaSU + SUSFS: the SUSFS commit must be pinned

When using `BakaSU` with SUSFS integration enabled, the SUSFS segment **must** be pinned to:

```
c06d5f8ef2b53d04c5e1c6b86dc3076f1e0e9f33
```

That is, set `manager_commit` to `0,c06d5f8ef2b53d04c5e1c6b86dc3076f1e0e9f33` (the first segment `0` leaves the manager and kernel KernelSU unpinned, the second pins SUSFS).

**Why**: newer SUSFS moved to a takeover model that requires KernelSU to export `my_setprocattr`, `my_write_context`, and `my_write_access` as non-`static` symbols. BakaSU has not caught up, so following the branch head ends in `undefined symbol` style link errors.

> This lesson comes from this repository's own build records and is **not written into any workflow input description**, so the Actions UI will not warn you.

### Additional notes

- **SUSFS patch source**: cloned by default from the `gki-<android>-<kernel>` branch of [simonpunk/susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu); SukiSU first tries the ShirkNeko fork and falls back to upstream when the branch is missing.
- **The legacy variants are the exception**: `SukiSU(40726)` and `SukiSU(40548)` check out the fixed commits recorded in `config/SukiSU(40726).config` and `config/SukiSU(40548).config` (they are named after SukiSU-Ultra commit counts and are historical snapshots); a missing file makes the build `exit 1`.
- **The BakaSU suspension is not caused by this repository**: upstream has disabled SUSFS builds since `48fa4bb` (`kernel: suspend susfs build`), waiting for the new `selinux_hide` model. This repository does not wave that through — it inspects the real in-tree shape once the patch has landed: below 6.6 it checks the manual hook and `should_check_current` / `backup_sepolicy` in `hooks.c`; from 6.6 on it checks the `_with_policy` model in `selinuxfs.c`. **Anything it cannot decide fails closed**, so no kernel upstream deliberately avoided gets produced.
- **BakaSU and FinaSU use a different SELinux model**: both removed `fake_state` upstream in favour of `backup_sepolicy` plus `security_*_with_policy`, while the SUSFS main patch still `extern`s `fake_state` and fails at ThinLTO link time with `undefined symbol: fake_state`. This repository rewrites those references after the patch lands (`adapt_finasu_selinux_hide_model` in [`scripts/susfs_fixes/apply.sh`](scripts/susfs_fixes/apply.sh)); a failed rewrite aborts the build.
- **FinaSU's kernel-side integration script comes from [LingLuo17/AnyKernel3](https://github.com/LingLuo17/AnyKernel3)**: `scripts/finasu_compat/apply.sh` is ported from commit `d6255c5f44e3871743c7d1570436822227b4b2fd` (GPL-3.0-only) and `extract_manager_cert.py` from commit `fb8379aa781f9e94cabee2c12f543144035b5da3`. Provenance, licensing, and changes are documented in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
- **Automatic trigger coverage**: `Auto_Trigger_BakaSU.yml` and `Auto_Trigger_SukiSU.yml` only track those two variants (every three days); FinaSU still needs a manual build.

## 🧩 Advanced features

All seven are off by default; see [docs/advanced-features-en.md](docs/advanced-features-en.md) for how to enable each one and for the details.

| Feature | Description | Actions input |
|---|---|---|
| 🛡️ GhostLock security fix | Patches the `rtmutex` CVE-2026-43499 / CVE-2026-53163 vulnerability chain | `cve_2026_43499_patch` |
| 🔌 Re-Kernel | Tombstone / freeze support driver | `use_rekernel` |
| 🌐 Network enhancement | All IPSet types + BBR + FQ/FQ_CODEL + IPv6 NAT + extra congestion algorithms | `use_net_enhance` |
| 📦 NoMount | Mount metamodule without relying on mount namespaces | `use_nomount` |
| 🧪 Droidspaces | Container support (experimental); 5.10/5.15/6.1/6.6 offer the `678` / `123` / `345` slots, while 6.12 only has enable / disable | `droidspaces` + `droidspaces_ntsync` |
| 🔧 Custom commit pinning | Locks commits through `config/config` or the `manager_commit` input | `manager_commit` |
| 🧪 Spoofed `/proc/config.gz` | Enabled automatically once `config/stock_defconfig` exists; presents a stock-looking config | No input (presence-based) |

### `manager_commit` semantics

The format is **`<manager & kernel KernelSU>,<SUSFS>`**; commas or pipes both work, `0` means “do not pin this segment”, and an empty value means “pin nothing”.

| Value | Meaning |
|---|---|
| `abc123...,0` | Pin only the manager and kernel KernelSU commit |
| `0,def456...` | Pin only the SUSFS commit (required for BakaSU, see above) |
| `abc123...,def456...` | Pin both |
| empty | Track upstream head |

`FinaSU` always uses the commit behind the official release and ignores the first segment.

## Version alignment and tracking policy

The general convention is **“track upstream head unless explicitly pinned”** — versions are only locked when you pass an explicit hash or tag:

- **KernelSU checkout**: SukiSU uses `main` or `builtin` (`builtin` automatically when SUSFS is on); BakaSU and FinaSU align to the same commit as the selected manager build so the kernel KernelSU version matches the manager APK exactly.
- **SUSFS patch source**: clones the head of the upstream `gki-<android>-<kernel>` branch by default; use the second segment of `manager_commit` when you need reproducibility (legacy variants excepted — they are pinned by design).
- **KernelSU UAPI version**: the target value is read from `supercall.h` **on the branch the kernel actually checks out** — `main` keeps it at `uapi/supercall.h`, `builtin` at `kernel/include/uapi/supercall.h`, and the two evolve independently. This avoids rewriting a BakaSU kernel to a SukiSU version number.
- **KPM patch tool**: follows [SukiSU_patch](https://github.com/SukiSU-Ultra/SukiSU_patch) upstream head and **never blocks a build**. `config/kpm_patch_sha256` merely records what upstream looked like during the last build; on drift the build logs a `::warning::` and continues. Only an explicitly passed `kpm_patch_sha256` triggers a fail-closed comparison. Use `scripts/tools/pin_kpm_patch.sh` to refresh the recorded value.

## Local build

Local builds require Linux. List the available configurations and build one version:

```bash
python3 build.py --list-configs
python3 build.py --android android14 --kernel 6.1 --sub-level 124 --os-patch 2025-02
```

See [`docs/local-build-en.md`](docs/local-build-en.md) for prerequisites, options, resuming, and single-phase debugging.

> Note: `--droidspaces` and `--artifact-mode` reuse the Actions choices verbatim, so they are **Chinese string literals** (`--droidspaces 不启用`, `--artifact-mode 仅 AnyKernel3` or `上传全部`); an English translation fails with `invalid choice`. `--kpm`, by contrast, takes the **English keys** `disabled` / `enabled` / `patched` (mapped to the Actions labels internally) — do not paste the dropdown's Chinese text.

## Upstream update checks

Scheduled workflows check for SukiSU and BakaSU updates and can trigger builds according to their configuration; see `.github/workflows/Auto_Trigger_*.yml` for scope, triggers, and required repository permissions.

FinaSU is not wired into the scheduled triggers yet; run a build entry manually when needed. The SUSFS patch source and KernelSU variants are pulled at upstream head during each build, so the same entry can produce different revisions on different days. Use `manager_commit` to pin commits when a reproducible artifact matters.

## Repository layout

| Path | Contents |
|---|---|
| `.github/workflows/` | Build, release, manager download, and data update workflows (15 files) |
| `scripts/build_kernel.sh` | Build steps shared by Actions and the local CLI (53 phases) |
| `scripts/susfs_fixes/` | SUSFS main patch application and context adaptation (including SELinux model rewrites) |
| `scripts/bakasu_compat/` | BakaSU upstream SUSFS suspension decision and release |
| `scripts/finasu_compat/` | FinaSU structural adaptation patch and certificate extraction |
| `scripts/sukisu_compat/` | SukiSU compatibility patches |
| `scripts/ksu_uapi_sync/` | Kernel-side KernelSU UAPI alignment |
| `scripts/susfs_probe/` | Raw SUSFS patch probing and result aggregation |
| `scripts/get_manager.sh` | Manager and manager artifact retrieval (invoked by workflows) |
| `build.py` | Local build CLI |
| `data/` | Android and kernel version data |
| `config/` | Kernel configuration fragments and legacy-variant pinned-commit configs |
| `security_patch/` | Optional security fixes |
| `zram/` | ZRAM patches and related source |
| `zram_patch/` | ZRAM (LZ4KD) patches for 6.12 |
| `hmbird_patch.c` | Additional patch source from the upstream `dev` branch (the local copy wins when present) |
| `docs/` | Local build and feature guides |
| `web/` | GitHub Pages source |

## Sources and licensing

This project includes code, patches, and configuration from multiple upstream projects and **cannot be described by a single license**.

The current review found that the SUSFS kernel patches are marked GPL-3.0-or-later while the Linux kernel is GPL-2.0-only. Combining them in one kernel artifact presents a **license-compatibility risk** that this repository's documentation and `LICENSE` cannot remove.

The root `LICENSE` is GPL-2.0 and **covers only original material here**; the FinaSU adaptation scripts ported from upstream ship with [LICENSE-GPL-3.0.txt](LICENSE-GPL-3.0.txt). Per-component status, rationale, and opt-out switches are in [NOTICE](NOTICE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

`STRICT_LICENSE_MODE=true` skips some components with unclear licensing (the Unicode fix, Samsung `min_kdp.c`, and KPM's `patch_linux`), but it **does not mean the whole build passes a license review**.

## Disclaimer

1. This is a **personal, self-use** project provided “as is”, without warranty of any kind, express or implied, including but not limited to merchantability, fitness for a particular purpose, and non-infringement.
2. The author **accepts no liability** for any direct or indirect damage arising from use of this repository's code, scripts, or build artifacts (device damage, data loss, voided warranty, account risk controls, and so on).
3. Back up the relevant partitions before flashing and make sure you understand the compatibility between the variant you choose, the kernel version, and your device.
4. This repository **has not been human-reviewed**; documentation and code may disagree — **the code wins**.
5. Before distributing any artifact built here, you are responsible for meeting each upstream license's source-availability and copyright-notice obligations.

## Reporting issues

This is a personal project and **no response time or fix is promised**. If you still want to file something:

- Use [Issues](https://github.com/Lokitla/GKI_SUKISU_SUSFS_for_Lokita/issues) and include the full Actions run link or log excerpt;
- State the kernel version, Android version, variant, and key inputs such as `enable_susfs` / `use_kpm` / `droidspaces`;
- For behaviour that belongs to an upstream (SUSFS, KernelSU, AnyKernel3, …), please report it upstream first.

Participation in this repository is governed by [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
