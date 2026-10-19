# 第三方组件许可核对记录

本文件补充 [NOTICE](NOTICE)，重点记录许可状态不清晰或可能与内核基线不兼容的组件。路径仅表示当前代码中的引入点；行号会随代码变化，应以对应函数和调用位置为准。

## 风险摘要

| 组件 | 进入方式 | 许可问题 | 已知退出方式 |
|---|---|---|---|
| SUSFS (`simonpunk/susfs4ksu`) | 补丁应用到内核源码树；当前常规构建可启用 | GPL-3.0-or-later 与 Linux GPL-2.0-only 内核组合不兼容风险 | 关闭 SUSFS；仍须确认构建脚本及 KSU 侧未残留相关代码 |
| NoMount (`maxsteeel/nomount`) | `USE_NOMOUNT=true` 时链接 `fs/nomount` 并编入内核 | GPL-3.0 与 GPL-2.0-only 内核组合不兼容风险 | 脚本默认关闭，但个别预设（如 `build-236-marble.yml`）会启用；严格模式不会自动覆盖此项 |
| Unicode 修复 (`Numbersf/Action-Build`) | 补丁应用到内核源码树 | 自定义许可，是否允许本项目这种引用和产物分发尚未确认 | `STRICT_LICENSE_MODE=true` 跳过该阶段 |
| 三星 `min_kdp.c` (`WildKernels/kernel_patches`) | 可选源文件复制进内核树并编译 | 上游未声明许可 | `STRICT_LICENSE_MODE=true` 跳过相关功能 |
| `patch_linux` (`SukiSU-Ultra/SukiSU_patch`) | 下载并执行预编译工具以改写 `Image` | 工具许可及对修改后产物的授权范围未确认 | `STRICT_LICENSE_MODE=true` 跳过 KPM 修补 |
| FinaSU 构建适配 (`LingLuo17/AnyKernel3/scripts/finasu_compat`) | 证书提取器与 SUSFS 适配补丁参与内核构建 | 上游 AnyKernel3 仓库使用 GPL-3.0；移植文件按 GPL-3.0-only 标注并保留来源 | 适用 GPL-3.0 的源码分发义务；见下方来源记录 |

以上退出开关只说明构建实现中存在相应分支，不等于输出已完成源码级验证，也不构成合规保证。尤其 SUSFS 当前是项目核心选项，关闭其开关后仍需检查实际 KSU 来源、补丁和文件是否带入 SUSFS 实现。

## 许可判断依据

- Linux 内核规则声明内核主体为 GPL-2.0-only：<https://github.com/torvalds/linux/blob/master/Documentation/process/license-rules.rst>
- GNU FAQ 说明 GPL-3.0 与 GPL-2.0-only 不兼容；GPL-2.0-or-later 才可能按 GPL-3.0 选择：<https://www.gnu.org/licenses/gpl-faq.en.html>
- SUSFS `1.3.0` LICENSE 标注 GPL-3.0-or-later：<https://gitlab.com/simonpunk/susfs4ksu/-/blob/1.3.0/LICENSE?ref_type=tags>
- Ling 的上游仓库与发布页：<https://github.com/LingLuo17/AnyKernel3>、<https://github.com/LingLuo17/AnyKernel3/releases>
- BakaSU 官方仓库说明其原名为 ReSukiSU，并列出内核、管理器及图标资源的分层许可：<https://github.com/Baka-SU/BakaSU>

## FinaSU 构建支持与来源

