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

- KernelSU 变体：SukiSU、BakaSU、Official、Next，以及保留的旧版 SukiSU 构建。
- SUSFS 集成与补丁适配；可按需导出补丁。
- ZRAM/LZ4KD 优化；6.12 使用本仓库维护的补丁。
- 可选 KPM、BBR 与网络配置、Baseband Guard、Re-Kernel、NoMount、Droidspaces/NTSync 和 GhostLock 修复。
- AnyKernel3 刷机包；完整产物模式还会生成不同压缩格式的 boot 镜像。
- 构建失败日志、拒绝补丁汇总和 Actions 摘要。

**兼容性提示：** KPM 在 Linux 6.10 及以上会自动跳过；6.12 构建请按需开启 ZRAM。部分设备 ROM 或内核配置可能不兼容，请先查看功能文档和对应构建记录。

## 本地构建

本地构建需要 Linux 环境。查看支持的版本并构建一个版本：

```bash
python3 build.py --list-configs
python3 build.py --android android14 --kernel 6.1 --sub-level 124 --os-patch 2025-02
```

更多环境要求、参数、断点续建和单步调试说明见 [`docs/local-build.md`](docs/local-build.md)。

## 上游更新

定时 workflow 会检查 SukiSU 和 BakaSU 的上游更新，并按配置触发构建。构建范围、触发条件和所需仓库权限见 `.github/workflows/Auto_Trigger_*.yml`。

## 目录结构

| 路径 | 内容 |
|---|---|
| `.github/workflows/` | 构建、发布、管理器下载和数据更新 workflow |
| `scripts/build_kernel.sh` | Actions 与本地 CLI 共用的构建步骤 |
| `scripts/susfs_fixes/` | SUSFS 补丁适配脚本 |
| `data/` | Android 与内核版本数据 |
| `config/` | 内核配置片段 |
| `security_patch/` | 可选安全修复补丁 |
| `zram/` | ZRAM 补丁及相关源码 |
| `docs/` | 本地构建和功能文档 |
| `web/` | GitHub Pages 页面源码 |

## 来源与许可

本项目包含多个上游项目的代码、补丁和配置。版权、来源与许可信息以各文件标头、[NOTICE](NOTICE) 和上游仓库中的许可证为准。分发构建产物前，请确认相关许可证及源码提供要求。

主要上游包括 [zzh20188/GKI_KernelSU_SUSFS](https://github.com/zzh20188/GKI_KernelSU_SUSFS)、[LingLuo17/AnyKernel3](https://github.com/LingLuo17/AnyKernel3)、[SukiSU-Ultra](https://github.com/SukiSU-Ultra/SukiSU-Ultra)、[KernelSU](https://github.com/tiann/KernelSU) 和 [susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu)。更多来源见 [NOTICE](NOTICE)。
