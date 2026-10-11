<div align="center">

# GKI KernelSU SUSFS

**Automated GKI kernel builds · KernelSU + SUSFS integrated**

[![Release](https://img.shields.io/github/v/release/Lokitla/GKI_SUKISU_SUSFS_for_Lokita?label=Release&style=flat-square&logo=github&logoColor=white&color=2ea44f)](https://github.com/Lokitla/GKI_SUKISU_SUSFS_for_Lokita/releases)
[![Upstream author](https://img.shields.io/badge/%E2%9D%A4%EF%B8%8F%20Upstream%20author-zzh20188-3DDC84?style=flat-square&logo=android&logoColor=white)](https://github.com/zzh20188)
[![KernelSU](https://img.shields.io/badge/KernelSU-Supported-5AA300?style=flat-square)](https://kernelsu.org/)
[![SUSFS](https://img.shields.io/badge/SUSFS-Integrated-E67E22?style=flat-square)](https://gitlab.com/simonpunk/susfs4ksu)

English | [简体中文](README.md)

</div>

---

## ⚠️ Read this first: personal-use notice

> [!WARNING]
> **This is a personal derivative repository, not an official release channel.
> Please do not contact the upstream authors about it.**

| Item | Details |
|---|---|
| **Nature** | A **personal-use derivative fork** of [zzh20188/GKI_KernelSU_SUSFS](https://github.com/zzh20188/GKI_KernelSU_SUSFS) |
| **Credit** | The build matrix, scripts and patch adaptation — **the vast majority of the core work was done by the upstream authors**. This repository only integrates them for personal use; all credit belongs upstream |
| **Development** | Workflows, build scripts and docs were modified **with AI assistance**, **without review, approval or involvement from any upstream author**, so behavior may differ from upstream |
| **Artifacts** | **For the maintainer's own testing only**. For official builds go to [zzh20188's repository](https://github.com/zzh20188/GKI_KernelSU_SUSFS/releases) |
| **Liability** | Upstream authors bear **no responsibility** for the content, quality or consequences of this repository |
| **Feedback** | Open an issue **in this repository**. **Do not contact upstream authors** in any way (issues, email, Coolapk DMs, etc.) |

**Flash at your own risk**: flashing a third-party kernel can brick your device, cause data loss, or trigger app risk detection. Always back up your stock boot image.

**Privacy**: the docs site (GitHub Pages) uses [GoatCounter](https://www.goatcounter.com/) for anonymous visit statistics and collects no personally identifiable information. Disable JavaScript or block `gc.zgo.at` to opt out.

---

## What this is

Built on [zzh20188](https://github.com/zzh20188)'s GKI build scaffolding, with
[ShirkNeko](https://github.com/ShirkNeko/GKI_KernelSU_SUSFS)'s KPM image patching and
local CLI design ported in, [coolzyd9107](https://github.com/coolzyd9107/GKI_SukiSU_Ultra_SUSFS)'s
release presentation as reference, and [LingLuo17](https://github.com/LingLuo17)'s
6.12 ZRAM patches, SukiSU compat patches, and network enhancement merged in, with the whole build flow converged into **one script**:

```
GitHub Actions  ──┐
                  ├──►  scripts/build_kernel.sh  (48 stages, single source of build logic)
local build.py  ──┘
```

**There is no logic fork between the two paths.** To change build behavior, edit
`scripts/build_kernel.sh` — never rewrite shell inside `build.yml`.

Covers Android 12 / 13 / 14 / 15 / 16 (kernels 5.10 / 5.15 / 6.1 / 6.6 / 6.12).
Each build produces an AnyKernel3 flashable zip, boot images in three compression
formats, the KernelSU manager and the SUSFS companion module.

---

## Quick links

| | |
|---|---|
| 📖 Advanced features | [docs/advanced-features-en.md](docs/advanced-features-en.md) |
| 💻 Local CLI build | [docs/local-build-en.md](docs/local-build-en.md) |
| 📥 Downloads | [Releases](https://github.com/Lokitla/GKI_SUKISU_SUSFS_for_Lokita/releases) |
| 🔰 Beginner guide | [GitHub Pages](https://lokitla.github.io/GKI_SUKISU_SUSFS_for_Lokita/guide.html) |
| 📊 Version lookup | [GitHub Pages](https://lokitla.github.io/GKI_SUKISU_SUSFS_for_Lokita/) |
| 📄 Sources & license | [NOTICE](NOTICE) · [FUSION.md](FUSION.md) |

---

## Build entry points and version matrix

### Entry points

| Entry | How much it builds |
|---|---|
| **Build kernels** (`main.yml`) | Expands the matrix, one job per Android 12–16 |
| **Kernel build - Android 12/13/14/15/16** (`kernel-a1*.yml`) | All sublevels of that kernel (**full** mode) |
| **Android kernel build - custom** (`kernel-custom.yml`) | Only the version you specify, **1 by default** |

### Three matrices (all figures verified)

| Matrix | 5.10 | 5.15 | 6.1 | 6.6 | 6.12 | Total | Used by |
|---|---|---|---|---|---|---|---|
| **auto** (slim) | 5 | 6 | 5 | 3 | — | **19** | Auto trigger; single-version entries called by `main.yml` |
| **full** | 22 | 20 | 23 | 15 | 4 | **84** | Manually triggered single-version entries |
| **data set** | 36 | 35 | 32 | 17 | 8 | **128** | "All available versions" in `data/`; source of `build.py --all` |

> **6.12 is not in the auto matrix**, so neither the auto trigger nor "Build kernels"
> includes it (ticking `include_612` won't help). For 6.12, **manually trigger
> "Kernel build - Android 16 (6.12)"** (full mode: 6.12.23 / 30 / 38 / 58).

### "Build target" syntax for the custom entry

| Input | Effect |
|---|---|
| `66` | Sublevel code → 5.10.66 |
| `236` | Sublevel code → 5.10.236 |
| `2022-01` | Patch level date → 5.10.66 |
| `lts` | LTS version |
| `all` | Every version of that kernel (**very slow**) |
| `66,236` | Comma separated, multiple at once (duplicates removed) |

When build scope is "all versions" or "LTS only", the build target is ignored.

---

## Features and switches

| Feature | Description | Default |
|---|---|---|
| KernelSU variant | `SukiSU` / `SukiSU(40726)` / `SukiSU(40548)` / `BakaSU` / `Official` / `Next` | **`BakaSU`** |
| SUSFS | SUSFS patch set with Inline Hook support | On |
| KPM | Patch `Image` after build to load KPM modules | `patched` ※ |
| ZRAM / LZ4KD | ZRAM enhancement (LZ4KD / LZ4K_OPLUS) | On |
| BBR | Set BBR as the default TCP congestion algorithm | Off |
| **Network enhancement** | IPSet (all types) + BBR + FQ/FQ_CODEL + IPv6 NAT + extra congestion algorithms | Off |
| BBG | Baseband-guard anti-wipe | Off |
| Re-Kernel | Re-Kernel driver (beta) | Off |
| NoMount | Mount meta-module, integrates [maxsteeel/nomount](https://github.com/maxsteeel/nomount) at the `fs/` layer | Off |
| Droidspaces | LXC-style container support (experimental) | Disabled |
| NTSync | Requires Droidspaces first | Off |
| CVE-2026-43499 | rtmutex fix chain (GhostLock) | Off |
| OnePlus 8E support | Do not enable on non-OnePlus devices | Off |
| Spoofed manager | Also fetch the manager APK with a spoofed package name | On |
| Telegram notify | Push a notification after the build | On |



### Switch availability matrix (does this entry actually pass the switch?)

This table exists to prevent "it looks supported but is permanently off" mistakes.

| Switch | Build kernels `main.yml` | Single-version `kernel-a1*.yml` | Custom `kernel-custom.yml` | Personal `build-236-marble.yml` | Local `build.py` |
|---|:---:|:---:|:---:|:---:|:---:|
| `use_zram` | ✅ | ✅ (no-op on 6.12) | ✅ | ✅ | `--zram` |
| `use_net_enhance` | ✅ | ✅ | ✅ | ✅ | `--net-enhance` |
| `use_bbg` | ✅ | ✅ | ✅ | ✅ | `--bbg` |
| `use_kpm` | ✅ | ✅ (no-op on 6.12) | ✅ | ✅ | `--kpm` |
| `use_rekernel` | ✅ | ✅ | ✅ | ✅ | `--rekernel` |
| `use_nomount` | ✅ | ✅ | ✅ | ✅ | `--nomount` |
| `skip_incompatible` | ❌ always false | ✅ | ❌ | ✅ | `--skip-incompatible` |
| `export_susfs_patches` | ✅ | ➖ main entry only | ❌ | ✅ | `--export-susfs-patches` |
| `ksu_branch_mode` | ❌ always `auto` | ✅ | ❌ | ❌ | `--ksu-branch-mode` |
| `manager_commit` (manager + SUSFS commit, comma-separated) | ✅ | ✅ | ✅ | ✅ | `--sukisu-commit` / `--susfs-commit` |
| `kpm_patch_sha256` | ➖ hidden, always empty | ➖ same | ➖ same | ➖ same | `--kpm-patch-sha256` |
| `manager_spoofed` (spoofed manager) | ➖ hidden, always on | ➖ same | ➖ same | ➖ same | not available |
| `supp_op` (OnePlus 8E) | ❌ always false | ✅ | ✅ | ➖ hardcoded false | `--op8e` |
| `ksu_mode` | ❌ | ❌ | ❌ | ❌ | not available |

Legend:

- **✅ = user-controllable when this entry is run manually** (the input exists in that
  file's `workflow_dispatch` block).
- **❌ = not offered by this entry**; a fixed default is used (written out in the code
  with a note explaining why). The main cause is `main.yml`'s `workflow_dispatch` inputs
  **hitting GitHub's 25-input limit**. Use the **single-version entry `kernel-*.yml`**
  or **local `build.py`** instead.
- **➖ = special cases**:
  - *main entry only* — the input exists only in `kernel-a1*.yml`'s `workflow_call`
    block (for `main.yml` to pass in), **not in `workflow_dispatch`**, so it is always
    `false` when you run the single-version entry by hand; only "Build kernels" can
    actually set it.
  - *hidden* — the option has been removed from every manual entry's UI with a fixed
    behaviour: `kpm_patch_sha256` behaves as left blank (no verification),
    `manager_spoofed` is always enabled. The underlying capability still lives in
    `build_kernel.sh` / local `build.py`.

**On commit hashes**: `sukisu_commit` and `susfs_commit` are merged into a single
input `manager_commit`, holding "SukiSU/manager hash, **optionally followed by a
comma and** the SUSFS hash". Parsing splits on the comma and strips surrounding
whitespace; the validation for each hash is unchanged. With a single value the second
hash is left empty (SUSFS unpinned).

**On `use_bbr`**: all Actions entries now use `use_net_enhance` only — network
enhancement already includes "set BBR as the default congestion algorithm", so two
switches would only create ambiguity. Only the local `build.py` keeps a separate
`--bbr`.

**Two switches are permanently ineffective on 6.12 (Android 16)** — an upstream
limitation, not a configuration problem:

- `use_zram`: upstream `SukiSU_patch`'s `other/zram/zram_patch/` ships only
  5.10 / 5.15 / 6.1 / 6.6, with no 6.12 directory, so those stages are skipped whole;
- `use_kpm`: the script forces `KPM_SUPPORTED=0` on kernel ≥ 6.10 (SukiSU's KPM code
  uses `netlink_kernel_cfg.cb_mutex`, removed in newer kernels).

`kernel-a16-6-12.yml` now defaults both to off so they no longer spin idly.

> Every cell is measured against one criterion — whether the input appears in that file's
> `workflow_dispatch` block — not inferred from the call chain. The two disagree easily:
> an input present only in `workflow_call` is visible along the call chain yet unreachable
> for the user.

### Three common pitfalls

**1. KPM does nothing on the default variant.** KPM is only provided by the SukiSU
variant; `BakaSU` / `Official` / `Next` have no `config KPM` in their kernel Kconfig.
The relevant stages are skipped automatically — the build does not fail, but the kernel
cannot load KPM modules. Switch the variant back to `SukiSU` if you need KPM.

**2. BBR needs its gate enabled first.** The `gki_defconfig` baselines of
5.10 / 5.15 / 6.1 / 6.12 have no `CONFIG_TCP_CONG_ADVANCED`, while `TCP_CONG_BBR` and
`DEFAULT_BBR` both sit inside `if TCP_CONG_ADVANCED` — with the gate closed, the two BBR
lines are dead entries nobody reads. The script writes `TCP_CONG_ADVANCED=y` first, and
also forces `TCP_CONG_BIC / WESTWOOD / HTCP` to `=y` (they default to `m` in Kconfig;
`=y` avoids emitting undeclared `.ko` files on the bazel path).

**3. ZRAM defaults have three layers.** The script's internal fallback is `false`
(only when nobody passes anything); the local CLI and **all** Actions entries default to
`true`. On 6.12 there is no lz4k patch stack, so it is skipped entirely with a warning
even when enabled.

---

## Build artifacts

With "upload all", each kernel version is split into two artifacts:

| Artifact | Contents | Size (5.10 example) |
|---|---|---|
| `..._kernel-<version>-AnyKernel3` | `AnyKernel3.zip` flashable package | ~18 MB |
| `..._kernel-<version>-Images` | `boot.img` / `boot-gz.img` / `boot-lz4.img` | ~50 MB (compressed) |

**You only need the AnyKernel3 package** — the `Image` inside is processed on-device by
`anykernel.sh`.

The three boot images differ in how the kernel is compressed, for `fastboot flash boot`:

| File | Compression | Use case |
|---|---|---|
| `boot.img` | none | Best compatibility, old bootloaders |
| `boot-gz.img` | gzip | Traditional default, supported almost everywhere |
| `boot-lz4.img` | lz4 | Common on modern GKI, fastest decompression |

Prefer `boot-lz4.img` on modern devices; try `-gz` if it hangs on the first screen; fall
back to uncompressed.

An "AnyKernel3 only" mode is also available to save release space.

---

## Compatibility notes

- **OnePlus ColorOS 14 / 15**: not supported; you may need to wipe data to boot.
- **6.12 (Android 16)**: compatibility patches for the new 6.10+ `security_add_hooks`
  signature are in place, but there are three hurdles — see below.
- **Older SukiSU**: builds for `SukiSU(40726)` / `SukiSU(40548)` are kept. They use
  entirely old code with none of the recent features or fixes; pair them with a matching
  manager version.
- **Re-Kernel**: supported, currently beta.

### The three 6.12 hurdles

**1 · `security_add_hooks` signature change.** The third parameter became
`const struct lsm_id *` in v6.10+, while KernelSU variants still pass a string per the
old signature. The patch stage fills in an argument macro based on kernel version:
**`&ksu_lsm_id` from v6.10 onward, a string literal on older kernels.**
(The field is `name`, not `lsm` — writing `.lsm` fails to compile.)

**2 · KPM does not compile.** SukiSU's `super_access.c` uses
`netlink_kernel_cfg.cb_mutex`, which no longer exists on 6.10+. The script **turns KPM
off automatically** instead of running a build that is doomed to fail (an early gate sets
`KPM_SUPPORTED=0`). Measured cost of forcing it: failure after 18 minutes, then a
retry-based fallback — about 20 extra minutes per version.

**3 · No ZRAM patch stack.** The lz4k stack only ships directories for
5.10 / 5.15 / 6.1 / 6.6. **Even with the ZRAM switch on, 6.12 skips the whole thing**
with a `::warning::`. This is deliberate — better to skip explicitly than to leave a
half-applied ZRAM patch that breaks GKI defconfig validation.

---

## Upstream update auto trigger

BakaSU (formerly ReSukiSU) and SukiSU ship from two unrelated upstream repositories with their own release
cadences, so auto-triggering is split into **two independent workflows**:

| Workflow | Upstream watched | Baseline branch | Variant built | Schedule (UTC) |
|---|---|---|---|---|
| `.github/workflows/Auto_Trigger_BakaSU.yml` | [Baka-SU/BakaSU](https://github.com/Baka-SU/BakaSU) `main` | `sha-bakasu` | `BakaSU` | every 3 days at 00:00 |
| `.github/workflows/Auto_Trigger_SukiSU.yml` | [SukiSU-Ultra](https://github.com/SukiSU-Ultra/SukiSU-Ultra) `main` | `sha-sukisu` | `SukiSU` | every 3 days at 12:00 |

The two are offset by 12 hours so they never contend for runner concurrency and so the two
releases stay easy to tell apart. Both follow the same procedure: fetch the upstream head
commit → compare against their own baseline branch → write it back and trigger a build per
`build_scope`.

1. New commit → write it back to the baseline branch and trigger **Build kernels**;
2. No new commit → do nothing, no runner time consumed;
3. Cannot fetch the commit (API rate limit) → fail immediately rather than build with an
   empty value.

Defaults to "all versions", expanding the **auto slim matrix of 19 kernel versions** via
`main.yml`, with ZRAM on and all other enhancements off.

> **Release tags are counted per variant.** `main.yml` now emits tags shaped like
> `<SUSFS version>-r<N>-<variant>`, where `-rN` only increments *within* one variant.
> Sharing a single `-rN` sequence would let the second release compute an already-existing
> tag — `gh release create` would then fail and that run's artifacts would be silently lost.

> **The BakaSU baseline is already in place** — `sha-bakasu` was migrated verbatim from
> the old `sha-resukisu` branch, so the first run reads an existing commit and will not misfire.
> If the baseline branch is rebuilt (latest_sha.txt lost), the first run counts as "new commit"
> and fires a full matrix build; to establish the baseline without building,
> run it manually once with `build_scope` set to "no build".
> The SukiSU workflow reuses the existing `sha-sukisu` branch, which already holds a
> SukiSU-Ultra commit, so it will not misfire.

Manual run options:

| Input | Description | Default |
|---|---|---|
| `force` | Ignore "is there a new commit" and trigger anyway | No |
| `build_scope` | `all versions` / `fixed 5.10.236` / `single version smoke` / `no build` | `all versions` |
| `include_612` | Try to include 6.12. **Note: 6.12 is not in the auto matrix, so it is still skipped** | No |
| `release_type` | `Release` / `Pre-Release` / `Actions` | `Release` |

> "fixed 5.10.236" runs the personal workflow `build-236-marble.yml` (for the Redmi Note
> 12 Turbo, codename marble). Its parameters are hardcoded; artifacts stay in Actions
> artifacts and **no Release is created**.
>
> Requires **Settings → Actions → Workflow permissions** to be `Read and write`,
> otherwise writing back to the sha branch is rejected with 403.

---

## Local build (CLI)

Build directly on your machine without GitHub Actions. **It shares the same script as the
cloud**, so behavior is identical.

```bash
# Build a single version
python3 build.py --android android14 --kernel 6.1 --sub-level 124 --os-patch 2025-02

# Common switches
python3 build.py --android android12 --kernel 5.10 --sub-level 236 \
                 --zram --net-enhance --nomount --rekernel
```

Supports all 48 stages, resume from a stage (`--from`) and re-run a single stage
(`--only`). Full options: [docs/local-build-en.md](docs/local-build-en.md).

---

## Repository layout

| Path | Purpose |
|---|---|
| `scripts/build_kernel.sh` | **Single source of build logic**, 48 stages |
| `build.py` | Local CLI entry; only parses args and calls the script above |
| `.github/workflows/build.yml` | Reusable build workflow (cache / artifacts / logs / notify) |
| `.github/workflows/main.yml` | "Build kernels" top-level entry, expands the matrix |
| `.github/workflows/kernel-a1*.yml` | Per-Android-version standalone entries |
| `.github/workflows/kernel-custom.yml` | Custom single-version entry |
| `.github/workflows/build-236-marble.yml` | **Personal**: fixed build for Redmi Note 12 Turbo |
| `.github/workflows/Auto_Trigger_BakaSU.yml` | Detects BakaSU upstream updates and triggers builds (BakaSU variant) |
| `.github/workflows/Auto_Trigger_SukiSU.yml` | Detects SukiSU upstream updates and triggers builds (SukiSU variant) |
| `.github/workflows/get-manager.yml` | Fetches manager APKs |
| `.github/workflows/update-pages.yml` | Updates `data/` and deploys Pages |
| `.github/workflows/susfs-probe.yml` | **Batch tool**: full builds with raw SUSFS patches, calibrates the compatibility line |
| `scripts/susfs_probe/` | Matrix generation / result-summary scripts for probing |
| `config/` | Config fragments, `config/config` commit pinning |
| `data/` | Available kernel sublevels and patch levels (128 entries) |
| `security_patch/` | CVE-2026-43499 fix chain |
| `zram/` | ARM64 NEON accelerated LZ4 implementation |
| `web/` | GitHub Pages site source |
| `scripts/susfs_fixes/apply.sh` | SUSFS patch adaptation and conflict fixes |
| `tools/migration/` | One-off migration scripts, **not part of the build** |
| `FUSION.md` | Comparison and migration notes for the three upstream repos |

---

## License and attribution

Full list in [NOTICE](NOTICE); migration comparison in [FUSION.md](FUSION.md). Main sources:

| Project | Upstream contribution | License |
|---|---|---|
| [WildKernels/GKI_KernelSU_SUSFS](https://github.com/WildKernels/GKI_KernelSU_SUSFS) | Common original upstream of zzh20188 and ShirkNeko | GPL-3.0-or-later |
| [zzh20188/GKI_KernelSU_SUSFS](https://github.com/zzh20188/GKI_KernelSU_SUSFS) | **Build scaffolding and most of the code** | GPL-2.0 |
| [ShirkNeko/GKI_KernelSU_SUSFS](https://github.com/ShirkNeko/GKI_KernelSU_SUSFS) | KPM image patching, local CLI design | Not declared |
| [coolzyd9107/GKI_SukiSU_Ultra_SUSFS](https://github.com/coolzyd9107/GKI_SukiSU_Ultra_SUSFS) | Release notes template | GPL-2.0 |
| [SukiSU-Ultra](https://github.com/SukiSU-Ultra/SukiSU-Ultra) | The KernelSU variant itself | GPL-3.0 (`kernel/` dir is GPL-2.0) |
| [simonpunk/susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu) | SUSFS patch set | GPL-3.0 |
| [WildKernels/AnyKernel3](https://github.com/WildKernels/AnyKernel3) | Flashable zip template | BSD-3-Clause style (`magiskboot` / `magiskpolicy` inside are GPL-3.0+) |

### Layered licensing

| Layer | License |
|---|---|
| Upstream zzh20188 scaffolding | Inherits **GPL-2.0** |
| Code and docs **added by this repository** | **GPL-2.0-or-later** |
| Actual kernel artifacts | Effectively **GPL-2.0-only** (the kernel cannot upgrade to v3) |
| Distribution as a whole | GPL-2.0-or-later, so it can legally coexist with the GPL-3.0 components it contains |

[LICENSE](LICENSE) keeps the GNU GPL v2 text verbatim; the file header declares the
distribution terms via an SPDX identifier. Attribution and compatibility notes live in
[NOTICE](NOTICE).

### License rule when porting code

Judge exactly one thing: **will the ported code end up in the kernel artifact?**

- **Not in the artifact** (build scripts / workflows / defconfig entries) → no conflict.
  This repository's GPL-2.0-or-later can be upgraded to v3, so it can legally carry
  GPL-3.0 script code; just note the source and license in the file header.
  `CONFIG_xxx=y` entries are switches for existing kernel features and are not
  copyrightable.
- **In the artifact** (kernel source patches, drivers compiled into the kernel) → must be
  GPL-2.0 compatible. The kernel is GPL-2.0-only and cannot be upgraded to v3, so
  GPL-3.0 code inside the kernel is a conflict.

> Therefore: when porting from a GPL-3.0 upstream, scripts and configs are safe, but
> **kernel patches must be reimplemented from a GPL-2.0 source** such as
> SukiSU-Ultra's `kernel/` directory.

### GPL-2.0 vs GPL-3.0

| Dimension | GPL-2.0 | GPL-3.0 / or-later |
|---|---|---|
| Anti-tivoization | No requirement | Forbids locking down with signatures or hardware |
| Patent grant | No explicit clause | Contributors grant a patent license automatically |
| Reinstatement after violation | Terminates, no reinstatement | Cure within 60 days of first violation |
| Combining with AGPL | Not allowed | Allowed |
| Compatibility | GPL-2.0-**only** cannot be merged into a GPL-3.0 work | GPL-2.0-**or-later** can upgrade to GPL-3.0 |

**Shared core restrictions (copyleft)**: when distributing binaries you must also provide
the complete corresponding source; derivative works must be distributed under the same
license; copyright notices, the full license text and modification notes must be kept,
and there is no warranty (AS IS).

> **On `-or-later`**: newly added code is GPL-2.0-or-later, meaning users may choose
> GPL-2.0 or any later GPL version (e.g. GPL-3.0) for that portion — this is exactly why
> it can coexist with GPL-3.0 components. Pure GPL-2.0-only code cannot be upgraded.

**This repository meets the source-availability requirement**: it is public, all build
scripts, patches and configs are readable, and upstream SukiSU / SUSFS / KernelSU sources
are available from their own repositories. Anyone redistributing artifacts built here
inherits the same obligations.

If you are an upstream author and believe any attribution is wrong, please open an issue
in this repository and it will be corrected immediately.

---

## Acknowledgements

This repository stands entirely on the shoulders of the upstream authors — the build
matrix, SUSFS adaptation, KPM patching and manager distribution: none of that hard work
was done by this repository's maintainer. All credit and respect goes to them:

- **[zzh20188](https://github.com/zzh20188)** — the scaffolding; most of the matrix and script work is his;
- **[ShirkNeko](https://github.com/ShirkNeko)** — KPM image patching and local CLI design;
- **[coolzyd9107](https://github.com/coolzyd9107)** — release presentation;
- **[LingLuo17](https://github.com/LingLuo17)** — 6.12 ZRAM patches, SukiSU compat patches, and network enhancement;
- and all contributors of [SukiSU-Ultra](https://github.com/SukiSU-Ultra/SukiSU-Ultra),
  [susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu),
  [KernelSU](https://kernelsu.org/) and
  [AnyKernel3](https://github.com/WildKernels/AnyKernel3).

The maintainer of this repository (with AI assistance) merely assembled the above into
something convenient for personal use.

**For any problem with this repository, please report it here — do not contact the
upstream authors in any way.** They did not participate in these modifications and should
not be held accountable for them.

---

<div align="center">

⭐ If this project helps you, please consider starring it!

</div>
