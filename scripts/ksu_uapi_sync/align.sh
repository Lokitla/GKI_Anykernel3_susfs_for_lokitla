#!/usr/bin/env bash
# SukiSU 内核侧 UAPI 对齐：把内核检出里的 KERNEL_SU_UAPI_VERSION（以及 UAPI 4
# 引入的 KSU_GET_INFO_FLAG_BUNDLED 常量）对齐到官方管理器构建所用的值。
#
# ==== 为什么需要这一步 ====
# SukiSU 的 builtin 分支（内建内核实现 + SUSFS 产品线）与 main 分支是两条
# 无共同祖先的独立线。官方管理器 APK 只能由 main 构建——builtin 是只含
# kernel/ 与 uapi/ 的分支，连 manager/ 目录都没有（本仓库
# .github/workflows/get-manager.yml:171-176 已记录这一点）。
#
# 管理器在 managerUAPIVersion > kernelUAPIVersion 时判定 requiresNewKernel，
# 首页报「需要更新内核」（上游 userspace 侧 Natives.kt 的比对逻辑）。
# 本仓库 scripts/build_kernel.sh 的 resolve_ksu_branch 在 ENABLE_SUSFS=true 时
# auto 模式会选 builtin，于是「内核=builtin、管理器=main」成为稳定组合，
# 内核 UAPI 恒落后于管理器 —— 该误报必然出现，且与内核功能无关。
#
# 对照实现：LingLuo17/AnyKernel3 的 b2f2598c（UAPI 2→5）与 1bb9d909
# （上游 builtin 合并 su-session 全套实现后，把补丁收敛为「仅剩常量」）。
# 其提交说明确认：UAPI 5 唯一的功能件 EVENT_SERVICES（dispatch.c 里的
# start/skip 语义）已随上游 70fa0e092 进入 builtin，缺的只是版本号常量本身，
# 所以「对齐」是纯常量改写，不引入新的内核侧代码。
#
# ==== 为什么不是静态补丁 ====
# 用户约束是「不把上游钉死、要随上游更新」。静态 patch 的上下文一旦被上游
# 改动就必然失效（LingLuo 的 builtin-uapi4.patch 前后改了两版就是实例）。
# 这里改为按「现状」推导：
#   目标值 = 上游 main 的 uapi/supercall.h 现值（可用 KSU_UAPI_TARGET 覆盖）
#   内核树现值 >= 目标值 → 上游已自行同步，幂等跳过
#   内核树现值 <  目标值 → 就地改写常量（锚定标识符，不写死文件路径）
#
# 兼容上游两种现存写法：
#   builtin: DECLARE(__u32, KERNEL_SU_UAPI_VERSION, 2);
#   main:    static const __u32 KERNEL_SU_UAPI_VERSION = 5;
#
# ==== 失败语义（刻意分档）====
# 硬失败（exit 1，调用方中止构建）只用于「已确知必须做、且动手后可以自证」的情形：
#   - 内核检出目录不存在（阶段顺序错误）
#   - 已定位到唯一 UAPI 头，但版本号写不进去 / 回读不一致
# 软跳过（warning + exit 0）用于「无法判定，不能瞎猜」的情形：
#   - 找不到 UAPI 头（上游改目录结构）、找到多个无法收窄（不确定改哪个）
#   - 取不到上游 main 的目标版本号（网络受限）
# 这些情形下放弃对齐只影响管理器首页的「需要更新内核」提示，不影响内核功能与
# 安全性，因此不该让整次内核构建失败；但都会打印明确的 warning，不会静默放过。
#
# 退出码：0=已对齐 / 无需对齐 / 无法判定已告警；1=对齐失败（须中止构建）

set -uo pipefail

KSU_DIR="${1:-KernelSU}"
TARGET="${KSU_UAPI_TARGET:-}"
# 目标 UAPI 版本必须取自**与内核实际检出同源**的上游文件，否则会把内核版本号改成一个它并不具备的号。
# 各变体的上游仓库与 UAPI 头路径并不一致：
#   SukiSU（main / builtin）   SukiSU-Ultra/SukiSU-Ultra  uapi/supercall.h（builtin 为 kernel/include/uapi/supercall.h）
#   BakaSU                     Baka-SU/BakaSU             uapi/supercall.h
#   FinaSU                     LyraVoid/FinaSU            uapi/supercall.h（随 Release 固定）
#   KernelSU / Next            tiann/KernelSU / KernelSU-Next  uapi/supercall.h
# 历史上这里写死 SukiSU-Ultra main，等于假设所有变体都跟 SukiSU main 同源。
# 一旦 SukiSU 先涨到 UAPI 6 而 BakaSU 仍停在 5，BakaSU 内核的版本号就会被改写成 6，
# 出现「版本号自称 6、实际缺 6 的符号」——正是要避免的情况。
KSU_UAPI_URL="${KSU_UAPI_URL:-}"
if [ -z "$KSU_UAPI_URL" ]; then
  case "${KSU_VARIANT:-SukiSU}" in
    BakaSU)  KSU_UAPI_URL="https://raw.githubusercontent.com/Baka-SU/BakaSU/main/uapi/supercall.h" ;;
    FinaSU)  KSU_UAPI_URL="https://raw.githubusercontent.com/LyraVoid/FinaSU/master/uapi/supercall.h" ;;
    Next)    KSU_UAPI_URL="https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/dev/uapi/supercall.h" ;;
    Official) KSU_UAPI_URL="https://raw.githubusercontent.com/tiann/KernelSU/main/uapi/supercall.h" ;;
    *)
      # SukiSU 系：main 与 builtin 是两条独立拓扑，UAPI 头路径也不同，按实际检出分支取。
      _uapi_branch="${KSU_BRANCH_MODE_RESOLVED:-main}"
      if [ "$_uapi_branch" = "builtin" ] || [ "$_uapi_branch" = "builtin-new" ] || [ "$_uapi_branch" = "builtin-rebase" ]; then
        KSU_UAPI_URL="https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/${_uapi_branch}/kernel/include/uapi/supercall.h"
      else
        KSU_UAPI_URL="https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/uapi/supercall.h"
      fi
      ;;
  esac
