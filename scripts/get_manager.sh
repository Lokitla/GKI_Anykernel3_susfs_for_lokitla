#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# 管理器与管理器工件下载逻辑（由 .github/workflows/get-manager.yml 调用）。
#
# 说明：本文件是从 get-manager.yml 的内联 `run:` 脚本原样抽出的，目的是绕开
#       GitHub Actions 对 `${{ }}` 表达式长度的限制（见上游 commit 0b25bd1
#       「keep manager workflow expressions within limit」）。逻辑本身由本仓库维护，
#       不来自第三方；管理器 APK 的来源见 NOTICE 中的对应变体条目。
set -euo pipefail

# 本脚本由 CI 直接执行，失败必须让 step 变红，不能带着半个 manager-artifacts 继续；
# 因此这里打开严格模式。为兼容 set -u，先把工作流传入的变量全部显式初始化。
: "${KSU_VARIANT:=}"
: "${KSU_VERSION:=}"
: "${MANAGER_SPOOFED:=}"
: "${SUKISU_COMMIT:=}"
: "${FINASU_RELEASE_COMMIT:=}"
: "${GH_TOKEN:=}"
: "${GITHUB_ENV:=}"
: "${GITHUB_OUTPUT:=}"
: "${GITHUB_WORKSPACE:=}"
: "${LEGACY_RELEASE_TAG:=}"
: "${LEGACY_DIR:=}"
: "${MANAGER_URL:=}"
: "${REPO:=}"
: "${KSUM:=}"

case "$KSU_VARIANT" in
  "SukiSU(40726)") LEGACY_RELEASE_TAG="v2.1.0-r2"; LEGACY_DIR="SukiSU_40726" ;;
  "SukiSU(40548)") LEGACY_RELEASE_TAG="v2.0.0-r34"; LEGACY_DIR="SukiSU_40548" ;;
  *) LEGACY_RELEASE_TAG="" ;;
esac
if [ -n "$LEGACY_RELEASE_TAG" ]; then
  echo "下载 $KSU_VARIANT 管理器..."
  mkdir -p "manager-artifacts/$LEGACY_DIR"
  MANAGER_URL=$(curl -fsSL "https://api.github.com/repos/zzh20188/GKI_KernelSU_SUSFS/releases/tags/$LEGACY_RELEASE_TAG" |
    jq -r '.assets[] | select(.name | startswith("SukiSU_") and endswith("-release.apk")) | .browser_download_url' |
    head -n 1)
  if [ -z "$MANAGER_URL" ]; then
    echo "未找到 $KSU_VARIANT 管理器下载地址。"
    exit 1
  fi
  curl -fL -o "manager-artifacts/$LEGACY_DIR/${LEGACY_DIR}-release.apk" "$MANAGER_URL" || {
    echo "::error::下载 $KSU_VARIANT 管理器失败：$MANAGER_URL"; exit 1;
  }
  [ -s "manager-artifacts/$LEGACY_DIR/${LEGACY_DIR}-release.apk" ] || {
    echo "::error::$KSU_VARIANT 管理器下载后为空文件"; exit 1;
  }
  exit 0
fi

