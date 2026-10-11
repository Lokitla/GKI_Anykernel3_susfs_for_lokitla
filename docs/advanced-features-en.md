# 🧩 Advanced Features

> This page collects six advanced topics: GhostLock Security Fix, Re-Kernel, the NoMount
> metamodule, Droidspaces Container Support, Custom Commit Pinning, and Spoofing `/proc/config.gz`.
> All are off by default. Mirrors the "Advanced Features" section in the main [README.md](../README.md).
>
> For local CLI usage see [💻 Local build docs](local-build-en.md); the Actions input name is
> listed in the "Actions input" column of each table below.

---

## 🛡️ GhostLock Security Fix

GhostLock is a pair of high-risk Linux kernel vulnerabilities tracked as `CVE-2026-43499` and `CVE-2026-53163`. An attacker does not need Root access or an additional kernel module. The vulnerability may be exploited by any application or local process that can run code on the device.

### Potential impact

- **System crash or forced reboot:** An ordinary application can crash the kernel, making the device unavailable and potentially causing the loss of unsaved data.
- **Local privilege escalation:** A more advanced exploit can cross Android security boundaries and give an ordinary application kernel-level control of the device.
- **Public exploits are available:** Both a denial-of-service proof of concept and a complete privilege-escalation chain targeting Android ARM64 have been published. This is no longer a theoretical risk.
- **No reliable temporary workaround exists:** Permission restrictions, application isolation, and hardening options may make exploitation harder, but they cannot fully prevent crashes or alternative exploit methods.

The vulnerability cannot be triggered directly over the network. However, a malicious application, untrusted code in a shared environment, or an attacker who already gained code execution through another vulnerability can use GhostLock as the next step. Extra care should therefore be taken with applications, modules, and scripts from unknown sources.

This project can check and apply the complete fix when building kernels 5.10, 5.15, 6.1, 6.6, and 6.12. The option is **disabled by default** (ShirkNeko upstream does not carry this fix). Enable `CVE-2026-43499 rtmutex fix chain` when starting a build to include GhostLock protection. Both vulnerability fixes must be present together, and the workflow handles this automatically. Kernels that already contain the complete fix are not patched again.

> **Note on patch files:** Only `CVE-2026-43499` has dedicated `.patch` files in `security_patch/` (one per kernel line: 5.10 / 5.15 / 6.1–6.6 / 6.12). The `CVE-2026-53163` follow-up fixes are generated **inline** by `security_patch/apply_cve_2026_43499.sh` (functions `ensure_remove_waiter_null_guard` and `replace_proxy_cleanup_condition`), so no separate `.patch` file exists for it — that is by design, not a missing artifact.

