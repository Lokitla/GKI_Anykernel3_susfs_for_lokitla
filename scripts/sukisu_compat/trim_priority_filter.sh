#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# 裁剪 SukiSU builtin 的 priority-uid-filter 集成（仅当目标内核的 SUSFS 不提供该 API）
#
# 背景：SukiSU builtin 2026-11 起把 priority uid filter 的调用写成无条件语句——
#   kernel/manager/pkg_observer.c   susfs_parse_priority_app_strings();   （两处）
#   kernel/supercall/dispatch.c     case CMD_SUSFS_SET_PRIORITY_UID_FILTER: ...
# 声明与实现都只在「带 priority uid filter 的 SUSFS」里提供
# （include/linux/susfs.h + fs/susfs.c 的 st_susfs_priority_uid_filter 一套）。
# scripts/build_kernel.sh 钉住的 SUSFS 提交还没带这套 API，于是所有 SukiSU
# 变体都在 ksu_main.o 阶段红：
#   error: call to undeclared function 'susfs_parse_priority_app_strings'
#   error: use of undeclared identifier 'CMD_SUSFS_SET_PRIORITY_UID_FILTER'
#   error: call to undeclared function 'susfs_set_priority_uid_filter'
#
# 判据只看目标内核的 SUSFS 头：头里有该 API 就整段跳过（SUSFS 钉住提交前移、
# 自带这套接口后本脚本自动失效）；没有才把 builtin 侧调用摘掉——等价于上游
# 11-01 新增该特性之前的行为，其它 SUSFS 功能不受影响。重复执行幂等。
#
# 必须在 apply_susfs 之后调用（需要一个已打上 SUSFS 的内核树）。
#
# 用法: trim_priority_filter.sh [KernelSU 目录]
#   内核根目录取 $KERNEL_ROOT，未设置时用当前工作目录。

set -eo pipefail

BASE="${KERNEL_ROOT:-$PWD}"
KSU_DIR="$BASE/${1:-KernelSU}"

fail() {
  if [ "${SKIP_INCOMPATIBLE:-false}" = "true" ]; then
    echo "::warning title=priority-uid-filter 裁剪已跳过::$1"
    exit 0
  fi
  echo "::error::$1"
  exit 1
}

SUSFS_HDR=""
for _h in "$BASE/common/include/linux/susfs.h" "$BASE/include/linux/susfs.h"; do
  if [ -f "$_h" ]; then SUSFS_HDR="$_h"; break; fi
done

if [ -z "$SUSFS_HDR" ]; then
  echo "未找到目标内核的 include/linux/susfs.h（SUSFS 未落地？），跳过 priority-uid-filter 裁剪"
  exit 0
fi

if grep -q 'susfs_parse_priority_app_strings' "$SUSFS_HDR"; then
  echo "SUSFS 头已提供 priority uid filter API（${SUSFS_HDR#$BASE/}），跳过裁剪"
  exit 0
fi

OBS_FILE="$KSU_DIR/kernel/manager/pkg_observer.c"
DSP_FILE="$KSU_DIR/kernel/supercall/dispatch.c"
TRIMMED=0

if [ -f "$OBS_FILE" ]; then
  if grep -qE '^[[:space:]]*susfs_parse_priority_app_strings\(\);' "$OBS_FILE"; then
    sed -i 's|^\([[:space:]]*\)susfs_parse_priority_app_strings();|\1// susfs_parse_priority_app_strings(); // SUSFS 未提供该 API（trim_priority_filter 摘除）|' "$OBS_FILE"
    if grep -qE '^[[:space:]]*susfs_parse_priority_app_strings\(\);' "$OBS_FILE"; then
      fail "pkg_observer.c priority 调用裁剪后仍有未注释的调用"
    fi
    echo "pkg_observer.c: 已摘除 susfs_parse_priority_app_strings() 调用"
    TRIMMED=1
  fi
fi

if [ -f "$DSP_FILE" ]; then
  if grep -qE '^[[:space:]]*case CMD_SUSFS_SET_PRIORITY_UID_FILTER:' "$DSP_FILE"; then
    # 只注释从 case 到 return 0; 的三行，保留缩进与行数，便于对照上游 diff
    sed -i -E '/^[[:space:]]*case CMD_SUSFS_SET_PRIORITY_UID_FILTER:/,/^[[:space:]]*return 0;/ s|^|// |' "$DSP_FILE"
    if grep -qE '^[[:space:]]*case CMD_SUSFS_SET_PRIORITY_UID_FILTER:' "$DSP_FILE"; then
      fail "dispatch.c priority 分支裁剪后仍有未注释的分支"
    fi
    echo "dispatch.c: 已摘除 CMD_SUSFS_SET_PRIORITY_UID_FILTER 分支"
    TRIMMED=1
  fi
fi

if [ "$TRIMMED" = "0" ]; then
  echo "KernelSU 侧未发现 priority-uid-filter 集成，无需裁剪"
fi

echo "priority-uid-filter 裁剪完成"