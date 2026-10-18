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

# 必须带 -e：缺了它，--variant/--ref 少给取值时 shift 2 失败却不终止，
# while [ $# -gt 0 ] 因 $# 不变而死循环，CI 上会一直挂到超时。
set -euo pipefail

# 本脚本所在目录：下面要用它判断同仓的 bakasu_compat/resume_susfs.sh 是否存在。
# 必须在 set -u 之下先定义，否则引用未定义变量会直接以 unbound variable 中止，
# 而不是走到我们想要的「没有树内判定脚本就按老逻辑 fail-fast」分支。
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

VARIANT="BakaSU"
REF="main"

while [ $# -gt 0 ]; do
  case "$1" in
    --variant)
      # 双保险：就算 -e 被移除，这里也会显式报错而不是死循环
      [ $# -ge 2 ] || { echo "::error::--variant 缺少取值（用法见 $0 --help）" >&2; exit 2; }
      VARIANT="$2"; shift 2 ;;
    --ref)
      [ $# -ge 2 ] || { echo "::error::--ref 缺少取值（用法见 $0 --help）" >&2; exit 2; }
      REF="$2"; shift 2 ;;
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

if grep -qE '^\s*\$\(error' <<< "$CONTENT"; then
  # 上游在挂起 = 常态（自 48fa4bb 起一直如此）。真正该不该放行，取决于
  # **本树**的 SUSFS 集成形态，只有补丁打完才看得出来；那个判定由
  # build_kernel.sh 的 bakasu_susfs_gate 阶段（调用
  # scripts/bakasu_compat/resume_susfs.sh）在 apply_susfs 之后做。
  #
  # 所以这里不再直接失败——否则这个提前探测会先把构建掐掉，
  # 让真正有依据的判定永远跑不到，等于把「按证据判定」降级成「一律拒绝」。
  # 这里只做情报：告诉调用方上游处于挂起，判定将延后到树内完成。
  if [ -f "$SELF_DIR/bakasu_compat/resume_susfs.sh" ]; then
    echo "::notice::上游 BakaSU 处于 SUSFS 挂起状态（ref=${REF} 含 \$(error)）"
    cat <<'INFO'

  上游自 48fa4bb 起在 kernel/tools/susfs_compat.mk 末尾保留**无条件**
  $(error Please wait susfs update.)，动机是 SUSFS 未同步最新 KernelSU 的
  selinux_hide 模型（可用性/隐蔽性受影响）。

  本仓库不在这里一概拒绝，而是延后到树内按证据判定：
    scripts/bakasu_compat/resume_susfs.sh（移植自 LingLuo17/AnyKernel3 6db3a675）
    在 apply_susfs 之后核对本树是否真的具备新模型：
      <  6.6：hooks.c 有手动钩子 ksu_selinux_hide_running 但缺
              should_check_current → 属旧 SUSFS，仍阻断；
      >= 6.6：selinuxfs.c 缺 security_context_to_sid_with_policy → 仍阻断；
      无法判定 → 一律阻断（fail-closed）。
    判定不通过时构建会在 bakasu_susfs_gate 阶段明确失败（不是等到编
    drivers/kernelsu 才炸），并打印上述规避指引。

  若想立刻绕过判定（不推荐，会带回上游要规避的检测风险）：关闭 SUSFS
  （enable_susfs=false），或把内核对齐到挂起前的提交
  5b76b884c75f729a220bb317aa4a4fc78f0e0e9c。
INFO
    exit 0
  fi

  # 没有树内判定脚本时保持原有 fail-fast：这时提前拦截仍是净收益。
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
