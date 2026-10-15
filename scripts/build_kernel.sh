#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# =============================================================================
# GKI 内核构建核心脚本 —— YAML 工作流与 Python CLI 共用的单一真相源
#
# 本脚本由 .github/workflows/build.yml 自动提取生成，逻辑与原工作流等价。
# 请勿直接手工编辑本文件的阶段函数：修改请改 build.yml 后重新生成，
# 或同步修改 build.py 与工作流，避免两套逻辑分叉。
#
# 用法:
#   ./scripts/build_kernel.sh --all                 运行完整构建
#   ./scripts/build_kernel.sh --from clone_deps     从指定阶段开始
#   ./scripts/build_kernel.sh --only compile_kernel 只跑单个阶段
#   ./scripts/build_kernel.sh --list                列出全部阶段
#
# 所有参数通过环境变量注入（见下方默认值），也可由 build.py 传入。
# =============================================================================
set -eo pipefail

# ---------------------------- 参数与默认值 ----------------------------
: "${ANDROID_VERSION:=android14}"
: "${KERNEL_VERSION:=6.1}"
: "${SUB_LEVEL:=124}"
: "${OS_PATCH_LEVEL:=2025-02}"
: "${KSU_VARIANT:=BakaSU}"
: "${KSU_MODE:=关闭}"
: "${VERSION:=}"
: "${REVISION:=}"
: "${BUILD_TIME:=}"
: "${USE_ZRAM:=false}"
: "${USE_BBR:=false}"
: "${USE_BBG:=false}"
: "${USE_KPM:=false}"
: "${USE_REKERNEL:=false}"
# 网络增强：IPSet 全类型 + BBR + FQ/FQ_CODEL 队列 + IPv6 NAT + 附加拥塞算法。
# 全部走 defconfig 写入，不引入第三方代码，默认关闭。
: "${USE_NET_ENHANCE:=false}"
# 兼容跳过：可选功能失败时降级为警告并继续构建，而非中断整个构建。
# 可跳过的阶段由 phase_skippable 白名单控制，SUSFS 与一加 8E 不在其中。
: "${SKIP_INCOMPATIBLE:=false}"
# NoMount 挂载元模块，移植自上游 zzh20188/GKI_KernelSU_SUSFS commit 27e129e
# （feat(ci): add optional NoMount metamodule integration，2026-09-19）。
# NoMount 在 fs/ 下注册子系统，与 SUSFS sus_mount 各走各的路径，可和任意 KSU 变体共存。
: "${USE_NOMOUNT:=false}"
: "${CVE_2026_43499_PATCH:=false}"
: "${EXPORT_SUSFS_PATCHES:=false}"
: "${ENABLE_SUSFS:=true}"
# SUSFS 原始补丁探测（来自上游 zzh20188 的 susfs-probe 工具分支）：
#   SUSFS_RAW_PROBE=true  -> 请求"只打原始补丁、不做适配修复"，用于校准兼容线。
#                            **需要 apply.sh 内部配合**才能生效（见 apply_susfs 阶段）。
#   SUSFS_SIDE_FIXES=true -> 探测时仍保留与子版本无关的侧修复（5.10 上游补丁
#                            自身的两处编译缺陷）
#   SUSFS_PIN_TIME        -> ISO 8601 时刻，把 susfs4ksu 固定到该时刻之前最后一次
#                            提交，让同一轮探测的所有任务用同一份上游代码。
#                            这一项已完整实现（见 clone_deps 阶段）。
: "${SUSFS_RAW_PROBE:=false}"
: "${SUSFS_SIDE_FIXES:=false}"
: "${SUSFS_PIN_TIME:=}"

