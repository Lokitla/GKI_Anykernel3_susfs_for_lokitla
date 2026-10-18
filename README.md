> **AI 辅助修改声明：** 本仓库近期内容经过 AI 辅助修改，尚未完成人工审核。许可、兼容性和构建结果均未完成全面复核。**不建议 fork 本仓库，也不建议使用本仓库构建或分发的产物。**

<div align="center">

# GKI KernelSU SUSFS

**Android GKI 内核自动化构建，集成 KernelSU 与 SUSFS**

[![Release](https://img.shields.io/github/v/release/Lokitla/GKI_SUKISU_SUSFS_for_Lokita?label=Release&style=flat-square&logo=github&logoColor=white&color=2ea44f)](https://github.com/Lokitla/GKI_SUKISU_SUSFS_for_Lokita/releases)
[![KernelSU](https://img.shields.io/badge/KernelSU-Supported-5AA300?style=flat-square)](https://kernelsu.org/)
[![SUSFS](https://img.shields.io/badge/SUSFS-Integrated-E67E22?style=flat-square)](https://gitlab.com/simonpunk/susfs4ksu)

[English](README-EN.md) | 简体中文

</div>

---

## 项目说明

本仓库基于 [zzh20188/GKI_KernelSU_SUSFS](https://github.com/zzh20188/GKI_KernelSU_SUSFS)，用于构建集成 KernelSU 和 SUSFS 的 Android GKI 内核。适配范围为 Android 12–16，对应 Linux 5.10、5.15、6.1、6.6 和 6.12。

这是一个非官方衍生项目。改动、构建配置和发布由本仓库维护；问题请在本仓库反馈。上游项目与来源说明见 [NOTICE](NOTICE) 和 [FUSION.md](FUSION.md)。

刷入第三方内核前，请确认设备和内核版本兼容，并备份原厂启动镜像。错误的镜像可能导致设备无法启动或数据丢失。

## 快速入口

| 内容 | 链接 |
|---|---|
| 构建产物 | [Releases](https://github.com/Lokitla/GKI_SUKISU_SUSFS_for_Lokita/releases) |
| 本地构建 | [docs/local-build.md](docs/local-build.md) |
| 功能说明 | [docs/advanced-features.md](docs/advanced-features.md) |
| 设备与内核版本查询 | [项目页面](https://lokitla.github.io/GKI_SUKISU_SUSFS_for_Lokita/) |
| 新手指南 | [GitHub Pages](https://lokitla.github.io/GKI_SUKISU_SUSFS_for_Lokita/guide.html) |
| 来源与许可 | [NOTICE](NOTICE) · [LICENSE](LICENSE) · [FUSION.md](FUSION.md) |

## 构建方式

构建可通过 GitHub Actions 或本地 `build.py` 启动，两者共用 [`scripts/build_kernel.sh`](scripts/build_kernel.sh) 中的构建步骤。

| 入口 | 用途 |
|---|---|
| `Build kernels` (`main.yml`) | 使用精简矩阵构建常用版本 |
| Android 12–16 独立 workflow | 手动构建对应 Android 版本的完整矩阵 |
| `kernel-custom.yml` | 按内核版本和子版本选择构建目标 |
| `build.py` | 本地单版本、矩阵或全量构建；参数见本地构建文档 |

当前矩阵概况如下。具体版本以 [`matrix.json`](.github/workflows/config/matrix.json) 和 [`data/`](data/) 为准。

| 矩阵 | 5.10 | 5.15 | 6.1 | 6.6 | 6.12 | 合计 | 用途 |
|---|---:|---:|---:|---:|---:|---:|---|
| `auto` | 5 | 6 | 5 | 3 | — | 19 | 自动触发和精简构建入口 |
| `full` | 22 | 20 | 25 | 17 | 7 | 91 | 独立 workflow 的全量版本 |
| `data/` 月度版本 | 36 | 35 | 32 | 17 | 8 | 128 | 本地 CLI 的版本数据（另含 LTS 记录）|

6.12 不在 `auto` 矩阵中。需要构建 6.12 时，请手动运行 Android 16（6.12）workflow 或使用自定义构建入口。数据更新 workflow 会同步更新全量矩阵。

## 功能

可选功能由工作流输入或本地 CLI 参数控制；不同构建入口提供的选项略有差异，详细参数以 [本地构建文档](docs/local-build.md) 和对应 workflow 为准。

- KernelSU 变体：SukiSU、SukiSU(40726)、SukiSU(40548)、BakaSU、FinaSU、Official、Next，以及保留的旧版 SukiSU 构建。
  注意：`main.yml` 不提供 Next（该入口面向稳定矩阵）；需要 Next 请用 `kernel-custom.yml` 或对应 Android 版本入口。
  三个主力变体（SukiSU / BakaSU / FinaSU）的 SUSFS 集成路径不同，选型见下面的【变体与 SUSFS】。
- SUSFS 集成与补丁适配；可按需导出补丁。
- ZRAM/LZ4KD 优化；6.12 使用本仓库维护的补丁。
- 可选 KPM、BBR 与网络配置、Baseband Guard、Re-Kernel、NoMount、Droidspaces/NTSync 和 GhostLock 修复。
- AnyKernel3 刷机包；完整产物模式还会生成不同压缩格式的 boot 镜像。
- 构建失败日志、拒绝补丁汇总和 Actions 摘要。

**兼容性提示：**

- **KPM 的实际可用范围比「版本号」窄**，三点必须同时满足：
  1. 变体提供 KPM —— 只有 SukiSU 系（含 `SukiSU(40726)` / `SukiSU(40548)`）；BakaSU / FinaSU / Official / Next 的 KernelSU 里没有 `config KPM`，请求了也会被跳过；
  2. 内核 ≤ 6.6 —— **6.10+ 自动关闭**（`kpm/super_access.c` 用了新内核已移除的 `netlink_kernel_cfg.cb_mutex`）；
  3. 内核 ≠ 6.6 —— **6.6 是特例**：构建脚本会写入 `CONFIG_KPM=y`，但跳过 Image 修补，模块实际加载不了，日志会打印「6.6 内核不支持 KPM 镜像修补」。

  因此当前**真正能加载 KPM 的是 SukiSU 系 + 内核 ≤ 6.1**。
- 6.12 构建请按需开启 ZRAM。部分设备 ROM 或内核配置可能不兼容，请先查看功能文档和对应构建记录。

## 变体与 SUSFS

三个主力变体的 SUSFS 集成走三条不同的路，选错变体会直接导致构建失败或产物功能异常。下表以代码实际行为为准（[`scripts/build_kernel.sh`](scripts/build_kernel.sh)）。

| 变体 | SUSFS 集成方式 | 管理器来源 | 注意事项 |
|---|---|---|---|
| **SukiSU** | 上游 KernelSU 内置 SUSFS 支持，本仓库只做 UAPI 对齐与上下文适配 | [SukiSU-Ultra](https://github.com/SukiSU-Ultra/SukiSU-Ultra) Actions 产物 | 开启 SUSFS 时自动选 `builtin`；`main` 分支与 SUSFS 冲突（`main` 用 `ksu_patch_text` 运行时改写，SUSFS 补丁用 `my_*` 替换，两者互踩），会**两道防线**拦住：①`ALLOW_SUSFS_WITH_MAIN=1` 才放行这条；②补丁落地后还会 grep `ksu_patch_text` 再拦一次。注意 CI 入口未暴露该变量，actions 上只能走 `builtin` |
| **BakaSU** | 上游 KernelSU 内置 SUSFS 支持，但上游对 SUSFS 构建**主动挂起**，本仓库按树内证据逐版本判定放行 | [BakaSU](https://github.com/Baka-SU/BakaSU) Actions 产物 | 上游 `susfs_compat.mk` 仍带无条件 `$(error)`；支持情况由 [`scripts/bakasu_compat/resume_susfs.sh`](scripts/bakasu_compat/resume_susfs.sh) 在补丁落地后判定，不通过即中止 |
| **FinaSU** | 走**上游 KernelSU 侧 SUSFS 补丁 + 本仓库结构适配补丁**（`scripts/finasu_compat/`），与上两者形态不同 | [FinaSU](https://github.com/LyraVoid/FinaSU) 官方 Release APK | 内核与管理器必须对齐同一 Release：构建时克隆 FinaSU 并检出该 Release 对应提交，同时把管理器 APK 的签名证书写入内核信任列表，否则管理器无法识别内核 |
| **Official / Next** | 无内置 SUSFS；Official 需额外打上游 `10_enable_susfs_for_ksu.patch` | [KernelSU](https://github.com/tiann/KernelSU) / [KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next) | Next 的 `dev` 分支未提供 `KSU_SUSFS_*` 开关，不能同时开启 SUSFS |

补充说明：

- **SUSFS 补丁源**：BakaSU / SukiSU 默认从 [simonpunk/susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu) 的 `gki-<android>-<kernel>` 分支克隆；SukiSU 会优先尝试 ShirkNeko 的 fork，分支不存在时回落到原版。
  主流变体跟随分支头、不钉提交；但**旧版变体（`SukiSU(40726)` / `SukiSU(40548)`）是例外**：它们按各自 `config/legacy_*` 里记录的固定提交检出，既不试 ShirkNeko 也不跟分支头——旧变体本就依赖特定提交才能编过。
  需要在新变体上复现历史构建时，可在入口的「提交 hash」第 2 段填 SUSFS 提交（Actions 界面没有单独的 `susfs_commit` 输入框）。
- **BakaSU 的挂起不是本仓库造成的**：上游自 `48fa4bb` 起主动停用 SUSFS 构建，等待 simonpunk 同步新的 `selinux_hide` 模型。本仓库不无条件放行，而是核对补丁落地后的真实形态（< 6.6 看 `hooks.c` 的手动钩子与 `should_check_current`，≥ 6.6 看 `selinuxfs.c` 的 `_with_policy` 模型；也可能命中 `backup_sepolicy` 新形态），判定不通过就明确失败，避免产出上游刻意规避的可检测内核。
- **BakaSU / FinaSU 的 SELinux 模型与旧式 SUSFS 不同**：BakaSU（`d7260ca1` 起）与 FinaSU 上游都已移除 `fake_state`，改用 `backup_sepolicy` + `security_*_with_policy`；而 SUSFS 主补丁仍按旧模型 `extern` 引用 `fake_state`，直接编译会在 ThinLTO 链接期报 `undefined symbol: fake_state`。本仓库在补丁落地后自动改写这些引用（**对 BakaSU 与 FinaSU 都生效**，判据是 `selinux_hide.c` 里已无 `fake_state`）（[`scripts/susfs_fixes/apply.sh`](scripts/susfs_fixes/apply.sh) 的 `adapt_finasu_selinux_hide_model`）；改写不成功（待替换串不是恰好命中一次、或仍有残留）一律中止构建。
- **FinaSU 的内核侧集成脚本来自 [LingLuo17/AnyKernel3](https://github.com/LingLuo17/AnyKernel3)**：`scripts/finasu_compat/apply.sh` 移植自该仓库 commit `d6255c5f44e3871743c7d1570436822227b4b2fd`（GPL-3.0-only），`extract_manager_cert.py` 移植自 commit `fb8379aa781f9e94cabee2c12f543144035b5da3`。这两处的来源、许可与改动说明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
- **自动触发覆盖范围**：`Auto_Trigger_BakaSU.yml` 与 `Auto_Trigger_SukiSU.yml` 只跟踪这两个变体的上游更新；FinaSU 目前需手动触发构建。

### 版本对齐与跟随策略

本仓库的通用约定是 **「不指定就跟随上游最新」**，只有显式传入 hash/tag 时才钉死版本：

- **KernelSU 检出**：SukiSU 走 `main` 或 `builtin`（开 SUSFS 时自动 `builtin`）；BakaSU / FinaSU 会对齐到所选管理器构建的同一提交，以便内核 KSU 版本与管理器 APK 严格一致。
- **SUSFS 补丁源**：始终克隆上游 `gki-<android>-<kernel>` 分支头，不钉提交；需要复现时传 `susfs_commit`。
- **KernelSU UAPI 版本**：目标值**取自内核实际检出所在分支的** `supercall.h` —— `main` 在 `uapi/supercall.h`、`builtin` 在 `kernel/include/uapi/supercall.h`，两者独立演进。因此不会出现「把 BakaSU 的版本号改成 SukiSU 的号」这类错配。
- **KPM 修补工具**：随 [SukiSU_patch](https://github.com/SukiSU-Ultra/SukiSU_patch) 上游最新，**不阻断构建**。`config/kpm_patch_sha256` 只是「上次构建时上游的样子」，值变化时打印 `::warning::` 并继续；只有显式传入 `kpm_patch_sha256` 才做 fail-closed 比对。上游更新后可用 `scripts/tools/pin_kpm_patch.sh` 刷新记录。

## 本地构建

本地构建需要 Linux 环境。查看支持的版本并构建一个版本：

```bash
python3 build.py --list-configs
python3 build.py --android android14 --kernel 6.1 --sub-level 124 --os-patch 2025-02
```

更多环境要求、参数、断点续建和单步调试说明见 [`docs/local-build.md`](docs/local-build.md)。

## 上游更新

定时 workflow 会检查 SukiSU 和 BakaSU 的上游更新，并按配置触发构建。构建范围、触发条件和所需仓库权限见 `.github/workflows/Auto_Trigger_*.yml`。

FinaSU 暂未接入定时触发，需要时手动运行构建入口。SUSFS 补丁源与 KernelSU 变体按构建时的上游最新状态拉取，因此同一入口在不同日期构建出的 SUSFS 版本可能不同；需要可复现的产物时，用「提交 hash」输入锁定管理器/内核 KSU 提交。

## 目录结构

| 路径 | 内容 |
|---|---|
| `.github/workflows/` | 构建、发布、管理器下载和数据更新 workflow |
| `scripts/build_kernel.sh` | Actions 与本地 CLI 共用的构建步骤 |
| `scripts/susfs_fixes/` | SUSFS 主补丁应用与上下文适配（含 SELinux 模型改写） |
| `scripts/bakasu_compat/` | BakaSU 上游 SUSFS 挂起判定与放行 |
| `scripts/finasu_compat/` | FinaSU 结构适配补丁与补丁应用 |
| `scripts/sukisu_compat/` | SukiSU 兼容补丁 |
| `scripts/ksu_uapi_sync/` | 内核侧 KernelSU UAPI 版本对齐 |
| `scripts/get_manager.sh` | 管理器与管理器工件下载（由 workflow 调用） |
| `data/` | Android 与内核版本数据 |
| `config/` | 内核配置片段 |
| `security_patch/` | 可选安全修复补丁 |
| `zram/` | ZRAM 补丁及相关源码 |
| `docs/` | 本地构建和功能文档 |
| `web/` | GitHub Pages 页面源码 |

## 来源与许可

本项目包含多个上游项目的代码、补丁和配置，不能用单一许可证概括。当前审查发现 SUSFS 内核补丁标注为 GPL-3.0-or-later，而 Linux 内核主体为 GPL-2.0-only；两者组合用于同一内核产物存在许可不兼容风险。当前文档和 `LICENSE` 不能消除此风险。详见 [NOTICE](NOTICE) 与 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

主要上游包括 [zzh20188/GKI_KernelSU_SUSFS](https://github.com/zzh20188/GKI_KernelSU_SUSFS)、[LingLuo17/AnyKernel3](https://github.com/LingLuo17/AnyKernel3)、[SukiSU-Ultra](https://github.com/SukiSU-Ultra/SukiSU-Ultra)、[FinaSU](https://github.com/LyraVoid/FinaSU)、[KernelSU](https://github.com/tiann/KernelSU) 和 [susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu)。FinaSU 已接入管理器获取、内核版本对齐及第二签名证书信任配置；来源与许可信息见 [NOTICE](NOTICE)。
