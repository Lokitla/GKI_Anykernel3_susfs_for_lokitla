#!/usr/bin/env bash
# 用途：解除上游 BakaSU 在 kernel/tools/susfs_compat.mk 末尾追加的**无条件**
#       $(error Please wait susfs update.)，把它换成「按内核版本 + 树内实际形态」
#       的精确门控。不钉上游 commit：上游解除挂起后本脚本自动 no-op。
#
# 来源：移植自 LingLuo17/AnyKernel3 commit 6db3a675
#       （scripts/bakasu_compat/resume_susfs.sh，GPL-3.0）。本仓库按自己的目录
#       布局与「编译前 fail-fast」风格重写，语义一致但更早失败。
#
# 为什么不能照抄「无条件放行」：
#   上游 48fa4bb（"kernel: suspend susfs build"）是有意暂停，动机是 SUSFS 未同步
#   最新 KernelSU 的 selinux_hide 模型，隐藏会被检测。LingLuo17 敢放行，是因为
#   其 scripts/susfs_fixes/apply.sh 里有 FinaSU/BakaSU 新模型适配段；本仓库现已
#   补齐同一段（apply.sh 的 adapt_finasu_selinux_hide_model，把补丁的 fake_state
#   引用改写成 backup_sepolicy + security_*_with_policy）。本脚本仍然只做
#   「把无条件的错误换成有依据的判定」：判定不成立就照旧阻断——宁可挡住，
#   也不产出上游明确暂停的可检测内核。
#
# 判定规则（与上游该文件自己列出的 selinux_hide/SUSFS 符号同源）：
#   <  6.6：hooks.c 无 ksu_selinux_hide_running（走 KernelSU 自动钩子）→ 放行；
#           有手动钩子但缺 should_check_current（旧 SUSFS）→ 阻断；
#   >= 6.6：selinuxfs.c 既无 security_context_to_sid_with_policy 也无
#           backup_sepolicy（本仓库新模型适配后的形态）→ 阻断。
#   无法判定（缺少 hooks.c / 版本未知 / 上游文件形态变了）→ 一律阻断（fail-closed）。
#
# 用法：resume_susfs.sh <KERNEL_ROOT> <KERNEL_VERSION> [KSU_DIR]
#       KERNEL_VERSION 形如 5.10 / 6.12；KSU_DIR 默认 KernelSU。
#       必须在 SUSFS 补丁**打完之后**调用（否则 hooks.c 还没有手动钩子，
#       判定会退化成「无手动钩子 → 放行」，等于无条件放行）。
#
# 退出码：0=放行或无需处理（含上游已解除）  1=上游暂停仍然成立，按门控阻断  2=用法错误
#
# 安全：参数来自工作流 env / 构建脚本，脚本内不做 eval，所有变量加引号。

set -euo pipefail

KERNEL_ROOT="${1:-}"
KERNEL_VERSION="${2:-}"
KSU_DIR="${3:-KernelSU}"

if [ -z "$KERNEL_ROOT" ] || [ -z "$KERNEL_VERSION" ]; then
  echo "::error::用法: resume_susfs.sh <KERNEL_ROOT> <KERNEL_VERSION> [KSU_DIR]" >&2
  exit 2
fi

# KernelSU 在 GKI 布局里与内核源码树（common/）平级，但保留 common/ 下的兜底，
# 免得将来目录调整后这里静默变成「没有 susfs_compat.mk」而一律放行。
COMPAT_MK=""
for cand in "$KERNEL_ROOT/$KSU_DIR/kernel/tools/susfs_compat.mk" \
            "$KERNEL_ROOT/common/$KSU_DIR/kernel/tools/susfs_compat.mk"; do
  if [ -f "$cand" ]; then COMPAT_MK="$cand"; break; fi