# SUSFS 开关清单——与 SukiSU builtin 分支 kernel/Kconfig 里的 KSU_SUSFS* 一一对应
# （builtin 的 Kconfig 共 11 项：KSU_SUSFS 总开关 + 下面 9 个子项；main 分支 0 项）。
# 单一真相源：写 defconfig 和编译前核对 Kconfig 都从这里取，避免两处各写一份而漂移。
SUSFS_CONFIG_OPTIONS=(
  CONFIG_KSU_SUSFS=y
  CONFIG_KSU_SUSFS_SUS_PATH=y
  CONFIG_KSU_SUSFS_SUS_MOUNT=y
  CONFIG_KSU_SUSFS_SUS_KSTAT=y
  CONFIG_KSU_SUSFS_SPOOF_UNAME=y
  CONFIG_KSU_SUSFS_ENABLE_LOG=y
  CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
  CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
  CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
  CONFIG_KSU_SUSFS_SUS_MAP=y
)
# 各功能写进 defconfig 的符号清单——编译前「Kconfig 是否真的声明了该符号」核对用。
# 与 config_zram / config_net_enhance / add_bbg 三个阶段实际写入的行一一对应；
# 目标是复现被 sed 掉的 build.config.gki::check_defconfig 的作用（见 verify_kconfig_decl）。
ZRAM_KCONFIG_EXPECT=(
  CONFIG_ZSMALLOC
  CONFIG_ZRAM
  CONFIG_MODULE_SIG
  CONFIG_CRYPTO_LZO
  CONFIG_ZRAM_DEF_COMP_LZ4KD
  CONFIG_CRYPTO_LZ4HC
  CONFIG_CRYPTO_LZ4K
  CONFIG_CRYPTO_LZ4KD
  CONFIG_CRYPTO_842
  CONFIG_CRYPTO_LZ4K_OPLUS
)
NET_ENHANCE_KCONFIG_EXPECT=(
  CONFIG_TCP_CONG_ADVANCED
  CONFIG_TCP_CONG_BBR
  CONFIG_DEFAULT_BBR
  CONFIG_DEFAULT_TCP_CONG
  CONFIG_NET_SCH_FQ
  CONFIG_NET_SCH_FQ_CODEL
  CONFIG_IP_SET
  CONFIG_IP_SET_MAX
  CONFIG_NETFILTER_XT_SET
)
BBG_KCONFIG_EXPECT=(
  CONFIG_BBG
)
# 不得手写进 defconfig 的「隐藏符号」黑名单。
# 这些符号在目标内核里没有 prompt（由 Kconfig 的 select/depends 自行推导），手工写进
# defconfig 要么被 olddefconfig 静默丢弃、要么与 Kconfig 推导结果打架，且都不会让构建失败，
# 属于「看着生效其实没生效」。zzh20188 的 16944b83 正是删掉了网络增强里的
# `set_config CONFIG_NETFS_SUPPORT y`（该符号在 5.10 根本不存在，fs/netfs/Kconfig 为 404），
# 本仓库没有那段错误写入，这里落成防回退守卫：将来有人再手写这些符号时立刻报错。
# 只列「已实测在本仓库目标版本上不该手写」的符号，不做泛指（否则会误伤
# CONFIG_DEFAULT_TCP_CONG 这类本身无 prompt、但写入后确实被采纳的符号）。
HIDDEN_CONFIG_DENY=(
  CONFIG_NETFS_SUPPORT
)

: "${SUPP_OP:=false}"
# 严格许可模式会跳过许可未明或采用非标准许可的可选补丁。来源和许可信息见
# THIRD_PARTY_NOTICES.md。默认关闭。
: "${STRICT_LICENSE_MODE:=false}"
: "${DROIDSPACES:=不启用}"
: "${DROIDSPACES_NTSYNC:=false}"
: "${ARTIFACT_UPLOAD_MODE:=上传全部}"

# USE_KPM 取值归一化：Actions 下拉传 "enabled (开启)" / "patched (开启并修补)"，
# 早期本地 CLI 传 "true"/"false"，而脚本只按 enabled* / patched* 匹配，
# 导致 --kpm 静默失效。这里统一成三态，任何入口传什么都不至于判错。
case "${USE_KPM,,}" in
  enabled*|patched*) : ;;
  true|1|yes|on|开启)  USE_KPM="enabled (开启)" ;;
  *)                   USE_KPM="disabled (关闭)" ;;
esac