fi
UPSTREAM_UAPI_URL="$KSU_UAPI_URL"

die() {
  echo "::error::SukiSU UAPI 对齐：$*"
  exit 1
}

read_uapi_from() {
  # 从任一形态的声明行里取数字：
  #   DECLARE(__u32, KERNEL_SU_UAPI_VERSION, 2);  → 2
  #   static const __u32 KERNEL_SU_UAPI_VERSION = 5; → 5
  grep -oE 'KERNEL_SU_UAPI_VERSION[^0-9]*[0-9]+' "$1" 2>/dev/null \
    | grep -oE '[0-9]+' | tail -n 1
}

# ---------- 0. 定位内核检出里的 UAPI 头 ----------
[ -d "$KSU_DIR" ] || die "内核检出目录不存在：$KSU_DIR（应先跑 add_kernelsu 阶段）"

mapfile -t hits < <(grep -rl --exclude-dir=.git --include='supercall.h' \
  'KERNEL_SU_UAPI_VERSION' "$KSU_DIR" 2>/dev/null)

if [ "${#hits[@]}" -gt 1 ]; then
  # 多种写法/多个副本时收窄：优先 kernel/ 段，再优先 uapi/ 段
  mapfile -t narrowed < <(printf '%s\n' "${hits[@]}" | grep '/kernel/' || true)
  [ "${#narrowed[@]}" -gt 0 ] && hits=("${narrowed[@]}")
  mapfile -t narrowed < <(printf '%s\n' "${hits[@]}" | grep '/uapi/' || true)
  [ "${#narrowed[@]}" -gt 0 ] && hits=("${narrowed[@]}")
fi

if [ "${#hits[@]}" -eq 0 ]; then
  echo "::warning::内核检出中找不到定义 KERNEL_SU_UAPI_VERSION 的头文件（上游可能改了目录结构），本次跳过 UAPI 对齐；若管理器首页报「需要更新内核」，可设 KSU_UAPI_TARGET 显式指定目标版本"
  exit 0
fi
if [ "${#hits[@]}" -ne 1 ]; then
  echo "::warning::在内核检出中命中 ${#hits[@]} 个 UAPI 头，无法确定应改哪一个，本次跳过 UAPI 对齐：${hits[*]}"
  exit 0
fi

UAPI_FILE="${hits[0]}"
CURRENT=$(read_uapi_from "$UAPI_FILE")
[ -n "$CURRENT" ] || die "无法从 $UAPI_FILE 解析 KERNEL_SU_UAPI_VERSION"

echo "内核 UAPI 头：$UAPI_FILE（当前版本 ${CURRENT}）"

# ---------- 1. 确定目标版本 ----------
if [ -z "$TARGET" ]; then
  # 临时目录可能受沙箱限制，用内核检出旁的可写路径落盘
  tmp_uapi="$(mktemp 2>/dev/null || echo "$KSU_DIR/.uapi_upstream.$$")"
  if ! curl -LSsf --retry 3 --retry-delay 2 --connect-timeout 30 \
       "$UPSTREAM_UAPI_URL" -o "$tmp_uapi" 2>/dev/null; then
    rm -f "$tmp_uapi"
    # 取不到上游值就无法安全推断目标号：只告警跳过，不因为一次网络抖动
    # 让整次内核构建失败（该问题仅影响管理器首页提示，不影响内核功能）。
    echo "::warning::无法获取上游 main 的 UAPI 版本（$UPSTREAM_UAPI_URL），本次跳过 UAPI 对齐；若管理器报「需要更新内核」，可设 KSU_UAPI_TARGET 显式指定"
    exit 0
  fi
  TARGET=$(read_uapi_from "$tmp_uapi")
  rm -f "$tmp_uapi"
fi