if [ "$KSU_VARIANT" = "FinaSU" ]; then
  REL_TAG=$(curl -fsSL --retry 3 --retry-all-errors --max-time 60 \
    https://api.github.com/repos/LyraVoid/FinaSU/releases/latest \
    | jq -er '.tag_name | strings | select(length > 0)')
  REL_JSON=$(curl -fsSL --retry 3 --retry-all-errors --max-time 60 \
    "https://api.github.com/repos/LyraVoid/FinaSU/releases/tags/$REL_TAG")
  REL_APK_URL=$(jq -r '[.assets[] | select(.name | endswith("-release.apk"))][0].browser_download_url // empty' <<< "$REL_JSON")
  if [ -z "$REL_APK_URL" ]; then
    echo "::error::FinaSU Release $REL_TAG 中没有正式签名的 release APK"
    exit 1
  fi
  if [ "$(curl -fsSL --retry 3 --retry-all-errors --max-time 60 \
    "https://api.github.com/repos/LyraVoid/FinaSU/commits/$REL_TAG" \
    | jq -er '.sha')" != "$FINASU_RELEASE_COMMIT" ]; then
    echo "::error::FinaSU 最新 Release 在本次流程中发生变化，请重新触发以保持内核和 APK 对齐"
    exit 1
  fi
  mkdir -p manager-artifacts
  REL_APK="manager-artifacts/$(basename "$REL_APK_URL")"
  curl -fL --retry 3 --retry-all-errors --connect-timeout 20 --max-time 300 \
    -o "$REL_APK" "$REL_APK_URL" || {
    echo "::error::下载 FinaSU 管理器失败：$REL_APK_URL"; exit 1;
  }
  unzip -tq "$REL_APK" >/dev/null 2>&1 || {
    echo "::error::FinaSU 下载文件不是有效 APK/ZIP"; exit 1;
  }
  CERT_INFO=$(python3 "$GITHUB_WORKSPACE/scripts/finasu_compat/extract_manager_cert.py" "$REL_APK") || {
    echo "::error::无法从 FinaSU Release APK 提取签名证书"; exit 1;
  }
  CERT_SIZE=$(awk 'NR == 1 {print $1}' <<< "$CERT_INFO")
  CERT_HASH=$(awk 'NR == 1 {print $2}' <<< "$CERT_INFO")
  [[ "$CERT_SIZE" =~ ^0x[0-9a-fA-F]{1,4}$ && "$CERT_HASH" =~ ^[0-9a-fA-F]{64}$ ]] || {
    echo "::error::FinaSU APK 签名证书格式校验失败"; exit 1;
  }
  MANAGER_VERSION=$(basename "$REL_APK" | grep -oE '[0-9]{4,}' | head -n 1 || true)
  if ! [[ "$MANAGER_VERSION" =~ ^[0-9]+$ ]]; then
    MANAGER_VERSION="$KSU_VERSION"
  fi
  [ "$MANAGER_VERSION" = "$KSU_VERSION" ] || {
    echo "::error::FinaSU APK 版本 $MANAGER_VERSION 与内核预期 $KSU_VERSION 不一致"; exit 1;
  }
  echo "MANAGER_VERSION=$MANAGER_VERSION" >> "$GITHUB_ENV"
  echo "MANAGER_SHA=$FINASU_RELEASE_COMMIT" >> "$GITHUB_ENV"
  echo "MANAGER_MATCHED=1" >> "$GITHUB_ENV"
  echo "managerVer=$MANAGER_VERSION" >> "$GITHUB_OUTPUT"
  echo "managerCertSize=$CERT_SIZE" >> "$GITHUB_OUTPUT"
  echo "managerCertHash=$CERT_HASH" >> "$GITHUB_OUTPUT"
  echo "FinaSU $REL_TAG APK 已下载；版本、提交与签名证书校验通过"
  exit 0
fi

if [ "$KSU_VARIANT" == "Next" ]; then
  echo "KernelSU Next..."
  REPO="KernelSU-Next/KernelSU-Next"
  KSUM="manager"
  BRANCH="dev"
elif [ "$KSU_VARIANT" == "SukiSU" ]; then
  echo "SukiSU..."
  REPO="SukiSU-Ultra/SukiSU-Ultra"
  KSUM="manager"
elif [ "$KSU_VARIANT" == "BakaSU" ]; then
  echo "BakaSU..."
  REPO="Baka-SU/BakaSU"
  KSUM="manager"
elif [ "$KSU_VARIANT" == "Official" ]; then
  echo "KSU..."
  REPO="tiann/KernelSU"
  KSUM="manager"
fi

FILENAME=$([[ "$KSU_VARIANT" == "Next" ]] && echo "build-manager-ci.yml" || echo "build-manager.yml")


# 按内核 KSU 版本选择 Manager，避免 APK 版本领先于内核版本
TARGET_KSU_VERSION="${KSU_VERSION:-}"
if ! [[ "$TARGET_KSU_VERSION" =~ ^[0-9]+$ ]]; then
  echo "无效的目标 KSU 版本: $TARGET_KSU_VERSION"
  exit 1
fi

