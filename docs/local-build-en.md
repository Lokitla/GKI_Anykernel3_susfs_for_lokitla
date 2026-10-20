# 💻 Local Build (CLI)

Build the kernel on your own machine, without GitHub Actions.

**Local and CI share the same build logic** — `build.py` only parses arguments; every real step
lives in [`scripts/build_kernel.sh`](../scripts/build_kernel.sh). Run `--list-phases` to see
the current phase list.

> Change build behaviour in `scripts/build_kernel.sh`, never by rewriting shell inside
> `.github/workflows/build.yml` — that would fork local and CI immediately.

---

## Requirements

| Item | Requirement |
|---|---|
| OS | Linux (Ubuntu 22.04+ recommended) |
| Privilege | `sudo` once, to install build dependencies |
| Disk | At least **40GB** free |
| Python | 3.8+ |

---

## Quick start

```bash
# List supported version combos (data comes from data/)
python3 build.py --list-configs

# List build phases
python3 build.py --list-phases

# Build a single version
python3 build.py --android android14 --kernel 6.1 --sub-level 124 --os-patch 2025-02

# Build every sublevel of one combo
python3 build.py --matrix android14-6.1

# Build every version (very slow, use with care)
python3 build.py --all

# Validate arguments only, without building
python3 build.py --android android14 --kernel 6.1 --dry-run
```

---

## Full options

### Build target

| Option | Description |
|---|---|
| `--android` / `-a` | Android version, e.g. `android14` |
| `--kernel` / `-k` | Kernel version, e.g. `6.1` |
| `--sub-level` / `-s` | Sublevel, e.g. `124`; omit for the newest |
| `--os-patch` | OS patch level, e.g. `2025-02` |
| `--revision` | Android 12 revision (optional) |
| `--matrix` / `-m` | Build every sublevel of a combo, e.g. `android14-6.1` |
| `--all` | Build every version combo |
| `--list-configs` | List supported version combos |

### KernelSU and SUSFS

| Option | Description |
|---|---|
| `--ksu-variant` | KernelSU variant, default `BakaSU`: `SukiSU` / `SukiSU(40726)` / `SukiSU(40548)` / `BakaSU` / `FinaSU` / `Official` / `Next` |
| `--ksu-branch-mode` | SukiSU branch to pull (SukiSU only): `auto`=follow the SUSFS toggle (default), `main`=manager branch, `builtin`=in-kernel implementation |
| `--no-susfs` | Disable SUSFS (enabled by default) |
| `--version` | Custom version name |
| `--build-time` | Custom build time (pins the kernel `UTS_VERSION` timestamp) |
| `--export-susfs-patches` | Export the SUSFS integration patch |
| `--sukisu-commit` | SukiSU commit hash; the kernel and the manager both use this commit (SukiSU variants only; blank = `sukisu=` in `config/config`, or the branch head) |
| `--susfs-commit` | SUSFS commit hash used for the in-kernel SUSFS patching (blank = the matching branch line in `config/config`, or the branch head) |

### Feature switches

| Option | Description |
|---|---|
| `--zram` / `--no-zram` | ZRAM (LZ4KD) enhancement (**on** by default; `--no-zram` disables) |
| `--bbr` | Set BBR as the default congestion algorithm |
| `--kpm` | KPM module support, default `patched`; accepts `disabled` / `enabled` / `patched` |
| `--kpm-patch-sha256` | sha256 anchor for the KPM patch tool (`patch_linux`). When set it is checked **fail-closed** — a mismatch aborts the build (blank = no check) |
| `--bbg` | Enable Baseband-guard |
| `--rekernel` | Enable the Re-Kernel driver (tombstone/freeze support) |
| `--net-enhance` | Enable network enhancement (full IPSet types + BBR + FQ/FQ_CODEL qdisc + IPv6 NAT + extra congestion algorithms; all are pre-existing kernel options) |
| `--skip-incompatible` | Skip optional features that fail instead of aborting the build (SUSFS and OnePlus 8E are never skipped) |
| `--nomount` | Enable the NoMount mount meta-module; the matching NoMount module must be flashed separately |
| `--op8e` | Enable OnePlus 8E support (do not enable on other devices) |
| `--cve-patch` | Apply the CVE-2026-43499 (GhostLock) fix chain |
| `--droidspaces` | Droidspaces container support (`不启用` [disabled] / `678` / `123` / `345`), experimental |
| `--ntsync` | Enable NTSync (requires Droidspaces) |

### Artifacts and debugging

| Option | Description |
|---|---|
| `--artifact-mode` | `上传全部` [upload all] (default) / `仅 AnyKernel3` [AnyKernel3 only] |
| `--only <phase>` | Run a single phase (debugging) |
| `--from <phase>` | Resume from a phase |
| `--list-phases` | List all build phases |
| `--dry-run` | Print what would run, without running it |
| `--workspace` / `-w` | Working directory |

---

## Resuming and single-step debugging

The build is split into phases; `--list-phases` prints the current numbered list. A kernel build
takes tens of minutes, so rerunning everything is expensive — use these two flags to rerun only
what broke:

```bash
# Rerun just the compile step
python3 build.py --android android14 --kernel 6.1 --only compile_kernel

# Resume from the KPM patch step (earlier output is kept)
python3 build.py --android android14 --kernel 6.1 --from patch_kpm_image
```

Common phase names: `sync_kernel_source`, `add_kernelsu`, `apply_susfs`, `config_kernel`,
`compile_kernel`, `patch_kpm_image`, `make_anykernel3`, `collect_conflicts`.

---

## Notes

- **"Clean disk space" runs only on GitHub Actions runners**; local builds skip it so nothing on
  your machine is deleted by accident.
- Whether `--kpm` actually works is decided by three conditions, narrower than a version number:
  1. **The variant must provide KPM** — only the SukiSU family (including `SukiSU(40726)` /
     `SukiSU(40548)`); BakaSU / FinaSU / Official / Next ship no `config KPM`, so the request is skipped.
  2. **Kernel ≤ 6.6** — on 6.10+ it is force-disabled (`KPM_SUPPORTED=0`: the KPM code uses
     `netlink_kernel_cfg.cb_mutex`, removed in newer kernels).
  3. **Kernel ≠ 6.6** — 6.6 is a special case: the script still writes `CONFIG_KPM=y` but **skips
     the Image patching** (log: "6.6 内核不支持 KPM 镜像修补"), so the module cannot load.

  Net: the only combination that currently loads KPM is **SukiSU family + kernel ≤ 6.1**.
- Defaults follow the **entry workflow's `inputs`**, and they differ per entry: `kernel-custom.yml` / `kernel-a12`–`a15` default `use_zram` on, while `kernel-a16-6-12.yml` defaults it off; `use_kpm` defaults to `patched` in most entries. On the CLI, `build.py`'s own defaults apply when a flag is omitted.

---

## Related docs

- [🧩 Advanced features](advanced-features-en.md): GhostLock, Droidspaces, NoMount, Re-Kernel, custom commits, spoofing `/proc/config.gz`
- [中文版](local-build.md)
- [Back to README](../README-EN.md)
