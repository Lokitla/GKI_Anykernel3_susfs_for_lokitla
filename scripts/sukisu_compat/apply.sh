#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# SukiSU 内核源码 API 兼容补丁（SukiSU-Ultra builtin / main 分支均适用）
#
# 背景：
#   1) builtin 分支 kernel/hook/lsm_hook.c 仍以旧签名
#      security_add_hooks(hooks, count, "ksu") 注册 LSM 钩子，
#      6.8+ 内核要求 (hooks, count, const struct lsm_id *)，
#      android16-6.12 GKI 编译报 -Wincompatible-pointer-types（-Werror）；
#   2) kernel/kpm/super_access.c 引用 netlink_kernel_cfg.cb_mutex，
#      该成员在 Linux 6.11 被上游移除，KPM 开启时 6.11+ 内核编译失败。
#
# 两组修复均以 LINUX_VERSION_CODE 守卫，6.10 及以下内核编译结果不变；
# 上游自行修复后 grep 检测会自动跳过，重复执行幂等。
#
# 用法: apply.sh [KernelSU 目录]（调用方工作目录需为 $KERNEL_ROOT）

set -eo pipefail

KSU_DIR="${1:-KernelSU}"

fail() {
  # 默认值兜底：脚本目前是 set -eo pipefail（无 -u），但调用方不保证注入该变量；
  # 一旦有人补上 -u，fail() 就会在最需要报错的路径上 unbound variable 崩溃。
  if [ "${SKIP_INCOMPATIBLE:-false}" = "true" ]; then
    echo "::warning title=SukiSU 兼容补丁已跳过::$1"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      echo "" >> "$GITHUB_STEP_SUMMARY"
      echo "> ⏭️ **SukiSU API 兼容补丁** 已自动跳过：$1（构建未中断）" >> "$GITHUB_STEP_SUMMARY"
    fi
    exit 0
  fi
  echo "::error::$1"
  exit 1
}

[ -d "$KSU_DIR" ] || fail "未找到 KernelSU 目录: $KSU_DIR"

COMPAT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LSM_FILE="$KSU_DIR/kernel/hook/lsm_hook.c"
if [ -f "$LSM_FILE" ] && grep -q 'security_add_hooks(ksu_hooks, ARRAY_SIZE(ksu_hooks), "ksu");' "$LSM_FILE"; then
  if grep -q 'ksu_lsm_id' "$LSM_FILE"; then
    echo "lsm_hook.c 已包含 lsm_id 兼容代码，跳过"
  else
    echo "应用 lsm_id 兼容补丁 (6.8+ security_add_hooks 新签名)..."
    patch -p1 --forward -d "$KSU_DIR" < "$COMPAT_DIR/sukisu-lsm-id-6.8.patch" \
      || fail "lsm_id 兼容补丁应用失败（SukiSU 上游代码可能已变化）"
    grep -q 'struct lsm_id ksu_lsm_id' "$LSM_FILE" \
      || fail "lsm_id 兼容补丁应用后校验失败"
    echo "lsm_hook.c: 6.8+ 已切换为 struct lsm_id 注册"
  fi
else
  echo "lsm_hook.c 不存在或无需 lsm_id 兼容补丁，跳过"
fi

SUPER_FILE="$KSU_DIR/kernel/kpm/super_access.c"
if [ -f "$SUPER_FILE" ] && grep -q 'DEFINE_MEMBER(netlink_kernel_cfg, cb_mutex)' "$SUPER_FILE"; then
  if grep -q 'KERNEL_VERSION(6, 11, 0)' "$SUPER_FILE"; then
    echo "super_access.c 已包含 cb_mutex 版本守卫，跳过"
  else
    echo "应用 cb_mutex 兼容补丁 (6.11+ 移除 netlink_kernel_cfg.cb_mutex)..."
    patch -p1 --forward -d "$KSU_DIR" < "$COMPAT_DIR/sukisu-cb-mutex-6.11.patch" \
      || fail "cb_mutex 兼容补丁应用失败（SukiSU 上游代码可能已变化）"
    grep -q 'KERNEL_VERSION(6, 11, 0)' "$SUPER_FILE" \
      || fail "cb_mutex 兼容补丁应用后校验失败"
    echo "super_access.c: 6.11+ 已跳过 cb_mutex 成员"
  fi
else
  echo "super_access.c 不存在或无需 cb_mutex 兼容补丁，跳过"
fi

echo "SukiSU API 兼容补丁处理完成"