calculate_run_ksu_version() {
  local head_sha="$1"
  local git_version=""

  # 【口径必须与内核侧一致】build_kernel.sh 的 resolve_sukisu_version 是按
  # GitHub API（commits?sha=main 的 Link rel=last）取提交数的，管理器这边
  # 候选 run 的版本也必须走同一条路。
  #
  # KernelSU 是 fetch-depth:1 的浅克隆，不能用 git rev-list --count，
  # rev-list 的结果取决于本地抓取深度，同一个 commit 两次运行能数出不同值
  # —— 于是同一份脚本，一次严格命中 40922，一次退到 40879，稳定性为零。
  # API 口径既稳定又与内核侧对齐；本地 git 仅作 API 拿不到时的兜底。
  # 没有 Link 头（单页结果）是正常情况，必须回退到本地 git 计数而不是
  # 被 set -e / pipefail 当成失败中断；末尾 `|| true` 保持原语义。
  git_version=$(curl -sI -H "Authorization: token $GH_TOKEN" \
      "https://api.github.com/repos/$REPO/commits?sha=$head_sha&per_page=1" 2>/dev/null |
      grep -i "^link:" | sed -n 's/.*page=\([0-9]*\)>; rel="last".*/\1/p') || true

  if [ -z "$git_version" ]; then
    if ! git -C KernelSU cat-file -e "$head_sha^{commit}" 2>/dev/null; then
      git -C KernelSU fetch --no-tags origin "$head_sha" >/dev/null 2>&1 || true
    fi
    if ! git -C KernelSU cat-file -e "$head_sha^{commit}" 2>/dev/null; then
      return 1
    fi
    # Manager CI 只跑在 main 上，必须按 main 的计数口径算。
    # 若该 commit 属于 builtin（独立分支，提交数仅 802），直接计数会得到
    # 远低于实际的版本号，从而把"候选管理器版本"误判为低于内核版本，
    # 最终选中一个过旧的 APK。
    if [ "$KSU_VARIANT" = "SukiSU" ] && \
       git -C KernelSU cat-file -e refs/remotes/origin/builtin^{commit} 2>/dev/null && \
       git -C KernelSU merge-base --is-ancestor "$head_sha" refs/remotes/origin/builtin 2>/dev/null; then
      git_version=$(git -C KernelSU rev-list --count refs/remotes/origin/main)
    else
      git_version=$(git -C KernelSU rev-list --count "$head_sha")
    fi
  fi

  if [ "$KSU_VARIANT" = "SukiSU" ] && ! [ "$git_version" -gt 802 ] 2>/dev/null; then
    echo "::warning::$head_sha 的提交数 $git_version 低于 builtin 规模，疑似计数基准错误，跳过该构建" >&2
    return 1
  fi

  case "$KSU_VARIANT" in
    "SukiSU") echo $((40000 + git_version - 2815)) ;;
    "BakaSU") echo $((30700 + git_version)) ;;
    "Official") echo $((20000 + git_version)) ;;
    "Next") echo $((30000 + git_version)) ;;
    *) return 1 ;;
  esac
}

# Spoofed（伪装官方 KernelSU 包名）管理器开关
#   开启：一并拉取 Spoofed-Manager（伪装官方包名的管理器）
#   关闭：过滤掉所有名字含 spoofed 的产物，只保留普通管理器
WANT_SPOOFED="$MANAGER_SPOOFED"
case "$WANT_SPOOFED" in
  true|TRUE|True|1) JQ_SPOOFED=true ;;
  *) JQ_SPOOFED=false ;;
esac
echo "拉取 Spoofed 管理器: $JQ_SPOOFED"

get_manager_artifacts() {
  local artifacts="$1"
  if [ "$KSU_VARIANT" == "Next" ]; then
    printf '%s' "$artifacts" | jq -r --arg name "$KSUM" --argjson sp "$JQ_SPOOFED" \
      '.artifacts[] | select(.name == $name) | select($sp or ((.name | ascii_downcase) | contains("spoofed") | not)) | "\(.name)\t\(.archive_download_url)"'
  elif [ "$KSU_VARIANT" == "BakaSU" ]; then
    printf '%s' "$artifacts" | jq -r --argjson sp "$JQ_SPOOFED" \
      '.artifacts[] | select(.name == "Manager-release" or ($sp and .name == "Spoofed-Manager-release")) | "\(.name)\t\(.archive_download_url)"'
  else
    # 排除 -gradle / -mappings 中间产物：它们与最终 APK 同名同尺寸，
    # 一并下载会让最终产物里混入未签名的中间 APK（每个变体多出一个）。
    printf '%s' "$artifacts" | jq -r --arg needle "$KSUM" --argjson sp "$JQ_SPOOFED" \
      '.artifacts[]
       | select((.name | ascii_downcase) | contains($needle))
       | select((.name | ascii_downcase) | (endswith("gradle") or endswith("mappings")) | not)
       | select($sp or ((.name | ascii_downcase) | contains("spoofed") | not))
       | "\(.name)\t\(.archive_download_url)"'
  fi
}

