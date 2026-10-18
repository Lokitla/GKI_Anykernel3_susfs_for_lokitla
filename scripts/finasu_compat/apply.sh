#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Based on LingLuo17/AnyKernel3 scripts/finasu_compat/apply.sh.
set -euo pipefail

KSU_DIR="${1:-KernelSU}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIFT_PATCH="$SCRIPT_DIR/susfs_drift_fixes.patch"
UPSTREAM_PATCH="${SUSFS4KSU:-$PWD/susfs4ksu}/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch"
DRIFT_FILES=(
  kernel/core/init.c
  kernel/feature/selinux_hide.c
  kernel/runtime/boot_event.c
  kernel/supercall/dispatch.c
)

fail() { echo "::error::$1" >&2; exit 1; }
[ -f "$UPSTREAM_PATCH" ] || fail "未找到 SUSFS KernelSU 补丁: $UPSTREAM_PATCH"
[ -f "$DRIFT_PATCH" ] || fail "未找到 FinaSU SUSFS 适配补丁: $DRIFT_PATCH"
[ -d "$KSU_DIR/.git" ] || fail "$KSU_DIR 不是 Git 检出目录"

exclude_args=()
for file in "${DRIFT_FILES[@]}"; do
  exclude_args+=("--exclude=$file")
done

git -C "$KSU_DIR" apply "${exclude_args[@]}" "$UPSTREAM_PATCH" \
  || fail "应用 SUSFS 上游补丁失败"
git -C "$KSU_DIR" apply "$DRIFT_PATCH" \
  || fail "应用 FinaSU SUSFS 结构适配补丁失败"

grep -q 'config KSU_SUSFS' "$KSU_DIR/kernel/Kconfig" \
  || fail "FinaSU Kconfig 未声明 SUSFS 配置"
grep -q 'susfs_init' "$KSU_DIR/kernel/core/init.c" \
  || fail "FinaSU init.c 未接入 SUSFS 初始化"
if grep -qE 'kernelsu-objs \+= hook/(lsm_hook|syscall_event_bridge|syscall_hook_manager|tp_marker)' "$KSU_DIR/kernel/Kbuild"; then
  fail "FinaSU Kbuild 仍启用了与 SUSFS 冲突的 syscall hook 对象"
fi
if find "$KSU_DIR/kernel" -name '*.rej' -print -quit | grep -q .; then
  fail "FinaSU SUSFS 补丁留下 .rej 文件"
fi
echo "FinaSU SUSFS 集成补丁应用并通过结构检查"
