<div align="center">

# GKI KernelSU SUSFS

**自动化构建 GKI 内核 · 集成 KernelSU + SUSFS**

[![Release](https://img.shields.io/github/v/release/Lokitla/GKI_SUKISU_SUSFS_for_Lokita?label=Release&style=flat-square&logo=github&logoColor=white&color=2ea44f)](https://github.com/Lokitla/GKI_SUKISU_SUSFS_for_Lokita/releases)
[![上游原作者](https://img.shields.io/badge/%E2%9D%A4%EF%B8%8F%20%E4%B8%8A%E6%B8%B8%E5%8E%9F%E4%BD%9C%E8%80%85-zzh20188-3DDC84?style=flat-square&logo=android&logoColor=white)](https://github.com/zzh20188)
[![KernelSU](https://img.shields.io/badge/KernelSU-Supported-5AA300?style=flat-square)](https://kernelsu.org/)
[![SUSFS](https://img.shields.io/badge/SUSFS-Integrated-E67E22?style=flat-square)](https://gitlab.com/simonpunk/susfs4ksu)

[English](README-EN.md) | 简体中文

</div>

---

## ⚠️ 请先读这一段：自用属性声明

> [!WARNING]
> **本仓库是个人自用衍生仓库，不是官方发布渠道，请勿打扰上游作者。**

| 项目 | 说明 |
|---|---|
| **性质** | [zzh20188/GKI_KernelSU_SUSFS](https://github.com/zzh20188/GKI_KernelSU_SUSFS) 的**个人自用衍生分支**（fork + 二次开发） |
| **功劳归属** | 构建矩阵、脚本与补丁适配等**绝大多数核心工作由上游作者完成**。本仓库只做了自用整合，所有功劳归于上游 |
| **开发方式** | 工作流、构建脚本与文档经过 **AI 辅助修改**，**未经任何上游作者审阅、认可或参与**，行为可能与上游不一致 |
| **产物用途** | **仅供本人测试**。需要官方版本请前往 [zzh20188 原仓库](https://github.com/zzh20188/GKI_KernelSU_SUSFS/releases) |
| **责任范围** | 上游作者对本仓库的内容、质量与后果**不承担任何责任** |
| **反馈渠道** | 请在**本仓库**提 Issue。**不要以任何方式打扰上游作者**（Issue、邮件、酷安私信等） |

**刷机风险自负**：刷入第三方内核存在变砖、丢失数据、触发应用风控等风险，请自行备份原厂 Boot 镜像。

**隐私说明**：文档站点（GitHub Pages）使用 [GoatCounter](https://www.goatcounter.com/) 做匿名访问统计，不收集可识别个人身份的信息；禁用 JavaScript 或拦截 `gc.zgo.at` 即可退出统计。

---

## 这是什么

本仓库以 [zzh20188](https://github.com/zzh20188) 的 GKI 构建基架为主体，移植了 [ShirkNeko](https://github.com/ShirkNeko/GKI_KernelSU_SUSFS) 的 KPM 镜像修补与本地 CLI 设计，参考了 [coolzyd9107](https://github.com/coolzyd9107/GKI_SukiSU_Ultra_SUSFS) 的 Release 呈现方式，并合并了 [LingLuo17](https://github.com/LingLuo17) 的 6.12 ZRAM 补丁、SukiSU compat 补丁与网络增强，把构建流程收敛到**同一份脚本**：

```
GitHub Actions  ──┐
                  ├──►  scripts/build_kernel.sh  （48 个阶段，唯一构建逻辑来源）
本地 build.py   ──┘
```

**不存在两套逻辑分叉**。改构建行为请改 `scripts/build_kernel.sh`，不要在 `build.yml` 里重写 shell。

覆盖 Android 12 / 13 / 14 / 15 / 16（内核 5.10 / 5.15 / 6.1 / 6.6 / 6.12），每次构建产出 AnyKernel3 刷机包、三种压缩格式的 boot 镜像、KernelSU 管理器与 SUSFS 配套模块。

---

## 快速导航

| | |
|---|---|
| 📖 进阶功能文档 | [docs/advanced-features.md](docs/advanced-features.md) |
| 💻 本地 CLI 构建 | [docs/local-build.md](docs/local-build.md) |
| 📥 下载 | [Releases](https://github.com/Lokitla/GKI_SUKISU_SUSFS_for_Lokita/releases) |
| 🔰 新手教程 | [GitHub Pages](https://lokitla.github.io/GKI_SUKISU_SUSFS_for_Lokita/guide.html) |
| 📊 版本查询 | [GitHub Pages](https://lokitla.github.io/GKI_SUKISU_SUSFS_for_Lokita/) |
| 📄 上游来源与许可证 | [NOTICE](NOTICE) · [FUSION.md](FUSION.md) |

---

## 构建入口与版本矩阵

### 两种入口

| 入口 | 一次构建多少 |
|---|---|
| **构建内核**（`main.yml`） | 展开版本矩阵，Android 12–16 各一个 job |
| **内核构建 - Android 12/13/14/15/16**（`kernel-a1*.yml`） | 该内核版本的全部子版本（**full** 模式） |
| **Android 内核构建-自定义**（`kernel-custom.yml`） | 只构建你指定的版本，**默认只出 1 个** |

### 三套矩阵（数字均已核实）

| 矩阵 | 5.10 | 5.15 | 6.1 | 6.6 | 6.12 | 合计 | 用在哪 |
|---|---|---|---|---|---|---|---|
| **auto**（精简） | 5 | 6 | 5 | 3 | — | **19** | 自动触发、被 `main.yml` 调用的单版本入口 |
| **full**（全量） | 22 | 20 | 23 | 15 | 4 | **84** | 手动触发独立单版本入口 |
| **data 全集** | 36 | 35 | 32 | 17 | 8 | **128** | `data/` 里"全部可用版本"的定义，`build.py --all` 的来源 |

> **6.12 不在 auto 矩阵里**，所以自动构建与「构建内核」都不会带它
> （勾 `include_612` 也不会）。需要 6.12 请**手动触发「内核构建 - Android 16 (6.12)」**
> （full 模式，构建 6.12.23 / 30 / 38 / 58 四个子版本）。

### 自定义入口的「构建目标」写法

| 填法 | 效果 |
|---|---|
| `66` | 子版本代号 → 5.10.66 |
| `236` | 子版本代号 → 5.10.236 |
| `2022-01` | 补丁级别日期 → 5.10.66 |
| `lts` | LTS 版本 |
| `all` | 该内核全部版本（**耗时很长**） |
| `66,236` | 逗号分隔，一次构建多个（重复自动去重） |

选「全部版本」或「仅 LTS」时，「构建目标」里填什么都会被忽略。

---

## 功能特性与开关

| 能力 | 说明 | 默认 |
|---|---|---|
| KernelSU 变体 | `SukiSU` / `SukiSU(40726)` / `SukiSU(40548)` / `BakaSU` / `Official` / `Next` | **`BakaSU`** |
| SUSFS | 集成 SUSFS 补丁集，支持 Inline Hook | 开启 |
| KPM | 编译后修补 Image 以加载 KPM 模块 | `patched`（开启并修补）※ |
| ZRAM / LZ4KD | ZRAM 增强算法（LZ4KD / LZ4K_OPLUS） | 开启 |
| BBR | 把 BBR 设为默认 TCP 拥塞算法 | 关闭 |
| **网络增强** | IPSet 全类型 + BBR + FQ/FQ_CODEL + IPv6 NAT + 附加拥塞算法 | 关闭 |
| BBG | Baseband-guard 防格机 | 关闭 |
| Re-Kernel | Re-Kernel 驱动（beta） | 关闭 |
| NoMount | 挂载元模块，在 `fs/` 层集成 [maxsteeel/nomount](https://github.com/maxsteeel/nomount) | 关闭 |
| Droidspaces | LXC 式容器支持（实验性） | 不启用 |
| NTSync | 需先启用 Droidspaces | 关闭 |
| CVE-2026-43499 | rtmutex 修复链（GhostLock） | 关闭 |
| 一加 8E 支持 | 非一加设备勿开 | 关闭 |
| Spoofed 管理器 | 一并拉取伪装包名的管理器 APK | 开启 |
| Telegram 通知 | 构建完成后推送通知 | 开启 |



### 开关可用性矩阵（各入口是否真的传了这个开关）

这一节用于避免"某个入口看起来支持、实际永远关闭"的误判。

| 开关 | 构建内核 `main.yml` | 单版本 `kernel-a1*.yml` | 自定义 `kernel-custom.yml` | 自用 `build-236-marble.yml` | 本地 `build.py` |
|---|:---:|:---:|:---:|:---:|:---:|
| `use_zram` | ✅ | ✅（6.12 恒不生效） | ✅ | ✅ | `--zram` |
| `use_net_enhance` | ✅ | ✅ | ✅ | ✅ | `--net-enhance` |
| `use_bbg` | ✅ | ✅ | ✅ | ✅ | `--bbg` |
| `use_kpm` | ✅ | ✅（6.12 恒不生效） | ✅ | ✅ | `--kpm` |
| `use_rekernel` | ✅ | ✅ | ✅ | ✅ | `--rekernel` |
| `use_nomount` | ✅ | ✅ | ✅ | ✅ | `--nomount` |
| `skip_incompatible` | ❌ 恒定 false | ✅ | ❌ | ✅ | `--skip-incompatible` |
| `export_susfs_patches` | ✅ | ➖ 仅由主入口传入 | ❌ | ✅ | `--export-susfs-patches` |
| `ksu_branch_mode` | ❌ 恒 `auto` | ✅ | ❌ | ❌ | `--ksu-branch-mode` |
| `manager_commit`（管理器 + SUSFS 提交 hash，逗号分隔） | ✅ | ✅ | ✅ | ✅ | `--sukisu-commit` / `--susfs-commit` |
| `kpm_patch_sha256` | ➖ 已隐藏，恒等于留空 | ➖ 同上 | ➖ 同上 | ➖ 同上 | `--kpm-patch-sha256` |
| `manager_spoofed`（Spoofed 管理器） | ➖ 已隐藏，恒启用 | ➖ 同上 | ➖ 同上 | ➖ 同上 | 无此参数 |
| `supp_op`（一加 8E） | ❌ 恒 false | ✅ | ✅ | ➖ 写死 false | `--op8e` |
| `ksu_mode` | ❌ | ❌ | ❌ | ❌ | 无此参数 |

图例：

- **✅ = 该入口手动运行时可由用户控制**（该 input 出现在文件的 `workflow_dispatch` 块）。
- **❌ = 该入口不提供此开关**，取固定默认值（代码里已写明并注明原因）。
  主要成因是 `main.yml` 的 `workflow_dispatch` 输入**已达 GitHub 的 25 个上限**。
  需要时改用**单版本入口 `kernel-*.yml`** 或**本地 `build.py`**。
- **➖ = 特殊情况**：
  - 「仅由主入口传入」——该 input 只存在于 `kernel-a1*.yml` 的 `workflow_call`
    块（供 `main.yml` 调用时传入），**不在 `workflow_dispatch` 块**，所以手动运行
    单版本入口时它恒为 `false`，只有走「构建内核」才能生效。
  - 「已隐藏」——该配置项已从所有手动入口的界面移除，行为固定：
    `kpm_patch_sha256` 等价于留空（不校验），`manager_spoofed` 恒启用。
    两者对应的底层能力仍保留在 `build_kernel.sh` / 本地 `build.py` 中。

**关于提交 hash**：`sukisu_commit` 与 `susfs_commit` 已合并为单一输入框
`manager_commit`，内容为「SukiSU/管理器 hash，**可选用英文逗号后接** SUSFS hash」，
解析按逗号拆分并去除多余空格，原有两个 hash 的校验逻辑不变。只填一段时
第二段为空（即不锁定 SUSFS）。

**关于 `use_bbr`**：所有 Actions 入口已统一为 `use_net_enhance`，不再单列
`use_bbr`——网络增强本身就包含「把 BBR 设为默认拥塞算法」，两个开关只会造成歧义。
只有本地 `build.py` 仍保留独立的 `--bbr`。

**6.12（Android 16）上有两个开关恒不生效**，这是上游限制而非配置问题：

- `use_zram`：上游 `SukiSU_patch` 的 `other/zram/zram_patch/` 只有
  5.10 / 5.15 / 6.1 / 6.6 四个目录，没有 6.12，相关阶段会整段跳过；
- `use_kpm`：内核 ≥ 6.10 时脚本强制 `KPM_SUPPORTED=0`
  （SukiSU 的 KPM 代码用了新内核已移除的 `netlink_kernel_cfg.cb_mutex`）。

`kernel-a16-6-12.yml` 已把这两项默认值改为关闭，避免"勾了却空转"。

> 矩阵每一格均以「该 input 是否出现在对应文件的 `workflow_dispatch` 块」为判据
> 实测得出，而非按调用链推断——两者容易不一致（例如某个 input 只在 `workflow_call`
> 块存在时，调用链看得到、用户却填不到）。

### 三个容易踩的坑

**1. KPM 在默认变体下不生效。** KPM 只有 SukiSU 变体提供，`BakaSU` / `Official` /
`Next` 的内核 Kconfig 里没有 `config KPM`。默认变体下相关阶段自动跳过——构建不中断，
但内核加载不了 KPM 模块。需要 KPM 请把变体切回 `SukiSU`。

**2. BBR 需要门控前置。** 5.10 / 5.15 / 6.1 / 6.12 的 `gki_defconfig` 基线里没有
`CONFIG_TCP_CONG_ADVANCED`，而 Kconfig 中 `TCP_CONG_BBR` 与 `DEFAULT_BBR` 都被
`if TCP_CONG_ADVANCED` 包住——门控不开，BBR 两行就是没人认的死行。脚本会先写
`TCP_CONG_ADVANCED=y`，并连带把 `TCP_CONG_BIC / WESTWOOD / HTCP` 置 `=y`
（三者 Kconfig 默认 `m`，置 `y` 是为避免在 bazel 路径产出未声明的 `.ko`）。

**3. ZRAM 的默认值分三层。** 脚本内部兜底默认 `false`（仅当无人传参时生效）；
本地 CLI 与**所有** Actions 入口默认 `true`。6.12 因没有 lz4k 补丁栈，即使开了也会
整段跳过并告警。

---

## 构建产物

「上传全部」模式下，每个内核版本拆成两个产物：

| 产物 | 内容 | 体积（5.10 为例） |
|---|---|---|
| `..._kernel-<版本>-AnyKernel3` | `AnyKernel3.zip` 刷机包 | 约 18 MB |
| `..._kernel-<版本>-Images` | `boot.img` / `boot-gz.img` / `boot-lz4.img` | 约 50 MB（压缩后） |

**刷机只需要 AnyKernel3 那个包**，里面的 `Image` 由 `anykernel.sh` 在设备上现场处理。

三个 boot 镜像的区别在于内核压缩方式，供 `fastboot flash boot` 使用：

| 文件 | 压缩 | 适用 |
|---|---|---|
| `boot.img` | 未压缩 | 兼容性最强，老 bootloader |
| `boot-gz.img` | gzip | 传统默认，几乎所有 bootloader 都支持 |
| `boot-lz4.img` | lz4 | 现代 GKI 常用，解压最快 |

现代设备优先 `boot-lz4.img`；卡第一屏换 `-gz`；仍不行用未压缩的。

可选「仅 AnyKernel3」模式：只上传刷机包，省 Release 体积。

---

## 兼容性提醒

- **一加 ColorOS 14 / 15**：目前不支持，刷入后可能需要清除数据才能开机。
- **6.12（Android 16）**：已为 6.10+ 的 `security_add_hooks` 新签名补了兼容补丁，
  但有三道坎，详见下节。
- **老版本 SukiSU**：保留了 `SukiSU(40726)` / `SukiSU(40548)` 的构建，它们完全使用
  旧版代码，不含最近的特性与修复，建议搭配对应版本的管理器。
- **Re-Kernel**：已支持，处于 beta 阶段。

### 6.12 的三道坎

**第一道 · `security_add_hooks` 签名变更。** 第三参数自 v6.10 起改成
`const struct lsm_id *`，而 KernelSU 各变体仍按老签名传字符串。打补丁阶段按内核版本
补实参宏：**v6.10 起传 `&ksu_lsm_id`，更早的内核照旧传字符串字面量**。
（注意：`struct lsm_id` 的字段是 `name` 不是 `lsm`，写成 `.lsm` 会编译报错。）

**第二道 · KPM 编译不过。** SukiSU 的 `super_access.c` 用了
`netlink_kernel_cfg.cb_mutex`，在 6.10+ 上不存在。脚本会**自动关掉 KPM**，
不再硬跑那轮注定失败的编译（早期闸门直接把 `KPM_SUPPORTED` 置 0）。
实测硬跑的代价是：18 分钟后失败，再靠重试兜底，一个版本多花近 20 分钟。

**第三道 · ZRAM 没有补丁栈。** lz4k 补丁栈只提供 5.10 / 5.15 / 6.1 / 6.6 四个目录。
**即使打开 ZRAM 开关，6.12 上也会整段跳过**并 `::warning::` 告警。这是刻意设计——
宁可明确跳过，也不要留下半套打了一般的 ZRAM 补丁让 GKI defconfig 校验炸掉。

---

## 上游更新自动触发

BakaSU（上游由 ReSukiSU 更名而来）与 SukiSU 是两个互不相干的上游仓库，各有独立的更新节奏，
因此拆成**两个各自独立、互不影响**的工作流：

| 工作流 | 检测的上游 | 记录的基线分支 | 构建变体 | 定时（UTC） |
|---|---|---|---|---|
| `.github/workflows/Auto_Trigger_BakaSU.yml` | [Baka-SU/BakaSU](https://github.com/Baka-SU/BakaSU) `main` | `sha-bakasu` | `BakaSU` | 每 3 天 00:00 |
| `.github/workflows/Auto_Trigger_SukiSU.yml` | [SukiSU-Ultra](https://github.com/SukiSU-Ultra/SukiSU-Ultra) `main` | `sha-sukisu` | `SukiSU` | 每 3 天 12:00 |

两者时刻错开 12 小时，避免同时抢占 Runner 并发、也让两版发布时间好区分。
流程一致：拉取上游最新提交号 → 与各自基线分支记录的旧值比对 →
有更新则回写基线并按 `build_scope` 触发构建。

单次运行的行为：

1. 有新提交 → 回写基线分支并触发**构建内核**；
2. 无新提交 → 什么都不做，不消耗 Runner 时长；
3. 拿不到提交号（API 限流）→ 直接失败退出，不会带着空值去构建。

默认跑「全部版本」，走 `main.yml` 展开 **auto 精简矩阵共 19 个内核版本**，
构建配置为 ZRAM 开启，其余增强项关闭。

> **两路的 Release 标签互相独立**：`main.yml` 生成的 tag 形如
> `<SUSFS版本>-r<N>-<变体>`，即 `-rN` 只在同一个变体内部递增。
> 若两路共用一套 `-rN` 序列，后发那次会算出已存在的 tag，
> `gh release create` 失败、该次产物全部静默丢失。

> **BakaSU 那条的基线已就位** —— `sha-bakasu` 分支由旧名 `sha-resukisu` 原样迁移，
> 首次运行能读到既有提交号、不会误触发。若基线分支重建（latest_sha.txt 丢失），
> 首次运行会视为「有更新」并触发全矩阵构建；只想建基线不想编的话，先手动跑一次它
> 并把 `build_scope` 选成「不构建」。
> SukiSU 那条沿用既有的 `sha-sukisu` 分支，里面已是 SukiSU-Ultra 的提交号，不会误触发。

手动运行时可改：

| 输入 | 说明 | 默认 |
|---|---|---|
| `force` | 忽略"是否有新提交"，强制触发 | 否 |
| `build_scope` | `全部版本` / `固定 5.10.236` / `单版本冒烟` / `不构建` | `全部版本` |
| `include_612` | 尝试纳入 6.12。**注意：6.12 不在 auto 矩阵内，勾选后仍会跳过** | 否 |
| `release_type` | `Release` / `Pre-Release` / `Actions` | `Release` |

> 「固定 5.10.236」走自用 workflow `build-236-marble.yml`（适配 Redmi Note 12 Turbo，
> 代号 marble），参数全写死，产物只留 Actions artifacts、**不发 Release**。
>
> 需要仓库 **Settings → Actions → Workflow permissions** 为 `Read and write`，
> 否则回写基线分支（sha-sukisu / sha-bakasu）会被 403 拦下。

---

## 本地构建（CLI）

不依赖 GitHub Actions，在本机直接构建。**与云端共用同一份脚本**，行为完全一致。

```bash
# 构建单个版本
python3 build.py --android android14 --kernel 6.1 --sub-level 124 --os-patch 2025-02

# 常用开关示例
python3 build.py --android android12 --kernel 5.10 --sub-level 236 \
                 --zram --net-enhance --nomount --rekernel
```

支持 48 个构建阶段、断点续建（`--from`）、单步重跑（`--only`）。
完整参数见 [docs/local-build.md](docs/local-build.md)。

---

## 仓库结构

| 路径 | 用途 |
|---|---|
| `scripts/build_kernel.sh` | **构建逻辑唯一来源**，48 个阶段 |
| `build.py` | 本地 CLI 入口，只做参数解析并调用上面的脚本 |
| `.github/workflows/build.yml` | 可复用构建工作流（缓存 / 产物 / 日志 / 通知） |
| `.github/workflows/main.yml` | 「构建内核」总入口，展开矩阵 |
| `.github/workflows/kernel-a1*.yml` | 按 Android 版本拆分的独立入口 |
| `.github/workflows/kernel-custom.yml` | 自定义单版本入口 |
| `.github/workflows/build-236-marble.yml` | **自用**：Redmi Note 12 Turbo 固定构建 |
| `.github/workflows/Auto_Trigger_BakaSU.yml` | 检测 BakaSU 上游更新并自动触发（BakaSU 变体） |
| `.github/workflows/Auto_Trigger_SukiSU.yml` | 检测 SukiSU 上游更新并自动触发（SukiSU 变体） |
| `.github/workflows/get-manager.yml` | 抓取管理器 APK |
| `.github/workflows/update-pages.yml` | 更新 `data/` 并部署 Pages |
| `.github/workflows/susfs-probe.yml` | **批量工具**：用原始 SUSFS 补丁全量编译，校准兼容线 |
| `scripts/susfs_probe/` | 探测用的矩阵生成 / 结论汇总脚本 |
| `config/` | 配置片段、`config/config` 提交锁定 |
| `data/` | 各版本可用的内核子版本与补丁级别（128 条） |
| `security_patch/` | CVE-2026-43499 修复链 |
| `zram/` | LZ4 的 ARM64 NEON 加速实现 |
| `web/` | GitHub Pages 站点源码 |
| `scripts/susfs_fixes/apply.sh` | SUSFS 补丁适配与冲突修复 |
| `tools/migration/` | 迁移期一次性脚本，**不参与构建** |
| `FUSION.md` | 三个上游仓库的比对与迁移记录 |

---

## 许可证与归属

完整清单见 [NOTICE](NOTICE)，迁移比对见 [FUSION.md](FUSION.md)。主要来源：

| 项目 | 上游贡献 | 许可证 |
|---|---|---|
| [WildKernels/GKI_KernelSU_SUSFS](https://github.com/WildKernels/GKI_KernelSU_SUSFS) | zzh20188 与 ShirkNeko 的共同原始上游 | GPL-3.0-or-later |
| [zzh20188/GKI_KernelSU_SUSFS](https://github.com/zzh20188/GKI_KernelSU_SUSFS) | **构建基座与绝大部分代码** | GPL-2.0 |
| [ShirkNeko/GKI_KernelSU_SUSFS](https://github.com/ShirkNeko/GKI_KernelSU_SUSFS) | KPM 镜像修补、本地 CLI 设计 | 未声明 |
| [coolzyd9107/GKI_SukiSU_Ultra_SUSFS](https://github.com/coolzyd9107/GKI_SukiSU_Ultra_SUSFS) | Release 说明模板 | GPL-2.0 |
| [SukiSU-Ultra](https://github.com/SukiSU-Ultra/SukiSU-Ultra) | KernelSU 变体本体 | GPL-3.0（`kernel/` 目录单独为 GPL-2.0） |
| [simonpunk/susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu) | SUSFS 补丁集 | GPL-3.0 |
| [WildKernels/AnyKernel3](https://github.com/WildKernels/AnyKernel3) | 刷机包模板 | BSD-3-Clause 风格（内含 `magiskboot` / `magiskpolicy` 为 GPL-3.0+） |

### 分层授权

| 层次 | 许可 |
|---|---|
| 上游 zzh20188 的基座代码 | 沿用 **GPL-2.0** |
| 本仓库**新增**的代码与文档 | **GPL-2.0-or-later** |
| 内核侧实际产物 | 实为 **GPL-2.0-only**（内核本身升不到 v3） |
| 整体分发 | 以 GPL-2.0-or-later 承载，以便与仓库内含的 GPL-3.0 组件合法共存 |

[LICENSE](LICENSE) 保留 GNU GPL v2 条款正文（不作删改），文件头以 SPDX 标识声明
分发方式；归属与兼容性说明写在 [NOTICE](NOTICE)。

### 移植代码时的协议判定规则

只判断一件事：**移植的东西会不会进内核产物**。

- **不进产物**（构建脚本 / 工作流 / defconfig 配置项）→ 无冲突。
  本仓库 GPL-2.0-or-later 可升级到 v3，能合法承载 GPL-3.0 的脚本代码；
  只需在文件头注明来源与许可。`CONFIG_xxx=y` 属于内核既有功能开关，不受版权保护。
- **进内核产物**（内核源码补丁、编进内核的驱动）→ 必须 GPL-2.0 兼容。
  内核是 GPL-2.0-only，升不到 v3，GPL-3.0 代码进内核即冲突。

> 因此：从 GPL-3.0 上游移植时，脚本与配置安全，但**内核补丁必须改从
> GPL-2.0 的源头（如 SukiSU-Ultra 的 `kernel/`）取源码自行实现**。

### GPL-2.0 与 GPL-3.0 的差异

| 维度 | GPL-2.0 | GPL-3.0 / or-later |
|---|---|---|
| 反硬件锁定 | 无要求 | 禁止用签名或硬件锁死 |
| 专利授权 | 无显式条款 | 贡献者自动授予专利许可 |
| 违反后恢复 | 违反即终止 | 首次违反 60 天内纠正可恢复 |
| 与 AGPL 合并 | 不允许 | 允许 |
| 与对方兼容性 | GPL-2.0-**only** 不能并入 GPL-3.0 作品 | GPL-2.0-**or-later** 可升到 GPL-3.0 |

**两者共同的核心限制（copyleft 传染性）**：分发二进制时必须同时提供完整源代码；
衍生作品必须以同一许可证分发；必须保留版权声明与许可全文，且无担保（AS IS）。

> **关于 `-or-later`**：新增部分采用 GPL-2.0-or-later，意味着使用者可选择按
> GPL-2.0 或更高版本（如 GPL-3.0）使用，这正是它能与 GPL-3.0 组件共存的原因；
> 纯 GPL-2.0-only 的代码不能这样升级。

**本仓库满足源码可得要求**：仓库公开，构建脚本、补丁与配置全部可查，上游
SukiSU / SUSFS / KernelSU 源码也可从其官方仓库获取。任何二次分发本仓库产物的行为，
同样需遵守上述义务。

如果你是上游作者并认为归属描述有误，请在本仓库提 Issue，会立即更正。

---

## 致谢

本仓库能存在，完全站在上游作者的肩膀上——内核构建矩阵、SUSFS 适配、KPM 修补、
管理器分发，这些硬核工作没有一样是本仓库作者完成的，所有功劳与敬意归于他们：

- **[zzh20188](https://github.com/zzh20188)** —— 本仓库的基座，构建矩阵与脚本的绝大部分工作出自他手；
- **[ShirkNeko](https://github.com/ShirkNeko)** —— KPM 镜像修补与本地 CLI 设计；
- **[coolzyd9107](https://github.com/coolzyd9107)** —— Release 呈现方式；
- **[LingLuo17](https://github.com/LingLuo17)** —— 6.12 ZRAM 补丁、SukiSU compat 补丁与网络增强；
- 以及 [SukiSU-Ultra](https://github.com/SukiSU-Ultra/SukiSU-Ultra)、
  [susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu)、
  [KernelSU](https://kernelsu.org/)、
  [AnyKernel3](https://github.com/WildKernels/AnyKernel3) 等项目的所有贡献者。

本仓库作者（借助 AI）所做的只是把上述成果拼装成自己用着顺手的样子。

**遇到本仓库的任何问题，请在本仓库反馈，不要以任何方式打扰上游作者**——
他们没有参与本仓库的修改，也不应为本仓库的问题买单。

---

<div align="center">

⭐ 如果这个项目对你有帮助，请点个 Star 支持一下！

</div>
