#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# =============================================================================
# 【占位文件 —— 待用完整文件覆盖，在此之前不要在本分支构建】
#
# 2026-10-15 的 beta 迁移中本文件被截断：完整脚本为 4270 行 / 196949 B，
# 实际只有约 9510 B 落入远端，截断点恰在 log_stage() 定义处。该片段语法合法、
# 且不含 main 调用，直接执行会以退出码 0 结束而什么都不做——即"构建成功但没编任何东西"。
# 这里改为显式失败，避免在修复前出现假绿。
#
# 修复（在 D:\optimized-projects\GKI_SUKISU_SUSFS_for_Lokita 执行）：
#   git add scripts/build_kernel.sh scripts/ksu_uapi_sync/align.sh \
#           scripts/bakasu_compat/resume_susfs.sh scripts/check_upstream_susfs.sh \
#           .github/workflows/get-manager.yml FUSION.md
#   git commit -m "beta: 落盘校验与可移植项（含完整 build_kernel.sh）"
#   git push --force-with-lease origin HEAD:refs/heads/beta
# 完整文件以本地工作区 scripts/build_kernel.sh 为准。
# =============================================================================
set -euo pipefail

echo "::error::beta 分支的 scripts/build_kernel.sh 是截断后的占位文件（完整版 4270 行 / 196949 B），拒绝执行；请先按文件头注释用完整文件覆盖。"
exit 1