done
if [ -z "$COMPAT_MK" ]; then
  COMPAT_MK="$(find "$KERNEL_ROOT" -maxdepth 5 -type f -path "*/kernel/tools/susfs_compat.mk" -print 2>/dev/null | head -n1 || true)"
fi

# 该文件是 BakaSU 独有闸门；其他变体没有它，直接通过。
if [ -z "$COMPAT_MK" ] || [ ! -f "$COMPAT_MK" ]; then
  echo "SUSFS 门控跳过：未找到 kernel/tools/susfs_compat.mk（变体 ${KSU_DIR} 无此闸门）"
  exit 0
fi
echo "上游 SUSFS 门控文件: $COMPAT_MK"

# 上游已解除挂起（或本脚本已跑过）→ no-op。幂等，可重复执行。
if ! grep -qF '$(error Please wait susfs update.)' "$COMPAT_MK"; then
  echo "SUSFS 门控跳过：上游已解除挂起（无 \$(error Please wait susfs update.)）"
  exit 0
fi

# ---- 定位树内证据文件 -------------------------------------------------------
find_in_tree() {
  # $1 = 相对 common/ 的路径（如 security/selinux/hooks.c）
  local rel="$1" c
  for c in "$KERNEL_ROOT/common/$rel" "$KERNEL_ROOT/$rel"; do
    [ -f "$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

HOOKS_C="$(find_in_tree security/selinux/hooks.c || true)"
SELINUXFS_C="$(find_in_tree security/selinux/selinuxfs.c || true)"

# ---- 版本判定（< 6.6 ?） ----------------------------------------------------
kv_major="${KERNEL_VERSION%%.*}"
kv_rest="${KERNEL_VERSION#*.}"
kv_minor="${kv_rest%%.*}"
LT66="unknown"
# 既要「有点号」（否则 ${KERNEL_VERSION#*.} 原样返回、minor 会等于整串），
# 又要两段都是纯数字，否则不做数值比较（历史上这里写错过，会让判定恒为 unknown）。
if [ -n "$kv_major" ] && [ -n "$kv_minor" ] && [ "$kv_rest" != "$KERNEL_VERSION" ]; then
  case "${kv_major}${kv_minor}" in
    *[!0-9]*) LT66="unknown" ;;
    *)
      if [ "$kv_major" -lt 6 ] || { [ "$kv_major" -eq 6 ] && [ "$kv_minor" -lt 6 ]; }; then
        LT66="yes"
      else
        LT66="no"
      fi
      ;;
  esac
fi
echo "SUSFS 门控：KERNEL_VERSION=${KERNEL_VERSION}（< 6.6 = ${LT66}）"

BLOCK_REASON=""

if [ "$LT66" = "unknown" ]; then
  BLOCK_REASON="无法从 KERNEL_VERSION='${KERNEL_VERSION}' 判定内核大版本，无法证明树内已具备新模型"
elif [ -z "$HOOKS_C" ]; then
  BLOCK_REASON="未找到 security/selinux/hooks.c（已试 ${KERNEL_ROOT}/common 与 ${KERNEL_ROOT}），无法证明 SUSFS 的 selinux_hide 形态"
elif [ "$LT66" = "yes" ]; then
  if grep -q "ksu_selinux_hide_running" "$HOOKS_C"; then
    # 有手动钩子：必须同时具备侧信道修复 should_check_current，否则是旧 SUSFS。
    if [ "$(grep -c -e "should_check_current" -e "backup_sepolicy" "$HOOKS_C" || true)" = "0" ]; then
      BLOCK_REASON="hooks.c 含手动钩子 ksu_selinux_hide_running 但既无 should_check_current 也无 backup_sepolicy，属上游点名要更新的旧 SUSFS（隐藏可被检测）"
    else
      echo "SUSFS 门控证据成立：hooks.c 具备 should_check_current / backup_sepolicy（新模型）"
    fi
  else
    echo "SUSFS 门控证据成立：hooks.c 无手动钩子，走 KernelSU 自动钩子"
  fi