case "$TARGET" in
  ''|*[!0-9]*) die "目标 UAPI 版本无效：'${TARGET}'" ;;
esac

# ---------- 2. 幂等判据 ----------
if [ "$CURRENT" -ge "$TARGET" ]; then
  echo "内核 UAPI ${CURRENT} >= 管理器期望 ${TARGET}，上游已同步，无需对齐"
  exit 0
fi

echo "内核 UAPI ${CURRENT} < 管理器期望 ${TARGET}，开始对齐：$UAPI_FILE"

# ---------- 3. 改写版本号 ----------
# 只替换标识符之后紧跟的那个数字，避免误伤同文件里其它常量。
sed -i -E "s/(KERNEL_SU_UAPI_VERSION[^0-9]*)[0-9]+/\1${TARGET}/" "$UAPI_FILE" \
  || die "改写 $UAPI_FILE 的 KERNEL_SU_UAPI_VERSION 失败"

AFTER=$(read_uapi_from "$UAPI_FILE")
[ "$AFTER" = "$TARGET" ] || die "版本号改写后回读为 '${AFTER}'，期望 ${TARGET}"

# ---------- 4. 补齐 UAPI 4 的 KSU_GET_INFO_FLAG_BUNDLED 常量 ----------
# 版本号（管理器弹「需要更新内核」的真正判据）此时已经改写完毕，下面补的只是一个能力
# 标志常量。所以本步凡「定位不到 / 声明风格不认识」一律降级为告警跳过，不让一次格式
# 差异把整次内核构建打挂；只有真正的写盘失败（IO 错误）才硬失败。
NEW_LINE=""
ANCHOR=""
if grep -q 'KSU_GET_INFO_FLAG_BUNDLED' "$UAPI_FILE"; then
  echo "KSU_GET_INFO_FLAG_BUNDLED 已存在，跳过"
else
  # 锚定在最后一个 KSU_GET_INFO_FLAG_* 定义之后；缩进与声明风格都从锚点行本身推导，
  # 不写死文件路径也不写死宏名。
  ANCHOR=$(grep -nE 'KSU_GET_INFO_FLAG_[A-Z0-9_]+.*\(1U[[:space:]]*<<[[:space:]]*[0-9]+\)' "$UAPI_FILE" \
    | tail -n 1 | cut -d: -f1)
  ANCHOR_LINE=""
  [ -n "$ANCHOR" ] && ANCHOR_LINE=$(sed -n "${ANCHOR}p" "$UAPI_FILE")

  case "$ANCHOR_LINE" in
    *DECLARE\(*)
      INDENT="${ANCHOR_LINE%%[![:space:]]*}"
      NEW_LINE="${INDENT}DECLARE(__u32, KSU_GET_INFO_FLAG_BUNDLED, (1U << 4));"
      ;;
    *DEFINE_KSU_UAPI_CONST\(*)
      # BakaSU（DEFINE_KSU_UAPI_CONST 宏，无分号）
      INDENT="${ANCHOR_LINE%%[![:space:]]*}"
      NEW_LINE="${INDENT}DEFINE_KSU_UAPI_CONST(__u32, KSU_GET_INFO_FLAG_BUNDLED, (1U << 4))"
      ;;
    *"static const"*)
      # SukiSU main（static const 变量，有分号）
      INDENT="${ANCHOR_LINE%%[![:space:]]*}"
      NEW_LINE="${INDENT}static const __u32 KSU_GET_INFO_FLAG_BUNDLED = (1U << 4);"
      ;;
    *)
      echo "::warning::无法在 $UAPI_FILE 中定位 KSU_GET_INFO_FLAG_* 定义或识别其声明风格，跳过 KSU_GET_INFO_FLAG_BUNDLED 的补齐（版本号已对齐，不影响「需要更新内核」提示）"
      ;;
  esac
fi

if [ -n "$NEW_LINE" ]; then
  awk -v n="$ANCHOR" -v line="$NEW_LINE" \
    'NR == n { print; print line; next } { print }' \
    "$UAPI_FILE" > "${UAPI_FILE}.uapi_tmp" || die "写入临时文件失败"
  mv "${UAPI_FILE}.uapi_tmp" "$UAPI_FILE" || die "替换 $UAPI_FILE 失败"

  grep -q 'KSU_GET_INFO_FLAG_BUNDLED' "$UAPI_FILE" \
    || die "插入后仍未匹配到 KSU_GET_INFO_FLAG_BUNDLED"
  echo "已补齐 KSU_GET_INFO_FLAG_BUNDLED (1U << 4)，插入于第 ${ANCHOR} 行之后"
fi

# ---------- 5. 终校验 ----------
FINAL=$(read_uapi_from "$UAPI_FILE")
[ "$FINAL" = "$TARGET" ] || die "终校验失败：回读 UAPI=${FINAL}，期望 ${TARGET}"

echo "SukiSU UAPI 对齐完成：${CURRENT} -> ${FINAL}（管理器期望 ${TARGET}）"
exit 0
