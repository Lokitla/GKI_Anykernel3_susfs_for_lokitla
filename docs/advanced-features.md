# 🧩 进阶功能

> 本页聚合本仓库的六项进阶用法：GhostLock 安全修复、Re-Kernel、NoMount 挂载元模块、
> Droidspaces 容器支持、自定义提交配置、伪装 `/proc/config.gz`。
> 它们默认均不启用 —— 这与主文档 [README.md](../README.md) 中的「🧩 进阶功能」一节对应。
>
> 本地 CLI 的用法见 [💻 本地构建文档](local-build.md)，云端 Actions 的参数名在下表「Actions 开关」一列。

---

## 🛡️ GhostLock 安全修复

GhostLock 是影响 Linux 内核的一组高风险漏洞，包括 `CVE-2026-43499` 和 `CVE-2026-53163`。攻击者不需要 Root 权限，也不需要额外的内核模块，只要能够在设备上运行普通应用或本地代码，就可能利用该漏洞。

### 可能造成的危害

- **系统崩溃或强制重启：** 普通应用即可触发内核崩溃，导致设备无法正常使用，未保存的数据也可能丢失。
- **本地权限提升：** 更复杂的利用可以绕过 Android 权限边界，让普通应用获得内核级权限，进而控制整个设备。
- **现成利用已经公开：** 目前已有拒绝服务 PoC，以及针对 Android ARM64 平台的完整提权利用链，风险不再停留在理论阶段。
- **没有可靠的临时规避方法：** 常见的权限限制、应用隔离或系统加固只能增加利用难度，无法彻底阻止系统崩溃或其他利用方式。

该漏洞不能直接从网络远程触发，但恶意应用、共享运行环境中的不可信程序，或者已经通过其他漏洞取得代码执行能力的攻击者，都可以进一步利用它。因此，安装来源不明的应用、模块或脚本时尤其需要注意。

本项目支持在构建 5.10、5.15、6.1、6.6 和 6.12 内核时检查并应用完整修复。该选项默认关闭（ShirkNeko 原仓库没有携带该修复），如需加入 GhostLock 防护，请在触发构建时手动开启 `CVE-2026-43499 rtmutex 修复链`。两个漏洞的修复必须同时存在，工作流会自动处理这一点；已经包含完整修复的内核不会重复打补丁。

> **关于 patch 文件**：只有 `CVE-2026-43499` 在 `security_patch/` 目录下有独立 `.patch` 文件（按内核版本分为 5.10 / 5.15 / 6.1-6.6 / 6.12 五个）。`CVE-2026-53163` 的后续修复由 `security_patch/apply_cve_2026_43499.sh` **内联生成**（`ensure_remove_waiter_null_guard` 与 `replace_proxy_cleanup_condition` 两个 awk 函数），因此**没有独立的 `.patch` 文件**——这是设计如此，不是遗漏。

