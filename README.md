> ## ⚠️ 先读这一段
>
> - **本仓库是个人自用的内核构建仓库**，不是官方项目，也不面向公众发布。没有任何形式的支持承诺。
> - 仓库内**大量内容由 AI 辅助生成或修改，尚未完成人工审核**。许可、兼容性、构建结果均未全面复核；文档与代码不一致是已知风险。
> - **不建议 fork 本仓库**，也不建议直接使用或分发本仓库构建出的任何产物。
> - **刷第三方内核风险自负**：可能导致设备无法开机、丢失数据或变砖。刷入前必须备份 `boot`、`vendor_boot`、`init_boot`（视设备而定）等分区，并确认已有可回退的原厂镜像。**作者不对任何直接或间接损失承担责任。**
> - 若你仍然决定使用：**请自行审计源码、自行验证产物、自行承担后果**。

<div align="center">

# GKI KernelSU SUSFS

**Android GKI 内核自动化构建，集成 KernelSU 与 SUSFS**

[![Release](https://img.shields.io/github/v/release/Lokitla/GKI_SUKISU_SUSFS_for_Lokita?label=Release&style=flat-square&logo=github&logoColor=white&color=2ea44f)](https://github.com/Lokitla/GKI_SUKISU_SUSFS_for_Lokita/releases)
[![KernelSU](https://img.shields.io/badge/KernelSU-Supported-5AA300?style=flat-square)](https://kernelsu.org/)
[![SUSFS](https://img.shields.io/badge/SUSFS-Integrated-E67E22?style=flat-square)](https://gitlab.com/simonpunk/susfs4ksu)

[English](README-EN.md) | 简体中文

</div>

---

## 📦 代码来源与致谢

本仓库**不是从零实现**，而是把多个上游项目的代码、补丁与配置按自己的流程拼装起来。下面逐项列出实际引入的来源；每一条都能在 `NOTICE` 或对应脚本里核到。

### 主要上游

| 上游 | 在本仓库中的角色 | 许可证 |
|---|---|---|
| [zzh20188/GKI_KernelSU_SUSFS](https://github.com/zzh20188/GKI_KernelSU_SUSFS) | **本仓库的基底**：构建流程、配置与部分补丁来源；`hmbird_patch.c` 也从其 `dev` 分支拉取 | GPL-2.0 |
| [AOSP kernel/common](https://android.googlesource.com/kernel/common/) / Linux | 被修改和编译的 GKI 内核基线 | 内核主体 GPL-2.0-only，个别文件另有兼容声明 |
| [tiann/KernelSU](https://github.com/tiann/KernelSU) | `Official` 变体的 KernelSU 实现 | GPL-2.0（以 `kernel/` 内文件头为准） |
| [KernelSU-Next/KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next) | `Next` 变体的 KernelSU 实现（`dev` 分支） | 以上游文件头为准 |
| [SukiSU-Ultra/SukiSU-Ultra](https://github.com/SukiSU-Ultra/SukiSU-Ultra) | `SukiSU` 变体（`main` / `builtin` 分支）与对应管理器 | 以上游文件头为准 |
| [Baka-SU/BakaSU](https://github.com/Baka-SU/BakaSU)（原名 ReSukiSU） | `BakaSU` 变体的内核与管理器 | 内核目录 GPL-2.0-only；其他代码 GPL-3.0-or-later；图标与美术资源另有条款 |
| [LyraVoid/FinaSU](https://github.com/LyraVoid/FinaSU) | `FinaSU` 变体的内核源码与官方 Release APK | 仓库标记 GPL-3.0 |
| [simonpunk/susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu) | SUSFS 主补丁来源，按 `gki-<android>-<kernel>` 分支克隆 | GPL-3.0-or-later |
| [ShirkNeko/susfs4ksu](https://github.com/ShirkNeko/susfs4ksu) | `SukiSU` 变体优先尝试的 susfs4ksu fork，分支不存在时回落原版 | 同上 |

### 构建期拉取的组件

| 上游 | 用途 | 许可证 / 状态 |
|---|---|---|
| [WildKernels/AnyKernel3](https://github.com/WildKernels/AnyKernel3) | 生成 AnyKernel3 刷机包 | 以实际检出版本的文件头与 `LICENSE` 为准 |
| [LingLuo17/AnyKernel3](https://github.com/LingLuo17/AnyKernel3) / [osm0sis/AnyKernel3](https://github.com/osm0sis/AnyKernel3) | FinaSU 内核侧集成脚本与 BakaSU SUSFS 门控的移植来源（commit `d6255c5f`、`fb8379aa`、`6db3a675`） | GPL-3.0-only（随 `LICENSE-GPL-3.0.txt` 附全文） |
| [SukiSU-Ultra/SukiSU_patch](https://github.com/SukiSU-Ultra/SukiSU_patch) | 预编译 `patch_linux`（KPM 修补）、ZRAM/LZ4KD 补丁、`10_enable_susfs_for_ksu.patch` | `patch_linux` **未见明确许可证** |
| [WildKernels/kernel_patches](https://github.com/WildKernels/kernel_patches) | 可选三星 `min_kdp.c` 源码 | **上游未见许可证声明** |
| [Numbersf/Action-Build](https://github.com/Numbersf/Action-Build) | Unicode 修复补丁 | 自定义条款，非标准 GPL |
| [maxsteeel/nomount](https://github.com/maxsteeel/nomount) | 可选 NoMount 内核源码 | GPL-3.0 |
| [Sakion-Team/Re-Kernel](https://github.com/Sakion-Team/Re-Kernel) | 可选 Re-Kernel 驱动 | 以固定上游提交与本仓库文件头为准 |
| [ravindu644/Droidspaces-OSS](https://github.com/ravindu644/Droidspaces-OSS) | 可选 Droidspaces 容器支持 | 同上 |
| [Goldzxcbug/Droidspaces_Kernel_patch](https://github.com/Goldzxcbug/Droidspaces_Kernel_patch) | NTSync 基础补丁与版本补丁 | **未见明确许可证，NOTICE 中也未单列**；启用前请自查 |
| [vc-teahouse/Baseband-guard](https://github.com/vc-teahouse/Baseband-guard) | 可选 BBG 基带保护 | 以固定上游提交与本仓库文件头为准 |
| [sidex15/susfs4ksu-module](https://github.com/sidex15/susfs4ksu-module) | 独立用户态 SUSFS 模块 ZIP | AGPL-3.0（独立打包，不进入内核源码） |
| [lz4/lz4](https://github.com/lz4/lz4)（Yann Collet） | `zram/lz4/` 中的 LZ4 实现 | BSD-2-Clause（`zram/lz4/lz4.c` 等文件头自述；`NOTICE` 未单列该目录） |
| Huawei EROFS | `zram/lz4/lz4armv8/` 的 arm64 NEON 解压实现 | 头注释自述源自华为 EROFS，**文件本身未写许可证**，`NOTICE` 也未收录 —— 属已知许可缺口 |

### 本仓库自维护的部分

- `scripts/` 下的 `*.sh`、`*.py`（含 `build_kernel.sh`、`get_manager.sh`、`susfs_fixes/`、`bakasu_compat/`、`sukisu_compat/`、`ksu_uapi_sync/`、`susfs_probe/` 等）、`build.py`、`zram_patch/6.12/`、`security_patch/` 的驱动脚本，**由本仓库作者自行维护，不属于任何上游项目，同样不提供任何担保**。
- 其中 `scripts/finasu_compat/apply.sh` 与 `extract_manager_cert.py`、`scripts/bakasu_compat/resume_susfs.sh` 是**从 LingLuo17/AnyKernel3 移植并按本仓库结构改写**的，按 GPL-3.0-only 保留来源与许可，详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
- 根目录 `LICENSE`（GPL-2.0）只覆盖本仓库原创部分，**不能覆盖或改写任何第三方许可**。

> 完整的组件清单、许可判断依据与已知风险见 [NOTICE](NOTICE) 与 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。本仓库**无法用单一许可证概括**。

## 项目说明

本仓库基于 [zzh20188/GKI_KernelSU_SUSFS](https://github.com/zzh20188/GKI_KernelSU_SUSFS)，用于构建集成 KernelSU 与 SUSFS 的 Android GKI 内核。适配范围为 Android 12–16，对应 Linux 5.10、5.15、6.1、6.6 与 6.12。

这是一个**非官方衍生项目**，仅供作者个人自用。改动、构建配置与发布都由本仓库维护，但**不代表任何上游项目的立场**。

## 快速入口

| 内容 | 链接 |
|---|---|
| 构建产物 | [Releases](https://github.com/Lokitla/GKI_SUKISU_SUSFS_for_Lokita/releases) |
| 本地构建 | [docs/local-build.md](docs/local-build.md) |
| 功能说明 | [docs/advanced-features.md](docs/advanced-features.md) |
| 设备与内核版本查询 | [项目页面](https://lokitla.github.io/GKI_SUKISU_SUSFS_for_Lokita/) |
| 新手指南 | [GitHub Pages](https://lokitla.github.io/GKI_SUKISU_SUSFS_for_Lokita/guide.html) |
| 来源与许可 | [NOTICE](NOTICE) · [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) · [LICENSE](LICENSE) · [LICENSE-GPL-3.0.txt](LICENSE-GPL-3.0.txt) |
| 上游整合记录 | [FUSION.md](FUSION.md) |

## 构建方式

构建可以由 GitHub Actions 或本地 `build.py` 启动，两者共用 [`scripts/build_kernel.sh`](scripts/build_kernel.sh) 中的 53 个构建阶段。

| 入口 | 用途 |
|---|---|
| `main.yml`（「构建内核」） | 使用精简矩阵构建常用版本；`workflow_dispatch` 输入项名额已按仓内注释所述用满（见 `main.yml` 内注释），`Next` 变体未在此入口开放 |
| Android 12–16 独立 workflow | 手动构建对应 Android 版本的完整矩阵（`kernel-a12-5-10.yml` 等 5 个） |
| `kernel-custom.yml`（「Android 内核构建-自定义」） | **自定义构建入口**：按内核版本 + 子版本 + 变体选择单个目标，输入项最全（含 `Next`） |
| `build.py` | 本地单版本、矩阵或全量构建；参数见 [本地构建文档](docs/local-build.md) |

当前矩阵概况如下，具体版本以 [`matrix.json`](.github/workflows/config/matrix.json) 与 [`data/`](data/) 为准。

| 矩阵 | 5.10 | 5.15 | 6.1 | 6.6 | 6.12 | 合计 | 用途 |
|---|---:|---:|---:|---:|---:|---:|---|
| `auto` | 5 | 6 | 5 | 3 | — | 19 | 自动触发与精简构建入口 |
| `full` | 22 | 20 | 25 | 17 | 7 | 91 | 独立 workflow 的全量版本 |
| `data/` 月度版本 | 36 | 35 | 32 | 17 | 8 | 128 | 本地 CLI 的版本数据（另含 LTS 记录） |

6.12 不在 `auto` 矩阵中。需要构建 6.12 时，请手动运行 Android 16（6.12）workflow 或使用 `kernel-custom.yml`。

> **Android 版本 ↔ 内核版本**：Android 12 → 5.10、Android 13 → 5.15、Android 14 → 6.1、Android 15 → 6.6、Android 16 → 6.12。workflow 与参数里的 `a12` … `a16` 就是这套映射，不要跨着选（例如 a14 只对应 6.1）。

## 🚀 快速开始：先选对入口

| 你想做什么 | 用哪个入口 | 关键输入 |
|---|---|---|
| 先编一个版本试试 | `kernel-custom.yml` | `kernel_version` + `os_patch_level`（如 `66`）+ `kernelsu_variant`；上传模式默认「仅上传 AnyKernel3.zip」 |
| 编某个 Android 版本的全量矩阵 | `kernel-a12-5-10.yml` … `kernel-a16-6-12.yml`（5 个） | 一般直接 Run workflow；版本清单来自 `full` 矩阵 |
| 走常用精简组合、产出 Release | `main.yml` | `kernelsu_variant`、`release_type`；用 `build_targets` 限定目标（`a12,a14` 或 `all`） |
| 完全本地构建 | `build.py` | 见 [本地构建](docs/local-build.md) |

三条实操提醒：

- **第一次建议**：用 `kernel-custom.yml`、`build_scope=指定版本`、「仅上传 AnyKernel3.zip」——一次 Run 只出一个刷机包，最省时间与额度。
- **`os_patch_level` 不是内核版本**：它接受子版本代号（`66`、`236`）、补丁级别日期（`2022-01`），也能逗号分隔多个（`66,236,2022-01`）；只填一个就只编一个。
- **只有 `main.yml` 会建 Release**；五个 `kernel-a1x` 与 `kernel-custom.yml` 只上传 Actions 工件。

## 构建输入速查

以下两表按 workflow 定义逐项核对（`.github/workflows/main.yml`、`.github/workflows/kernel-custom.yml`），默认值与选项以文件为准。

### `kernel-custom.yml`：21 项，选项最全（含 `Next`）

| 输入 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `kernel_version` | choice | `5.10` | 5.10 / 5.15 / 6.1 / 6.6 / 6.12 |
| `kernelsu_variant` | choice | `BakaSU` | SukiSU / SukiSU(40726) / SukiSU(40548) / BakaSU / FinaSU / Official / `Next` |
| `enable_susfs` | boolean | `true` | 集成 SUSFS；各变体集成路径不同，见「变体与 SUSFS」 |
| `use_kpm` | choice | `patched (开启并修补)` | disabled / enabled / patched；真正能生效的组合见「KPM 兼容性」 |
| `droidspaces` | choice | `不启用` | 不启用 / 678 / 123 / 345；6.12 只有「不启用 / 启用」两项 |
| `artifact_upload_mode` | choice | `仅上传 AnyKernel3.zip` | 或「上传全部」（额外产出 boot 等 `*.img`） |
| `build_scope` | choice | `指定版本` | 指定版本 / 全部版本 / 仅 LTS；选后两者时 `os_patch_level` 不生效 |
| `os_patch_level` | string | `66` | 子版本代号或补丁级别日期，可逗号分隔多个 |
| `version` | string | 空 | 自定义版本名（可选） |
| `build_time` | string | 固定 UTC 时间串 | 自定义构建时间；`N` 或留空 = 当前 UTC |
| `use_zram` | boolean | `true` | ZRAM/LZ4KD 增强算法 |
| `use_bbg` | boolean | `false` | BBG 基带保护 |
| `use_rekernel` | boolean | `false` | Re-Kernel 驱动 |
| `use_nomount` | boolean | `false` | NoMount 挂载元模块 |
| `cve_2026_43499_patch` | boolean | `false` | CVE-2026-43499 / 53163 rtmutex 修复链 |
| `droidspaces_ntsync` | boolean | `false` | NTSync 支持（需先启用 Droidspaces） |
| `use_net_enhance` | boolean | `false` | IPSet 全类型 + BBR + FQ/FQ_CODEL + IPv6 NAT 等 |
| `supp_op` | boolean | `false` | 一加 8E 支持；**非一加设备勿开** |
| `send_telegram` | boolean | `true` | Telegram 通知（需配置 secrets） |
| `use_release_cache` | boolean | `false` | 用 GitHub Release 存 ccache（见「产物与命名」） |
| `manager_commit` | string | 空 | `<管理器&内核KSU>,<SUSFS>` 两段；留空跟随上游最新，语义见下文专节 |

### `main.yml`：20 项

| 输入 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `release_type` | choice | `Release` | Release / Pre-Release / Actions |
| `kernelsu_variant` | choice | `BakaSU` | 6 个，**不含 `Next`** |
| `build_targets` | string | `all` | 逗号分隔 `a12/a13/a14/a15/a16` 或 `all`，只跑命中的 job |
| `export_susfs_patches` | boolean | `true` | 收集 SUSFS 集成补丁（SukiSU / BakaSU / FinaSU） |
| `enable_susfs` / `use_kpm` / `use_zram` / `droidspaces` 等 | — | — | 与 `kernel-custom.yml` 同名项含义一致 |

两表的主要差异：`main.yml` 没有 `kernel_version` / `os_patch_level` / `build_scope` / `artifact_upload_mode`（它跑固定的 `auto` 精简矩阵，用 `build_targets` 限定范围），也不开放 `Next`；反过来它多一个 `export_susfs_patches`。

## 产物与命名

| 产物 | 命名规则 | 何时出现 |
|---|---|---|
| 刷机包 | `<android版本>-<内核版本>.<子版本>-<os_patch_level>-AnyKernel3.zip`，例 `android14-6.1.177-2025-02-AnyKernel3.zip`（`anykernel3_zip_name()`，`scripts/build_kernel.sh:4181-4183`） | 每次构建；「仅上传 AnyKernel3.zip」模式下是唯一产物 |
| 内核镜像 | `*.img` → artifact `…-Images` | 仅「上传全部」模式 |
| 构建日志 | `build-logs/` → artifact `…-Build-Logs`；`main.yml` 汇总为 `AIO-BUILD-LOGS.zip` | 每次构建 |
| 补丁拒绝汇总 | `patch-rejects/` → artifact `…-Rejects`；`main.yml` 汇总为 `AIO-REJ.zip` | 有 hunk 失配时非空 |
| SUSFS 集成补丁 | `susfs-patch/` → artifact `SUSFS-Patch-<变体>-…`；`main.yml` 汇总为 `SUSFS-Patches-<变体>` | `export_susfs_patches=true`（`main.yml`）或相应开关 |
| SUSFS 探测报告 | `susfs-probe/` → artifact `SUSFS-Probe-…` | 每次构建 |
| ccache 缓存 | Release `Build Cache`（tag `ccache-cache`），资产 `cache-<分支>-<android>-<kernel>-<sub>.tar.zst`（另带 `.hmac`） | 勾 `use_release_cache` 时 |

AnyKernel3.zip 里就是 [WildKernels/AnyKernel3](https://github.com/WildKernels/AnyKernel3) 的模板目录 + 刚编出的 `Image`（`scripts/build_kernel.sh:4236-4250`）；产物名由 `anykernel3_zip_name()` 生成，`SUB_LEVEL` 会直接拼进文件名。


仓库当前共有 15 个工作流文件、`scripts/build_kernel.sh` 4751 行、`build.yml` 21 个步骤。

## 功能

可选功能由工作流输入或本地 CLI 参数控制；不同入口提供的选项略有差异，详细参数以 [本地构建文档](docs/local-build.md) 与对应 workflow 为准。

- KernelSU 变体：SukiSU、SukiSU(40726)、SukiSU(40548)、BakaSU、FinaSU、Official、Next，共 7 个（以 `build.py` 的 `KSU_VARIANTS` 为准）。
  注意：`main.yml` 不提供 `Next`（该入口面向稳定矩阵，且输入项名额已满）；需要 `Next` 请用 `kernel-custom.yml`。
- SUSFS 集成与补丁适配；可按需导出集成补丁。
- ZRAM/LZ4KD 优化；6.12 使用本仓库维护的补丁（`zram_patch/6.12/`）。
- 可选 KPM、网络增强（IPSet + BBR + FQ/FQ_CODEL + IPv6 NAT）、Baseband Guard、Re-Kernel、NoMount、Droidspaces/NTSync、一加 8E 支持与 CVE-2026-43499/53163 修复。
- AnyKernel3 刷机包；完整产物模式还会生成不同压缩格式的 boot 镜像。
- 构建失败日志、拒绝补丁汇总与 Actions 摘要。

### ⚠️ KPM 兼容性（实际可用范围比版本号窄得多）

KPM 需要以下条件**同时**满足：

1. **变体提供 KPM** —— 只有 SukiSU 系（含 `SukiSU(40726)` / `SukiSU(40548)`）。`BakaSU` / `FinaSU` / `Official` / `Next` 的内核**没有 `config KPM`**，请求了也会被跳过并打印警告（`scripts/build_kernel.sh:1585-1594`，`stage_add_kernelsu` 里的 `KPM_SUPPORTED` 判定）。
2. **内核 ≤ 6.6** —— 6.10 及以上会自动关闭（`kpm/super_access.c` 用了新内核已移除的 `netlink_kernel_cfg.cb_mutex`）。
3. **内核 ≠ 6.6** —— 6.6 是特例：构建脚本会写入 `CONFIG_KPM=y`，但**跳过 Image 修补**，模块实际加载不了，日志会打印「6.6 内核不支持 KPM 镜像修补」（`scripts/build_kernel.sh:3899`）。

**因此当前真正能加载 KPM 的组合是：SukiSU 系 + 内核 ≤ 6.1。**

## 变体与 SUSFS

各变体的 SUSFS 集成路径不同，选错会导致构建失败或产物功能异常。下表以代码实际行为为准（[`scripts/build_kernel.sh`](scripts/build_kernel.sh)）。

| 变体 | SUSFS 集成方式 | 管理器来源 | 注意事项 |
|---|---|---|---|
| **SukiSU** | 上游 KernelSU 内置 SUSFS 支持，本仓库只做 UAPI 对齐与上下文适配 | [SukiSU-Ultra](https://github.com/SukiSU-Ultra/SukiSU-Ultra) Actions 产物 | 开启 SUSFS 时自动选 `builtin`；`main` 分支与 SUSFS 冲突（`main` 用 `ksu_patch_text` 运行时改写，SUSFS 补丁用 `my_*` 替换，两者互踩），有**两道防线**：①`ALLOW_SUSFS_WITH_MAIN=1` 才放行；②补丁落地后还会 grep `ksu_patch_text` 再拦一次。CI 入口未暴露该变量，Actions 上只能走 `builtin` |
| **BakaSU** | 上游 KernelSU 内置 SUSFS 支持，但上游对 SUSFS 构建**主动挂起**，本仓库按树内证据逐版本判定放行 | [BakaSU](https://github.com/Baka-SU/BakaSU) Actions 产物 | 上游 `susfs_compat.mk` 仍带无条件 `$(error)`；由 [`scripts/bakasu_compat/resume_susfs.sh`](scripts/bakasu_compat/resume_susfs.sh) 在补丁落地后判定，不通过即中止。**另见下方钉提交警告** |
| **FinaSU** | 走上游 KernelSU 侧 SUSFS 补丁 + 本仓库结构适配补丁（`scripts/finasu_compat/`） | [FinaSU](https://github.com/LyraVoid/FinaSU) 官方 Release APK | 内核与管理器必须对齐同一 Release：构建时检到该 Release 对应提交，并把管理器 APK 的签名证书写入内核信任列表，否则管理器无法识别内核 |
| **Official / Next** | 无内置 SUSFS；Official 需额外应用上游 `10_enable_susfs_for_ksu.patch` | [KernelSU](https://github.com/tiann/KernelSU) / [KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next) | `Next` 的 `dev` 分支未提供 `KSU_SUSFS_*` 开关，**不能同时开启 SUSFS**（脚本会直接报错） |

### ⚠️ BakaSU + 集成 SUSFS：必须钉 SUSFS 提交

用 `BakaSU` 并勾选「集成 SUSFS」时，**必须**把 SUSFS 段钉死到：

```
c06d5f8ef2b53d04c5e1c6b86dc3076f1e0e9f33
```

即 `manager_commit` 填 `0,c06d5f8ef2b53d04c5e1c6b86dc3076f1e0e9f33`（第 1 段 `0` = 不锁管理器/内核 KSU，第 2 段锁 SUSFS）。

**原因**：更新的 SUSFS 已切到「接管式」模型，要求 KernelSU 以非 `static` 符号导出 `my_setprocattr` / `my_write_context` / `my_write_access`；BakaSU 尚未同步，跟随分支最新会得到 `undefined symbol` 之类的链接错误。

> 说明：这条经验来自本仓库的构建记录，**没有写进任何 workflow 的输入描述**，所以 Actions 界面不会提示你。

### 补充说明

- **SUSFS 补丁源**：默认从 [simonpunk/susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu) 的 `gki-<android>-<kernel>` 分支克隆；SukiSU 会优先尝试 ShirkNeko 的 fork，分支不存在时回落原版。
- **旧变体是例外**：`SukiSU(40726)` / `SukiSU(40548)` 按各自 `config/SukiSU(40726).config` / `config/SukiSU(40548).config` 中记录的固定提交检出（这两个变体按 SukiSU-Ultra 的提交计数命名，是历史快照）；文件缺失时构建直接 `exit 1`。
- **BakaSU 的挂起不是本仓库造成的**：上游自 `48fa4bb`（`kernel: suspend susfs build`）起主动停用 SUSFS 构建，等待上游同步新的 `selinux_hide` 模型。本仓库不无条件放行，而是核对补丁落地后的真实形态：< 6.6 检查 `hooks.c` 的手动钩子与 `should_check_current` / `backup_sepolicy`；≥ 6.6 检查 `selinuxfs.c` 的 `_with_policy` 模型。**判定不了一律 fail-closed**，避免产出上游刻意规避的可检测内核。
- **BakaSU / FinaSU 的 SELinux 模型与旧式 SUSFS 不同**：两者上游都已移除 `fake_state`，改用 `backup_sepolicy` + `security_*_with_policy`；而 SUSFS 主补丁仍按旧模型 `extern` 引用 `fake_state`，直接编译会在 ThinLTO 链接期报 `undefined symbol: fake_state`。本仓库在补丁落地后自动改写这些引用（`adapt_finasu_selinux_hide_model`，见 [`scripts/susfs_fixes/apply.sh`](scripts/susfs_fixes/apply.sh)）；改写不成功一律中止构建。
- **FinaSU 的内核侧集成脚本来自 [LingLuo17/AnyKernel3](https://github.com/LingLuo17/AnyKernel3)**：`scripts/finasu_compat/apply.sh` 移植自 commit `d6255c5f44e3871743c7d1570436822227b4b2fd`（GPL-3.0-only），`extract_manager_cert.py` 移植自 commit `fb8379aa781f9e94cabee2c12f543144035b5da3`。来源、许可与改动见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
- **自动触发覆盖范围**：`Auto_Trigger_BakaSU.yml` 与 `Auto_Trigger_SukiSU.yml` 只跟踪这两个变体的上游更新（每 3 天一次）；FinaSU 目前需手动触发。

## 🧩 进阶功能

以下七项默认都不启用，开启方式与细节见 [docs/advanced-features.md](docs/advanced-features.md)。

| 功能 | 说明 | Actions 开关 |
|---|---|---|
| 🛡️ GhostLock 安全修复 | 修补 `rtmutex` 相关 CVE-2026-43499 / CVE-2026-53163 漏洞链 | `cve_2026_43499_patch` |
| 🔌 Re-Kernel | 墓碑/冻结支持驱动 | `use_rekernel` |
| 🌐 网络增强 | IPSet 全类型 + BBR + FQ/FQ_CODEL + IPv6 NAT + 附加拥塞算法 | `use_net_enhance` |
| 📦 NoMount | 挂载元模块（不依赖挂载命名空间） | `use_nomount` |
| 🧪 Droidspaces | 容器支持（实验性）；5.10/5.15/6.1/6.6 可选 `678` / `123` / `345` 槽位，6.12 只有「不启用 / 启用」两项 | `droidspaces` + `droidspaces_ntsync` |
| 🔧 自定义提交配置 | 通过 `config/config` 或 `manager_commit` 输入锁定提交 | `manager_commit` |
| 🧪 伪装 `/proc/config.gz` | 放入 `config/stock_defconfig` 后自动启用，伪装为原厂配置 | 无开关（存在即启用） |

### `manager_commit` 的语义

格式为 **`<管理器&内核KSU>,<SUSFS>`**，逗号或竖线分隔均可，`0` 表示该段不指定，留空表示完全不锁定。

| 写法 | 含义 |
|---|---|
| `abc123...,0` | 只锁管理器与内核 KSU 提交 |
| `0,def456...` | 只锁 SUSFS 提交（BakaSU 必须这样写，见上文） |
| `abc123...,def456...` | 两段都锁 |
| 留空 | 跟随上游最新 |

`FinaSU` 固定使用官方 Release 对应提交，会忽略第 1 段。

## 版本对齐与跟随策略

通用约定是 **「不指定就跟随上游最新」**，只有显式传入 hash/tag 时才钉死版本：

- **KernelSU 检出**：SukiSU 走 `main` 或 `builtin`（开 SUSFS 时自动 `builtin`）；BakaSU / FinaSU 会对齐到所选管理器构建的同一提交，使内核 KSU 版本与管理器 APK 严格一致。
- **SUSFS 补丁源**：默认克隆上游 `gki-<android>-<kernel>` 分支头，不钉提交；需要复现时用 `manager_commit` 第 2 段（旧变体除外，它们本来就钉死）。
- **KernelSU UAPI 版本**：目标值取自**内核实际检出所在分支**的 `supercall.h` —— `main` 在 `uapi/supercall.h`、`builtin` 在 `kernel/include/uapi/supercall.h`，两者独立演进。因此不会出现「把 BakaSU 的版本号改成 SukiSU 的号」这类错配。
- **KPM 修补工具**：随 [SukiSU_patch](https://github.com/SukiSU-Ultra/SukiSU_patch) 上游最新，**不阻断构建**。`config/kpm_patch_sha256` 只是「上次构建时上游的样子」，值变化时打印 `::warning::` 并继续；只有显式传入 `kpm_patch_sha256` 才做 fail-closed 比对。上游更新后可用 `scripts/tools/pin_kpm_patch.sh` 刷新记录。

## 本地构建

本地构建需要 Linux 环境。查看支持的版本并构建一个版本：

```bash
python3 build.py --list-configs
python3 build.py --android android14 --kernel 6.1 --sub-level 124 --os-patch 2025-02
```

更多环境要求、参数、断点续建与单步调试说明见 [`docs/local-build.md`](docs/local-build.md)。

> 注意：`build.py` 的 `--droidspaces` 与 `--artifact-mode` 直接沿用 Actions 的**中文字面量**（`--droidspaces 不启用`、`--artifact-mode 仅 AnyKernel3` / `上传全部`），照抄英文会报 `invalid choice`；而 `--kpm` 收的是**英文键** `disabled` / `enabled` / `patched`（内部再映射成 Actions 的中文文案），别把下拉框那串中文抄进来。

## 🧯 排错速查（按报错对号入座）

下面每一行都来自本仓库真实跑出来的失败，处置也都已写进脚本；遇到时先看「处置」，不要按字面去补依赖或改 API。

| 报错 / 现象 | 根因 | 处置 |
|---|---|---|
| `fs/namespace.c Hunk #1 FAILED at 32`（或 `task_mmu.c` / `exec.c` 同类 `Hunk #N FAILED`） | 月度源码树与 SUSFS 补丁对 `#include` 的行数不一致（多一行或少一行）→ hunk 上下文整段失配 | 已有 `adjust_context_include()` 自动补/删并在打完后还原（`scripts/susfs_fixes/apply.sh:50-123`）。若仍失败，看日志里打印的该文件 include 列表与补丁期望的 hunk |
| `undefined symbol: fake_state` | 补丁按旧 `fake_state` 模型 `extern`，而 BakaSU / FinaSU 上游早已换成 `backup_sepolicy` + `security_*_with_policy` | 自动改写（`adapt_finasu_selinux_hide_model`，同样在 `susfs_fixes/apply.sh`）；若日志说「改写 N 处」后仍有残留，脚本会直接中止 |
| `undefined symbol: my_setprocattr / my_write_context / my_write_access` | SUSFS 已切「接管式」，要求 KernelSU 以非 `static` 符号导出这三个；该变体 / 内核组合不满足 | 脚本内置变体钉表（`scripts/build_kernel.sh:705-709`）会在你未显式指定时自动钉住；也可手动 `manager_commit=0,<SUSFS提交>`。BakaSU 必须 `c06d5f8`，见上文 |
| `implicit declaration of function close_fd` | FinaSU 上游补丁按 ≥5.15 的 `close_fd()` 写死，而 5.10 只有 `__close_fd(files, fd)` | `scripts/finasu_compat/apply.sh` 自动改回 `ksu_close_fd()`（ksyscall 宏，与版本无关） |
| `CONFIG_ZRAM_DEF_COMP_LZ4KD` 不在生成的 `.config` 里…Kconfig 未认领该符号 | kleaf/bazel 路径下 `defconfig_fragment` 合并太晚，choice 回落到首个可见成员且值粘性 | 已由 `stage_config_zram` 显式钉住并写出其余成员 `# … is not set`（`scripts/build_kernel.sh:3015-3032`） |
| BBG `flask.h` 阶段 `ld: cannot find …` / 找不到 `ld` | `GKI build/build.sh` 在 `make mrproper` 之前重写了 `PATH`（不含 `/usr/bin`）；apt 装 binutils 对它无效，且该步会自愈 | **不要**当成依赖缺失去改，见 `scripts/build_kernel.sh` 里的相关注释 |
| `Please wait susfs update.` 或 SUSFS 构建被拦 | BakaSU 上游主动挂起 SUSFS 构建（`suspend susfs build`） | 设计内拦截；钉 `c06d5f8` 或等上游解除，`resume_susfs.sh` 在上游解除后自动 no-op |
| `redefinition … struct lsm_id` vs `const struct lsm_id` | sukisu_compat 与内核树重复定义 `lsm_id` | 守卫同时认 `ksu_lsm_id`（`scripts/build_kernel.sh:3363-3365`） |
| 矩阵全 skipped 却算成功、发出空 Release | 旧版把 `skipped` 当通过；空矩阵判断缺失 | 已修：`main.yml` 判 `count`、`check_build` 重写、空矩阵 job 加 `if` |

更多环境要求、断点续建与单步调试见 [本地构建文档](docs/local-build.md)。

## 上游更新

定时 workflow 会检查 SukiSU 与 BakaSU 的上游更新，并按配置触发构建；构建范围、触发条件与所需仓库权限见 `.github/workflows/Auto_Trigger_*.yml`。

FinaSU 未接入定时触发，需要时手动运行构建入口。SUSFS 补丁源与 KernelSU 变体按构建时的上游最新状态拉取，因此同一入口在不同日期可能构建出不同版本；需要可复现产物时，用 `manager_commit` 锁定提交。

## 目录结构

| 路径 | 内容 |
|---|---|
| `.github/workflows/` | 构建、发布、管理器下载与数据更新 workflow（15 个） |
| `scripts/build_kernel.sh` | Actions 与本地 CLI 共用的构建步骤（53 个阶段） |
| `scripts/susfs_fixes/` | SUSFS 主补丁应用与上下文适配（含 SELinux 模型改写） |
| `scripts/bakasu_compat/` | BakaSU 上游 SUSFS 挂起判定与放行 |
| `scripts/finasu_compat/` | FinaSU 结构适配补丁与证书提取 |
| `scripts/sukisu_compat/` | SukiSU 兼容补丁 |
| `scripts/ksu_uapi_sync/` | 内核侧 KernelSU UAPI 版本对齐 |
| `scripts/susfs_probe/` | SUSFS 原始补丁探测与结果汇总 |
| `scripts/get_manager.sh` | 管理器与管理器工件下载（由 workflow 调用） |
| `build.py` | 本地构建 CLI |
| `data/` | Android 与内核版本数据 |
| `config/` | 内核配置片段与旧变体固定提交配置 |
| `security_patch/` | 可选安全修复补丁 |
| `zram/` | ZRAM 补丁及相关源码 |
| `zram_patch/` | 6.12 的 ZRAM（LZ4KD）补丁 |
| `hmbird_patch.c` | 上游 `dev` 分支的附加补丁源（本地存在时优先使用本地副本） |
| `docs/` | 本地构建与功能文档 |
| `web/` | GitHub Pages 页面源码 |

## 来源与许可

本项目包含多个上游项目的代码、补丁与配置，**不能用单一许可证概括**。

当前审查发现：SUSFS 内核补丁标注为 GPL-3.0-or-later，而 Linux 内核主体为 GPL-2.0-only；两者组合进同一内核产物存在**许可不兼容风险**。本仓库的文档与 `LICENSE` 不能消除该风险。

根目录 `LICENSE` 为 GPL-2.0，**仅覆盖本仓库原创部分**；从上游引入的 FinaSU 适配脚本随附 [LICENSE-GPL-3.0.txt](LICENSE-GPL-3.0.txt)。逐组件的状态、判断依据与退出开关见 [NOTICE](NOTICE) 与 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

`STRICT_LICENSE_MODE=true` 可以跳过部分许可状态不明的组件（Unicode 修复、三星 `min_kdp.c`、KPM 的 `patch_linux`），但**不等于整体许可通过**。

## 免责声明

1. 本仓库为**个人自用**项目，按「现状」提供，不附带任何明示或暗示担保，包括但不限于适销性、特定用途适用性与不侵权担保。
2. 使用本仓库的代码、脚本或构建产物所造成的任何直接或间接损失（设备损坏、数据丢失、保修失效、账号风控等），作者**不承担责任**。
3. 刷机前请自行备份关键分区，并确认理解所用变体、内核版本与设备之间的兼容性。
4. 本仓库**未完成人工审核**，文档与代码可能不一致；发现差异时**以代码为准**。
5. 分发任何由本仓库构建的产物前，请自行履行各上游许可证要求的源码提供与版权声明义务。

## 问题反馈

本仓库为个人自用项目，**不承诺响应时间或修复**。若仍要提交，请：

- 使用 [Issues](https://github.com/Lokitla/GKI_SUKISU_SUSFS_for_Lokita/issues)，并附上完整的 Actions 运行链接或日志片段；
- 说明内核版本、Android 版本、变体、`enable_susfs` / `use_kpm` / `droidspaces` 等关键输入；
- 涉及上游行为的问题（SUSFS、KernelSU、AnyKernel3 等）请优先到对应上游反馈。

参与本仓库讨论请遵守 [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)。