else
  if [ -z "$SELINUXFS_C" ]; then
    BLOCK_REASON="未找到 security/selinux/selinuxfs.c，无法证明 >=6.6 的 _with_policy 模型"
  elif [ "$(grep -c -e "security_context_to_sid_with_policy" -e "backup_sepolicy" "$SELINUXFS_C" || true)" = "0" ]; then
    BLOCK_REASON="selinuxfs.c 既无 security_context_to_sid_with_policy 也无 backup_sepolicy，>=6.6 上 SUSFS 会运行时 panic"
  else
    echo "SUSFS 门控证据成立：selinuxfs.c 具备 _with_policy / backup_sepolicy 新模型"
  fi
fi

if [ -n "$BLOCK_REASON" ]; then
  echo "::error::上游 BakaSU 的 SUSFS 构建暂停在本树内**依然成立**：${BLOCK_REASON}"
  cat <<'GUIDE'
  （上游 48fa4bb 以无条件 $(error Please wait susfs update.) 暂停全部 SUSFS 构建，
   等待 simonpunk 同步最新 KernelSU 的 selinux_hide 模型；本脚本只把「无条件的
   暂停」换成「有依据的判定」，判定不通过时照旧阻断，绝不静默放行。）

  规避方式：
    1) 关闭 SUSFS：enable_susfs=false（能编过，但产物不含 SUSFS）；
    2) 等上游解除暂停：Auto_Trigger_BakaSU 每 3 天检测一次，解除后自动补建；
    3) 检查适配段是否真的生效：apply.sh 的 adapt_finasu_selinux_hide_model 需要
       KernelSU/kernel/feature/selinux_hide.c 已切到 backup_sepolicy 新模型；若该文件
       仍是假的（缺文件 / 仍含 fake_state），适配段会跳过，此时本门控照旧阻断。
GUIDE
  exit 1
fi

# ---- 判定通过：把无条件的 $(error) 换成同一套门控 ---------------------------
# 让编译期看到的 susfs_compat.mk 与这里的判定一致；否则编译到 drivers/kernelsu
# 时仍会被上游那句 $(error) 炸掉，白白多跑 20 分钟。
GATE='# susfs build gate (replaces the unconditional upstream suspension 48fa4bb)
# Ported from LingLuo17/AnyKernel3 6db3a675, adapted to this repo. The tree is
# checked against the same markers upstream named before the pause:
#   <  6.6: manual hook (ksu_selinux_hide_running) without should_check_current
#           means a stale (detectable) susfs: require an update;
#   >= 6.6: susfs without security_context_to_sid_with_policy / backup_sepolicy
#           would panic at runtime: require an update.
KSU_COMPAT_KVER_LT66 := $(shell awk '"'"'$$1=="VERSION" { v = $$3 } $$1=="PATCHLEVEL" { p = $$3 } END { if (v < 6 || (v == 6 && p < 6)) print "yes" }'"'"' $(srctree)/Makefile)

ifeq ($(KSU_COMPAT_KVER_LT66),yes)
ifneq ($(shell grep -q "ksu_selinux_hide_running" $(srctree)/security/selinux/hooks.c; echo $$?),0)
# no manual hook: KernelSU falls back to its own auto hook, safe to build
else ifeq ($(shell grep -c -e "should_check_current" -e "backup_sepolicy" $(srctree)/security/selinux/hooks.c),0)
$(info -- $(REPO_NAME): susfs selinux_hide lacks the should_check_current side-channel fix)
$(info -- $(REPO_NAME): Please wait simonpunk update)
$(error Please wait susfs update.)
endif
else
ifeq ($(shell grep -c -e "security_context_to_sid_with_policy" -e "backup_sepolicy" $(srctree)/security/selinux/selinuxfs.c),0)
$(info -- $(REPO_NAME): susfs lacks the security_context_to_sid_with_policy model)
$(info -- $(REPO_NAME): Please wait simonpunk update)
$(error Please wait susfs update.)
endif
endif'