该修复已完成 [84 个内核版本的全量构建验证](https://github.com/zzh20188/GKI_KernelSU_SUSFS/actions/runs/29509099128)。如果想了解漏洞原理、受影响范围、公开利用和缓解措施，请阅读 CIQ 的详细文章：[GhostLock Mitigation](https://kb.ciq.com/article/rocky-linux/rl-ghostlock-mitigation)。

---

## 🔌 Re-Kernel（墓碑/冻结支持）

> **TIPS：** Re-Kernel 为「墓碑」类模块（冻结应用的模块）提供内核侧支持，
> 上游为 [Sakion-Team/Re-Kernel](https://github.com/Sakion-Team/Re-Kernel)，本仓库取其主线版本。

被冻结的进程无法正常响应，Re-Kernel 在内核里监听三类事件并上报给用户态：

| 类型 | 触发条件 | 适用场景 |
|---|---|---|
| Binder | 冻结进程收到 Binder 调用 | 系统服务或其他应用访问冻结进程 |
| Signal | 冻结进程收到 SIGKILL 等关键信号 | 感知杀进程等行为 |
| Network | 被监控 UID 收到入站网络包 | 消息类应用接收推送 |

### 开启方式

| 入口 | 参数 |
|---|---|
| Actions | `use_rekernel`（**默认关闭**） |
| 本地 CLI | `--rekernel` |

### 实现说明

源码在构建期被拉到 `common/drivers/rekernel/`，并**编译进内核**（不是外部模块），
由 `CONFIG_REKERNEL` 控制：

- `obj-m := rekernel.o` 被改写为 `obj-$(CONFIG_REKERNEL) += rekernel.o`
- `depends on MODULES` 被移除（内置编译不需要模块支持）
- 通过 `source "drivers/rekernel/Kconfig"` 挂进驱动树

---

## 🌐 网络增强（可选）

一次性启用若干**内核既有**的网络能力，不涉及第三方代码，全部通过 defconfig 写入：

| 类别 | 内容 |
|---|---|
| 拥塞控制 | `CONFIG_TCP_CONG_BBR=y` + `CONFIG_DEFAULT_BBR=y`（BBR 设为默认），另内建 BIC / CUBIC / WESTWOOD / HTCP |
| 队列调度 | `CONFIG_NET_SCH_FQ=y`、`CONFIG_NET_SCH_FQ_CODEL=y` |
| IPSet | `CONFIG_IP_SET=y`，集合上限 `CONFIG_IP_SET_MAX=65534`，并启用全部 bitmap / hash / list 类型 |
| Netfilter | `CONFIG_NETFILTER_XT_SET`、`CONFIG_NETFILTER_XT_MATCH_ADDRTYPE` |
| IPv6 NAT | `CONFIG_IP6_NF_NAT=y`、`CONFIG_IP6_NF_TARGET_MASQUERADE=y` |

**为什么强制内建（`=y`）而不是模块（`=m`）**：BIC / WESTWOOD / HTCP 在 mainline Kconfig 里
是 `default m`，一旦编成 `tcp_bic.ko` 这类模块，而 GKI 的 `module_outs` 并未声明它们，
bazel 会直接构建失败。所以本阶段写入时会把已存在的 `=m` 一并改成 `=y`。

**开启方式**

| 入口 | 参数 |
|---|---|
| Actions | `use_net_enhance`（**默认关闭**） |
| 本地 CLI | `--net-enhance` |

> 用户态需自行准备 `ipset` 工具：内核只提供能力，不附带用户态程序。
> IPSet 的 `CONFIG_IP_SET_MAX=65534` 落在内核 Kconfig 的 range（2–65534）内，无需改源码。
- defconfig 追加 `CONFIG_REKERNEL=y` 与 `CONFIG_REKERNEL_NETWORK=y`

> **为什么要内置：** Re-Kernel 依赖 `kallsyms_lookup_name` 等内核内部符号，
> 而 GKI 对**外部模块**隐藏这些符号。走 in-tree 内置编译可以看到它们，
> 所以本仓库采用内置方式而非 LKM。

---

## 📦 NoMount 挂载元模块

> 移植自上游 `zzh20188/GKI_KernelSU_SUSFS` 的 commit `27e129e`。

[NoMount](https://github.com/maxsteeel/nomount) 是一个挂载元模块，提供**无需传统挂载点**的
模块挂载方案。它在内核 `fs/` 层注册自己的子系统，与 SUSFS 的 `sus_mount` **各走各的路径**，
因此可与任意 KernelSU 变体及 SUSFS 共存。

### 开启方式

| 入口 | 参数 |
|---|---|
| Actions | `use_nomount`（**默认关闭**） |
| 本地 CLI | `--nomount` |

> ⚠️ 开启后**需要自行刷入配套的 NoMount 模块**才能使用，内核侧只提供支撑。

### 实现说明

构建期从上游拉取 `setup.sh` 并执行，完成后校验 `fs/nomount` 软链接是否就位，
再向 defconfig 追加 `CONFIG_NOMOUNT=y`。

阶段 `integrate_nomount` 必须位于这些阶段之间，**顺序有硬约束**：

- 必须在 `gen_susfs_patch` **之后** —— 否则它的改动会被算进导出的 `susfs.patch`
- 必须在 `backup_defconfig` **之后** —— 否则 `CONFIG_NOMOUNT` 不会被 bazel fragment 的 diff 捕获

### 供应链锚点（可选）

`setup.sh` 是从网络拉取的脚本，可用 `NOMOUNT_SETUP_SHA256` 环境变量固定其 sha256。
设置了就会做 **fail-closed** 校验，不符即中止构建；留空则不校验（默认）。

---

## 🧪 Droidspaces 容器支持（实验性）

> **实验性功能：** 不保证所有 GKI 版本均能成功构建或启动，刷入前请务必备份 Boot 镜像。
>
> **TIPS：** 工作流使用的是 [Droidspaces](https://github.com/ravindu644/Droidspaces-OSS) 的 [官方补丁](https://github.com/ravindu644/Droidspaces-OSS/tree/main/Documentation/resources/kernel-patches/GKI) ，如有更好的补丁可以提个issues，此外由于存在三个补丁，或许需要反复试验以确保其中一个适配你的机型，请根据他人或实际经验来选择。

[Droidspaces](https://github.com/ravindu644/Droidspaces-OSS) 是一个轻量级的 Linux 容器工具，可以在 Android 上运行完整的 Linux 环境（支持 systemd、OpenRC 等），用于搭建开发环境、运行服务器等场景。

**支持范围：** 5.10 / 5.15 / 6.1 / 6.6 / 6.12

**使用方式：** 在手动触发构建时，选择 `Droidspaces 容器支持` 选项：

| 选项 | 说明 |
|:---:|:---|
| `不启用` | 关闭（默认） |
| `678` | 使用 6_7_8 槽位补丁（推荐） |
| `123` | 使用 1_2_3 槽位补丁（备用） |
| `345` | 使用 3_4_5 槽位补丁（备用） |

> **提示：** 6.12 内核只有 `不启用` / `启用` 两项，没有槽位之分。

**如果构建失败或刷入后 bootloop：** 可尝试切换到其他槽位补丁（如 678 → 123 或 345），不同内核子版本可能适用不同的补丁。

## 🔧 自定义提交配置
通过 [`config/config`](../config/config) 文件可以指定 SUSFS 和 SukiSU 使用特定的 commit。

**什么是提交 (commit)？**

提交是一串哈希字符串，代表仓库在某个时间点的状态。例如将 sukisu 设为 `4b8644515fe6d87a109129e590ccd9d33a855dca`，即使用 1 月 30 日的 SukiSU 版本编译内核。

**为什么要指定提交？**

- 当上游仓库更新引入 bug 或兼容性问题时，可回退到稳定版本
- 当 SUSFS 与 SukiSU 版本不同步导致编译失败时，可手动指定兼容的版本

**如何获取提交哈希？**

- SUSFS: [susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu)
- SukiSU: [SukiSU-Ultra commits/builtin](https://github.com/SukiSU-Ultra/SukiSU-Ultra/commits/builtin/)

以 SUSFS 为例，先选择分支，再复制对应提交的哈希值：

![选择分支](../assets/susfs_branch.png)
![复制提交](../assets/susfs_commit.png)

```ini
# 启用自定义提交
custom=true

# SUSFS 各分支的 commit hash
gki-android12-5.10=
gki-android13-5.15=
gki-android14-6.1=
gki-android15-6.6=

# SukiSU 的 commit hash
sukisu=
```

> 留空则使用该分支的最新提交。

---

## 🧪 伪装 `/proc/config.gz`（Stock Config）

这是一个进阶技巧，不需要在工作流里手动开关。  
构建时会自动检测 `config/stock_defconfig` 是否存在：存在则应用，不存在则跳过。

使用方法：
1. 确保设备当前是官方 ROM + 官方内核。
2. 获取设备上的 `/proc/config.gz`（可在手机端或电脑端操作）。
3. 解压后重命名为 `stock_defconfig`，上传到仓库 [`config/`](../config/) 目录并提交（可直接在手机端完成）。

构建流程会自动：
- 复制到内核源码：`$KERNEL_ROOT/common/arch/arm64/configs/stock_defconfig`
- 在 `$KERNEL_ROOT/common/kernel/Makefile` 中将 `$(obj)/config_data` 规则从 `$(KCONFIG_CONFIG)` 切换为 `arch/arm64/configs/stock_defconfig`
- 使编译产物中的 `/proc/config.gz` 更贴近你的官方内核配置
