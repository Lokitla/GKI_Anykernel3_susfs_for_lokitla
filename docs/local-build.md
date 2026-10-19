# 💻 本地构建（CLI）

不依赖 GitHub Actions，直接在本机构建内核。

**本地与云端共用同一份构建逻辑** —— 入口 `build.py` 只做参数解析，真正的步骤全部在
[`scripts/build_kernel.sh`](../scripts/build_kernel.sh) 中。阶段列表可用 `--list-phases` 查看。

> 改构建行为请改 `scripts/build_kernel.sh`，不要在 `.github/workflows/build.yml` 里重写 shell ——
> 否则本地与云端会立刻分叉。

---

## 环境要求

| 项目 | 要求 |
|---|---|
| 系统 | Linux（推荐 Ubuntu 22.04+） |
| 权限 | 首次构建需 `sudo` 安装编译依赖 |
| 磁盘 | 至少 **40GB** 可用空间 |
| Python | 3.8+ |

---

## 快速开始

```bash
# 查看支持的版本组合（数据来自 data/）
python3 build.py --list-configs

# 列出构建阶段
python3 build.py --list-phases

# 构建单个版本
python3 build.py --android android14 --kernel 6.1 --sub-level 124 --os-patch 2025-02

# 构建某个组合的全部子版本
python3 build.py --matrix android14-6.1

# 构建全部版本（耗时极长，谨慎使用）
python3 build.py --all

# 只校验参数，不真正构建
python3 build.py --android android14 --kernel 6.1 --dry-run
```

---

## 完整选项

### 构建目标

| 选项 | 说明 |
|---|---|
| `--android` / `-a` | Android 版本，如 `android14` |
| `--kernel` / `-k` | 内核版本，如 `6.1` |
| `--sub-level` / `-s` | 子版本号，如 `124`；省略则用最新 |
| `--os-patch` | OS 补丁级别，如 `2025-02` |
| `--revision` | Android 12 的 revision（可选） |
| `--matrix` / `-m` | 构建指定组合的全部子版本，如 `android14-6.1` |
| `--all` | 构建全部版本组合 |
| `--list-configs` | 列出支持的版本组合 |

### KernelSU 与 SUSFS

| 选项 | 说明 |
|---|---|
| `--ksu-variant` | KernelSU 变体，默认 `BakaSU`：`SukiSU` / `SukiSU(40726)` / `SukiSU(40548)` / `BakaSU` / `FinaSU` / `Official` / `Next` |
| `--ksu-branch-mode` | SukiSU 拉取分支（仅 SukiSU 生效）：`auto`=跟随 SUSFS 开关自动选（默认）、`main`=纯管理器分支、`builtin`=内核内置实现 |
| `--no-susfs` | 不集成 SUSFS（默认集成） |
| `--version` | 自定义版本名 |
| `--build-time` | 自定义构建时间（固定内核 `UTS_VERSION` 时间戳） |
| `--export-susfs-patches` | 导出 SUSFS 集成补丁 |
| `--sukisu-commit` | SukiSU 提交 hash：内核与管理器统一使用该 commit（仅 SukiSU 变体生效；留空则用 `config/config` 的 `sukisu=` 或分支最新） |
| `--susfs-commit` | SUSFS 提交 hash：内核 SUSFS 修补使用该 commit（留空则用 `config/config` 的对应分支行或分支最新） |

### 功能开关