The fix has passed a [full build validation covering 84 kernel versions](https://github.com/zzh20188/GKI_KernelSU_SUSFS/actions/runs/29509099128). For vulnerability details, affected systems, public exploits, and mitigation guidance, read CIQ's article: [GhostLock Mitigation](https://kb.ciq.com/article/rocky-linux/rl-ghostlock-mitigation).

---

## 🔌 Re-Kernel (tombstone / freeze support)

> **Tip:** Re-Kernel provides kernel-side support for "tombstone"-style modules (apps that freeze
> other apps). Upstream is [Sakion-Team/Re-Kernel](https://github.com/Sakion-Team/Re-Kernel);
> this repo tracks its mainline version.

A frozen process cannot respond normally. Re-Kernel watches three kinds of events in-kernel and
reports them to userspace:

| Type | Trigger | Use case |
|---|---|---|
| Binder | A frozen process receives a Binder call | System services or other apps reaching a frozen process |
| Signal | A frozen process receives a key signal such as SIGKILL | Detect process kills |
| Network | A monitored UID receives an inbound packet | Messaging apps receiving pushes |

### How to enable

| Entry point | Argument |
|---|---|
| Actions | `use_rekernel` (**off** by default) |
| Local CLI | `--rekernel` |

### Implementation notes

During the build the sources are placed in `common/drivers/rekernel/` and compiled **into the
kernel** (not as an external module), controlled by `CONFIG_REKERNEL`:

- `obj-m := rekernel.o` is rewritten to `obj-$(CONFIG_REKERNEL) += rekernel.o`
- `depends on MODULES` is removed (not needed for a built-in driver)
- hooked into the driver tree via `source "drivers/rekernel/Kconfig"`
- `CONFIG_REKERNEL=y` and `CONFIG_REKERNEL_NETWORK=y` are appended to the defconfig

---

## 🌐 Network enhancement (optional)

Enables a batch of **pre-existing kernel** networking capabilities. No third-party code
is involved — everything is written into the defconfig:

| Category | Contents |
|---|---|
| Congestion control | `CONFIG_TCP_CONG_BBR=y` + `CONFIG_DEFAULT_BBR=y` (BBR becomes the default), plus BIC / CUBIC / WESTWOOD / HTCP built in |
| Queueing disciplines | `CONFIG_NET_SCH_FQ=y`, `CONFIG_NET_SCH_FQ_CODEL=y` |
| IPSet | `CONFIG_IP_SET=y`, `CONFIG_IP_SET_MAX=65534`, and every bitmap / hash / list type |
| Netfilter | `CONFIG_NETFILTER_XT_SET`, `CONFIG_NETFILTER_XT_MATCH_ADDRTYPE` |
| IPv6 NAT | `CONFIG_IP6_NF_NAT=y`, `CONFIG_IP6_NF_TARGET_MASQUERADE=y` |

**Why built-in (`=y`) rather than module (`=m`)**: BIC / WESTWOOD / HTCP default to `m`
in the mainline Kconfig. Built as modules they produce `tcp_bic.ko` and friends, which
GKI's `module_outs` does not declare — bazel fails outright. This stage therefore rewrites
any existing `=m` to `=y`.

**How to enable**

| Entry point | Parameter |
|---|---|
| Actions | `use_net_enhance` (**off** by default) |
| Local CLI | `--net-enhance` |

> You still need a userspace `ipset` tool: the kernel provides the capability only.
> `CONFIG_IP_SET_MAX=65534` sits inside the kernel Kconfig range (2–65534), so no source
> change is required.

> **Why built-in:** Re-Kernel depends on internal symbols such as `kallsyms_lookup_name`, which
> GKI hides from **external modules**. In-tree compilation can see them, so this repo builds it in
> rather than shipping an LKM.

---

## 📦 NoMount metamodule

> Ported from upstream `zzh20188/GKI_KernelSU_SUSFS` commit `27e129e`.

[NoMount](https://github.com/maxsteeel/nomount) is a mount metamodule providing module mounting
**without a traditional mount point**. It registers its own subsystem under `fs/` and takes a
**different path from SUSFS `sus_mount`**, so it coexists with any KernelSU variant and with SUSFS.

### How to enable

| Entry point | Argument |
|---|---|
| Actions | `use_nomount` (**off** by default) |
| Local CLI | `--nomount` |

> ⚠️ After enabling you must **flash the matching NoMount module yourself** — the kernel side only
> provides the support.

### Implementation notes

The build fetches `setup.sh` from upstream and runs it, then verifies the `fs/nomount` symlink is
in place before appending `CONFIG_NOMOUNT=y` to the defconfig.

The `integrate_nomount` phase must remain between these phases; its **position is a hard
constraint**:

- it must run **after** `gen_susfs_patch` — otherwise its changes leak into the exported `susfs.patch`
- it must run **after** `backup_defconfig` — otherwise `CONFIG_NOMOUNT` is missed by the bazel
  fragment diff

### Supply-chain anchor (optional)

`setup.sh` is fetched over the network, so its sha256 can be pinned with the `NOMOUNT_SETUP_SHA256`
environment variable. When set, the build checks it **fail-closed** and aborts on mismatch; blank
means no check (the default).

---

## 🧪 Droidspaces Container Support (Experimental)

> **Experimental feature:** Successful build and boot is not guaranteed across all GKI versions. Always back up your boot image before flashing.
>
> **TIPS:** The workflow uses the [official Droidspaces patches](https://github.com/ravindu644/Droidspaces-OSS/tree/main/Documentation/resources/kernel-patches/GKI) from [Droidspaces](https://github.com/ravindu644/Droidspaces-OSS). If you have better patches, feel free to open an issue. Since there are three patch variants, you may need to test them repeatedly to find one that fits your device. Choose based on other users' feedback or your own experience.

[Droidspaces](https://github.com/ravindu644/Droidspaces-OSS) is a lightweight Linux containerization tool that lets you run full Linux environments (with systemd, OpenRC, etc.) on Android — useful for development, running servers, and more.

**Supported versions:** 5.10 / 5.15 / 6.1 / 6.6 / 6.12

**Usage:** When triggering a build manually, select the `Droidspaces` option:

| Option | Description |
|:---:|:---|
| `不启用` (disabled) | Disabled (default) |
| `678` | Use 6_7_8 slot patch (recommended) |
| `123` | Use 1_2_3 slot patch (fallback) |
| `345` | Use 3_4_5 slot patch (fallback) |

> **Note:** Kernel 6.12 has only two options — `不启用` (disabled) and `启用` (enabled). There are no slots there.

**If the build fails or bootloops after flashing:** Try switching to a different slot patch (e.g. 678 → 123 or 345). Different kernel sub-levels may require different patches.

## 🔧 Custom Commit Pinning
Use the [`config/config`](../config/config) file to pin SUSFS and SukiSU to specific commits.

**What is a commit?**

A commit is a hash string representing the state of a repository at a specific point in time. For example, setting sukisu to `4b8644515fe6d87a109129e590ccd9d33a855dca` means using the January 30th version of SukiSU to build the kernel.

**Why pin a commit?**

- When upstream updates introduce bugs or compatibility issues, you can roll back to a stable version
- When SUSFS and SukiSU versions are out of sync causing build failures, you can manually specify compatible versions

**How to get a commit hash?**

- SUSFS: [susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu)
- SukiSU: [SukiSU-Ultra commits/builtin](https://github.com/SukiSU-Ultra/SukiSU-Ultra/commits/builtin/)

Taking SUSFS as an example, first select the branch, then copy the commit hash:

![Select branch](../assets/susfs_branch.png)
![Copy commit](../assets/susfs_commit.png)

```ini
# Enable custom commits
custom=true

# SUSFS commit hash per branch
gki-android12-5.10=
gki-android13-5.15=
gki-android14-6.1=
gki-android15-6.6=

# SukiSU commit hash
sukisu=
```

> Empty value = use the latest commit of that branch.

---

## 🧪 Spoof `/proc/config.gz` (Stock Config)

This is an advanced trick and requires no workflow toggle.  
The build process auto-detects whether `config/stock_defconfig` exists: if present, it is applied; if absent, it is skipped.

How to use:
1. Make sure your device is running stock ROM + stock kernel.
2. Obtain `/proc/config.gz` from your device (phone-side or PC-side workflow both work).
3. Decompress it, rename it to `stock_defconfig`, upload it to the [`config/`](../config/) directory in your repo, and commit (can be done directly on phone).

During the build, the workflow will automatically:
- Copy it to `$KERNEL_ROOT/common/arch/arm64/configs/stock_defconfig`
- In `$KERNEL_ROOT/common/kernel/Makefile`, switch the `$(obj)/config_data` rule from `$(KCONFIG_CONFIG)` to `arch/arm64/configs/stock_defconfig`
- Make `/proc/config.gz` in the built kernel closer to your stock kernel config