# ═══════════════════════════════════════════════════════════
# 从 APK 文件名提取实际 versionCode
# 文件名格式：BakaSU_v4.2.0-rc2_35163-arm64-v8a-release.apk
#          KernelSU_v40924_20260929_arm64.apk
# 取第一段 >=4 位数字（与「校验管理器 APK 版本」步骤同一口径）：
#   BakaSU_v4.2.0-rc2_35163-... → 35163
#   KernelSU_v40924_20260929_... → 40924（不会误取日期 20260929）
# ═══════════════════════════════════════════════════════════
extract_apk_version() {
  local apk_name="$1"
  echo "$apk_name" | grep -oE '[0-9]{4,}' | head -n 1
}

DOWNLOAD_LIST=""
BEST_VERSION=0
BEST_BUILD_ID=""
BEST_BRANCH=""
# 实际版本验证（cf784f5）：下载后从 APK 文件名提取实际版本
BEST_ACTUAL=0        # 实际版本最大值
BEST_DIR=""          # 最佳候选目录
MATCHED=0            # 是否精确匹配
MAX_FETCH=6          # 限制下载数量，避免浪费带宽
FETCHED=0            # 已下载数量
BEST_SHA=""          # 最佳候选 run 的 head_sha（内核对齐用）
# 严格对齐用：精确等于内核 KSU 版本的候选
EXACT_LIST=""
EXACT_ID=""
EXACT_BRANCH=""
EXACT_VERSION=0
EXACT_SHA=""
# 分支过滤（重要）：早期这里不加过滤，因为上游 Manager CI 一度只跑在
# 发布分支上（见下方 calculate_run_ksu_version 的说明）。但上游现在会在
# 各类功能/修复分支上触发 build-manager.yml —— 实测 SukiSU-Ultra 最近 30
# 次成功构建里 16 次来自 cpu_spoof / mount_hide / fix/* / chore/* 等分支。
# 这些 APK 携带分支特性，版本串或应用名里会出现 PR / 分支标记，
# 导致管理器版本与内核对不上。正式产物必须只在发布分支上找。
case "$KSU_VARIANT" in
  "Next") RELEASE_BRANCH="dev" ;;
  *)      RELEASE_BRANCH="main" ;;
esac
# 不要在 URL 上依赖 branch= 过滤！实测 GitHub 的 branch= 会把 main 分支上
# 真正最新的那条成功构建滤掉：
#   不带过滤  → 能查到 34761911123（head=7755cdb36f63，即 main HEAD，KSU 40922）
#   带 branch=main → 只剩 31890547561（08-15 的旧产物，KSU 40879）
# 结果是内核按 main 提交数算出 40922，管理器却降到 40879，差 43；而产物名
# 又恒定取目标值，看起来像 40922，实际 APK 是旧的 —— 这正是"管理器与内核
# 版本对不上"且时好时坏的根因。
# 改为全量拉取，在下方循环里按 head_branch 自行过滤，两边效果一致且可靠。
RUNS_URL="https://api.github.com/repos/$REPO/actions/workflows/$FILENAME/runs?status=success&per_page=100"
echo "Manager 查找范围: $REPO/$FILENAME @ $RELEASE_BRANCH（全量拉取后按 head_branch 过滤）"