本仓库的 FinaSU 工作流从 [LyraVoid/FinaSU](https://github.com/LyraVoid/FinaSU) 最新 Release 获取官方 APK，并把内核源码固定到同一 Release tag 对应的 commit。发布说明中的 commit 链接用于定位 APK 对应源码；分发 FinaSU APK 时应同时提供该源码及 GPL-3.0 许可信息。

以下实现移植并按其许可证 GPL-3.0-only 使用，来源仓库为 [LingLuo17/AnyKernel3](https://github.com/LingLuo17/AnyKernel3)（GitHub 全称 `LingLuo17/AnyKernel3`，许可证 SPDX：`GPL-3.0`）。

- [`extract_manager_cert.py`](https://github.com/LingLuo17/AnyKernel3/blob/fb8379aa781f9e94cabee2c12f543144035b5da3/scripts/finasu_compat/extract_manager_cert.py)：从 APK 签名块提取官方证书信息，GPL-3.0-only。移植自上游 commit `fb8379aa781f9e94cabee2c12f543144035b5da3`。
- [`apply.sh`](https://github.com/LingLuo17/AnyKernel3/blob/d6255c5f44e3871743c7d1570436822227b4b2fd/scripts/finasu_compat/apply.sh)：FinaSU 内核侧 SUSFS 集成 —— 以 `patch -p1 --forward` 应用 susfs4ksu 的 `10_enable_susfs_for_ksu.patch`（允许部分 hunk 失败），再按补丁本意对结构漂移点做内联修复，GPL-3.0-only。移植自上游 commit `d6255c5f44e3871743c7d1570436822227b4b2fd`（2026-10-17，"fix(finasu): restore arch syscall_hook objects for preinit ksu_syscall_table reference"）。本仓库在上游基础上补强了失败处理：上游用 `|| true` 静默吞掉补丁失败，本仓库改为 `patch` 退出码 ≥2 直接中止、并对最终产物做 fail-closed 断言（详见脚本头部说明）。
- [`LICENSE-GPL-3.0.txt`](LICENSE-GPL-3.0.txt)：随上述移植文件附带的 GPL-3.0 许可证文本，取自上游仓库的 `LICENSE` 文件。

> 历史说明：本仓库早期版本另带一个 `susfs_drift_fixes.patch`（上游 `fb8379aa` 时期的独立适配补丁）。上游自 `d6255c5f4` 起已把该补丁的全部改动改为 `apply.sh` 内联修复，因此本仓库同步移除该文件，不再保留冗余补丁副本。

FinaSU 仓库标记 GPL-3.0。许可是否与实际构建组合兼容，应以本次使用的具体文件、commit 和许可文本核查结果为准；本说明不把整个仓库或内核产物统一标为 GPL-3.0。

## BakaSU 构建支持与来源

BakaSU 自上游 `48fa4bb` 起在 `kernel/tools/susfs_compat.mk` 末尾保留无条件的 `$(error Please wait susfs update.)`，主动暂停 SUSFS 构建。本仓库不解锁该文件，而是**按树内证据逐版本判定是否放行**。

- [`resume_susfs.sh`](https://github.com/LingLuo17/AnyKernel3/blob/6db3a675/scripts/bakasu_compat/resume_susfs.sh)：GPL-3.0。移植自 [LingLuo17/AnyKernel3](https://github.com/LingLuo17/AnyKernel3) 的 commit `6db3a675`，本仓库按自己的目录布局与「编译前 fail-fast」风格重写，语义一致但更早失败（判定在 `apply_susfs` 之后、编译之前）。
  与原实现的差别：上游允许无条件放行，本仓库只把「无条件的 `$(error)`」换成「有依据的判定」，判定不成立时照旧阻断（fail-closed），避免产出上游刻意规避的可检测内核。


## 本仓库文件的许可归属总表

仓库内每个脚本文件头部都有 `SPDX-License-Identifier` 行。按来源分为三类：

| 类别 | 文件 | 许可 |
|---|---|---|
| **① 移植自上游，保留上游许可** | `scripts/bakasu_compat/resume_susfs.sh` | `GPL-3.0-only`（源自 LingLuo17/AnyKernel3 `6db3a675`） |
| | `scripts/finasu_compat/apply.sh` | `GPL-3.0-only`（源自 LingLuo17/AnyKernel3 `d6255c5f4`） |
| | `scripts/finasu_compat/extract_manager_cert.py` | `GPL-3.0-only`（源自 LingLuo17/AnyKernel3 `fb8379aa7`） |
| **② 本仓库自维护** | `scripts/build_kernel.sh`、`scripts/check_upstream_susfs.sh`、`scripts/get_manager.sh`、`scripts/ksu_uapi_sync/align.sh`、`scripts/sukisu_compat/apply.sh`、`scripts/susfs_fixes/apply.sh`、`scripts/susfs_probe/*.py`、`scripts/tools/pin_kpm_patch.sh`、`tools/*.py`、`zram/apply_lz4_neon.sh` | `GPL-2.0-or-later` |
| **③ 一次性迁移留档（不参与构建）** | `tools/migration/*.py` | `GPL-2.0-or-later`，仅作过程留档，见该目录 README |

注意：

- 上述 SPDX 行描述的是**本仓库该文件自身的许可**，不代表整个仓库或内核产物只有一种许可——内核对部分受 GPL-2.0-only 约束，上游补丁可能另有许可（见上节）。
- `apply.sh` 的引用实现参考了 LingLuo17/AnyKernel3，但 `align.sh` 只在注释中标注**对照实现**，代码由本仓库自行编写，因此按 ② 处理。
- 移植文件（①）在分发时需同时提供对应上游源码与许可证文本；GPL-3.0 全文见 [`LICENSE-GPL-3.0.txt`](LICENSE-GPL-3.0.txt)。
- 表② 的 `zram/apply_lz4_neon.sh` 本身是本仓库脚本；它操作的 `zram/lz4/`（Yann Collet，BSD-2-Clause）与 `zram/lz4/lz4armv8/`（源自 Huawei EROFS 的 NEON 实现）属另一类第三方源码，逐文件头自带许可声明，详见 [`NOTICE`](NOTICE) 的同名两条。

## 许可风险组件细节

### `Numbersf/Action-Build` Unicode 补丁

补丁修改内核源码。上游自定义许可的适用范围、与 GPL 内核组合的兼容性以及对镜像和刷机包再分发的明确授权尚未由权利人确认。此前文档对其“允许分发构建产物”的解释不应视为法律结论。取得明确授权前，分发含该补丁的产物风险未消除。

### 未声明许可的源码和二进制

`min_kdp.c` 被复制进内核时属于产物源码的一部分；`patch_linux` 虽是构建工具而非直接复制到内核源码，但会修改待分发的 Image。公开可下载、仓库有 fork 或构建成功，都不能代替版权许可。应取得权利人许可或停用该功能，并确认其内容未从其他步骤间接进入产物。