| 选项 | 说明 |
|---|---|
| `--zram` / `--no-zram` | ZRAM (LZ4KD) 增强算法（**默认开启**，`--no-zram` 关闭） |
| `--bbr` | 设置 BBR 为默认拥塞算法 |
| `--kpm` | KPM 模块支持，默认 `patched`（开启并修补）；可带值 `disabled` / `enabled` / `patched` |
| `--kpm-patch-sha256` | KPM 修补工具（`patch_linux`）的 sha256 锚点。传入后做 **fail-closed** 比对，不符即拒绝执行（留空不校验） |
| `--bbg` | 启用 Baseband-guard 防格机 |
| `--rekernel` | 启用 Re-Kernel 驱动（墓碑/冻结支持） |
| `--net-enhance` | 启用网络增强（IPSet 全类型 + BBR + FQ/FQ_CODEL 队列 + IPv6 NAT + 附加拥塞算法，均为内核既有配置） |
| `--skip-incompatible` | 可选功能失败时自动跳过而非中断构建（SUSFS 与一加 8E 除外） |
| `--nomount` | 启用 NoMount 挂载元模块，需自行刷入配套 NoMount 模块 |
| `--op8e` | 启用一加 8E 支持（非一加设备勿开） |
| `--cve-patch` | 应用 CVE-2026-43499（GhostLock）修复链 |
| `--droidspaces` | Droidspaces 容器支持（`不启用` / `678` / `123` / `345`），实验性 |
| `--ntsync` | 启用 NTSync 支持（需先启用 Droidspaces） |

### 产物与调试

| 选项 | 说明 |
|---|---|
| `--artifact-mode` | `上传全部`（默认）/ `仅 AnyKernel3` |
| `--only <阶段>` | 只运行指定阶段（调试用） |
| `--from <阶段>` | 从指定阶段开始运行（断点续建） |
| `--list-phases` | 列出全部构建阶段 |
| `--dry-run` | 只打印将要执行的构建，不真正执行 |
| `--workspace` / `-w` | 指定工作目录 |

---

## 断点续建与单步调试

构建由多个阶段组成，`--list-phases` 可查看完整列表与编号。内核构建动辄数十分钟，
全量重跑代价很高，用这两个参数可以只重跑出问题的那一段：

```bash
# 只重跑编译内核这一步
python3 build.py --android android14 --kernel 6.1 --only compile_kernel

# 从打 KPM 补丁这一步继续（前面的产物保留）
python3 build.py --android android14 --kernel 6.1 --from patch_kpm_image
```

常用阶段名：`sync_kernel_source`、`add_kernelsu`、`apply_susfs`、`config_kernel`、
`compile_kernel`、`patch_kpm_image`、`make_anykernel3`、`collect_conflicts`。

---

## 注意事项

- **「清理磁盘空间」只在 GitHub Actions runner 上执行**，本地构建会自动跳过，以免误删你机器上的文件。
- `--kpm` 的实际可用范围由三件事同时决定，比版本号更窄：
  1. **变体必须提供 KPM** —— 只有 SukiSU 系（含 `SukiSU(40726)` / `SukiSU(40548)`）；
     BakaSU / FinaSU / Official / Next 的 KernelSU 没有 `config KPM`，请求了也会被跳过。
  2. **内核 ≤ 6.6** —— 6.10+ 会被强制关闭（`KPM_SUPPORTED=0`：KPM 代码用了新内核已移除的
     `netlink_kernel_cfg.cb_mutex`）。
  3. **内核 ≠ 6.6** —— 6.6 是特例：脚本仍会写 `CONFIG_KPM=y`，但**跳过 Image 修补**
     （日志打印「6.6 内核不支持 KPM 镜像修补」），模块实际加载不了。

  结论：当前真正能加载 KPM 的组合是 **SukiSU 系 + 内核 ≤ 6.1**。
- 各开关默认值以**入口 workflow 的 `inputs` 为准**，不同入口并不一致：`kernel-custom.yml` / `kernel-a12`~`a15` 的 `use_zram` 默认开启，但 `kernel-a16-6-12.yml` 默认关闭；`use_kpm` 在多数入口默认 `patched (开启并修补)`。命令行未传时按 `build.py` 自身的默认值。

---

## 相关文档

- [🧩 进阶功能](advanced-features.md)：GhostLock、Droidspaces、NoMount、Re-Kernel、自定义提交、伪装 `/proc/config.gz`
- [English version](local-build-en.md)
- [返回 README](../README.md)