# 指定了 SukiSU 提交时，直接定位该提交触发的 Manager 构建：
# Manager CI 的 head_sha 就是 SukiSU 的提交，因此可精确命中，
# 保证管理器与内核完全来自同一个 commit。
if [ -n "$SUKISU_COMMIT" ] && [ "$KSU_VARIANT" = "SukiSU" ]; then
  echo "按指定提交 $SUKISU_COMMIT 精确查找 Manager 构建..."
  PINNED_RUNS=$(curl -s -H "Authorization: token $GH_TOKEN" \
    "https://api.github.com/repos/$REPO/actions/workflows/$FILENAME/runs?head_sha=$SUKISU_COMMIT&status=success&per_page=5")
  PINNED_ID=$(printf '%s' "$PINNED_RUNS" | jq -r '.workflow_runs[0].id // empty')
  if [ -n "$PINNED_ID" ]; then
    # 过滤 pull_request 事件：fork 的 main 分支发起 PR 时 head_branch 也是 main，
    # 但 head_sha 指向的是 fork 的提交，不是上游的发布构建。
    PINNED_EVENT=$(printf '%s' "$PINNED_RUNS" | jq -r '.workflow_runs[0].event // "push"')
    PINNED_BRANCH=$(printf '%s' "$PINNED_RUNS" | jq -r '.workflow_runs[0].head_branch // "main"')
    if [ "$PINNED_EVENT" = "pull_request" ]; then
      echo "::warning::提交 $SUKISU_COMMIT 的构建 $PINNED_ID 来自 pull_request（$PINNED_BRANCH），跳过（仅接受 push/workflow_dispatch）"
      PINNED_ID=""
    fi
  fi
  if [ -n "$PINNED_ID" ]; then
    ARTIFACTS=$(curl -s -H "Authorization: token $GH_TOKEN" \
      "https://api.github.com/repos/$REPO/actions/runs/$PINNED_ID/artifacts")
    CANDIDATE_LIST=$(get_manager_artifacts "$ARTIFACTS")
    if [ -n "$CANDIDATE_LIST" ]; then
      DOWNLOAD_LIST="$CANDIDATE_LIST"
      BEST_BUILD_ID="$PINNED_ID"
      BEST_BRANCH="pinned"
      BEST_SHA="$SUKISU_COMMIT"
      echo "命中指定提交的 Manager 构建: $PINNED_ID"
    else
      echo "::warning::提交 $SUKISU_COMMIT 的构建 $PINNED_ID 中没有匹配的 Manager 产物，回退按版本查找"
    fi
  else
    echo "::warning::提交 $SUKISU_COMMIT 没有成功的 Manager 构建（或来自 PR），回退按版本查找（将取不高于该版本的最新产物）"
  fi
fi