# ---- 判定通过：改写 susfs_compat.mk，把无条件 $(error) 换成同一套门控 --------
# 删之前先确认上游三行**确实在**，删之后还要确认「必须保留的内容」没被连带删掉。
# 原因：一旦读取/写入失败却继续往下走，会写出一个只剩 gate 的空壳 mk，
# 反而把 -DKSU_COMPAT_HAS_SUSFS_FEATURE_SELINUX_HIDE 这条共存适配删掉
# ——那会让 BakaSU 的 ksu_patch_text 与 SUSFS 的替换互相踩踏，SELinux 隐藏失效，
# 且只在真机上暴露。宁可原样不动并明确报错。
UPSTREAM_BLOCK_OK=1
for _l in '$(info -- $(REPO_NAME): susfs has NOT update with latest KernelSU source)' \
          '$(info -- $(REPO_NAME): Please wait simonpunk update)' \
          '$(error Please wait susfs update.)'; do
  if ! grep -qxF "$_l" "$COMPAT_MK"; then
    UPSTREAM_BLOCK_OK=0
    echo "::error::susfs_compat.mk 缺少上游暂停行：${_l}"
  fi
done
if [ "$UPSTREAM_BLOCK_OK" != "1" ]; then
  echo "::error::susfs_compat.mk 与上游暂停提交 (48fa4bb) 形态不一致，保持原文件不动"
  exit 1
fi

# 保留内容基线：这两条 ccflags 是 BakaSU 与 SUSFS 的共存适配，改写后必须仍在。
KEEP_BEFORE="$(grep -c '^ccflags-y += -DKSU_COMPAT_' "$COMPAT_MK" || true)"
if [ "$KEEP_BEFORE" -lt 1 ]; then
  echo "::error::susfs_compat.mk 未含任何 KSU_COMPAT ccflags 适配行，形态异常，保持原文件不动"
  exit 1
fi

TMP_MK="$(mktemp)"
awk '
  $0 == "$(info -- $(REPO_NAME): susfs has NOT update with latest KernelSU source)" { next }
  $0 == "$(info -- $(REPO_NAME): Please wait simonpunk update)" { next }
  $0 == "$(error Please wait susfs update.)" { next }
  { print }
' "$COMPAT_MK" > "$TMP_MK"

if [ ! -s "$TMP_MK" ]; then
  rm -f "$TMP_MK"
  echo "::error::改写 susfs_compat.mk 结果为空，已放弃（原文件未改动）"
  exit 1
fi

KEEP_AFTER="$(grep -c '^ccflags-y += -DKSU_COMPAT_' "$TMP_MK" || true)"
if [ "$KEEP_AFTER" != "$KEEP_BEFORE" ]; then
  rm -f "$TMP_MK"
  echo "::error::改写后 KSU_COMPAT ccflags 适配行由 ${KEEP_BEFORE} 条变为 ${KEEP_AFTER} 条，已放弃（原文件未改动）"
  exit 1
fi

# 兜底：若上游改用 CRLF 或不完全等于上面三行，awk 精确匹配不会命中，
# 这里就会发现残留的 $(error)，中止并保留原文件（fail-closed，不静默半删）。
if grep -qE '(^|[^A-Za-z])\$\(error' "$TMP_MK"; then
  rm -f "$TMP_MK"
  echo "::error::susfs_compat.mk 仍含未识别的 \$(error)（可能上游改了措辞或用了 CRLF），已放弃（原文件未改动）"
  exit 1
fi

printf '%s\n' "$GATE" >> "$TMP_MK"
mv "$TMP_MK" "$COMPAT_MK"
echo "SUSFS 门控已改写：把上游无条件暂停替换为按内核版本的门控（${KERNEL_VERSION}）"
exit 0
