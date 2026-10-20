#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# 生成/刷新 KPM 修补工具（patch_linux）的 sha256 锚点。
#
# 背景：build_kernel.sh 默认跟随 SukiSU_patch 上游 main 分支，零版本锚点，
# 上游一旦被改（投毒或误改）无法察觉。本脚本下载当前上游文件、算出 sha256，
# 写入 config/kpm_patch_sha256；此后构建会与本记录比对，不符只打 ::warning:: 并继续
# （要钉死版本须显式传 EXPECTED_KPM_PATCH_SHA256，那时才 fail-closed 中止）。
#
# 用法:
#   ./scripts/tools/pin_kpm_patch.sh              # 写入锚点（默认）
#   ./scripts/tools/pin_kpm_patch.sh --check      # 只比对不写入（CI 巡检用）
#   ./scripts/tools/pin_kpm_patch.sh --clear      # 清除锚点，恢复零锚点运行
#   ./scripts/tools/pin_kpm_patch.sh --url <url>  # 指定其它下载地址
#
# 上游更新 patch_linux 后，重新跑一次本脚本即可刷新锚点。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PIN_FILE="$REPO_ROOT/config/kpm_patch_sha256"
DEFAULT_URL="https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU_patch/refs/heads/main/kpm/patch_linux"
URL="$DEFAULT_URL"
MODE="write"

while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE="check"; shift ;;
    --clear) MODE="clear"; shift ;;
    --url)   URL="${2:?--url 需要参数}"; shift 2 ;;
    -h|--help) sed -n '3,15p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

if [ "$MODE" = "clear" ]; then
  rm -f "$PIN_FILE"
  echo "已清除锚点 $PIN_FILE（恢复零锚点运行，构建时会打印 ::warning::）"
  exit 0
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

echo "下载: $URL"
curl -LSsf "$URL" -o "$tmp"

size=$(stat -c %s "$tmp")
if [ "$size" -lt 1024 ]; then
  echo "::error::下载内容异常（${size} 字节），拒绝生成锚点" >&2
  exit 1
fi
sha=$(sha256sum "$tmp" | awk '{print $1}')
echo "大小: ${size} 字节"
echo "sha256: $sha"

if [ "$MODE" = "check" ]; then
  if [ ! -f "$PIN_FILE" ]; then
    echo "::error::锚点文件不存在（$PIN_FILE），当前为零锚点运行" >&2
    exit 1
  fi
  cur=$(tr -d '[:space:]' < "$PIN_FILE")
  if [ "$cur" = "$sha" ]; then
    echo "✅ 锚点与上游一致"
  else
    # 项目约定：不指定就跟随上游最新。漂移只是信息，不是错误，退出码保持 0。
    echo "::warning::锚点漂移：记录 $cur，上游现为 $sha（构建仍会继续；如需刷新记录请不带 --check 运行本脚本）"
  fi
  exit 0
fi

mkdir -p "$REPO_ROOT/config"
printf '%s\n' "$sha" > "$PIN_FILE"
echo
echo "✅ 已写入 $PIN_FILE"
echo "   此后 build_kernel.sh 会与本记录比对：不一致只告警不中止；要钉死请传 EXPECTED_KPM_PATCH_SHA256。"
echo "   上游更新后重新运行本脚本刷新锚点。"