if [ -z "$DOWNLOAD_LIST" ]; then
echo "开始查找不高于 KSU $TARGET_KSU_VERSION 的 Manager 产物..."
# 每个候选现在要打一次 API 取版号，翻页上限从 10 收到 3：
# 严格命中通常就落在第 1 页（最新的那批构建），扫不到才说明真没有。
for PAGE in $(seq 1 3); do
  echo "--------------------------------------------------"
  echo "正在检查第 ${PAGE} 页历史构建..."
  RUNS=$(curl -s -H "Authorization: token $GH_TOKEN" "$RUNS_URL&page=$PAGE")
  RUN_COUNT=$(printf '%s' "$RUNS" | jq '.workflow_runs | length')
  if [ "$RUN_COUNT" -eq 0 ]; then
    break
  fi

  for INDEX in $(seq 0 $((RUN_COUNT - 1))); do
    BUILD_ID=$(printf '%s' "$RUNS" | jq -r ".workflow_runs[$INDEX].id")
    HEAD_SHA=$(printf '%s' "$RUNS" | jq -r ".workflow_runs[$INDEX].head_sha")
    HEAD_BRANCH=$(printf '%s' "$RUNS" | jq -r ".workflow_runs[$INDEX].head_branch")
    EVENT_NAME=$(printf '%s' "$RUNS" | jq -r ".workflow_runs[$INDEX].event")

    # 发布分支过滤在这里自己做，而不是交给 API 的 branch= 参数（见上方说明）。
    # 必须同时排除 pull_request 事件：fork 的 main 分支发起 PR 时 head_branch 也是 main，
    # 但产物是 PR 构建（未合入 main），不能当发布版本用。
    if [ "$HEAD_BRANCH" != "$RELEASE_BRANCH" ] || [ "$EVENT_NAME" = "pull_request" ]; then
      continue
    fi

    RUN_KSU_VERSION=$(calculate_run_ksu_version "$HEAD_SHA" || true)
    if ! [[ "$RUN_KSU_VERSION" =~ ^[0-9]+$ ]]; then
      echo "跳过构建 $BUILD_ID: 无法根据提交 $HEAD_SHA 计算 KSU 版本"
      continue
    fi
    if [ "$RUN_KSU_VERSION" -gt "$TARGET_KSU_VERSION" ]; then
      echo "跳过构建 $BUILD_ID ($HEAD_BRANCH): Manager KSU $RUN_KSU_VERSION 高于内核 KSU $TARGET_KSU_VERSION"
      continue
    fi

    ARTIFACTS=$(curl -s -H "Authorization: token $GH_TOKEN" \
      "https://api.github.com/repos/$REPO/actions/runs/$BUILD_ID/artifacts")
    CANDIDATE_LIST=$(get_manager_artifacts "$ARTIFACTS")
    if [ -z "$CANDIDATE_LIST" ]; then
      echo "跳过构建 $BUILD_ID ($HEAD_BRANCH): 未找到包含 '$KSUM' 的产物"
      continue
    fi

    # 严格对齐优先：版本号必须精确等于内核的 KSU 版本。
    # 命中即收手，不再往下扫更旧的候选。
    if [ "$RUN_KSU_VERSION" -eq "$TARGET_KSU_VERSION" ]; then
      EXACT_LIST="$CANDIDATE_LIST"
      EXACT_ID="$BUILD_ID"
      EXACT_BRANCH="$HEAD_BRANCH"
      EXACT_VERSION="$RUN_KSU_VERSION"
      EXACT_SHA="$HEAD_SHA"
      echo "候选 Manager(严格命中): 构建 $BUILD_ID ($HEAD_BRANCH), KSU $RUN_KSU_VERSION"
      break 2
    fi

    # 未精确命中：先记下「不高于内核的最大值」备用，最终是否采用由下方裁决
    if [ -z "$DOWNLOAD_LIST" ] || [ "$RUN_KSU_VERSION" -gt "$BEST_VERSION" ]; then
      DOWNLOAD_LIST="$CANDIDATE_LIST"
      BEST_VERSION="$RUN_KSU_VERSION"
      BEST_BUILD_ID="$BUILD_ID"
      BEST_BRANCH="$HEAD_BRANCH"
      BEST_SHA="$HEAD_SHA"
      echo "候选 Manager(备选): 构建 $BUILD_ID ($HEAD_BRANCH), KSU $RUN_KSU_VERSION"
    fi
  done
done
fi

# ---------- 严格对齐裁决 ----------
# 过去的写法是「取不高于内核版本的最大值」，找不到相等就悄悄用一个
# 更旧的 APK —— 这正是「内核 40924 / 管理器被挑成 40922」这类错配的来源。
# 现在：有精确匹配就只用它；没有则明确告警，把落后幅度摆到台面上。
if [ -n "$EXACT_LIST" ]; then
  DOWNLOAD_LIST="$EXACT_LIST"
  BEST_BUILD_ID="$EXACT_ID"
  BEST_BRANCH="$EXACT_BRANCH"
  BEST_VERSION="$EXACT_VERSION"
  BEST_SHA="$EXACT_SHA"
  echo "✓ 管理器与内核严格对齐: KSU $TARGET_KSU_VERSION（构建 $BEST_BUILD_ID @ $BEST_BRANCH）"
elif [ -n "$DOWNLOAD_LIST" ]; then
  LAG=$((TARGET_KSU_VERSION - BEST_VERSION))
  echo "::warning::未找到与内核 KSU $TARGET_KSU_VERSION 严格匹配的 Manager 构建，回退使用 $BEST_VERSION（构建 $BEST_BUILD_ID @ $BEST_BRANCH），版本落后 $LAG。管理器与内核版本不一致，刷入后可能提示版本不匹配。若经常发生，可在构建入口的「管理器提交 hash」里锁定同一个提交。"
fi

if [ -z "$DOWNLOAD_LIST" ]; then
  echo "未获取到 KSU 版本小于等于 $TARGET_KSU_VERSION 的 Manager artifact 下载地址列表。"
  exit 1
fi
echo "选择 Manager 构建 $BEST_BUILD_ID ($BEST_BRANCH), KSU $BEST_VERSION"

