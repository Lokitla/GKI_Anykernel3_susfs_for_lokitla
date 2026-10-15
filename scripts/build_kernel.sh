#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# =============================================================================
# 【占位文件 —— 待用完整文件覆盖，在此之前不要在本分支构建】
#
# 2026-10-15 的 beta 迁移中本文件被截断：完整脚本 4283 行 / 197808 B，
# 实际只有约 9510 B 落入远端，截断点恰在 log_stage() 定义处。该片段语法合法、
# 且不含 main 调用，直接执行会以退出码 0 结束而什么都不做 —— 即"构建成功但没编任何东西"。
# 这里改为显式失败，避免在修复前出现假绿。
#
# 为什么不用 git switch：本工作区有 6 个文件待提交，且 beta 与本地 main 的
# 文件版本不同，`git switch -c beta origin/beta` 会被未提交修改挡住或产生冲突。
# 下面用底层命令以 origin/beta 为父提交重建提交，完全不碰工作区：
#
#   cd D:\optimized-projects\GKI_SUKISU_SUSFS_for_Lokita
#   git fetch origin beta
#   git read-tree origin/beta      # 只把索引置为 beta 的树，不动工作区
#   git add scripts/build_kernel.sh scripts/ksu_uapi_sync/align.sh \
#           scripts/bakasu_compat/resume_susfs.sh scripts/check_upstream_susfs.sh \
#           .github/workflows/get-manager.yml FUSION.md
#   tree=$(git write-tree)
#   parent=$(git rev-parse origin/beta)
#   commit=$(git commit-tree "$tree" -p "$parent" \
#            -m "beta: 覆盖完整 build_kernel.sh 并补齐复核修复")
#   git push origin "$commit:refs/heads/beta"    # 父提交即 beta 顶端，正常快进，无需 --force
#
# 校验：git cat-file -s origin/beta:scripts/build_kernel.sh 应约为 197808。
# 权威内容为本地工作区 scripts/build_kernel.sh（已含 pipefail/SIGPIPE 与 cd 引号修复）。
#
# 只想验证「5.10.236 + BakaSU + zram + 网络增强 + BBG」能否编过，不必等本文件：
# main 分支的 .github/workflows/kernel-custom.yml 已接受 use_bbg=true，可直接在
# main 上手动 dispatch（kernel_version=5.10 / kernelsu_variant=BakaSU /
# os_patch_level=236 / use_zram=true / use_net_enhance=true / use_bbg=true）。
# 本分支的改动是给这条路径补断言与门禁，不改变四件套本身能否编过。
# =============================================================================
set -euo pipefail

echo "::error::beta 分支的 scripts/build_kernel.sh 是截断后的占位文件（完整版 4283 行 / 197808 B），拒绝执行；请先按文件头注释用完整文件覆盖。"
exit 1
