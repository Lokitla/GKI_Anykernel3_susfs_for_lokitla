#!/usr/bin/env bash
# 用途：上游 SUSFS 闸门健康检查（fail-fast，避免整轮构建空跑）
#
# 背景：BakaSU 上游会在 kernel/tools/susfs_compat.mk 末尾追加**无条件**的
#       $(error Please wait susfs update.)，主动挂起 SUSFS 构建
#       （2026-10-10 提交 48fa4bb，动机是 SUSFS 未同步最新 KernelSU，
#        selinux_hide 会被大量检测）。该 error 要等到编 drivers/kernelsu
#       时才炸，一次构建白跑 20+ 分钟才失败。
#
# 作用：构建开始前先探测该文件，命中立刻失败并给出可执行的规避指引。
#
# 用法：check_upstream_susfs.sh [--variant BakaSU] [--ref main|<commit>]
#       --ref 应传内核实际要检出的 ref：本仓库未指定对齐提交时默认跟随 main。
#
# 退出码：0=通过或跳过  1=上游已挂起 SUSFS  2=用法错误
#
# 安全：参数来自工作流 env，脚本内不做 eval，所有变量加引号。

set -uo pipefail

VARIANT="BakaSU"
REF="main"

while [ $# -gt 0 ]; do
  case "$1" in
    --variant) VARIANT="${2:-}"; shift 2 ;;
    --ref)     REF="${2:-}";     shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "未知参数: $1（用法见 $0 --help）" >&2; exit 2 ;;
  esac
done

[ -n "$VARIANT" ] || { echo "::error::--variant 不能为空" >&2; exit 2; }
[ -n "$REF" ] || REF="main"

# susfs_compat.mk 是 BakaSU 特有文件，其他变体没有这道闸门
if [ "$VARIANT" != "BakaSU" ]; then
  echo "健康检查跳过：变体 ${VARIANT} 无 susfs_compat.mk 闸门"
  exit 0
fi

URL="https://raw.githubusercontent.com/Baka-SU/BakaSU/${REF}/kernel/tools/susfs_compat.mk"
echo "上游 SUSFS 闸门检查：${URL}"

# 双通道取内容：优先 raw（免鉴权、不限流），失败则回退 gh api（runner 上必然可用）。
# 两条都拿不到时不阻断构建——健康检查是止损手段，不能反过来变成新的故障源。
CONTENT=""
if CONTENT=$(curl -fsSL --max-time 30 "$URL" 2>/dev/null); then
  :
elif command -v gh >/dev/null 2>&1; then
  echo "raw 通道不可用，回退 gh api"
  CONTENT=$(gh api "repos/Baka-SU/BakaSU/contents/kernel/tools/susfs_compat.mk?ref=${REF}" \
    --jq .content 2>/dev/null | base64 -d 2>/dev/null) || CONTENT=""
fi

if [ -z "$CONTENT" ]; then
  echo "::warning::无法读取上游 susfs_compat.mk（网络/限流或 ${REF} 无此文件），跳过健康检查"
  exit 0
fi

if printf '%s\n' "$CONTENT" | grep -qE '^\s*\$\(error'; then
  echo "::error::上游 BakaSU 已主动挂起 SUSFS 构建（ref=${REF} 的 susfs_compat.mk 含 \$(error)）"
  cat <<'GUIDE'

  此时构建必然在 compile_kernel 阶段失败（drivers/kernelsu 加载该 mk 即 Stop）。
  上游动机：SUSFS 未同步最新 KernelSU，selinux_hide 会被检测，故主动停用。
  三选一规避：
    1) 内核对齐到挂起前的提交：kernel-custom.yml 的「内核 KSU 对齐提交」填
       5b76b884c75f729a220bb317aa4a4fc78f0e0e9c（2026-10-09，挂起前最后一个提交；
       本脚本会以该 ref 复检，确认其 susfs_compat.mk 无 error 才放行）。
       留空 = 跟随上游 main，会一直踩雷。
       注意：这会带回上游停用 SUSFS 所要规避的 selinux_hide 检测风险，自行权衡。
    2) 关闭 SUSFS：enable_susfs=false（能编过，但产物不含 SUSFS）。
    3) 等上游解除挂起后重跑：Auto_Trigger_BakaSU 每 3 天检测一次，
       解除后会自动补建（挂起期间它不会回写 sha，不会漏掉这次构建）。
GUIDE
  exit 1
fi

echo "上游 SUSFS 闸门正常（ref=${REF}）"
exit 0