# 产物名要写【实际下载到的 APK 版本】而不是内核目标版本。回退发生时两者
# 不同，标成目标值会让人误以为拿到的就是严格匹配的那个 APK——这也是之前
# 明明差了 43 个版本、产物名却一直是 (40922) 的原因。
# cf784f5: 改为下载后验证实际版本，避免估算版本与实际版本不一致。
# 注意：用 printf %b 写入临时文件，保留 tab 和换行
echo "开始下载并验证 Manager APK 实际版本..."

# 创建临时候选目录
CANDIDATE_BASE="/tmp/manager_candidates_$$"
mkdir -p "$CANDIDATE_BASE"

# 将下载列表写入临时文件（用 printf %b 保留 tab 和换行）
DOWNLOAD_LIST_FILE="/tmp/download_list_$$.txt"
printf '%b' "$DOWNLOAD_LIST" > "$DOWNLOAD_LIST_FILE"

FETCHED=0
MATCHED=0
BEST_ACTUAL=0
BEST_DIR=""

# 下载并验证每个候选 APK
while IFS= read -r LINE; do
  # 跳过空行
  [ -z "$LINE" ] && continue
  
  # 用 awk 解析 tab 分隔的 NAME 和 URL
  NAME=$(echo "$LINE" | awk -F'\t' '{print $1}')
  URL=$(echo "$LINE" | awk -F'\t' '{print $2}')
  
  # 跳过无效行
  [ -z "$NAME" ] && continue
  [ -z "$URL" ] && continue
  
  # 限制下载数量
  FETCHED=$((FETCHED + 1))
  if [ "$FETCHED" -gt "$MAX_FETCH" ]; then
    echo "已达下载上限 $MAX_FETCH，停止扫描"
    break
  fi
  
  SAFE_NAME=$(echo "$NAME" | tr '/ ' '__')
  ZIP_NAME="$KSU_VARIANT-${SAFE_NAME}($KSU_VERSION).zip"
  
  # 下载 APK 到临时目录
  CANDIDATE_DIR="$CANDIDATE_BASE/$FETCHED"
  mkdir -p "$CANDIDATE_DIR"
  APK_PATH="$CANDIDATE_DIR/$NAME"
  
  echo "下载候选 $FETCHED: $NAME"
  # 单个候选下载失败是「跳过该候选」的既定路径（原实现靠后面 unzip 失败兜底），
  # 这里显式跳过，避免 set -e 把一次网络抖动升级成整步失败。
  if ! curl -L -H "Authorization: token $GH_TOKEN" -o "$APK_PATH" "$URL"; then
    echo "⚠️  下载失败，跳过：$NAME"
    rm -rf "$CANDIDATE_DIR"
    continue
  fi
  
  # artifact 是 zip 压缩包，真实版本号在包内 APK 文件名上：
  # 先解压再找 APK，不能拿 artifact 名（如 Spoofed-Manager-release）提取版本
  mkdir -p "$CANDIDATE_DIR/extracted"
  if ! unzip -q "$APK_PATH" -d "$CANDIDATE_DIR/extracted" 2>/dev/null; then
    echo "⚠️  无法解压产物，跳过：$NAME"
    rm -rf "$CANDIDATE_DIR"
    continue
  fi
  APK_FILE=$(find "$CANDIDATE_DIR/extracted" -type f -name "*.apk" -print -quit)
  if [ -z "$APK_FILE" ]; then
    echo "⚠️  产物中没有 APK，跳过：$NAME"
    rm -rf "$CANDIDATE_DIR"
    continue
  fi
  
  # 从 APK 文件名提取实际版本
  # 提取不到版本号是「跳过该候选」的正常路径，别让 set -e 直接终止脚本。
  ACTUAL_VERSION=$(extract_apk_version "$(basename "$APK_FILE")") || true
  
  if ! [[ "$ACTUAL_VERSION" =~ ^[0-9]+$ ]]; then
    echo "⚠️  无法提取版本，跳过：$NAME"
    rm -rf "$CANDIDATE_DIR"
    continue
  fi
  
  echo "候选 $FETCHED: 实际版本=$ACTUAL_VERSION, 目标版本=$TARGET_KSU_VERSION"
  
  # ═══ 版本验证 ═══
  if [ "$ACTUAL_VERSION" -gt "$TARGET_KSU_VERSION" ]; then
    # ❌ 实际版本 > 内核版本 → 拒绝
    echo "❌ 拒绝：实际版本 $ACTUAL_VERSION > 内核版本 $TARGET_KSU_VERSION"
    rm -rf "$CANDIDATE_DIR"
    continue
  fi
  
  if [ "$ACTUAL_VERSION" -eq "$TARGET_KSU_VERSION" ]; then
    # ✅ 精确匹配 → 立即停止，清理其他候选
    echo "✅ 精确匹配：实际版本 $ACTUAL_VERSION"
    MATCHED=1
    BEST_ACTUAL="$ACTUAL_VERSION"
    BEST_DIR="$CANDIDATE_DIR"
    # 清理其他候选
    find "$CANDIDATE_BASE" -mindepth 1 -maxdepth 1 -type d \
      ! -path "$CANDIDATE_DIR" -exec rm -rf {} +
    break
  elif [ "$ACTUAL_VERSION" -gt "$BEST_ACTUAL" ]; then
    # ⚠️ 未匹配但更高 → 记录为备选
    echo "⚠️  备选：实际版本 $ACTUAL_VERSION (当前最佳 $BEST_ACTUAL)"
    rm -rf "$BEST_DIR" 2>/dev/null || true
    BEST_ACTUAL="$ACTUAL_VERSION"
    BEST_DIR="$CANDIDATE_DIR"
  else
    # 更低版本 → 丢弃
    echo "丢弃：实际版本 $ACTUAL_VERSION < 当前最佳 $BEST_ACTUAL"
    rm -rf "$CANDIDATE_DIR"
  fi