# KPM 镜像修补工具，移植自 ShirkNeko/GKI_KernelSU_SUSFS (scripts/config.py)
# ShirkNeko/SukiSU_patch 已改名为 SukiSU-Ultra/SukiSU_patch，旧路径目前靠 301 跳转苟活，
# 直接指向新名字，免得哪天跳转撤掉就整片构建一起挂。
# 跟随 SukiSU_patch 上游 main 分支（不钉 commit，便于自动跟进上游）
: "${KPM_PATCH_URL:=https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU_patch/refs/heads/main/kpm/patch_linux}"
# KPM 修补工具的可选 sha256 锚点。留空则不校验（跟随 main、零锚点风险）；
# 传入具体 64 位 hex 后，下方 stage_patch_kpm 会做 fail-closed 比对，不符即拒绝执行。
# 入口优先级（高 → 低）：
#   1) 环境变量 EXPECTED_KPM_PATCH_SHA256（CI: build.yml inputs.kpm_patch_sha256；本地: --kpm-patch-sha256）
#   2) $WORKSPACE/config/kpm_patch_sha256（仓库内单一 pin 源，可用 scripts/tools/pin_kpm_patch.sh 生成）
#   3) 空 → 不校验，打印 ::warning:: 明示零锚点运行
: "${EXPECTED_KPM_PATCH_SHA256:=}"
: "${WORKSPACE:=$(pwd)}"
: "${COMPILE_TIMEOUT_MINUTES:=30}"
: "${COMPILE_MAX_ATTEMPTS:=3}"
: "${GITHUB_SHA:=$(git -C "$WORKSPACE" rev-parse HEAD 2>/dev/null || echo unknown)}"
: "${GITHUB_RUN_ID:=local}"
: "${GITHUB_SERVER_URL:=}"
: "${GITHUB_REPOSITORY:=}"
: "${MANAGER_STR:=}"
export WORKSPACE GITHUB_SHA GITHUB_RUN_ID GITHUB_SERVER_URL GITHUB_REPOSITORY MANAGER_STR
export ANDROID_VERSION
export KERNEL_VERSION
export SUB_LEVEL
export OS_PATCH_LEVEL
export KSU_VARIANT
export KSU_MODE
export VERSION
export REVISION
export BUILD_TIME
export USE_ZRAM
export USE_BBR
export USE_BBG
export USE_KPM
export USE_REKERNEL
export USE_NET_ENHANCE
export SKIP_INCOMPATIBLE
export USE_NOMOUNT
export CVE_2026_43499_PATCH
export EXPORT_SUSFS_PATCHES
export ENABLE_SUSFS
export EXPECTED_KPM_PATCH_SHA256
export SUPP_OP
export STRICT_LICENSE_MODE
# SUSFS 原始补丁探测的三个开关必须 export：apply.sh 是 bash 子进程调用的，
# 不 export 的话子进程里 ${SUSFS_RAW_PROBE:-false} 恒为 false，探测形同虚设。
# SUSFS_PROBE_DIR 是 apply.json 的写出目录，同样要透过去；build.yml 负责设置。
export SUSFS_RAW_PROBE SUSFS_SIDE_FIXES SUSFS_PIN_TIME
: "${SUSFS_PROBE_DIR:=$WORKSPACE/susfs-probe}"
export SUSFS_PROBE_DIR
# 探测矩阵里同一子版本会跨多个月份出现（如 5.10.209 的 2024-11 与 2025-01），
# 而 CONFIG 只到子版本这一步，产物名不带月份就会互相覆盖。
ARTIFACT_SUFFIX=""
if [ "${SUSFS_RAW_PROBE:-false}" = "true" ]; then
  ARTIFACT_SUFFIX="-${OS_PATCH_LEVEL:-unknown}"
fi
export ARTIFACT_SUFFIX
export DROIDSPACES
export DROIDSPACES_NTSYNC
export ARTIFACT_UPLOAD_MODE

# ---------------------------- 运行时状态 ----------------------------
export COMPILE_FAILED=0
export SUSFS_PATCH_EXPORT=false
export REJ_COUNT=0
export TOOLCHAIN_CACHE_HIT="${TOOLCHAIN_CACHE_HIT:-false}"
# 注意：切勿在全局导出 OUT_DIR —— GKI 的 build/build.sh 会把它当作内核输出目录继承，
# 导致产物从 out/<branch>/dist 跑到别处。SUSFS 补丁导出目录请在阶段内局部定义。

log_stage() {
  echo ""
  echo "================================================================"
  echo "  [$1] $2"
  echo "================================================================"
}