done < "$DOWNLOAD_LIST_FILE"

# 清理临时文件
rm -f "$DOWNLOAD_LIST_FILE"

# ═══ 裁决：用实际版本命名 ═══
if [ -n "$BEST_DIR" ]; then
  # 解压最佳候选到工作目录
  mkdir -p "manager-artifacts"
  for f in "$BEST_DIR"/*; do
    # 跳过 extracted 子目录，只解压下载下来的 zip（文件名即 artifact 名，
    # 分流步骤依赖这个子目录名区分 spoofed/普通）
    [ -f "$f" ] || continue
    SAFE_NAME=$(basename "$f" | tr '/ ' '__')
    unzip -o "$f" -d "manager-artifacts/$SAFE_NAME" || {
      echo "::error::解压管理器产物失败：$f"; exit 1;
    }
    # 解压成功不等于有产物：空目录会让后续「分流/上传」步骤安静地拿到 0 个 APK。
    if [ -z "$(find "manager-artifacts/$SAFE_NAME" -type f -print -quit)" ]; then
      echo "::error::解压后目录为空：manager-artifacts/$SAFE_NAME（$f）"; exit 1;
    fi
  done
  
  if [ "$MATCHED" -eq 1 ]; then
    echo "✅ 精确匹配成功：版本 $BEST_ACTUAL"
  else
    echo "⚠️  未找到精确匹配，使用最高版本 $BEST_ACTUAL (目标 $TARGET_KSU_VERSION)"
    echo "::warning::管理器版本 $BEST_ACTUAL 落后内核版本 $TARGET_KSU_VERSION"
  fi

  # 用实际版本命名（对齐原始数据交给「计算对齐提交」步骤）
  echo "MANAGER_VERSION=$BEST_ACTUAL" >> $GITHUB_ENV
  echo "managerVer=$BEST_ACTUAL" >> $GITHUB_OUTPUT
  echo "MANAGER_SHA=${BEST_SHA:-}" >> $GITHUB_ENV
  echo "MANAGER_MATCHED=$MATCHED" >> $GITHUB_ENV
else
  echo "::error::未找到任何有效 Manager APK"
  exit 1
fi

# 清理临时目录
rm -rf "$CANDIDATE_BASE"

if [ "$KSU_VARIANT" == "BakaSU" ]; then
  echo "仅保留 BakaSU arm64-v8a release 管理器..."
  find manager-artifacts -type f -name "*.apk" ! -name "*-arm64-v8a-release.apk" -delete
  find manager-artifacts -type f -name "*debug*.apk" -delete
  if ! find manager-artifacts -type f -name "*-arm64-v8a-release.apk" | grep -q .; then
    echo "未找到 BakaSU arm64-v8a release 管理器。"
    exit 1
  fi
  find manager-artifacts -type f -name "*.apk" -print
fi

