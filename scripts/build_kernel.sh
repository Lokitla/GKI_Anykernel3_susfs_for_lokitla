#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# =============================================================================
# GKI 内核构建核心脚本 —— GitHub Actions 与 Python CLI 共用
#
# 构建阶段集中在本文件；工作流负责输入、调度和产物处理，build.py 负责本地参数解析。
#
# 用法:
#   ./scripts/build_kernel.sh --all                 运行完整构建
#   ./scripts/build_kernel.sh --from clone_deps     从指定阶段开始
#   ./scripts/build_kernel.sh --only compile_kernel 只跑单个阶段
#   ./scripts/build_kernel.sh --list                列出全部阶段
#
# 所有参数通过环境变量注入（见下方默认值），也可由 build.py 传入。
# =============================================================================
set -eo pipefail

# ---------------------------- 参数与默认值 ----------------------------
: "${ANDROID_VERSION:=android14}"
: "${KERNEL_VERSION:=6.1}"
: "${SUB_LEVEL:=124}"
: "${OS_PATCH_LEVEL:=2025-02}"
: "${KSU_VARIANT:=BakaSU}"
: "${KSU_CERT_SIZE:=}"
: "${KSU_CERT_HASH:=}"
: "${KSU_MODE:=关闭}"
: "${VERSION:=}"
: "${REVISION:=}"
: "${BUILD_TIME:=}"
: "${USE_ZRAM:=false}"
: "${USE_BBR:=false}"
: "${USE_BBG:=false}"
: "${USE_KPM:=false}"
: "${USE_REKERNEL:=false}"
# 网络增强：IPSet 全类型 + BBR + FQ/FQ_CODEL 队列 + IPv6 NAT + 附加拥塞算法。
# 全部走 defconfig 写入，不引入第三方代码，默认关闭。
: "${USE_NET_ENHANCE:=false}"
# 兼容跳过：可选功能失败时降级为警告并继续构建，而非中断整个构建。
# 可跳过的阶段由 phase_skippable 白名单控制，SUSFS 与一加 8E 不在其中。
: "${SKIP_INCOMPATIBLE:=false}"
# NoMount 挂载元模块，移植自上游 zzh20188/GKI_KernelSU_SUSFS commit 27e129e
# （feat(ci): add optional NoMount metamodule integration，2026-09-19）。
# NoMount 在 fs/ 下注册子系统，与 SUSFS sus_mount 各走各的路径，可和任意 KSU 变体共存。
: "${USE_NOMOUNT:=false}"
: "${CVE_2026_43499_PATCH:=false}"
: "${EXPORT_SUSFS_PATCHES:=false}"
: "${ENABLE_SUSFS:=true}"
# SUSFS 原始补丁探测（来自上游 zzh20188 的 susfs-probe 工具分支）：
#   SUSFS_RAW_PROBE=true  -> 请求"只打原始补丁、不做适配修复"，用于校准兼容线。
#                            **需要 apply.sh 内部配合**才能生效（见 apply_susfs 阶段）。
#   SUSFS_SIDE_FIXES=true -> 探测时仍保留与子版本无关的侧修复（5.10 上游补丁
#                            自身的两处编译缺陷）
#   SUSFS_PIN_TIME        -> ISO 8601 时刻，把 susfs4ksu 固定到该时刻之前最后一次
#                            提交，让同一轮探测的所有任务用同一份上游代码。
#                            这一项已完整实现（见 clone_deps 阶段）。
: "${SUSFS_RAW_PROBE:=false}"
: "${SUSFS_SIDE_FIXES:=false}"
: "${SUSFS_PIN_TIME:=}"

# SUSFS 开关清单——与 SukiSU builtin 分支 kernel/Kconfig 里的 KSU_SUSFS* 一一对应
# （builtin 的 Kconfig 共 11 项：KSU_SUSFS 总开关 + 下面 9 个子项；main 分支 0 项）。
# 单一真相源：写 defconfig 和编译前核对 Kconfig 都从这里取，避免两处各写一份而漂移。
SUSFS_CONFIG_OPTIONS=(
  CONFIG_KSU_SUSFS=y
  CONFIG_KSU_SUSFS_SUS_PATH=y
  CONFIG_KSU_SUSFS_SUS_MOUNT=y
  CONFIG_KSU_SUSFS_SUS_KSTAT=y
  CONFIG_KSU_SUSFS_SPOOF_UNAME=y
  CONFIG_KSU_SUSFS_ENABLE_LOG=y
  CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
  CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
  CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
  CONFIG_KSU_SUSFS_SUS_MAP=y
)
# 各功能写进 defconfig 的符号清单——编译前「Kconfig 是否真的声明了该符号」核对用。
# 与 config_zram / config_net_enhance / add_bbg 三个阶段实际写入的行一一对应；
# 目标是复现被 sed 掉的 build.config.gki::check_defconfig 的作用（见 verify_kconfig_decl）。
ZRAM_KCONFIG_EXPECT=(
  CONFIG_ZSMALLOC
  CONFIG_ZRAM
  CONFIG_MODULE_SIG
  CONFIG_CRYPTO_LZO
  CONFIG_ZRAM_DEF_COMP_LZ4KD
  CONFIG_CRYPTO_LZ4HC
  CONFIG_CRYPTO_LZ4K
  CONFIG_CRYPTO_LZ4KD
  CONFIG_CRYPTO_842
  CONFIG_CRYPTO_LZ4K_OPLUS
)
NET_ENHANCE_KCONFIG_EXPECT=(
  CONFIG_TCP_CONG_ADVANCED
  CONFIG_TCP_CONG_BBR
  CONFIG_DEFAULT_BBR
  CONFIG_DEFAULT_TCP_CONG
  CONFIG_NET_SCH_FQ
  CONFIG_NET_SCH_FQ_CODEL
  CONFIG_IP_SET
  CONFIG_IP_SET_MAX
  CONFIG_NETFILTER_XT_SET
)
BBG_KCONFIG_EXPECT=(
  CONFIG_BBG
)
# 不得手写进 defconfig 的「隐藏符号」黑名单。
# 这些符号在目标内核里没有 prompt（由 Kconfig 的 select/depends 自行推导），手工写进
# defconfig 要么被 olddefconfig 静默丢弃、要么与 Kconfig 推导结果打架，且都不会让构建失败，
# 属于「看着生效其实没生效」。zzh20188 的 16944b83 正是删掉了网络增强里的
# `set_config CONFIG_NETFS_SUPPORT y`（该符号在 5.10 根本不存在，fs/netfs/Kconfig 为 404），
# 本仓库没有那段错误写入，这里落成防回退守卫：将来有人再手写这些符号时立刻报错。
# 只列「已实测在本仓库目标版本上不该手写」的符号，不做泛指（否则会误伤
# CONFIG_DEFAULT_TCP_CONG 这类本身无 prompt、但写入后确实被采纳的符号）。
HIDDEN_CONFIG_DENY=(
  CONFIG_NETFS_SUPPORT
)

: "${SUPP_OP:=false}"
# 严格许可模式会跳过许可未明或采用非标准许可的可选补丁。来源和许可信息见
# THIRD_PARTY_NOTICES.md。默认关闭。
: "${STRICT_LICENSE_MODE:=false}"
: "${DROIDSPACES:=不启用}"
: "${DROIDSPACES_NTSYNC:=false}"
: "${ARTIFACT_UPLOAD_MODE:=上传全部}"

# USE_KPM 取值归一化：Actions 下拉传 "enabled (开启)" / "patched (开启并修补)"，
# 早期本地 CLI 传 "true"/"false"，而脚本只按 enabled* / patched* 匹配，
# 导致 --kpm 静默失效。这里统一成三态，任何入口传什么都不至于判错。
case "${USE_KPM,,}" in
  enabled*|patched*) : ;;
  true|1|yes|on|开启)  USE_KPM="enabled (开启)" ;;
  *)                   USE_KPM="disabled (关闭)" ;;
esac

# KPM 镜像修补工具，移植自 ShirkNeko/GKI_KernelSU_SUSFS (scripts/config.py)
# ShirkNeko/SukiSU_patch 已改名为 SukiSU-Ultra/SukiSU_patch，旧路径目前靠 301 跳转苟活，
# 直接指向新名字，免得哪天跳转撤掉就整片构建一起挂。
# 跟随 SukiSU_patch 上游 main 分支（不钉 commit，便于自动跟进上游）
: "${KPM_PATCH_URL:=https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU_patch/refs/heads/main/kpm/patch_linux}"
# KPM 修补工具的可选 sha256 锚点。留空则不校验（跟随 main、零锚点风险）；
# 传入具体 64 位 hex 后，下方 stage_patch_kpm 会做 fail-closed 比对，不符即拒绝执行。
# 入口优先级（高 → 低）：
#   1) 环境变量 EXPECTED_KPM_PATCH_SHA256（CI: build.yml inputs.kpm_patch_sha256；本地: --kpm-patch-sha256）
#   2) $WORKSPACE/config/kpm_patch_sha256（仓库内单一 pin 源，可用 scripts/tools/pin_kpm_patch.sh 生成）
#   3) 空 → 不校验，打印 ::warning:: 明示零锚点运行
: "${EXPECTED_KPM_PATCH_SHA256:=}"
: "${WORKSPACE:=$(pwd)}"
: "${COMPILE_TIMEOUT_MINUTES:=30}"
: "${COMPILE_MAX_ATTEMPTS:=3}"
: "${GITHUB_SHA:=$(git -C "$WORKSPACE" rev-parse HEAD 2>/dev/null || echo unknown)}"
: "${GITHUB_RUN_ID:=local}"
: "${GITHUB_SERVER_URL:=}"
: "${GITHUB_REPOSITORY:=}"
: "${MANAGER_STR:=}"
export WORKSPACE GITHUB_SHA GITHUB_RUN_ID GITHUB_SERVER_URL GITHUB_REPOSITORY MANAGER_STR
export ANDROID_VERSION
export KERNEL_VERSION
export SUB_LEVEL
export OS_PATCH_LEVEL
export KSU_VARIANT
export KSU_CERT_SIZE KSU_CERT_HASH
export KSU_MODE
export VERSION
export REVISION
export BUILD_TIME
export USE_ZRAM
export USE_BBR
export USE_BBG
export USE_KPM
export USE_REKERNEL
export USE_NET_ENHANCE
export SKIP_INCOMPATIBLE
export USE_NOMOUNT
export CVE_2026_43499_PATCH
export EXPORT_SUSFS_PATCHES
export ENABLE_SUSFS
export EXPECTED_KPM_PATCH_SHA256
export SUPP_OP
export STRICT_LICENSE_MODE
# SUSFS 原始补丁探测的三个开关必须 export：apply.sh 是 bash 子进程调用的，
# 不 export 的话子进程里 ${SUSFS_RAW_PROBE:-false} 恒为 false，探测形同虚设。
# SUSFS_PROBE_DIR 是 apply.json 的写出目录，同样要透过去；build.yml 负责设置。
export SUSFS_RAW_PROBE SUSFS_SIDE_FIXES SUSFS_PIN_TIME
: "${SUSFS_PROBE_DIR:=$WORKSPACE/susfs-probe}"
export SUSFS_PROBE_DIR
# 探测矩阵里同一子版本会跨多个月份出现（如 5.10.209 的 2024-11 与 2025-01），
# 而 CONFIG 只到子版本这一步，产物名不带月份就会互相覆盖。
ARTIFACT_SUFFIX=""
if [ "${SUSFS_RAW_PROBE:-false}" = "true" ]; then
  ARTIFACT_SUFFIX="-${OS_PATCH_LEVEL:-unknown}"
fi
export ARTIFACT_SUFFIX
export DROIDSPACES
export DROIDSPACES_NTSYNC
export ARTIFACT_UPLOAD_MODE

# ---------------------------- 运行时状态 ----------------------------
export COMPILE_FAILED=0
export SUSFS_PATCH_EXPORT=false
export REJ_COUNT=0
export TOOLCHAIN_CACHE_HIT="${TOOLCHAIN_CACHE_HIT:-false}"
# 注意：切勿在全局导出 OUT_DIR —— GKI 的 build/build.sh 会把它当作内核输出目录继承，
# 导致产物从 out/<branch>/dist 跑到别处。SUSFS 补丁导出目录请在阶段内局部定义。

log_stage() {
  echo ""
  echo "================================================================"
  echo "  [$1] $2"
  echo "================================================================"
}

# ---------------------------- 阶段函数 ----------------------------
stage_summary() {
  log_stage "summary" "构建信息摘要"
  local _pwd="$PWD"
  echo "========================================"
  echo "       内核构建配置摘要"
  echo "========================================"
  echo "Android 版本  : ${ANDROID_VERSION}"
  echo "内核版本      : ${KERNEL_VERSION}"
  echo "子版本号      : ${SUB_LEVEL}"
  echo "补丁级别      : ${OS_PATCH_LEVEL}"
  echo "KSU 变体      : ${KSU_VARIANT}"
  echo "构建时间      : ${BUILD_TIME}"
  echo "SUSFS 状态    : ${ENABLE_SUSFS}"
  echo "ZRAM 增强     : ${USE_ZRAM}"
  echo "BBG 补丁      : ${USE_BBG}"
  echo "KPM 功能      : ${USE_KPM}"
  echo "Re-Kernel     : ${USE_REKERNEL}"
  echo "NoMount       : ${USE_NOMOUNT}"
  echo "网络增强      : ${USE_NET_ENHANCE}"
  echo "兼容跳过      : ${SKIP_INCOMPATIBLE}"
  echo "CVE-2026-43499: ${CVE_2026_43499_PATCH}"
  echo "SUSFS 集成补丁导出: ${EXPORT_SUSFS_PATCHES}"
  echo "Droidspaces   : ${DROIDSPACES}"
  echo "NTSync        : ${DROIDSPACES_NTSYNC}"
  echo "产物上传模式  : ${ARTIFACT_UPLOAD_MODE}"
  # 实际状态来自 apply_stock_config；这里以前写死"自动检测"，
  # 文件不存在时也照样显示，看不出这个功能到底开没开
  if [ -f "$WORKSPACE/config/stock_defconfig" ]; then
    echo "Stock Config  : 启用（config/stock_defconfig 已就位）"
  else
    echo "Stock Config  : 未启用（缺 config/stock_defconfig，跳过 /proc/config.gz 伪装）"
  fi
  echo "========================================"


  # BBR 开关展示（zzh20188 原摘要没有该项）
  echo "BBR 拥塞控制: ${USE_BBR}"

  cd "$_pwd"
}

run_summary() { stage_summary "$@"; }

stage_cleanup_disk() {
  log_stage "cleanup_disk" "清理磁盘空间"
  local _pwd="$PWD"
  # 先并行 mv 到临时目录（瞬时完成），再在后台低优先级删除，不阻塞后续步骤
  # 临时目录必须放在工作区之外：checkout 会以 runner 用户清空工作区，
  # 遇到 sudo mv 进来的 root 属主文件会 EACCES 失败
  TRASH_DIR=/tmp/.background_trash
  sudo rm -rf "$TRASH_DIR"
  mkdir -p "$TRASH_DIR"/{1..17}

  safe_mv() {
    [ -e "$1" ] && sudo mv "$1" "$2" || true
  }
  export -f safe_mv

  safe_mv /usr/share/dotnet         "$TRASH_DIR"/1  &
  safe_mv /usr/local/lib/android    "$TRASH_DIR"/2  &
  safe_mv /opt/ghc                  "$TRASH_DIR"/3  &
  safe_mv /opt/hostedtoolcache/CodeQL "$TRASH_DIR"/4 &
  safe_mv /usr/local/aws-sam-cli    "$TRASH_DIR"/5  &
  safe_mv /usr/local/share/chromium "$TRASH_DIR"/6  &
  safe_mv /usr/local/share/powershell "$TRASH_DIR"/7 &
  safe_mv /usr/local/lib/heroku     "$TRASH_DIR"/8  &
  safe_mv /usr/local/lib/node_modules "$TRASH_DIR"/9 &
  safe_mv /opt/az                   "$TRASH_DIR"/10 &
  safe_mv /opt/microsoft/powershell "$TRASH_DIR"/11 &
  safe_mv /opt/hostedtoolcache/go   "$TRASH_DIR"/12 &
  safe_mv /opt/hostedtoolcache/PyPy "$TRASH_DIR"/13 &
  safe_mv /opt/hostedtoolcache/node "$TRASH_DIR"/14 &
  sudo bash -c "mv /usr/local/bin/aliyun /usr/local/bin/azcopy /usr/local/bin/bicep \
    /usr/local/bin/cmake-gui /usr/local/bin/cpack /usr/local/bin/helm \
    /usr/local/bin/hub /usr/local/bin/kubectl /usr/local/bin/minikube \
    /usr/local/bin/node /usr/local/bin/packer /usr/local/bin/sam \
    /usr/local/bin/stack /usr/local/bin/terraform /usr/local/bin/oc \
    $TRASH_DIR/15 2>/dev/null || true" &
  sudo bash -c "mv /usr/local/julia* $TRASH_DIR/16 2>/dev/null || true" &
  sudo bash -c "mv /usr/local/bin/pulumi* $TRASH_DIR/17 2>/dev/null || true" &
  wait

  # 后台低优先级删除，顺带清理浏览器包和 apt 缓存
  (
    sudo nice -n 19 ionice -c 3 rm -rf "$TRASH_DIR"
    sudo apt-get purge -y firefox google-chrome-stable microsoft-edge-stable \
      >/dev/null 2>&1 || true
    sudo apt-get autoremove -y >/dev/null 2>&1 || true
    sudo apt-get clean >/dev/null 2>&1 || true
    command -v docker >/dev/null 2>&1 && \
      docker rmi $(docker images -q) 2>/dev/null || true
  ) >/dev/null 2>&1 &
  disown

  cd "$_pwd"
}

# 安全门：仅 GitHub Actions runner 执行，本地构建跳过以免破坏系统
run_cleanup_disk() {
  if [ "${GITHUB_ACTIONS:-false}" = "true" ]; then
    stage_cleanup_disk "$@"
  else
    echo "跳过阶段: cleanup_disk（仅 GitHub Actions runner 执行）"
  fi
}

stage_init_env() {
  log_stage "init_env" "初始化构建环境"
  local _pwd="$PWD"
  CONFIG="${ANDROID_VERSION}-${KERNEL_VERSION}-${SUB_LEVEL}"
  KERNEL_ROOT="$WORKSPACE/$CONFIG"
  mkdir -p "$KERNEL_ROOT"

  LEGACY_SUKISU_CONFIG=""
  case "${KSU_VARIANT}" in
    SukiSU\(*\)) LEGACY_SUKISU_CONFIG="$WORKSPACE/config/${KSU_VARIANT}.config" ;;
  esac

  if [ -n "$LEGACY_SUKISU_CONFIG" ] && [ ! -f "$LEGACY_SUKISU_CONFIG" ]; then
    echo "未找到 ${KSU_VARIANT} 固定提交配置: $LEGACY_SUKISU_CONFIG" >&2
    exit 1
  fi

  export CONFIG="$CONFIG"
  export KERNEL_ROOT="$KERNEL_ROOT"
  export LEGACY_SUKISU_CONFIG="$LEGACY_SUKISU_CONFIG"
  export DEFCONFIG="$KERNEL_ROOT/common/arch/arm64/configs/gki_defconfig"
  export SUSFS4KSU="$WORKSPACE/susfs4ksu"
  export KERNEL_PATCHES="$WORKSPACE/kernel_patches"
  export SUKISU_PATCHES="$WORKSPACE/SukiSU_patch"
  export ZZH_PATCHES="$WORKSPACE"
  export ANYKERNEL3="$WORKSPACE/AnyKernel3"
  export ACTION_BUILD="$WORKSPACE/Action-Build"
  export AVBTOOL="$WORKSPACE/kernel-build-tools/linux-x86/bin/avbtool"
  export MKBOOTIMG="$WORKSPACE/mkbootimg/mkbootimg.py"
  export UNPACK_BOOTIMG="$WORKSPACE/mkbootimg/unpack_bootimg.py"
  export BOOT_SIGN_KEY_PATH="$WORKSPACE/kernel-build-tools/linux-x86/share/avb/testkey_rsa2048.pem"

  mkdir -p "$WORKSPACE/git-repo"
  # storage.googleapis.com 偶发 TLS 握手失败（curl 退出码 35），全量构建 80+ 个
  # job 各跑一次，累积下来命中概率不低。--retry-all-errors 才会重试握手类错误，
  # -f 保证 HTTP 错误页不会被当成成功写进 repo 文件。
  curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors --connect-timeout 30 \
    https://storage.googleapis.com/git-repo-downloads/repo \
    -o "$WORKSPACE/git-repo/repo"
  chmod 0755 "$WORKSPACE/git-repo/repo"
  export PATH="$WORKSPACE/git-repo:$PATH"
  export REPO="$WORKSPACE/git-repo/repo"

  cd "$_pwd"
}

run_init_env() { stage_init_env "$@"; }

stage_show_config() {
  log_stage "show_config" "显示配置信息"
  local _pwd="$PWD"
  CONFIG_FILE="$WORKSPACE/config/config"
  if [ -f "$CONFIG_FILE" ]; then
    echo "加载配置文件: $CONFIG_FILE"
    cat "$CONFIG_FILE"
  fi
  if [ -n "$LEGACY_SUKISU_CONFIG" ]; then
    echo "加载老版 SukiSU 固定提交配置: $LEGACY_SUKISU_CONFIG"
    cat "$LEGACY_SUKISU_CONFIG"
  fi

  cd "$_pwd"
}

run_show_config() { stage_show_config "$@"; }

stage_install_deps() {
  log_stage "install_deps" "安装编译依赖"
  local _pwd="$PWD"
  sudo apt-get update
  sudo apt-get install -y ccache python3 git curl build-essential libssl-dev bison flex libelf-dev dwarves lz4

  cd "$_pwd"
}

run_install_deps() { stage_install_deps "$@"; }

stage_setup_ccache() {
  log_stage "setup_ccache" "配置 ccache"
  local _pwd="$PWD"
  mkdir -p ~/.cache/bazel
  ccache --version
  ccache --max-size=2G
  ccache --set-config=compression=true
  export CCACHE_DIR="$HOME/.ccache"

  cd "$_pwd"
}

run_setup_ccache() { stage_setup_ccache "$@"; }

stage_download_toolchain() {
  log_stage "download_toolchain" "下载工具链"
  local _pwd="$PWD"
  AOSP_MIRROR=https://android.googlesource.com
  BRANCH=main-kernel-build-2024
  # 工具链来自 android.googlesource.com，与 GitHub/GitLab 分属不同基建，但同样是
  # 下游一切编译的前提：这里失败，后面每一步都无可挽回。同样走退避重试。
  clone_with_retry $AOSP_MIRROR/kernel/prebuilts/build-tools kernel-build-tools -b $BRANCH --depth 1 || {
    echo "::error::AOSP 工具链 build-tools 克隆失败（分支 $BRANCH）"; cd "$_pwd"; return 1
  }
  clone_with_retry $AOSP_MIRROR/platform/system/tools/mkbootimg mkbootimg -b $BRANCH --depth 1 || {
    echo "::error::AOSP mkbootimg 克隆失败（分支 $BRANCH）"; cd "$_pwd"; return 1
  }

  cd "$_pwd"
}

# 条件执行（等价原工作流 if:）
run_download_toolchain() {
  if [ "${TOOLCHAIN_CACHE_HIT:-false}" != "true" ]; then
    stage_download_toolchain "$@"
  else
    echo "跳过阶段: download_toolchain（条件不满足）"
  fi
}

stage_gen_sign_key() {
  log_stage "gen_sign_key" "生成签名密钥"
  local _pwd="$PWD"
  # 复用已有密钥以保证 boot 签名可复现，仅在缺失时生成；公钥归档便于审计
  #
  # 注意（可复现性）：该 pem 位于 kernel-build-tools/ 内，会随「缓存工具链」
  # 步骤（actions/cache key: toolchain-${runner.os}-v1）一起被缓存与恢复。
  # 因此：
  #   - 缓存命中 → 复用首次构建生成的密钥，跨 Android/内核版本一致；
  #   - 缓存未命中/被清除 → 重新生成随机密钥，boot.img 签名随之变化。
  # 若需要"任意时刻字节级可复现"，应把密钥作为 secret 注入而非依赖缓存状态。
  # 这里显式打印指纹，便于事后确认某次产物到底由哪把密钥签名。
  if [ -s "$BOOT_SIGN_KEY_PATH" ]; then
    echo "复用已有签名密钥: $BOOT_SIGN_KEY_PATH"
  else
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 > "$BOOT_SIGN_KEY_PATH"
    echo "已生成新签名密钥: $BOOT_SIGN_KEY_PATH"
    echo "::warning::本次内核 boot 签名使用了新生成的随机密钥（缓存未命中）。" \
         "同缓存周期内的其他构建复用它；缓存失效后签名密钥会变化。"
  fi
  mkdir -p "$WORKSPACE/build-logs"
  openssl rsa -in "$BOOT_SIGN_KEY_PATH" -pubout -out "$WORKSPACE/build-logs/boot_sign_key.pub" 2>/dev/null || true
  # 输出公钥指纹，作为 key=value 追加到 build-logs 供审计与产物对照
  if [ -s "$WORKSPACE/build-logs/boot_sign_key.pub" ]; then
    fingerprint=$(openssl pkey -pubin -in "$WORKSPACE/build-logs/boot_sign_key.pub" \
      -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
    echo "boot 签名公钥指纹(sha256): ${fingerprint:-不可用}"
    echo "boot_sign_key_fingerprint=${fingerprint:-unavailable}" \
      >> "$WORKSPACE/build-logs/build-info.txt"
  fi

  cd "$_pwd"
}

run_gen_sign_key() { stage_gen_sign_key "$@"; }

stage_setup_git() {
  log_stage "setup_git" "配置 Git"
  local _pwd="$PWD"
  git config --global user.name "BuildBot"
  git config --global user.email "BuildGkiKernel@gmail.com"
  # 上游 git 服务偶发连接停滞：传输速率低于 1KB/s 持续 180 秒即中止，
  # 避免在 repo sync / git clone 中无限挂起直到 job 超时
  git config --global http.lowSpeedLimit 1000
  git config --global http.lowSpeedTime 180

  cd "$_pwd"
}

run_setup_git() { stage_setup_git "$@"; }

# 带退避重试的依赖克隆（移植自 zzh20188/GKI_KernelSU_SUSFS ce91de25「fix: retry
# dependency clones with backoff and cleanup」）。
#
# 为什么需要它：本仓库每次构建都要从 GitHub/GitLab 拉十来个仓库，而 GitLab 在整点
# 高负载时会直接拒绝克隆；矩阵里 80+ 个任务同时开跑，撞上的概率被进一步放大。
# 原先任何一次 clone 失败都会让整个任务在第 3 分钟就前功尽弃。这里做三件事：
#   1. 每轮重试前先 rm -rf 目标目录 —— 上一次中断留下的半成品目录会让 git clone
#      直接报 "destination path already exists"，重试必然失败，等于没有重试；
#   2. 递增等待 15/30/60/120 秒并加 0~9 秒随机抖动 —— 固定间隔会让同一个矩阵的
#      任务在同一秒一起重试，把上游再打挂一次；
#   3. 用尽 5 次后清掉残留并原样返回 git 的退出码，不掩盖真实失败原因。
#
# 用法: clone_with_retry <仓库地址> <目标目录> [其余 git clone 参数...]
clone_with_retry() {
  local repository="$1" destination="$2"
  shift 2
  local attempt delay rc=1
  for attempt in 1 2 3 4 5; do
    echo "克隆 ${repository}（第 ${attempt}/5 次）..."
    rm -rf -- "$destination" || return 1
    if git clone "$repository" "$destination" "$@"; then
      return 0
    else
      rc=$?
    fi
    if [ "$attempt" -lt 5 ]; then
      delay=$((15 * (1 << (attempt - 1)) + RANDOM % 10))
      echo "::warning::克隆 ${repository} 失败（退出码 ${rc}），${delay} 秒后重试"
      sleep "$delay" || return 1
    fi
  done
  rm -rf -- "$destination" || return 1
  echo "::error::克隆 ${repository} 失败，已用尽 5 次尝试（退出码 ${rc}）"
  return "$rc"
}

stage_clone_deps() {
  log_stage "clone_deps" "克隆依赖仓库"
  local _pwd="$PWD"
  ANYKERNEL_BRANCH="gki-2.0"

  # 只取工作树所需文件，全部浅克隆：这些仓库每次构建都会被 80+ 个任务各拉一遍，
  # 全量克隆会白白吃掉上游带宽，也让每个任务多花几十秒。
  #
  # 注意：susfs4ksu **不在这里**克隆。它原本排在本阶段，而本阶段位于
  # sync_kernel_source（repo sync）与 add_kernelsu 之前——前期把最大的几个仓库
  # 挤在同一时刻并发拉取，最容易撞上上游瞬时失败。已拆到 clone_susfs 阶段，
  # 见该阶段的说明（移植自 zzh20188 90b76411）。
  echo "克隆 AnyKernel3..."
  clone_with_retry https://github.com/WildKernels/AnyKernel3.git AnyKernel3 -b "$ANYKERNEL_BRANCH" || {
    echo "::error::AnyKernel3 克隆失败（分支 $ANYKERNEL_BRANCH）"
    cd "$_pwd"; return 1
  }
  rm -rf AnyKernel3/.git

  # 注意：阶段函数是在 `if ! "run_${p}"` 里被调用的，bash 会因此在函数体内部
  # 关闭 `set -e`，所以这里的每一步都必须自己判失败并 return 1；否则克隆失败后
  # 函数会带着最后的 `cd "$_pwd"`（返回 0）"成功"退出，一路编到一个缺依赖的内核。
  echo "准备补丁资源..."
  clone_with_retry https://github.com/WildKernels/kernel_patches.git kernel_patches || {
    echo "::error::kernel_patches 克隆失败"; cd "$_pwd"; return 1
  }
  clone_with_retry https://github.com/SukiSU-Ultra/SukiSU_patch.git SukiSU_patch || {
    echo "::error::SukiSU_patch 克隆失败"; cd "$_pwd"; return 1
  }
  echo "使用当前仓库补丁目录: $ZZH_PATCHES"
  clone_with_retry https://github.com/Numbersf/Action-Build.git Action-Build --depth=1 || {
    echo "::error::Action-Build 克隆失败"; cd "$_pwd"; return 1
  }

  cd "$_pwd"
}

run_clone_deps() { stage_clone_deps "$@"; }

# susfs4ksu 的克隆（移植自 zzh20188/GKI_KernelSU_SUSFS 90b76411「defer SUSFS
# cloning until after KernelSU setup」）。
#
# 原先它排在 clone_deps 里，而 clone_deps 位于 sync_kernel_source（repo sync）与
# add_kernelsu 之前：最大的几个仓库被挤在同一时刻并发拉取，任何一家抖动都要整轮重来。
# 拆出来单独排在 KernelSU 就绪之后，克隆之间的并发压力被摊开，失败面随之收窄。
#
# **不钉上游 commit**：分支永远取 gki-<android>-<kernel>，跟随上游更新。
stage_clone_susfs() {
  log_stage "clone_susfs" "克隆 SUSFS 补丁源"
  local _pwd="$PWD"
  SUSFS_BRANCH="gki-${ANDROID_VERSION}-${KERNEL_VERSION}"

  echo "克隆 SUSFS (分支: $SUSFS_BRANCH)..."
  # 注意：ShirkNeko 的 fork 并**不**保证存在 gki-<android>-<kernel> 分支。
  # 原实现直接 clone 并把错误丢进 /dev/null，克隆失败才回退——在带重试的版本里
  # 这会先白等 15+30+60+120 秒再把「分支不存在」当成网络故障重试 5 次。
  # 分支是否存在是可以用 ls-remote 廉价问出来的确定性问题，先问再决定拉谁。
  # 保留原语义：探测本身失败（网络抖动）不做断言，照原样回退 simonpunk。
  remote_has_branch() {
    local out
    # 捕获而非 grep -q 直接收尾：本脚本 set -o pipefail，而 grep -q 命中即退出
    # 会让上游 git 收到 SIGPIPE（退出码 141），整条管道被判为失败——分支明明存在
    # 却被当成不存在。分支列表只有几行，整体读进变量没有代价。
    out=$(git ls-remote --heads "$1" "$2" 2>/dev/null) || return 1
    [ -n "$out" ]
  }

  if [ -n "$LEGACY_SUKISU_CONFIG" ]; then
    clone_with_retry https://gitlab.com/simonpunk/susfs4ksu.git susfs4ksu -b "$SUSFS_BRANCH" || {
      echo "::error::simonpunk/susfs4ksu 克隆失败（分支 $SUSFS_BRANCH）"; cd "$_pwd"; return 1
    }
  elif [ "${KSU_VARIANT}" == "SukiSU" ] && remote_has_branch https://github.com/ShirkNeko/susfs4ksu.git "$SUSFS_BRANCH"; then
    clone_with_retry https://github.com/ShirkNeko/susfs4ksu.git susfs4ksu -b "$SUSFS_BRANCH" || {
      echo "::error::ShirkNeko/susfs4ksu 克隆失败（分支 $SUSFS_BRANCH）"; cd "$_pwd"; return 1
    }
  else
    [ "${KSU_VARIANT}" == "SukiSU" ] && echo "ShirkNeko 仓库无分支 $SUSFS_BRANCH，改用 simonpunk 原版"
    clone_with_retry https://gitlab.com/simonpunk/susfs4ksu.git susfs4ksu -b "$SUSFS_BRANCH" || {
      echo "::error::simonpunk/susfs4ksu 克隆失败（分支 $SUSFS_BRANCH）"; cd "$_pwd"; return 1
    }
  fi

  # ShirkNeko 与 simonpunk 是两个内容并不相同的 fork（6.12 只有 simonpunk 有分支）。
  # 不走上面的 ls-remote 预判、而是直接 clone 的路径必须自己报出实际来源：日志里
  # 看不出这次到底用了哪一家的补丁，排查"SUSFS 行为和别人不一样"时会白绕一大圈。
  echo "SUSFS 实际来源: $(git -C susfs4ksu remote get-url origin) @ $(git -C susfs4ksu rev-parse --short=9 HEAD)"

  # 先记录分支最新提交日期，之后再切到固定提交，避免把这个日期读成固定提交的日期
  SUSFS_LATEST_COMMIT_DATE=$(git -C susfs4ksu log -1 --date=format:'%Y-%m-%d %H:%M:%S %z' --format='%cd')
  export SUSFS_LATEST_COMMIT_DATE="$SUSFS_LATEST_COMMIT_DATE"
  echo "SUSFS 仓库最新提交日期: $SUSFS_LATEST_COMMIT_DATE"

  # SUSFS 固定时刻（susfs-probe 探测模式用）：一轮探测会跑几个小时，若中途上游
  # 推送新提交，各任务的补丁版本就不一致，汇总出的结论会互相矛盾。这里把
  # susfs4ksu 固定到该时刻之前的最后一次提交。
  # 只有显式设置了 SUSFS_PIN_TIME 才放弃浅克隆（需要完整历史才能按时间定位），
  # 正常构建完全不受影响。显式的 SUSFS_COMMIT 优先级更高，见下方。
  if [ -n "${SUSFS_PIN_TIME:-}" ]; then
    echo "按固定时刻拉取 susfs4ksu 历史（早于 ${SUSFS_PIN_TIME} 的最后一次提交）..."
    git -C susfs4ksu fetch --unshallow >/dev/null 2>&1 || true
    local pinned_susfs
    pinned_susfs=$(git -C susfs4ksu rev-list -1 --before="${SUSFS_PIN_TIME}" HEAD 2>/dev/null)
    if [ -n "$pinned_susfs" ]; then
      git -C susfs4ksu checkout "$pinned_susfs" >/dev/null 2>&1
      echo "susfs4ksu 已固定到: $(git -C susfs4ksu rev-parse --short=9 HEAD)"
    else
      echo "::warning::未能按 ${SUSFS_PIN_TIME} 定位 susfs4ksu 提交（可能早于仓库历史），保持分支最新"
    fi
  fi

  # 浅克隆只含分支头，切换到历史提交前需要单独拉取该提交
  checkout_susfs_commit() {
    local target="$1"
    if git -C susfs4ksu cat-file -e "${target}^{commit}" 2>/dev/null; then
      git -C susfs4ksu checkout "$target"
    else
      git -C susfs4ksu fetch --depth 1 origin "$target" && git -C susfs4ksu checkout "$target"
    fi
  }

  # SUSFS 提交锁定：显式传入的 SUSFS_COMMIT 环境变量优先级最高。
  # 优先级：显式入参 > config/config > 分支最新。
  # 老版本变体（SukiSU(40726)/SukiSU(40548)）走各自的固定配置，不受此开关影响。
  if [ -n "${SUSFS_COMMIT:-}" ] && [ -z "$LEGACY_SUKISU_CONFIG" ]; then
    if [[ ! "$SUSFS_COMMIT" =~ ^[0-9a-fA-F]{40}$ && ! "$SUSFS_COMMIT" =~ ^[0-9a-fA-F]{64}$ ]]; then
      echo "::warning::忽略非法 SUSFS 提交: ${SUSFS_COMMIT}（要求 40 位 SHA-1 或 64 位 SHA-256 的 hex，改用默认分支）"
    else
      echo "切换 SUSFS 到指定提交: $SUSFS_COMMIT"
      checkout_susfs_commit "$SUSFS_COMMIT"
    fi
  elif [ -n "$LEGACY_SUKISU_CONFIG" ]; then
    SUSFS_FIXED_COMMIT=$(grep "^${SUSFS_BRANCH}=" "$LEGACY_SUKISU_CONFIG" | cut -d'=' -f2-)
    if [ -z "$SUSFS_FIXED_COMMIT" ]; then
      echo "未在 $LEGACY_SUKISU_CONFIG 配置 $SUSFS_BRANCH 的固定 SUSFS 提交" >&2
      exit 1
    fi
    echo "${KSU_VARIANT} 固定 SUSFS 提交: $SUSFS_FIXED_COMMIT"
    checkout_susfs_commit "$SUSFS_FIXED_COMMIT"
  else
    CONFIG_FILE="config/config"
    if [ -f "$CONFIG_FILE" ]; then
      CUSTOM_ENABLED=$(grep "^custom=" "$CONFIG_FILE" | cut -d'=' -f2)
      if [ "$CUSTOM_ENABLED" == "true" ]; then
        CUSTOM_COMMIT=$(grep "^${SUSFS_BRANCH}=" "$CONFIG_FILE" | cut -d'=' -f2)
        if [ -n "$CUSTOM_COMMIT" ]; then
          echo "切换 SUSFS 到自定义提交: $CUSTOM_COMMIT"
          checkout_susfs_commit "$CUSTOM_COMMIT"
        fi
      fi
    fi
  fi

  cd "$_pwd"
}

# 条件执行（等价原工作流 if: inputs.enable_susfs）：
# SUSFS 关闭时补丁源根本不会被读取，克隆它纯属浪费，也白白多一次可能失败的网络调用。
run_clone_susfs() {
  if [ "${ENABLE_SUSFS}" = "true" ]; then
    stage_clone_susfs "$@"
  else
    echo "跳过阶段: clone_susfs（SUSFS 未启用）"
  fi
}

stage_sync_kernel_source() {
  log_stage "sync_kernel_source" "初始化并同步内核源码"
  local _pwd="$PWD"
  cd "${KERNEL_ROOT}"
  FORMATTED_BRANCH="${ANDROID_VERSION}-${KERNEL_VERSION}-${OS_PATCH_LEVEL}"
  # AOSP common 提供带 -lts 后缀的分支（如 android14-6.1-lts），可按常规分支名同步。
  # LTS 时 SUB_LEVEL 为字面量 X，此处从 data json 解析真实 lts 版本号替换之，
  # 使产物名（如 android14-6.1.177-lts-AnyKernel3.zip）可读可分发。
  if [ "${OS_PATCH_LEVEL}" = "lts" ]; then
    LTS_JSON="$WORKSPACE/data/${ANDROID_VERSION}/${KERNEL_VERSION}.json"
    if [ -f "$LTS_JSON" ]; then
      LTS_FULL=$(python3 -c "import json,sys
try:
    print(json.load(open('$LTS_JSON')).get('lts',''))
except Exception:
    pass" 2>/dev/null)
      # SUB_LEVEL 会被直接拼进产物文件名（anykernel3_zip_name / boot.*.img），
      # 而 data json 的 lts 由 update_data.py 自动流程写入 —— 属于外部数据。
      # 不做校验的话，一个 '6.1.177/../../evil' 的 lts 就能让 `cp ... ../$name`
      # 落到预期目录之外；带空格/换行的值还会污染下游 unzip/upload-artifact。
      # validate_inputs() 只覆盖了 OS_PATCH_LEVEL 与 REVISION，这里补上 SUB_LEVEL。
      # 合法形态：纯数字子版本，允许 X/y（上游对 x.y 系列用 y 表示子版本）。
      if [ -n "$LTS_FULL" ] && [[ "${LTS_FULL##*.}" =~ ^[0-9]+$ ]]; then
        SUB_LEVEL="${LTS_FULL##*.}"
        export SUB_LEVEL
        echo "LTS 真实版本: ${LTS_FULL}（sub level ${SUB_LEVEL}）"
      elif [ -n "$LTS_FULL" ]; then
        echo "::warning::data json 的 lts 字段非预期格式（期望 x.y.<数字>，实为 '${LTS_FULL}'），LTS 产物名保留字面量 X"
      else
        echo "::warning::data json 未含 lts 字段，LTS 产物名保留字面量 X"
      fi
    else
      echo "::warning::未找到 $LTS_JSON，LTS 产物名保留字面量 X"
    fi
  fi
  MAX_ATTEMPTS=3
  RETRY_DELAY=15
  SYNC_TIMEOUT=15m

  # android.googlesource.com 偶发限流、连接重置或单个 project 拉取卡死，
  # 单次失败不代表分支有问题，整轮重来通常就能成功。
  init_repo() {
    $REPO init --depth=1 -u https://android.googlesource.com/kernel/manifest \
      -b common-${FORMATTED_BRANCH} --repo-rev=v2.16 || return 1

    # ls-remote 同样可能瞬时失败；失败时返回空会让弃用分支判定出错，
    # 因此按退出码重试，全部失败就让本轮重来而不是白跑一次 sync。
    local ok=false
    for _ in 1 2 3; do
      if REMOTE_BRANCH=$(git ls-remote https://android.googlesource.com/kernel/common ${FORMATTED_BRANCH}); then
        ok=true
        break
      fi
      sleep 5
    done
    if [ "$ok" != true ]; then
      echo "git ls-remote 查询 ${FORMATTED_BRANCH} 失败"
      return 1
    fi

    DEFAULT_MANIFEST_PATH=.repo/manifests/default.xml
    TAG_FALLBACK=""
    if grep -q deprecated <<< "$REMOTE_BRANCH"; then
      echo "检测到已弃用的分支: $FORMATTED_BRANCH"
      sed -i "s/\"${FORMATTED_BRANCH}\"/\"deprecated\/${FORMATTED_BRANCH}\"/g" $DEFAULT_MANIFEST_PATH
    elif [ -z "$REMOTE_BRANCH" ]; then
      # Google 会把过期的月度分支整个删掉（既不在活跃也不在 deprecated/ 下），
      # 但 manifest 仍指向该分支。发布 tag 不会被删，回退到编号最大的 _rN tag。
      # 必须写成 refs/tags/ 全路径，裸 tag 名会被 repo 当成分支去 refs/heads/ 下找。
      local latest_tag tag_query rc
      if tag_query=$(git ls-remote https://android.googlesource.com/kernel/common "refs/tags/${FORMATTED_BRANCH}_r*" 2>&1); then
        latest_tag=$(printf '%s\n' "$tag_query" \
          | awk '{print $2}' | grep -v '\^{}$' | sed 's|refs/tags/||' \
          | awk -F'_r' '$NF ~ /^[0-9]+$/ {print $NF+0, $0}' | sort -n | tail -n 1 | cut -d' ' -f2-)
      else
        rc=$?
        echo "::error::查询 ${FORMATTED_BRANCH} 发布 tag 失败（git ls-remote 退出码 $rc）: $tag_query"
        return "$rc"
      fi
      if [ -z "$latest_tag" ]; then
        echo "::error::分支 ${FORMATTED_BRANCH} 在上游既无分支也无发布 tag"
        return 1
      fi
      echo "分支 ${FORMATTED_BRANCH} 已被上游删除，回退到发布 tag: $latest_tag"
      sed -i "/path=\"common\"/ s|revision=\"${FORMATTED_BRANCH}\"|revision=\"refs/tags/${latest_tag}\"|" $DEFAULT_MANIFEST_PATH
      TAG_FALLBACK="$latest_tag"
    fi
  }

  attempt=1
  while :; do
    echo "第 $attempt/$MAX_ATTEMPTS 次初始化并同步，分支: common-${FORMATTED_BRANCH}（单次超时 $SYNC_TIMEOUT）"
    df -h "$PWD" | tail -n +2 || true

    rc=0
    if init_repo; then
      # 不加 --fail-fast：单个 project 出错时让其余 project 继续拉完，
      # 重试只需要补齐缺失部分。-j4 与 --no-clone-bundle 是为了避免
      # 高并发触发限流、以及跳过经常超时的 clone.bundle。
      SYNC_FLAGS="-c -j4 --jobs-checkout=4 --no-tags --no-clone-bundle --retry-fetches=3"
      # 第二次在原地续传（repo sync 可断点续传），第三次才整目录重来
      [ "$attempt" -gt 1 ] && SYNC_FLAGS="$SYNC_FLAGS --force-sync"
      timeout -k 60 "$SYNC_TIMEOUT" $REPO sync $SYNC_FLAGS || rc=$?
      if [ "$rc" -eq 0 ]; then
        echo "内核源码同步成功（第 $attempt 次）"
        break
      fi
      if [ "$rc" -eq 124 ]; then
        echo "repo sync 超时（$SYNC_TIMEOUT）"
      else
        echo "repo sync 失败，退出码 $rc"
      fi
    else
      rc=1
      echo "repo init 或分支预检失败"
    fi

    if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
      echo "::error::内核源码同步连续 $MAX_ATTEMPTS 次失败"
      exit "$rc"
    fi

    # 清理残留的 git-remote-https 进程：AOSP 连接停滞时会留下僵尸进程，
    # 占用文件句柄并导致后续 sync 以 "remote: error: RPC failed" 失败
    if [ "$rc" -ne 0 ]; then
      pkill -9 -f 'git-remote-https' 2>/dev/null || true
      pkill -9 -f 'android\.googlesource\.com' 2>/dev/null || true
      sleep 5
    fi

    # 最后一次重试前彻底清空：只删 .repo 会残留半检出的 project 目录，
    # 之后每次 sync 都会以 "Checking out local projects failed" 收场。
    if [ "$attempt" -eq $((MAX_ATTEMPTS - 1)) ]; then
      echo "清空工作目录后重来"
      # 用显式变量而不是 $PWD：这行是 -exec rm -rf，一旦所处目录不是内核源码根
      # （比如哪天有人把这段挪到别处、或 KERNEL_ROOT 为空导致 cd 失败），
      # 删掉的就是整个工作区——scripts/、config/ 一起没了，且报错信息完全指不到这里。
      # 三重校验：路径非空、必须是绝对路径、必须真的是内核源码根（有 common/ 或 .repo）。
      if [ -z "${KERNEL_ROOT}" ] || [[ "${KERNEL_ROOT}" != /* ]]; then
        echo "::error::KERNEL_ROOT 非法（'${KERNEL_ROOT}'），拒绝清空目录"
        exit 1
      fi
      if [ ! -d "${KERNEL_ROOT}/common" ] && [ ! -d "${KERNEL_ROOT}/.repo" ]; then
        echo "::error::${KERNEL_ROOT} 看起来不是内核源码根（缺 common/ 与 .repo），拒绝清空目录"
        exit 1
      fi
      echo "清空 ${KERNEL_ROOT} 后重来"
      find "${KERNEL_ROOT}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    fi

    echo "${RETRY_DELAY}s 后重试..."
    sleep "$RETRY_DELAY"
    attempt=$((attempt + 1))
  done

  export REMOTE_BRANCH="$REMOTE_BRANCH"
  export TAG_FALLBACK="$TAG_FALLBACK"

  cd "$_pwd"
}

run_sync_kernel_source() { stage_sync_kernel_source "$@"; }

stage_apply_stock_config() {
  log_stage "apply_stock_config" "应用 Stock Config 伪装"
  local _pwd="$PWD"
  STOCK_SRC="$WORKSPACE/config/stock_defconfig"
  STOCK_DST="$KERNEL_ROOT/common/arch/arm64/configs/stock_defconfig"

  if [ ! -f "$STOCK_SRC" ]; then
    echo "未检测到 $STOCK_SRC，跳过 Stock Config 伪装。"
    return 0
  fi

  mkdir -p "$(dirname "$STOCK_DST")"
  if ! cp "$STOCK_SRC" "$STOCK_DST"; then
    echo "::error::复制 stock_defconfig 失败: $STOCK_SRC -> $STOCK_DST"
    exit 1
  fi
  echo "已复制 stock_defconfig -> $STOCK_DST"

  NEW_RULE='$(obj)/config_data: arch/arm64/configs/stock_defconfig FORCE'
  OLD_RULE='$(obj)/config_data: $(KCONFIG_CONFIG) FORCE'
  TARGET_MAKEFILE="$KERNEL_ROOT/common/kernel/Makefile"

  if [ ! -f "$TARGET_MAKEFILE" ]; then
    echo "::error::未找到 $TARGET_MAKEFILE"
    exit 1
  fi

  if grep -qF "$NEW_RULE" "$TARGET_MAKEFILE"; then
    echo "config_data 规则已是 stock_defconfig，跳过。"
  elif grep -qF "$OLD_RULE" "$TARGET_MAKEFILE"; then
    sed -i 's|$(obj)/config_data: $(KCONFIG_CONFIG) FORCE|$(obj)/config_data: arch/arm64/configs/stock_defconfig FORCE|' "$TARGET_MAKEFILE"
    echo "已替换 config_data 规则: $TARGET_MAKEFILE"
  else
    echo "::error::未在 $TARGET_MAKEFILE 找到规则: $OLD_RULE"
    exit 1
  fi

  cd "$_pwd"
}

run_apply_stock_config() { stage_apply_stock_config "$@"; }

stage_extract_sublevel() {
  log_stage "extract_sublevel" "提取实际子版本号"
  local _pwd="$PWD"
  ACTUAL_SUBLEVEL="${SUB_LEVEL}"
  if [[ -f "$KERNEL_ROOT/common/Makefile" ]]; then
    EXTRACTED=$(grep '^SUBLEVEL = ' "$KERNEL_ROOT/common/Makefile" | awk '{print $3}')
    [[ -n "$EXTRACTED" ]] && ACTUAL_SUBLEVEL="$EXTRACTED"
  fi
  export ACTUAL_SUBLEVEL="$ACTUAL_SUBLEVEL"
  echo "实际子版本号: $ACTUAL_SUBLEVEL"

  # LTS (X) 构建：产物命名使用实际子版本号，而非输入值 X
  if [ "$SUB_LEVEL" = "X" ]; then
    CONFIG="${ANDROID_VERSION}-${KERNEL_VERSION}-${ACTUAL_SUBLEVEL}"
    echo "CONFIG=$CONFIG" >> "${GITHUB_ENV:-/dev/null}"
    NAME_SUBLEVEL="$ACTUAL_SUBLEVEL"
    echo "LTS 构建: 产物命名使用实际子版本号 $ACTUAL_SUBLEVEL"
  else
    NAME_SUBLEVEL="$SUB_LEVEL"
  fi
  export NAME_SUBLEVEL="$NAME_SUBLEVEL"
  echo "NAME_SUBLEVEL=$NAME_SUBLEVEL" >> "${GITHUB_ENV:-/dev/null}"

  cd "$_pwd"
}

run_extract_sublevel() { stage_extract_sublevel "$@"; }

stage_apply_cve_patch() {
  log_stage "apply_cve_patch" "自动应用 CVE-2026-43499 rtmutex 修复链"
  local _pwd="$PWD"
  cd "${KERNEL_ROOT}"/common
  bash "$WORKSPACE/security_patch/apply_cve_2026_43499.sh" \
    "${KERNEL_VERSION}" \
    "$ACTUAL_SUBLEVEL" \
    "$WORKSPACE/security_patch"

  cd "$_pwd"
}

# 条件执行（等价原工作流 if:）
run_apply_cve_patch() {
  if [ "$CVE_2026_43499_PATCH" = "true" ]; then
    stage_apply_cve_patch "$@"
  else
    echo "跳过阶段: apply_cve_patch（条件不满足）"
  fi
}

stage_fix_glibc() {
  log_stage "fix_glibc" "修复 glibc 2.38 兼容性"
  local _pwd="$PWD"
  cd "${KERNEL_ROOT}"/common
  RAW_SUB="${SUB_LEVEL}"
  [[ ! "$RAW_SUB" =~ ^[0-9]+$ ]] && CURRENT_SUB=99999 || CURRENT_SUB=$RAW_SUB

  NEEDS_FIX=false
  if [[ "${ANDROID_VERSION}" == "android13" && "${KERNEL_VERSION}" == "5.10" && $CURRENT_SUB -le 186 ]] ||
     [[ "${ANDROID_VERSION}" == "android13" && "${KERNEL_VERSION}" == "5.15" && $CURRENT_SUB -le 119 ]] ||
     [[ "${ANDROID_VERSION}" == "android14" && "${KERNEL_VERSION}" == "6.1" && $CURRENT_SUB -le 43 ]]; then
    NEEDS_FIX=true
  fi

  if [ "$NEEDS_FIX" = true ]; then
    GLIBC_VERSION=$(ldd --version 2>/dev/null | head -n 1 | awk '{print $NF}')
    if [ "$(printf '%s\n' "2.38" "$GLIBC_VERSION" | sort -V | head -n1)" = "2.38" ]; then
      echo "应用 glibc 2.38 兼容性修复..."
      sed -i '/\$(Q)\$(MAKE) -C \$(SUBCMD_SRC) OUTPUT=\$(abspath \$(dir \$@))\/ \$(abspath \$@)/s//$(Q)$(MAKE) -C $(SUBCMD_SRC) EXTRA_CFLAGS="$(CFLAGS)" OUTPUT=$(abspath $(dir $@))\/ $(abspath $@)/' tools/bpf/resolve_btfids/Makefile 2>/dev/null || true

      if [[ "${KERNEL_VERSION}" == "5.10" || "${KERNEL_VERSION}" == "5.15" ]]; then
        sed -i '/char \*buf = NULL;/a int i;' tools/lib/subcmd/parse-options.c 2>/dev/null || true
        sed -i 's/for (int i = 0; subcommands\[i\]; i++) {/for (i = 0; subcommands[i]; i++) {/' tools/lib/subcmd/parse-options.c 2>/dev/null || true
        sed -i '/if (subcommands) {/a int i;' tools/lib/subcmd/parse-options.c 2>/dev/null || true
        sed -i 's/for (int i = 0; subcommands\[i\]; i++)/for (i = 0; subcommands[i]; i++)/' tools/lib/subcmd/parse-options.c 2>/dev/null || true
      fi
    fi
  fi

  cd "$_pwd"
}

run_fix_glibc() { stage_fix_glibc "$@"; }

stage_add_oneplus8e() {
  log_stage "add_oneplus8e" "添加一加 8E 处理器支持"
  local _pwd="$PWD"
  cd "${KERNEL_ROOT}"/common/drivers

  # 优先用仓库里随版本固定的副本（hmbird_patch.c）。
  # 优先使用仓库内的固定副本，缺失时再从上游下载并校验。
  if [ -f "${WORKSPACE}/hmbird_patch.c" ]; then
    echo "使用仓库内的 hmbird_patch.c"
    cp "${WORKSPACE}/hmbird_patch.c" ./hmbird_patch.c
  else
    echo "仓库内无副本，从上游获取 hmbird_patch.c..."
    # 该文件会参与内核编译，下载后先校验 C 源码特征。
    if ! fetch_remote_script \
        "https://github.com/zzh20188/GKI_KernelSU_SUSFS/raw/refs/heads/dev/hmbird_patch.c" \
        hmbird_patch.c "hmbird_patch.c" \
        '#include|static[[:space:]]+(int|void|struct)|HMBIRD'; then
      echo "::error::hmbird_patch.c 获取或校验失败，一加 8E 支持无法启用"
      cd "$_pwd"
      return 1
    fi
    echo "::warning::hmbird_patch.c 取自上游 dev 分支（未钉 commit），内容随上游变动"
  fi

  # 重复运行时不要往 Makefile 里堆重复行
  if ! grep -q 'obj-y += hmbird_patch.o' Makefile; then
    echo "obj-y += hmbird_patch.o" >> Makefile
  fi

  cd "$_pwd"
}

# 条件执行（等价原工作流 if:）
run_add_oneplus8e() {
  if [ "$SUPP_OP" = "true" ]; then
    stage_add_oneplus8e "$@"
  else
    echo "跳过阶段: add_oneplus8e（条件不满足）"
  fi
}

# 计算 SukiSU 的 KSU_VERSION，基准固定为 main 分支的提交数。
#
# 为什么必须用 main 而不是当前 HEAD：
#   builtin 是与 main 无共同祖先的独立分支（提交数 802，main 为 3737）。两者
#   VERSION_BASE/VERSION_OFFSET 相同，若按 HEAD 计数，builtin 会得到
#   40000+802-2815=37987，而管理器（只能来自 main）是 40922，版本不匹配则闪退。
#   上游 kernel/Makefile 里写死 REPO_BRANCH := main 正是这个原因。
#
# 依赖 KernelSU/ 目录（本函数内自行 cd，不改变调用方 cwd）。
resolve_sukisu_version() {
  local ksu_dir="KernelSU" count="" api_count="" local_count=""

  [ -d "$ksu_dir/.git" ] || { echo "::error::找不到 $ksu_dir/.git"; return 1; }

  # 首选 GitHub API：main 分支提交总数 = Link 头里最后一页的页码
  api_count=$(curl -sI "https://api.github.com/repos/SukiSU-Ultra/SukiSU-Ultra/commits?sha=main&per_page=1" 2>/dev/null |
    grep -i "^link:" | sed -n 's/.*page=\([0-9]*\)>; rel="last".*/\1/p')

  # 兜底用本地 main 的计数（全量克隆时可用）
  if git -C "$ksu_dir" rev-parse --verify -q refs/remotes/origin/main >/dev/null 2>&1; then
    local_count=$(git -C "$ksu_dir" rev-list --count refs/remotes/origin/main 2>/dev/null)
  elif git -C "$ksu_dir" rev-parse --verify -q refs/heads/main >/dev/null 2>&1; then
    local_count=$(git -C "$ksu_dir" rev-list --count refs/heads/main 2>/dev/null)
  fi

  # 两者都拿到时取较大值：API 可能因分支默认值变化而偏小，本地可能因浅克隆而偏小
  if [ -n "$api_count" ] && [ -n "$local_count" ]; then
    if [ "$api_count" -ge "$local_count" ] 2>/dev/null; then count="$api_count"; else count="$local_count"; fi
  elif [ -n "$api_count" ]; then
    count="$api_count"
  elif [ -n "$local_count" ]; then
    count="$local_count"
  fi

  # 都拿不到时的最后回退：只能信 HEAD。此时若在 builtin 上会偏低，
  # 明确告警而不是悄悄给出错误版本号。
  if [ -z "$count" ]; then
    count=$(git -C "$ksu_dir" rev-list --count HEAD 2>/dev/null)
    echo "::warning::SukiSU 无法取得 main 提交数，回退 HEAD=$count（若在 builtin 分支则版本号会偏低）"
  fi

  case "$count" in
    ''|*[!0-9]*) echo "::error::SukiSU 提交数解析异常: '$count'"; return 1 ;;
  esac
  [ "$count" -gt 0 ] || { echo "::error::SukiSU 提交数为 0"; return 1; }

  echo $((40000 + count - 2815))
}

stage_resolve_ksu_branch() {
  log_stage "resolve_ksu_branch" "确定 KernelSU 分支"
  local _pwd="$PWD"
  variant_input="${KSU_VARIANT}"

  # KSU_BRANCH_MODE 手动指定分支：
  #   auto    —— 默认。SukiSU 开 SUSFS 走 builtin，关 SUSFS 走 main
  #   main    —— 强制 main（纯管理器分支，内核侧只有薄 hook 层）
  #   builtin —— 强制 builtin（内核侧内置完整 KernelSU 实现，SUSFS 需要的能力更全）
  # 仅对 SukiSU 生效；其他变体忽略此开关。
  BRANCH_MODE="${KSU_BRANCH_MODE:-auto}"

  case "$variant_input" in
    "Official"|"BakaSU")
      BRANCH="main"
      ;;
    "FinaSU")
      BRANCH="master"
      ;;
    "SukiSU")
      case "$BRANCH_MODE" in
        main)
          BRANCH="main"
          echo "SukiSU: 手动指定 main 分支"
          ;;
        builtin)
          BRANCH="builtin"
          echo "SukiSU: 手动指定 builtin 分支"
          ;;
        *)
          if [ "${ENABLE_SUSFS}" = "false" ]; then
            BRANCH="main"
          else
            BRANCH="builtin"
          fi
          echo "SukiSU: auto 模式（ENABLE_SUSFS=${ENABLE_SUSFS}）→ $BRANCH"
          ;;
      esac
      ;;
    "Next")
      # 曾写 dev_susfs：KernelSU-Next 的 setup.sh 用的是
      # `git checkout "$1" || echo "[-] Checkout default branch"`，ref 不存在会被
      # 静默吞掉、回落到默认分支，写错分支名照样"成功"收尾。上游 dev 分支下
      # kernel/Kconfig 里现在已无 KSU_SUSFS_* 开关，dev_susfs 这个 ref 也不存在
      # （实测 404），所以直接写死实际存在的 dev，失败要炸出来而不是静默回落。
      BRANCH="dev"
      ;;
    *)
      if [ -z "$LEGACY_SUKISU_CONFIG" ] || [ ! -f "$LEGACY_SUKISU_CONFIG" ]; then
        echo "未知变体: $variant_input" >&2
        exit 1
      fi
      SUKISU_FIXED_COMMIT=$(grep "^sukisu=" "$LEGACY_SUKISU_CONFIG" | cut -d'=' -f2-)
      if [ -z "$SUKISU_FIXED_COMMIT" ]; then
        echo "未在 $LEGACY_SUKISU_CONFIG 配置 SukiSU 固定提交" >&2
        exit 1
      fi
      # 与下方 PINNED_COMMIT 一致：来自配置文件的值同样要过 hex 校验，
      # 否则一行被污染的配置就能把任意字符串带进下游 git 操作。
      if [[ ! "$SUKISU_FIXED_COMMIT" =~ ^[0-9a-fA-F]{40}$ && ! "$SUKISU_FIXED_COMMIT" =~ ^[0-9a-fA-F]{64}$ ]]; then
        echo "::error::$LEGACY_SUKISU_CONFIG 的 sukisu= 不是合法的 commit hash（要求 40 位 SHA-1 或 64 位 SHA-256 的 hex）：$SUKISU_FIXED_COMMIT" >&2
        exit 1
      fi
      BRANCH="$SUKISU_FIXED_COMMIT"
      ;;
  esac

  # 统一 SukiSU 提交来源：CI 传入的 SUKISU_COMMIT 环境变量优先于 config/config，
  # 与 get-manager.yml 完全对齐（之前只从 config/config 的 sukisu= 行读取，且依赖
  # build.yml 的 sed 改写与 custom=true 标志，任一环节缺失内核就会退回默认分支/最新）。
  # 指定提交时内核与管理器必须来自同一个 commit，版本才能一致。
  PINNED_COMMIT="${SUKISU_COMMIT:-}"
  CONFIG_FILE="config/config"
  if [ -z "$PINNED_COMMIT" ] && [ -f "$CONFIG_FILE" ]; then
    CUSTOM_ENABLED=$(grep "^custom=" "$CONFIG_FILE" | cut -d'=' -f2)
    if [ "$CUSTOM_ENABLED" == "true" ] && [ "$variant_input" == "SukiSU" ]; then
      PINNED_COMMIT=$(grep "^sukisu=" "$CONFIG_FILE" | cut -d'=' -f2)
    fi
  fi
  if [ -n "$PINNED_COMMIT" ] && [ "$variant_input" == "SukiSU" ]; then
    # 长度 + 字符集双重校验。只判长度不够：`$PINNED_COMMIT` 会作为位置参数交给
    # `bash -s "$BRANCH"`，虽然双引号挡住了命令替换，但 `--xxx` 形态会被 bash 当成
    # 选项解析（实测报 "invalid option"），含空格/控制字符的值也会污染下游 git 操作。
    # commit hash 的合法字符集固定为 [0-9a-f]，这里 fail-closed。
    if [[ ! "$PINNED_COMMIT" =~ ^[0-9a-fA-F]{40}$ && ! "$PINNED_COMMIT" =~ ^[0-9a-fA-F]{64}$ ]]; then
      echo "::warning::忽略非法 SukiSU 提交: ${PINNED_COMMIT}（要求 40 位 SHA-1 或 64 位 SHA-256 的 hex，改用默认分支）"
    else
      BRANCH="$PINNED_COMMIT"
      echo "SukiSU 使用自定义提交: $PINNED_COMMIT"
      # 固定提交无法从名字判断血统，只能靠下面的分支复核（setup 之后用 git 实际
      # checkout 结果比对）兜底。这里先提示一次，避免拿 main 血统的提交配 SUSFS。
      if [ "${ENABLE_SUSFS}" = "true" ]; then
        echo "::warning::SukiSU 固定提交 + SUSFS：请确认 $PINNED_COMMIT 属于 builtin 血统（kernel/feature/selinux_hide.c 中不应出现 ksu_patch_text），否则 SELinux 隐藏会失效"
      fi
    fi
  fi

  # KernelSU-Next 的 dev 分支没有 KSU_SUSFS_* 开关，勾了 SUSFS 只会走到
  # verify_susfs_kconfig 抛"未声明 N/N 个 SUSFS 开关"，看不出是变体选错了。
  # 这里提前拦掉，并直说该换哪个变体。
  if [ "$variant_input" = "Next" ] && [ "${ENABLE_SUSFS}" = "true" ]; then
    echo "::error::KernelSU-Next（dev 分支）未提供 SUSFS 开关，不能同时勾选「集成 SUSFS」"
    echo "::error::需要 SUSFS 请改用 BakaSU 或 SukiSU（auto 模式会自动选 builtin）"
    return 1
  fi

  # SUSFS 补丁把 selinuxfs.c 的 context_write / access_write / sel_open_handle_status
  # 整支换成了 my_write_context / my_write_access / my_sel_open_handle_status；
  # 而 SukiSU 的 main 分支用 ksu_patch_text 在运行时改写这三个函数的函数体开头
  # （selinux_hide.c 的 356 / 366 / 404 行）。同一组函数被两套机制各改一次，
  # 结果是 SELinux 隐藏失效——u:r:ksu:s0 这类真实上下文会泄漏出去。
  # builtin 分支的 selinux_hide.c 里 ksu_patch_text 出现 0 次，只提供 fake_state
  # 把 LSM 层交给 SUSFS 补丁处理，才是配套组合。
  # 所以「main + SUSFS」这个必然产出坏内核的组合要显式确认才能继续。
  if [ "$variant_input" = "SukiSU" ] && [ "$BRANCH" = "main" ] \
     && [ "${ENABLE_SUSFS}" = "true" ] && [ "${ALLOW_SUSFS_WITH_MAIN:-0}" != "1" ]; then
    echo "::error::SukiSU main 分支不能配 SUSFS：main 用 ksu_patch_text 改写 context_write/access_write/sel_open_handle_status，与 SUSFS 补丁的 my_* 替换互相覆盖，SELinux 隐藏会失效"
    echo "::error::请改用 builtin（auto 模式在 ENABLE_SUSFS=true 时自动选 builtin）或关闭 SUSFS；确知后果要继续请设 ALLOW_SUSFS_WITH_MAIN=1"
    return 1
  fi

  # BRANCH 为纯 ref（分支名或 commit hash），不再带 "-s" 前缀。
  # SukiSU/KernelSU 官方/BakaSU 的 setup.sh 用法是 `setup.sh [--cleanup | <commit-or-tag>]`，
  # 将 ref 作为位置参数传入，避免把选项误作分支名。
  # 位置参数，git checkout "-s builtin" 报 unknown switch 后静默回退默认分支，
  # 导致"说要 builtin 实际编了 main"。调用侧统一改回 `bash -s "$BRANCH"`。
  export BRANCH="$BRANCH"
  echo "KSU 分支: $BRANCH (mode=$BRANCH_MODE)"

  cd "$_pwd"
}

# 条件执行（等价原工作流 if:）
run_resolve_ksu_branch() {
  if [ "$KSU_MODE" != "禁用KSU" ]; then
    stage_resolve_ksu_branch "$@"
  else
    echo "跳过阶段: resolve_ksu_branch（条件不满足）"
  fi
}

# 下载上游脚本并做内容校验（供应链风险兜底）。
#
# curl -f / wget -q 只保证 HTTP 成功，不足以判断拿到的是脚本：CDN 错误页、
# 被劫持的空壳、截断的半截文件都能以 200 返回。这里要求「非空 + 可读 + 含
# shell 脚本痕迹」，不满足即拒绝（fail-closed），避免把来路不明的内容交给 bash。
#
# 供 KernelSU、BBG 等需要下载并执行 setup 脚本的阶段共用。
#
# 用法: fetch_remote_script <url> <输出路径> <标签> [特征正则] [wget]
#   特征正则默认匹配 shell/KernelSU/setup 字样；调用方应按被下载脚本的
#   实际内容给出更贴合的特征，避免校验形同虚设。
fetch_remote_script() {
  local url="$1" out="$2" label="$3"
  local pattern="${4:-'(^|[[:space:]])sh[[:space:]]|#!/|KernelSU|setup'}"
  local use_wget="${5:-false}"

  # 先清掉可能存在的旧文件：校验失败时若不删，磁盘上就会留一份"上一次成功下载
  # 的脚本"，后续任何按 -f/-s 判断要不要执行的地方都可能误用它。
  rm -f "$out"

  local fetch_rc=0
  if [ "$use_wget" = "true" ]; then
    wget --tries=3 --timeout=30 -q -O "$out" "$url" || fetch_rc=$?
  else
    curl -LSsf --retry 3 --retry-delay 2 --connect-timeout 30 "$url" -o "$out" || fetch_rc=$?
  fi
  if [ "$fetch_rc" -ne 0 ]; then
    echo "::error::下载 ${label} 失败（exit=$fetch_rc）: $url"
    rm -f "$out"
    return 1
  fi
  if [ ! -s "$out" ]; then
    echo "::error::${label} 内容为空（疑似 CDN 错误页或下载截断），拒绝执行"
    rm -f "$out"
    return 1
  fi
  if ! grep -qE "$pattern" "$out"; then
    echo "::error::${label} 内容不像预期脚本（未匹配特征 /${pattern}/），拒绝执行"
    rm -f "$out"
    return 1
  fi
  echo "${label} 校验通过（$(wc -c < "$out") 字节）"
  return 0
}

stage_add_kernelsu() {
  log_stage "add_kernelsu" "添加 KernelSU"
  local _pwd="$PWD"
  cd "${KERNEL_ROOT}"
  # 上游 setup.sh 下载后先做内容校验再执行（供应链风险兜底）。
  fetch_ksu_setup() {
    fetch_remote_script "$1" /tmp/ksu_setup.sh "$2" \
      '(^|[[:space:]])sh[[:space:]]|#!/|KernelSU|setup' || return 1
  }

  case "${KSU_VARIANT}" in
    "Official")
      echo "添加 KernelSU 官方版..."
      # 下载后显式校验再执行（不钉 commit，跟随上游 main 分支）
      KSU_SETUP="https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh"
      fetch_ksu_setup "$KSU_SETUP" "KernelSU 官方" || return 1
      bash -s "$BRANCH" < /tmp/ksu_setup.sh || { echo "::error::KernelSU 官方 setup.sh 执行失败"; return 1; }

      cd KernelSU
      KSU_GIT_VERSION=$(git rev-list --count HEAD)
      KSU_VERSION=$((20000 + KSU_GIT_VERSION))
      export KSU_VERSION="$KSU_VERSION"

      if [ -f "kernel/Kbuild" ]; then
        sed -i "s/DKSU_VERSION=16/DKSU_VERSION=${KSU_VERSION}/" kernel/Kbuild
      fi
      cd ..
      ;;
    "Next")
      echo "添加 KernelSU-Next..."
      # 下载后显式校验再执行（不钉 commit，跟随上游 dev 分支）
      KSU_SETUP="https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/refs/heads/dev/kernel/setup.sh"
      fetch_ksu_setup "$KSU_SETUP" "KernelSU-Next" || return 1
      bash -s "$BRANCH" < /tmp/ksu_setup.sh || { echo "::error::KernelSU-Next setup.sh 执行失败"; return 1; }
      ;;
    "SukiSU")
      echo "添加 ${KSU_VARIANT}..."
      # 下载后显式校验再执行（不钉 commit，跟随上游 main 分支）
      KSU_SETUP="https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh"
      fetch_ksu_setup "$KSU_SETUP" "SukiSU" || return 1
      bash -s "$BRANCH" < /tmp/ksu_setup.sh || { echo "::error::SukiSU setup.sh 执行失败"; return 1; }

      # 版本号处理：以 main 分支提交数为基准，且直接沿用上游的计算口径。
      #
      # 不能写 `git rev-list --count HEAD` 再套公式：
      #   builtin 是与 main 无共同祖先的独立分支（提交数 802，main 为 3737），
      #   按 HEAD 计数会得出 40000+802-2815=37987，而管理器（来自 main）是 40922，
      #   管理器启动比对版本失败即闪退。
      #
      # 上游 kernel/Makefile（builtin）与 kernel/Kbuild（main）里都已经做了正确处理：
      #   REPO_BRANCH := main
      #   GITHUB_COMMITS := curl ".../commits?sha=main&per_page=1"   # 网络取 main 总数
      #   LOCAL_COUNT := $(if $(GITHUB_COMMITS),$(GITHUB_COMMITS),$(git rev-list --count main))
      #   KSU_VERSION := $(VERSION_BASE + LOCAL_COUNT - VERSION_OFFSET)
      # 所以我们只做校验与兜底，不再自行改写版本号。
      #
      # builtin 的版本定义位于 kernel/Makefile，不在 kernel/Kbuild。
      if [ -d "KernelSU/.git" ]; then
        KSU_VERSION=$(resolve_sukisu_version) || {
          echo "::error::SukiSU 版本号解析失败"; return 1;
        }
        export KSU_VERSION="$KSU_VERSION"
        echo "SukiSU KSU_VERSION（main 基准）= $KSU_VERSION"

        # 仅在文件存在时做一次显式对齐，覆盖上游可能因网络受限而退化的取值。
        # 用 [0-9][0-9]* 匹配，避免把 \$(KSU_VERSION) 这类变量引用误伤。
        if [ -f "KernelSU/kernel/Kbuild" ]; then
          sed -i "s/\bDKSU_VERSION=[0-9][0-9]*/DKSU_VERSION=${KSU_VERSION}/" KernelSU/kernel/Kbuild
        fi
        if [ -f "KernelSU/kernel/Makefile" ]; then
          sed -i "s/\bVERSION_BASE[[:space:]]*:=[[:space:]]*[0-9][0-9]*/VERSION_BASE    := 40000/" KernelSU/kernel/Makefile
          sed -i "s/\bVERSION_OFFSET[[:space:]]*:=[[:space:]]*[0-9][0-9]*/VERSION_OFFSET  := 2815/" KernelSU/kernel/Makefile
        fi
      fi
      ;;
    "BakaSU")
      echo "添加 BakaSU..."
      # 下载后显式校验再执行（默认跟随上游 main 分支）
      KSU_SETUP="https://raw.githubusercontent.com/Baka-SU/BakaSU/main/kernel/setup.sh"
      fetch_ksu_setup "$KSU_SETUP" "BakaSU" || return 1
      bash -s "$BRANCH" < /tmp/ksu_setup.sh || { echo "::error::BakaSU setup.sh 执行失败"; return 1; }

      # [对齐] 内核侧 KernelSU 检出到所选官方 Manager 构建的同一提交
      #（Kbuild 以 30700 + git 提交数 计算版本，与官方管理器 versionCode 同源同值），
      # 保证内核 KSU 版本与拉取的管理器安装包严格一致。KSU_COMMIT 为空 = 跟随 main HEAD。
      if [ -n "${KSU_COMMIT:-}" ]; then
        echo "KernelSU 对齐官方 Manager 构建提交: $KSU_COMMIT"
        if ! git -C KernelSU checkout --detach "$KSU_COMMIT" 2>/dev/null; then
          git -C KernelSU fetch --no-tags origin "$KSU_COMMIT" >/dev/null 2>&1 \
            || { echo "::error::无法 fetch KernelSU 对齐提交 $KSU_COMMIT"; return 1; }
          git -C KernelSU checkout --detach "$KSU_COMMIT" \
            || { echo "::error::无法检出 KernelSU 对齐提交 $KSU_COMMIT"; return 1; }
        fi
        if [ "$(git -C KernelSU rev-parse HEAD 2>/dev/null)" != "$KSU_COMMIT" ]; then
          echo "::error::KernelSU 检出官方构建提交 $KSU_COMMIT 失败，无法对齐管理器版本"
          return 1
        fi
        echo "KernelSU 已对齐到 $KSU_COMMIT（KSU 版本 = $((30700 + $(git -C KernelSU rev-list --count HEAD 2>/dev/null || echo 0)))）"
      fi
      ;;
    "FinaSU")
      echo "添加 FinaSU..."
      if [ -z "${KSU_COMMIT:-}" ] || [ -z "$KSU_CERT_SIZE" ] || [ -z "$KSU_CERT_HASH" ]; then
        REL_JSON=$(curl -fsSL --retry 3 --retry-all-errors --max-time 60 \
          https://api.github.com/repos/LyraVoid/FinaSU/releases/latest) \
          || { echo "::error::无法读取 FinaSU 最新 Release"; return 1; }
        REL_TAG=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])' <<< "$REL_JSON")
        if [ -z "${KSU_COMMIT:-}" ]; then
          KSU_COMMIT=$(curl -fsSL --retry 3 --retry-all-errors --max-time 60 \
            "https://api.github.com/repos/LyraVoid/FinaSU/commits/$REL_TAG" \
            | python3 -c 'import json,sys; print(json.load(sys.stdin)["sha"])') \
            || { echo "::error::无法解析 FinaSU Release 对应提交"; return 1; }
          [[ "$KSU_COMMIT" =~ ^[0-9a-fA-F]{40}$ ]] \
            || { echo "::error::FinaSU Release 返回了无效提交号"; return 1; }
          export KSU_COMMIT
        fi
        if [ -z "$KSU_CERT_SIZE" ] || [ -z "$KSU_CERT_HASH" ]; then
          REL_APK_URL=$(python3 -c 'import json,sys; d=json.load(sys.stdin); a=[x for x in d.get("assets",[]) if x.get("name","").endswith("-release.apk")]; print(a[0]["browser_download_url"] if a else "")' <<< "$REL_JSON")
          [ -n "$REL_APK_URL" ] || { echo "::error::FinaSU Release 未附正式签名的 release APK"; return 1; }
          TMP_APK_DIR=$(mktemp -d)
          curl -fL --retry 3 --retry-all-errors --connect-timeout 20 --max-time 300 \
            -o "$TMP_APK_DIR/manager.apk" "$REL_APK_URL" \
            || { echo "::error::下载 FinaSU Release APK 失败"; return 1; }
          CERT_INFO=$(python3 "$WORKSPACE/scripts/finasu_compat/extract_manager_cert.py" "$TMP_APK_DIR/manager.apk") \
            || { echo "::error::无法提取 FinaSU 管理器签名证书"; return 1; }
          rm -rf "$TMP_APK_DIR"
          KSU_CERT_SIZE=$(awk 'NR == 1 {print $1}' <<< "$CERT_INFO")
          KSU_CERT_HASH=$(awk 'NR == 1 {print $2}' <<< "$CERT_INFO")
          export KSU_CERT_SIZE KSU_CERT_HASH
        fi
      fi
      git clone --depth 1 https://github.com/LyraVoid/FinaSU.git KernelSU || {
        echo "::error::克隆 FinaSU 失败"; return 1;
      }
      if [ -n "${KSU_COMMIT:-}" ]; then
        if ! git -C KernelSU checkout --detach "$KSU_COMMIT" 2>/dev/null; then
          git -C KernelSU fetch --no-tags origin "$KSU_COMMIT" \
            || { echo "::error::无法获取 FinaSU Release 对应提交 $KSU_COMMIT"; return 1; }
          git -C KernelSU checkout --detach "$KSU_COMMIT" \
            || { echo "::error::无法检出 FinaSU Release 对应提交 $KSU_COMMIT"; return 1; }
        fi
        [ "$(git -C KernelSU rev-parse HEAD)" = "$KSU_COMMIT" ] \
          || { echo "::error::FinaSU 未检出到管理器 Release 对应提交"; return 1; }
      else
        echo "::error::缺少 FinaSU 管理器 Release 对应提交，拒绝生成版本不匹配的内核"
        return 1
      fi

      DRIVER_DIR="$KERNEL_ROOT/common/drivers"
      [ -d "$DRIVER_DIR" ] || { echo "::error::未找到 GKI drivers 目录: $DRIVER_DIR"; return 1; }
      ln -sfn "$(realpath --relative-to="$DRIVER_DIR" "$KERNEL_ROOT/KernelSU/kernel")" "$DRIVER_DIR/kernelsu"
      grep -qE 'obj-.*CONFIG_KSU.*kernelsu/' "$DRIVER_DIR/Makefile" \
        || echo 'obj-$(CONFIG_KSU) += kernelsu/' >> "$DRIVER_DIR/Makefile"
      if ! grep -q 'source "drivers/kernelsu/Kconfig"' "$DRIVER_DIR/Kconfig"; then
        sed -i '/endmenu/i source "drivers/kernelsu/Kconfig"' "$DRIVER_DIR/Kconfig"
      fi

      if [ -z "$KSU_CERT_SIZE" ] || [ -z "$KSU_CERT_HASH" ]; then
        echo "::error::未取得官方 FinaSU 管理器签名证书，无法让内核识别管理器"
        return 1
      fi
      if [[ ! "$KSU_CERT_SIZE" =~ ^0x[0-9a-fA-F]{1,4}$ ]] || [[ ! "$KSU_CERT_HASH" =~ ^[0-9a-fA-F]{64}$ ]]; then
        echo "::error::FinaSU 管理器证书信息格式无效"
        return 1
      fi
      KBUILD_FILE="KernelSU/kernel/Kbuild"
      [ -f "$KBUILD_FILE" ] || { echo "::error::FinaSU Kbuild 文件不存在"; return 1; }
      if ! grep -qE '^ccflags-y[[:space:]]*\+=[[:space:]]*-DEXPECTED_HASH=' "$KBUILD_FILE"; then
        echo "::error::FinaSU Kbuild 缺少 EXPECTED_HASH 锚点，无法配置第二管理器证书槽"
        return 1
      fi
      if ! grep -q '^KSU_EXPECTED_SIZE2[[:space:]]*:=' "$KBUILD_FILE"; then
        awk -v size="$KSU_CERT_SIZE" -v hash="$KSU_CERT_HASH" '
          !done && /^ccflags-y[[:space:]]*\+=[[:space:]]*-DEXPECTED_HASH=/ {
            print
            print "KSU_EXPECTED_SIZE2 := " size
            print "KSU_EXPECTED_HASH2 := " hash
            print "KSU_SECOND_SIGNATURE_RELEASE := 1"
            done=1
            next
          }
          { print }
          END { if (!done) exit 1 }
        ' "$KBUILD_FILE" > "$KBUILD_FILE.new" \
          && mv "$KBUILD_FILE.new" "$KBUILD_FILE" \
          || { rm -f "$KBUILD_FILE.new"; echo "::error::写入 FinaSU 证书信任配置失败"; return 1; }
      else
        sed -i -E \
          -e "s|^KSU_EXPECTED_SIZE2[[:space:]]*:=.*|KSU_EXPECTED_SIZE2 := $KSU_CERT_SIZE|" \
          -e "s|^KSU_EXPECTED_HASH2[[:space:]]*:=.*|KSU_EXPECTED_HASH2 := $KSU_CERT_HASH|" \
          "$KBUILD_FILE"
      fi
      grep -q '^KSU_SECOND_SIGNATURE_RELEASE[[:space:]]*:= 1$' "$KBUILD_FILE" \
        || echo 'KSU_SECOND_SIGNATURE_RELEASE := 1' >> "$KBUILD_FILE"
      echo "已将官方 FinaSU 管理器证书写入内核第二信任槽"
      ;;
    *)
      if [ -z "$LEGACY_SUKISU_CONFIG" ]; then
        echo "未知变体: ${KSU_VARIANT}" >&2
        exit 1
      fi
      echo "添加 ${KSU_VARIANT}..."
      # 下载后显式校验再执行（不钉 commit，跟随上游 main 分支）
      KSU_SETUP="https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh"
      fetch_ksu_setup "$KSU_SETUP" "SukiSU" || return 1
      bash -s "$BRANCH" < /tmp/ksu_setup.sh || { echo "::error::SukiSU setup.sh 执行失败"; return 1; }
      ;;
  esac

  # setup.sh 内部是 `git checkout "$1" ... || echo "[-] Checkout default branch"`：
  # 复核 KernelSU 实际分支或提交；与预期不符时终止构建。
  KSU_EXPECT_REF="${KSU_COMMIT:-$BRANCH}"
  if [ -d "KernelSU/.git" ] && [ -n "$KSU_EXPECT_REF" ]; then
    KSU_ACTUAL_BRANCH=$(git -C KernelSU rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    KSU_ACTUAL_HEAD=$(git -C KernelSU rev-parse HEAD 2>/dev/null || echo "")
    # 期望值既可能是分支名也可能是 40/64 位 commit（后者是 detached HEAD，
    # --abbrev-ref 会返回 HEAD），两种形态都要认；对齐时 KSU_COMMIT 优先。
    if [ "$KSU_ACTUAL_BRANCH" != "$KSU_EXPECT_REF" ] && [[ "$KSU_ACTUAL_HEAD" != "$KSU_EXPECT_REF"* ]]; then
      echo "::error::KernelSU 分支未生效：期望 $KSU_EXPECT_REF，实际分支=$KSU_ACTUAL_BRANCH HEAD=$KSU_ACTUAL_HEAD"
      return 1
    fi
    echo "KernelSU 分支校验通过：$KSU_EXPECT_REF（HEAD=${KSU_ACTUAL_HEAD:0:9}）"

    # 终极防线：直接看源码有没有 ksu_patch_text。分支名/提交号都可能骗人，
    # 但"这段内核里到底有没有在运行时改写 context_write/access_write/
    # sel_open_handle_status"骗不了人——有就和 SUSFS 的 my_* 替换打架。
    #
    # 例外：下游（BakaSU）官方为 SUSFS 做了共存适配——
    #   kernel/tools/susfs_compat.mk 在 CONFIG_KSU_SUSFS 下检测
    #   security/selinux/hooks.c 是否含 SUSFS 注入的 ksu_selinux_hide_running，
    #   命中就加 -DKSU_COMPAT_HAS_SUSFS_FEATURE_SELINUX_HIDE，把 selinux_hide.c
    #   里整段 ksu_patch_text 用 #ifndef 剔除。这类源码里 grep ksu_patch_text
    #   必然命中，但编译出来是干净内核，按"main 血统"拦就是误报。
    # FinaSU 的 SUSFS 适配在 apply_susfs 阶段才会替换这段 hook；此处检查的是
    # 尚未适配的上游源码，不能据此判断最终组合。适配脚本会在补丁落地后检查结果。
    if [ "${ENABLE_SUSFS}" = "true" ] && [ "${KSU_VARIANT}" != "FinaSU" ] \
       && [ -f "KernelSU/kernel/feature/selinux_hide.c" ]; then
      KSU_HIDE_SRC="KernelSU/kernel/feature/selinux_hide.c"
      if grep -q "KSU_COMPAT_HAS_SUSFS_FEATURE_SELINUX_HIDE" "$KSU_HIDE_SRC"; then
        echo "SELinux 兼容性校验通过：selinux_hide.c 的 ksu_patch_text 受 KSU_COMPAT_HAS_SUSFS_FEATURE_SELINUX_HIDE 包裹"
        echo "  SUSFS 补丁把 ksu_selinux_hide_running 注入 hooks.c 后，susfs_compat.mk 会定义该宏，"
        echo "  上述补丁代码在编译期被 #ifndef 剔除（BakaSU 官方共存机制，非冲突）"
      elif grep -q "ksu_patch_text" "$KSU_HIDE_SRC"; then
        echo "::error::KernelSU 源码含 ksu_patch_text（main 血统），与 SUSFS 的 SELinux 补丁冲突，隐藏必然失效"
        echo "::error::请切到 builtin 分支；确知后果要继续请设 ALLOW_SUSFS_WITH_MAIN=1"
        [ "${ALLOW_SUSFS_WITH_MAIN:-0}" = "1" ] || return 1
      else
        echo "SELinux 兼容性校验通过：selinux_hide.c 无 ksu_patch_text（与 SUSFS 补丁配套）"
      fi
    fi
  fi

  # KPM 是 SukiSU-Ultra 独有的模块加载功能，KernelSU 官方 / BakaSU / KernelSU-Next
  # 均未提供 KPM Kconfig。提前检查，避免源码准备完成后才发现该组合不受支持。
  # 这里在 KernelSU 源码就位后立刻查。
  #
  # 要区分两种「没有 KPM」：
  #   1) 变体本身就不提供（BakaSU / Official / Next）——这是上游的既定事实，
  #      警告后跳过即可。默认变体已切到 BakaSU，而 use_kpm 默认仍是「patched」，
  #      硬失败会让整条默认链路（含自动更新）一次都跑不起来。
  #   2) SukiSU 系却找不到 `config KPM`——那是异常（上游该有却没有），照旧报错。
  #
  # 结论写进 KPM_SUPPORTED，供后面「写 defconfig」与「修补 Image」两个阶段复用，
  # 免得各 grep 一遍漏拦其中一环，也免得同一件事在三处各写一遍规则。
  KPM_SUPPORTED=1
  if [ -d "KernelSU" ] && { [[ "${USE_KPM}" == enabled* ]] || [[ "${USE_KPM}" == patched* ]]; }; then
    case "${KSU_VARIANT}" in
      BakaSU|Official|Next|FinaSU)
        KPM_SUPPORTED=0
        echo "::warning::变体 ${KSU_VARIANT} 的内核不提供 KPM（Kconfig 里没有 config KPM）"
        echo "::warning::本次构建已按 ${USE_KPM} 请求 KPM，但 KPM 相关阶段会全部跳过："
        echo "::warning::  · 内核可正常编译，KPM 模块也加载不了；如需 KPM 请换回 SukiSU 变体"
        ;;
    esac
    if [ "${KPM_SUPPORTED}" = "1" ] \
      && ! grep -RqsE '^[[:space:]]*config[[:space:]]+KPM([[:space:]]|$)' KernelSU 2>/dev/null; then
      KPM_SUPPORTED=0
      echo "::error::已请求启用 KPM，但变体 ${KSU_VARIANT} 的 KernelSU 未声明 CONFIG_KPM"
      echo "::error::KPM 目前只有 SukiSU / SukiSU 固定提交变体提供；请改用这两个变体，或把 KPM 关掉"
      return 1
    fi

    # 变体确实提供 KPM，但内核版本太新：6.10+ 上 SukiSU 的
    # drivers/kernelsu/kpm/super_access.c 用了 netlink_kernel_cfg.cb_mutex 与
    # DYNAMIC_STRUCT_END(netlink_kernel_cfg)，那个成员在新内核里已经没了。
    # 实测 6.12.30：第一次构建跑满 18 分钟后报
    # `no member named 'cb_mutex' in 'struct netlink_kernel_cfg'`。
    #
    # 与其让它失败、再由 stage_compile_kernel 的重试丢弃 ksu.fragment 兜底
    # （等于每版白烧 18 分钟），不如在这里就关掉：KPM 相关阶段全部跳过，
    # defconfig 里也不写 CONFIG_KPM —— 与重试路径的落点完全一致，只是不用先炸一次。
    kv_major="${KERNEL_VERSION%%.*}"
    kv_minor="${KERNEL_VERSION#*.}"; kv_minor="${kv_minor%%.*}"
    if [ "${KPM_SUPPORTED}" = "1" ] \
       && { [ "${kv_major}" -gt 6 ] \
            || { [ "${kv_major}" -eq 6 ] && [ "${kv_minor:-0}" -ge 10 ]; }; }; then
      KPM_SUPPORTED=0
      echo "::warning::内核 ${KERNEL_VERSION} 上 KPM 代码编译不过（kpm/super_access.c 用了新内核已移除的 netlink_kernel_cfg.cb_mutex）"
      echo "::warning::已自动关闭 KPM（与构建失败后重试丢弃 ksu.fragment 的落点相同，但省掉一轮约 18 分钟的失败编译）"
      echo "::warning::KPM 相关阶段将全部跳过；如需 KPM 请改用 ≤ 6.6 的内核"
    fi
  fi

  if [ -d "KernelSU/.git" ]; then
    KSU_LATEST_COMMIT_DATE=$(git -C KernelSU log -1 --date=format:'%Y-%m-%d %H:%M:%S %z' --format='%cd')
    export KSU_LATEST_COMMIT_DATE="$KSU_LATEST_COMMIT_DATE"
  else
    export KSU_LATEST_COMMIT_DATE="未知"
  fi

  # 清理下载到 /tmp 的 setup 脚本，避免跨任务 /tmp 竞态（同路径重复写入）
  rm -f /tmp/ksu_setup.sh

  cd "$_pwd"
}

# 条件执行（等价原工作流 if:）
run_add_kernelsu() {
  if [ "$KSU_MODE" != "禁用KSU" ]; then
    stage_add_kernelsu "$@"
  else
    echo "跳过阶段: add_kernelsu（条件不满足）"
  fi
}

stage_sync_ksu_uapi() {
  log_stage "sync_ksu_uapi" "对齐 KernelSU 内核侧 UAPI 版本"
  local _pwd="$PWD"
  cd "$KERNEL_ROOT"

  if [ ! -d "$KERNEL_ROOT/KernelSU" ]; then
    echo "跳过：未找到 KernelSU 检出（KSU 可能已禁用）"
    cd "$_pwd"
    return 0
  fi

  # 只有「内核侧分支 ≠ 管理器分支」的变体才有 UAPI 漂移：
  #   SukiSU —— 内核走 builtin（其 kernel/include/uapi/supercall.h 里
  #             KERNEL_SU_UAPI_VERSION=2），而管理器 APK 只能由 main 构建
  #             （main 的 uapi/supercall.h 已是 5）。管理器在
  #             managerUAPIVersion > kernelUAPIVersion 时判 requiresNewKernel，
  #             于是首页稳定误报「需要更新内核」——与内核功能无关。
  #   BakaSU —— 内核与管理器同源（都跟 main），当前两侧都已是 5；仍跑一遍只为
  #             在上游回退或分叉时立刻暴露，属防回退而非修现状。
  # Official / Next 的内核与管理器同属一个仓库同一血统，不存在该漂移，不介入。
  case "${KSU_VARIANT}" in
    SukiSU|SukiSU\(*\))
      UAPI_UPSTREAM="https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/uapi/supercall.h" ;;
    BakaSU) UAPI_UPSTREAM="https://raw.githubusercontent.com/Baka-SU/BakaSU/main/uapi/supercall.h" ;;
    *)
      echo "跳过：变体 ${KSU_VARIANT} 的内核与管理器同源，无 UAPI 漂移"
      cd "$_pwd"
      return 0
      ;;
  esac

  if [ ! -f "$WORKSPACE/scripts/ksu_uapi_sync/align.sh" ]; then
    echo "::warning::未找到 scripts/ksu_uapi_sync/align.sh，跳过 UAPI 对齐"
    cd "$_pwd"
    return 0
  fi

  # 目标版本按「现状」从上游 main 现取，不写死数字、不钉 commit（用户约束：
  # 不把上游钉死、要随上游更新）。取不到上游值时脚本内部只告警不硬失败。
  KSU_UAPI_URL="$UAPI_UPSTREAM" \
    bash "$WORKSPACE/scripts/ksu_uapi_sync/align.sh" "KernelSU" \
    || { echo "::error::KernelSU 内核侧 UAPI 对齐失败"; cd "$_pwd"; return 1; }

  cd "$_pwd"
}

run_sync_ksu_uapi() { stage_sync_ksu_uapi "$@"; }

stage_apply_sukisu_compat() {
  log_stage "apply_sukisu_compat" "应用 SukiSU 内核 API 兼容补丁 (6.8+ lsm_id / 6.11+ netlink cb_mutex)"
  local _pwd="$PWD"
  cd "${KERNEL_ROOT}"

  # 仅当 KSU_VARIANT 为 SukiSU 时执行
  if [ "$KSU_VARIANT" != "SukiSU" ]; then
    echo "跳过：当前变体 ${KSU_VARIANT} 不需要 SukiSU compat 补丁"
    cd "$_pwd"
    return 0
  fi

  if [ ! -f "$WORKSPACE/scripts/sukisu_compat/apply.sh" ]; then
    echo "::warning::未找到 scripts/sukisu_compat/apply.sh，跳过 SukiSU compat 补丁"
    cd "$_pwd"
    return 0
  fi

  bash "$WORKSPACE/scripts/sukisu_compat/apply.sh" KernelSU || {
    echo "::warning::SukiSU compat 补丁应用失败（可能已应用或上下文不匹配）"
    cd "$_pwd"
    return 0
  }

  echo "SukiSU compat 补丁应用完成"
  cd "$_pwd"
}

run_apply_sukisu_compat() {
  if [ "$KSU_MODE" != "禁用KSU" ] && [ "$KSU_VARIANT" = "SukiSU" ]; then
    stage_apply_sukisu_compat "$@"
  else
    echo "跳过阶段: apply_sukisu_compat（条件不满足）"
  fi
}

stage_config_sukisu_manager() {
  log_stage "config_sukisu_manager" "配置 SukiSU 管理器信息"
  local _pwd="$PWD"
  cd "${KERNEL_ROOT}"/KernelSU
  KBUILD_FILE="./kernel/Kbuild"
  CUSTOM_TAG="${MANAGER_STR:-}"

  if [ ! -f "$KBUILD_FILE" ]; then
    echo "未找到 $KBUILD_FILE，跳过 SukiSU 版本标识定制"
    cd "$_pwd"
    return 0
  fi

  GIT_HASH=$(git rev-parse --short=8 HEAD)
  # BRANCH 是纯 ref（分支名或 40/64 位 commit），不再是 "-s builtin" 这种带前缀的旧格式
  BRANCH_NAME="$BRANCH"
  if [ "${#BRANCH}" = "40" ] || [ "${#BRANCH}" = "64" ]; then
    # 固定提交是 detached HEAD，--abbrev-ref 只会返回 "HEAD"，用提交号前 12 位更可读
    BRANCH_NAME="${BRANCH:0:12}"
  fi

  if [ -n "$CUSTOM_TAG" ]; then
    VERSION_TEMPLATE="v\$1-$CUSTOM_TAG@$BRANCH_NAME[$GIT_HASH]"
  else
    VERSION_TEMPLATE="v\$1-$GIT_HASH@$BRANCH_NAME"
  fi

  # 版本标识仅用于展示。若上游没有对应定义，发出告警并继续构建。
  if ! awk -v body="$VERSION_TEMPLATE" '
    BEGIN {
      in_block = 0
      replaced = 0
    }
    /^[[:space:]]*define get_ksu_version_full$/ {
      print
      print body
      in_block = 1
      replaced = 1
      next
    }
    in_block && /^[[:space:]]*endef$/ {
      print
      in_block = 0
      next
    }
    !in_block {
      print
    }
    END {
      if (!replaced) {
        exit 1
      }
    }
  ' "$KBUILD_FILE" > "${KBUILD_FILE}.tmp"; then
    echo "::warning::$KBUILD_FILE 中未找到 define get_ksu_version_full，跳过 SukiSU 版本标识定制"
    rm -f "${KBUILD_FILE}.tmp"
    cd "$_pwd"
    return 0
  fi
  mv "${KBUILD_FILE}.tmp" "$KBUILD_FILE"

  echo "已更新 get_ksu_version_full 模板: $VERSION_TEMPLATE"

  cd "$_pwd"
}

# 条件执行（等价原工作流 if:）
run_config_sukisu_manager() {
  if [ "$KSU_MODE" != "禁用KSU" ] && { [ "$KSU_VARIANT" = "SukiSU" ] || [ "$KSU_VARIANT" = "SukiSU(40726)" ] || [ "$KSU_VARIANT" = "SukiSU(40548)" ]; }; then
    stage_config_sukisu_manager "$@"
  else
    echo "跳过阶段: config_sukisu_manager（条件不满足）"
  fi
}

stage_susfs_baseline() {
  log_stage "susfs_baseline" "记录 SUSFS 基线快照"
  local _pwd="$PWD"
  cd "${KERNEL_ROOT}"/common
  # 排除 .rej/.orig 和补丁文件本身：apply.sh 会把 SUSFS 补丁拷进 common/ 并留下 .rej
  # 从真实索引复制一份再 add，只需哈希变动文件，避免对整棵内核树重新哈希
  cp "$(git rev-parse --git-path index)" /tmp/susfs-base.idx
  # GIT_INDEX_FILE 一旦导出就会污染本进程后续所有 git 调用（包括横跨其间的
  # apply_susfs 阶段）。这里只在 write-tree 这一条命令上生效，用完立刻撤销。
  GIT_INDEX_FILE=/tmp/susfs-base.idx git add -A -- . ':!*.rej' ':!*.orig' ':!*.patch'
  SUSFS_BASE_TREE=$(GIT_INDEX_FILE=/tmp/susfs-base.idx git write-tree)
  export SUSFS_BASE_TREE="$SUSFS_BASE_TREE"
  export SUSFS_PATCH_EXPORT="true"
  echo "基线树对象: $SUSFS_BASE_TREE"

  cd "$_pwd"
}

# 条件执行（等价原工作流 if:）
run_susfs_baseline() {
  if [ "$EXPORT_SUSFS_PATCHES" = "true" ] && [ "$ENABLE_SUSFS" = "true" ] && [ "$KSU_MODE" != "禁用KSU" ] && { [ "$KSU_VARIANT" = "SukiSU" ] || [ "$KSU_VARIANT" = "BakaSU" ] || [ "$KSU_VARIANT" = "FinaSU" ]; }; then
    stage_susfs_baseline "$@"
  else
    echo "跳过阶段: susfs_baseline（条件不满足）"
  fi
}

# SUSFS 补丁本身不含 Kconfig——CONFIG_KSU_SUSFS* 全部由 KernelSU 侧声明：
#   SukiSU builtin 的 kernel/Kconfig 里 KSU_SUSFS* 齐全（总开关 + 9 个子项）
#   SukiSU main   的 kernel/Kconfig 里一个都没有
# 而 build.config.gki 的 check_defconfig 已被本脚本 sed 掉，defconfig 里写了
# 却没有 Kconfig 认领的项会被静默丢弃：构建照样成功、内核照样能开机，
# SUSFS 却一行都没编进去（管理器里也就看不到 SUSFS 选项）。
# 所以这里按 Kconfig 的实际声明逐项核对，缺一个就终止。
verify_susfs_kconfig() {
  local ksu_dir="$KERNEL_ROOT/KernelSU"
  local declared_list opt name
  local -a missing=()

  if [ ! -d "$ksu_dir" ]; then
    echo "::error::未找到 $ksu_dir，无法核对 SUSFS Kconfig"
    return 1
  fi

  # pipefail 下 grep 无匹配会让整条赋值失败，必须兜住
  declared_list=$(grep -RhE '^[[:space:]]*config[[:space:]]+KSU_SUSFS[A-Z_]*([[:space:]]|$)' \
    "$ksu_dir" 2>/dev/null \
    | sed -E 's/^[[:space:]]*config[[:space:]]+//; s/[[:space:]].*$//' | sort -u) || true

  for opt in "${SUSFS_CONFIG_OPTIONS[@]}"; do
    name="${opt%%=*}"
    name="${name#CONFIG_}"
    # here-string 精确整行匹配：本脚本开着 pipefail，`printf ... | grep -qx` 在命中时
    # 会让写端收到 SIGPIPE(141)，整条管道被判失败——「明明已声明却报缺失」的假阳性，
    # 会把 SUSFS 门禁在所有版本上误杀。
    if ! grep -qx "$name" <<< "$declared_list"; then
      missing+=("CONFIG_${name}")
    fi
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    echo "::error title=SUSFS Kconfig 缺失::KernelSU（${KSU_VARIANT} / ${BRANCH}）未声明 ${#missing[@]}/${#SUSFS_CONFIG_OPTIONS[@]} 个 SUSFS 开关"
    printf '  缺失: %s\n' "${missing[@]}"
    echo "::error::这些开关会被 Kconfig 静默丢弃（build.config.gki 的 check_defconfig 已禁用），SUSFS 不会编进内核"
    echo "::error::SukiSU 请用 builtin 分支；Official 需确认 10_enable_susfs_for_ksu.patch 已打上"
    return 1
  fi
  echo "SUSFS Kconfig 校验通过：KernelSU 已声明全部 ${#SUSFS_CONFIG_OPTIONS[@]} 个 SUSFS 开关"
}

# BBG / zram / 网络增强 与 verify_susfs_kconfig 同级的核对：这三个功能把自己的开关写进
# gki_defconfig，但 build.config.gki 的 check_defconfig 已被本脚本 sed 掉（见 stage_config_kernel），
# 一旦上游改了目录结构或补丁没打上，写进去的符号没有任何 Kconfig 认领，会被 olddefconfig
# 静默丢弃——构建照样成功、内核照样能开机，功能却一行都没编进去。
#
# 判定口径：只核对「本次真的写进了 defconfig 的、且属于这三个功能的」符号，即
#   （三个 EXPECT 数组的并集）∩（diff $DEFCONFIG.orig $DEFCONFIG 的新增/改动行）
# 这样既不会因某个符号只在本内核版本才写入（如 CONFIG_ZRAM_DEF_COMP_LZ4KD 只在 5.10 写）
# 而误报，也不会去管这三个功能以外的符号（那属于各自的阶段）。
# 声明判定依据 Kconfig 语言规范："config <name>" 或 "menuconfig <name>"（二选一，行首可缩进）。
#
# 隐藏符号守卫：HIDDEN_CONFIG_DENY 里的符号在目标内核上没有 prompt（由 Kconfig 的 select/depends
# 自行推导）。手写进 defconfig 的后果是「被 olddefconfig 静默丢弃、构建照样绿」，属于最难发现的
# 一类失效，所以任何阶段写入都在此硬失败，而不是等编译完了才发现功能没进去。
# 判定对象是本次 run 相对基准的增量（$DEFCONFIG.orig -> $DEFCONFIG），与下面的符号核对同一口径，
# 不会误伤 defconfig 基线里本来就存在的行。
verify_no_hidden_config() {
  local base_file="$DEFCONFIG.orig"
  local written opt
  local -a hit=()

  if [ "${#HIDDEN_CONFIG_DENY[@]}" -eq 0 ]; then
    return 0
  fi
  if [ ! -f "$base_file" ]; then
    echo "::warning::$base_file 不存在（backup_defconfig 未运行？），跳过隐藏符号守卫"
    return 0
  fi

  written=$(diff "$base_file" "$DEFCONFIG" 2>/dev/null | grep '^>' | sed -E 's/^>[[:space:]]*//') || true
  for opt in "${HIDDEN_CONFIG_DENY[@]}"; do
    # 用 here-string 而不是 `printf ... | grep -q`：本脚本开着 pipefail，grep -q 命中即退出，
    # 管道写端会因 SIGPIPE 变成 141，整条管道被判失败——「明明命中却报缺失」的假阳性。
    # here-string 不构成 pipeline，grep 的退出码就是判断结果。
    if grep -qE "^${opt}=|^# ${opt} is not set$" <<< "$written"; then
      hit+=("$opt")
    fi
  done

  if [ "${#hit[@]}" -gt 0 ]; then
    echo "::error title=隐藏符号被手写进 defconfig::${hit[*]}"
    echo "::error::这些符号在目标内核上没有 prompt，由 Kconfig 的 select/depends 自行推导；手写进 defconfig 会被 olddefconfig 静默丢弃，构建照样通过但功能不生效"
    echo "::error::请改用 config_defined()/enable_config_if_defined() 先探测，或干脆不写、让 Kconfig 自己 select"
    return 1
  fi
  return 0
}

verify_kconfig_decl() {
  # 隐藏符号守卫先于「本次是否请求了功能」的判定：它与具体功能开关无关，任何时候都该拦。
  verify_no_hidden_config || return 1

  local kconfig_root="$KERNEL_ROOT/common"
  local base_file="$DEFCONFIG.orig"
  local declared_list written opt name
  local -a want=() check=() missing=()

  if [ ! -d "$kconfig_root" ]; then
    echo "::warning::未找到 $kconfig_root，跳过 Kconfig 声明核对"
    return 0
  fi

  # 1) 本次请求了哪些功能，就核对哪些符号（被 SKIP_INCOMPATIBLE 显式降级的阶段不算）
  if [ "${USE_ZRAM}" = "true" ] && [ "${ZRAM_LZ4K_OK:-0}" = "1" ]; then
    if ! phase_was_skipped config_zram; then want+=("${ZRAM_KCONFIG_EXPECT[@]}"); fi
  fi
  if [ "${USE_NET_ENHANCE}" = "true" ]; then
    if ! phase_was_skipped config_net_enhance; then want+=("${NET_ENHANCE_KCONFIG_EXPECT[@]}"); fi
  fi
  if [ "${USE_BBG}" = "true" ]; then
    if ! phase_was_skipped add_bbg; then want+=("${BBG_KCONFIG_EXPECT[@]}"); fi
  fi

  if [ "${#want[@]}" -eq 0 ]; then
    echo "Kconfig 声明核对：本次未请求 BBG/zram/网络增强，跳过"
    return 0
  fi

  # 2) 取本 run 相对基准 defconfig 的增量，只留真正落进 defconfig 的符号
  if [ -f "$base_file" ]; then
    written=$(diff "$base_file" "$DEFCONFIG" 2>/dev/null | grep '^>' | sed -E 's/^>[[:space:]]*//') || true
    for opt in "${want[@]}"; do
      # 同样避开 `printf ... | grep -q` 的 SIGPIPE 假阳性（见 verify_no_hidden_config）。
      if grep -qE "^${opt}(=|$)" <<< "$written"; then
        check+=("$opt")
      fi
    done
    if [ "${#check[@]}" -eq 0 ]; then
      echo "Kconfig 声明核对：增量里没有本次请求的符号（可能已被 config_susfs 等后续阶段覆盖），跳过"
      return 0
    fi
  else
    # 没有基准文件就无法判断「本次写了什么」，退化为核对全部期望符号；
    # 这种情形只在 --from / --only 跳过 backup_defconfig 时出现，不构成构建失败理由。
    echo "::warning::$base_file 不存在（backup_defconfig 未运行？），退化为核对全部期望符号"
    check=("${want[@]}")
  fi

  # 3) 一次性扫出内核树里所有声明的符号名（-R 会跟随 security/baseband-guard 软链到 Baseband-guard/Kconfig）
  #    pipefail 下 grep 无匹配会让整条赋值失败，必须兜住
  declared_list=$(grep -RhE '^[[:space:]]*(menuconfig|config)[[:space:]]+[A-Za-z0-9_]+' \
    --include='Kconfig*' "$kconfig_root" 2>/dev/null \
    | sed -E 's/^[[:space:]]*(menuconfig|config)[[:space:]]+//; s/[[:space:]].*$//' | sort -u) || true

  if [ -z "$declared_list" ]; then
    echo "::warning::$kconfig_root 下没扫到任何 Kconfig 声明，跳过核对（避免误报）"
    return 0
  fi

  for opt in "${check[@]}"; do
    name="${opt#CONFIG_}"
    # here-string 精确整行匹配，避免管道 + grep -q 的 SIGPIPE 假阳性
    # （declared_list 是整棵内核树的符号全集，足以撑满管道缓冲区）。
    if ! grep -qx "$name" <<< "$declared_list"; then
      missing+=("$opt")
    fi
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    echo "::error title=Kconfig 声明缺失::本次写进 defconfig 的 ${#missing[@]}/${#check[@]} 个符号在内核 Kconfig 里没有任何声明"
    printf '  缺少声明: %s\n' "${missing[@]}"
    echo "::error::这些符号会被 olddefconfig 静默丢弃（build.config.gki 的 check_defconfig 已禁用），对应功能不会编进内核"
    echo "::error::BBG 请检查 setup.sh 是否仍把 Kconfig 接进 security/Kconfig；zram 请检查 lz4k 补丁是否打上；网络增强请检查上游 Kconfig 是否改名"
    return 1
  fi
  echo "Kconfig 声明校验通过：本次写入的 ${#check[@]} 个功能符号在内核 Kconfig 中全部有声明"
}

stage_apply_susfs() {
  log_stage "apply_susfs" "应用 SUSFS 补丁"
  local _pwd="$PWD"

  # SUSFS 补丁引用大量 ksu_* 符号（ksu_handle_*、ksu_is_*_enabled 等），
  # 没有 KernelSU 源码时补丁照打不误，最后一定卡在链接期 undefined reference，
  # 报出来的错和真正的原因隔着十万八千里。这里提前说清楚。
  if [ "${ENABLE_SUSFS}" = "true" ] && [ "${KSU_MODE}" = "禁用KSU" ]; then
    echo "::error::SUSFS 依赖 KernelSU，KSU_MODE=禁用KSU 时不能启用 SUSFS（请关闭 SUSFS 或改用非禁用KSU 模式）"
    return 1
  fi

  cd "${KERNEL_ROOT}"
  # 原始补丁探测（SUSFS_RAW_PROBE）由 apply.sh 自己实现，这里只透传开关：
  # apply.sh 同时负责"应用补丁"和"适配修复"，直接跳过它会连补丁都不打，
  # 拿到的就不是"原始补丁能否落地"的结论。apply.sh 打完原始补丁会写出
  # $SUSFS_PROBE_DIR/apply.json 并直接结束；编译结论再由 build.yml 末尾的
  # 「写入 SUSFS 探测结果」步骤合并成 result.json。
  # FinaSU 的 SUSFS 集成走另一条路：上游 KernelSU 侧补丁 + 本仓库的结构适配补丁，
  # 与 BakaSU/SukiSU 的「内置 SUSFS」不是同一形态。必须先跑完 finasu_compat，
  # 再让下面的 apply.sh 打内核侧补丁 —— 顺序反了会因 selinux_hide 形态不同而失配。
  # 它自己带 fail-closed（任一补丁失败 / 留 .rej / Kbuild 仍启用冲突对象都直接失败），
  # 这里仍然上抛，避免主循环关闭 set -e 时被吞掉。
  if [ "${KSU_VARIANT}" = "FinaSU" ]; then
    bash "$WORKSPACE/scripts/finasu_compat/apply.sh" "$KERNEL_ROOT/KernelSU" \
      || { cd "$_pwd"; return 1; }
    if grep -q 'ksu_patch_text' "$KERNEL_ROOT/KernelSU/kernel/feature/selinux_hide.c"; then
      echo "::error::FinaSU SUSFS 适配后仍保留 ksu_patch_text，拒绝继续构建以避免 SELinux 隐藏冲突"
      return 1
    fi
    echo "FinaSU SELinux 校验通过：适配后的 selinux_hide.c 不再包含 ksu_patch_text"
  fi

  # apply.sh 的 exit 1 必须在这里上抛：主循环用 `if ! "run_${p}"` 调用阶段，
  # 该上下文下 bash 会关闭函数体内的 set -e，所以 apply.sh 自己 exit 1 并不会
  # 中止构建（2026-10 首次 BBG 构建实测：verify_susfs_landing 报了 2 处缺失，
  # 构建仍一路跑到 zram 阶段才因别的原因失败）。不打草稿地放行等于 fail-open。
  if ! bash "$WORKSPACE/scripts/susfs_fixes/apply.sh"; then
    cd "$_pwd"
    return 1
  fi
  cd "$_pwd"

  # 补丁落地后立刻核对 Kconfig：只查 .rej 和源码注入还不够，
  # Kconfig 不认领的话 defconfig 写得再全也是白写。
  if [ "${ENABLE_SUSFS}" = "true" ] && [ "${KSU_MODE}" != "禁用KSU" ]; then
    verify_susfs_kconfig
    verify_susfs_selinux_compat
  fi
}

# BakaSU 的 KSU_COMPAT_HAS_SUSFS_FEATURE_SELINUX_HIDE 只能由 susfs_compat.mk
# 在编译 Makefile 解析时定义，触发条件是 security/selinux/hooks.c 里出现
# ksu_selinux_hide_running（SUSFS 补丁注入）。add_kernelsu 阶段做静态检查时
# SUSFS 还没打，看不出这个宏到底成不成立；只有补丁落地后复查 hooks.c 才抓得到
# ——宏没定义时 BakaSU 的 ksu_patch_text 会照常编进来，和 SUSFS 的替换互相
# 踩踏，表现就是 SELinux 隐藏失效，且只在真机上才暴露。
verify_susfs_selinux_compat() {
  # KERNEL_ROOT 下内核源码不一定在根：GKI 分支里实际在 <KERNEL_ROOT>/common。
  # 直接拼 ${KERNEL_ROOT}/security/selinux/hooks.c 会一路径不对就整个跳过检查，
  # 静默漏掉宏没定义的情况（实测 6.12 矩阵就是这么哑火了）。
  local hooks_c=""
  local cand
  for cand in "${KERNEL_ROOT}/security/selinux/hooks.c" \
              "${KERNEL_ROOT}/common/security/selinux/hooks.c"; do
    [ -f "$cand" ] && { hooks_c="$cand"; break; }
  done
  if [ -z "$hooks_c" ]; then
    echo "::warning::未找到 security/selinux/hooks.c（已试 ${KERNEL_ROOT} 与 ${KERNEL_ROOT}/common），跳过 SELinux 兼容宏前置条件检查"
    return 0
  fi
  if grep -q "ksu_selinux_hide_running" "$hooks_c"; then
    echo "SELinux 兼容宏前置条件就绪：hooks.c 已含 ksu_selinux_hide_running"
  else
    echo "::warning::security/selinux/hooks.c 未找到 ksu_selinux_hide_running"
    echo "  SUSFS 的 SELinux 补丁可能没打上，或该 SUSFS 分支换了符号名"
    echo "  结果：KSU_COMPAT_HAS_SUSFS_FEATURE_SELINUX_HIDE 不会被定义，BakaSU 的"
    echo "  ksu_patch_text 会与 SUSFS 的 my_* 替换冲突，SELinux 隐藏可能失效"
  fi
}

# 条件执行（等价原工作流 if:）
run_apply_susfs() {
  if [ "$ENABLE_SUSFS" = "true" ]; then
    stage_apply_susfs "$@"
  else
    echo "跳过阶段: apply_susfs（条件不满足）"
  fi
}

# ── 上游 BakaSU 的 SUSFS 构建暂停：编译前按树内证据判定 ──────────────────────
# 上游 BakaSU 自 48fa4bb 起在 kernel/tools/susfs_compat.mk 末尾追加**无条件**的
#   $(info -- $(REPO_NAME): susfs has NOT update with latest KernelSU source)
#   $(info -- $(REPO_NAME): Please wait simonpunk update)
#   $(error Please wait susfs update.)
# 全部 SUSFS 构建被主动挂起（simonpunk 尚未同步最新 KernelSU 的 selinux_hide
# 模型）。该 error 要等编 drivers/kernelsu 解析这个 mk 时才炸 —— 白跑 20+ 分钟。
#
# resume_susfs.sh（移植自 LingLuo17/AnyKernel3 6db3a675，按本仓库重写）把
# 「无条件暂停」换成「按内核版本 + 树内实际形态」的判定：判定通过才改写该文件
# 放行，不通过照旧阻断（fail-closed），上游解除暂停后自动 no-op。
#
# 为什么必须放在 apply_susfs **之后**：判定依赖 hooks.c 里的手动钩子
# ksu_selinux_hide_running，那是 SUSFS 补丁打进去的。补丁之前调用会退化成
# 「无手动钩子 → 放行」，等于无条件解除挂起 —— 正是要避免的。
# 又必须放在 compile_kernel **之前**：SUSFS 相关阶段全在编译前，判定不过就不该
# 让编译空跑。
#
# 注意：LingLuo17 敢直接放行，是因为其 scripts/susfs_fixes/apply.sh 里有
# 「FinaSU/BakaSU 新模型适配段」把 SUSFS 集成改到当前形态；本仓库 apply.sh 现已
# 补齐同一段（adapt_finasu_selinux_hide_model：把补丁里的 fake_state 引用改写成
# backup_sepolicy + security_*_with_policy）。本门控仍在适配段之后独立复核树内形态，
# 适配段没生效（缺 selinux_hide.c / 该文件仍是 fake_state 旧模型）时照旧阻断。
stage_bakasu_susfs_gate() {
  log_stage "bakasu_susfs_gate" "校验上游 BakaSU 的 SUSFS 构建暂停是否仍然成立"
  if [ "${ENABLE_SUSFS}" != "true" ] || [ "${KSU_VARIANT}" != "BakaSU" ]; then
    echo "跳过阶段: bakasu_susfs_gate（仅 ENABLE_SUSFS=true 且 KSU_VARIANT=BakaSU 适用）"
    return 0
  fi

  local gate="$WORKSPACE/scripts/bakasu_compat/resume_susfs.sh"
  if [ ! -f "$gate" ]; then
    echo "::error::缺少 $gate，无法在编译前判定上游 SUSFS 暂停；不猜、不放行"
    return 1
  fi

  bash "$gate" "$KERNEL_ROOT" "${KERNEL_VERSION}" "KernelSU"
}

run_bakasu_susfs_gate() { stage_bakasu_susfs_gate "$@"; }

stage_gen_susfs_patch() {
  log_stage "gen_susfs_patch" "生成 SUSFS 集成补丁"
  local _pwd="$PWD"
  # 局部作用域，避免污染 GKI 构建系统使用的 OUT_DIR
  local OUT_DIR="${WORKSPACE}/susfs-patch"
  cd "${KERNEL_ROOT}"/common
  export_susfs_patch() {
    cp /tmp/susfs-base.idx /tmp/susfs-after.idx || return 1
    export GIT_INDEX_FILE=/tmp/susfs-after.idx
    git add -A -- . ':!*.rej' ':!*.orig' ':!*.patch' || return 1
    local after_tree
    after_tree=$(git write-tree) || return 1
    unset GIT_INDEX_FILE

    mkdir -p "$OUT_DIR"
    git diff --binary "$SUSFS_BASE_TREE" "$after_tree" > "$OUT_DIR/susfs.patch" || return 1
    if [ ! -s "$OUT_DIR/susfs.patch" ]; then
      echo "补丁内容为空"
      return 1
    fi
    # 反向试打，证明补丁与当前工作树完全一致
    git apply --check -R "$OUT_DIR/susfs.patch" || return 1

    local formatted_branch gki_branch gki_commit
    formatted_branch="${ANDROID_VERSION}-${KERNEL_VERSION}-${OS_PATCH_LEVEL}"
    gki_branch="$formatted_branch"
    grep -q deprecated <<< "$REMOTE_BRANCH" && gki_branch="deprecated/$formatted_branch"
    # 分支已被上游删除时，实际检出的是发布 tag
    [ -n "$TAG_FALLBACK" ] && gki_branch="refs/tags/$TAG_FALLBACK"
    gki_commit=$(git rev-parse HEAD)

    # KSU 与 SUSFS 提交都取本次构建实际克隆的仓库，不用 ls-remote 现查
    local ksu_repo ksu_commit ksu_slug ksu_setup_cmd
    ksu_repo=$(git -C "$KERNEL_ROOT/KernelSU" remote get-url origin | sed 's/\.git$//')
    ksu_commit=$(git -C "$KERNEL_ROOT/KernelSU" rev-parse HEAD)
    ksu_slug=${ksu_repo#https://github.com/}
    ksu_setup_cmd="curl -LSs https://raw.githubusercontent.com/$ksu_slug/main/kernel/setup.sh | bash -s $ksu_commit"

    local susfs_repo susfs_branch susfs_commit
    susfs_repo=$(git -C "$SUSFS4KSU" remote get-url origin | sed 's/\.git$//')
    susfs_branch="gki-${ANDROID_VERSION}-${KERNEL_VERSION}"
    susfs_commit=$(git -C "$SUSFS4KSU" rev-parse HEAD)

    local rej_count patch_sha256
    # 与冲突收集阶段使用同一过滤规则：上游跟踪且未修改的 .rej 不算本次补丁拒绝。
    mapfile -t SUSFS_REJ_FILES < <(
      find . -type f -name '*.rej' | sort | while IFS= read -r rej; do
        if git -C "$(dirname "$rej")" ls-files --error-unmatch -- "$(basename "$rej")" >/dev/null 2>&1 \
          && git -C "$(dirname "$rej")" diff --quiet -- "$(basename "$rej")" 2>/dev/null; then
          continue
        fi
        printf '%s\n' "$rej"
      done
    )
    rej_count=${#SUSFS_REJ_FILES[@]}
    patch_sha256=$(sha256sum "$OUT_DIR/susfs.patch" | awk '{print $1}')

    jq -n \
      --arg android_version "${ANDROID_VERSION}" \
      --arg kernel_version "${KERNEL_VERSION}" \
      --arg sub_level "${SUB_LEVEL}" \
      --arg actual_sublevel "$ACTUAL_SUBLEVEL" \
      --arg os_patch_level "${OS_PATCH_LEVEL}" \
      --arg gki_branch "$gki_branch" \
      --arg gki_commit "$gki_commit" \
      --arg ksu_variant "${KSU_VARIANT}" \
      --arg ksu_repo "$ksu_repo" \
      --arg ksu_commit "$ksu_commit" \
      --arg ksu_setup_cmd "$ksu_setup_cmd" \
      --arg susfs_repo "$susfs_repo" \
      --arg susfs_branch "$susfs_branch" \
      --arg susfs_commit "$susfs_commit" \
      --argjson rej_count "$rej_count" \
      --arg patch_sha256 "$patch_sha256" \
      --arg generated_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
      --arg run_id "$GITHUB_RUN_ID" \
      '$ARGS.named' > "$OUT_DIR/manifest.json" || return 1

    echo "补丁大小: $(du -h "$OUT_DIR/susfs.patch" | cut -f1)，本项目补丁拒绝数: $rej_count"
    cat "$OUT_DIR/manifest.json"
  }

  if ! export_susfs_patch; then
    echo "::warning::SUSFS 集成补丁导出失败，本次构建不上传补丁"
    rm -rf "$OUT_DIR"
    export SUSFS_PATCH_EXPORT="false"
  fi

  cd "$_pwd"
}

# 条件执行（等价原工作流 if:）
run_gen_susfs_patch() {
  if [ "$SUSFS_PATCH_EXPORT" = "true" ]; then
    stage_gen_susfs_patch "$@"
  else
    echo "跳过阶段: gen_susfs_patch（条件不满足）"
  fi
}

stage_clone_droidspaces() {
  log_stage "clone_droidspaces" "克隆 Droidspaces 补丁仓库"
  local _pwd="$PWD"
  clone_with_retry https://github.com/ravindu644/Droidspaces-OSS.git /tmp/Droidspaces-OSS --depth 1 || {
    echo "::error::Droidspaces-OSS 克隆失败"; cd "$_pwd"; return 1
  }
  export DROIDSPACES_PATCHES="/tmp/Droidspaces-OSS/Documentation/resources/kernel-patches/GKI"

  cd "$_pwd"
}

# 条件执行（等价原工作流 if:）
run_clone_droidspaces() {
  if [ "$DROIDSPACES" != "不启用" ]; then
    stage_clone_droidspaces "$@"
  else
    echo "跳过阶段: clone_droidspaces（条件不满足）"
  fi
}

stage_backup_defconfig() {
  log_stage "backup_defconfig" "备份基准 defconfig"
  local _pwd="$PWD"
  cp "$DEFCONFIG" "$DEFCONFIG.orig"
  cd "$_pwd"
}

run_backup_defconfig() { stage_backup_defconfig "$@"; }

# ---------------------------- NoMount 集成 ----------------------------
# 来源：上游 commit 27e129e（feat(ci): add optional NoMount metamodule integration）。
#
# 位置不能挪动，上游注释给了两条硬约束：
#   1. 必须在「生成 SUSFS 集成补丁」(gen_susfs_patch) 之后 ——
#      否则 NoMount 对 fs/ 的改动会被算进 susfs.patch，导出给别人一个残缺补丁；
#   2. 必须在「备份基准 defconfig」(backup_defconfig) 之后 ——
#      追加 CONFIG_NOMOUNT=y 才能让 6.1+ 的 bazel fragment diff 抓到这一项。
# 放在 PHASES 的 backup_defconfig 与 integrate_droidspaces 之间，两条同时满足。
#
# NoMount 在 fs/ 下注册子系统，与 SUSFS 的 sus_mount 各走各的路径，
# 因此可以和任意 KSU 变体共存。
stage_integrate_nomount() {
  log_stage "integrate_nomount" "集成 NoMount 挂载元模块"
  local _pwd="$PWD"
  cd "${KERNEL_ROOT}"/common

  local setup_url="https://raw.githubusercontent.com/maxsteeel/nomount/refs/heads/dev/kernel/setup.sh"
  local setup_file="${WORKSPACE}/nomount-setup.sh"

  # setup.sh 内部会克隆 NoMount 仓库、建立 fs/nomount 软链接并注册
  # Kconfig/Makefile，自带幂等守卫，重复执行是安全的。
  curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors "$setup_url" -o "$setup_file"

  # 供应链锚点（可选）：仓库对 KPM 修补工具已有 EXPECTED_KPM_PATCH_SHA256 的校验先例，
  # 这里同样支持 NOMOUNT_SETUP_SHA256。留空则与上游行为一致（不校验）。
  # 注意这里没有再占用 workflow_dispatch 的 input 名额（那配额已满 25），
  # 走环境变量即可。
  if [ -n "${NOMOUNT_SETUP_SHA256:-}" ]; then
    local actual
    actual=$(sha256sum "$setup_file" | awk '{print $1}')
    if [ "$actual" != "$NOMOUNT_SETUP_SHA256" ]; then
      echo "::error::NoMount setup.sh sha256 不匹配：期望 $NOMOUNT_SETUP_SHA256，实际 $actual"
      cd "$_pwd"
      return 1
    fi
    echo "NoMount setup.sh sha256 校验通过"
  fi

  # 上游是 `curl ... | bash -s dev`；写成文件模式后位置参数少一层 -s。
  bash "$setup_file" dev

  if [ ! -L "fs/nomount" ]; then
    echo "::error::NoMount 集成失败：fs/nomount 软链接缺失"
    cd "$_pwd"
    return 1
  fi
  local nm_commit
  nm_commit=$(git -C NoMount rev-parse HEAD)
  echo "NoMount 集成完成，commit: $nm_commit"
  # ::notice:: 会写进 GitHub 的 annotations（CI 走可读 API），日志本体不便离线取回时，
  # 据此即可确证本阶段真的执行过 —— 而不是被条件包装器静默跳过。
  echo "::notice::NoMount 集成成功：fs/nomount 已就位, commit=${nm_commit}"

  # 启用 defconfig（幂等）
  if ! grep -q '^CONFIG_NOMOUNT=y' "$DEFCONFIG"; then
    echo "CONFIG_NOMOUNT=y" >> "$DEFCONFIG"
    echo "已启用 CONFIG_NOMOUNT=y"
  else
    echo "CONFIG_NOMOUNT=y 已存在，跳过"
  fi
  cd "$_pwd"
}

run_integrate_nomount() {
  if [ "$USE_NOMOUNT" = "true" ]; then
    stage_integrate_nomount "$@"
  else
    echo "跳过阶段: integrate_nomount（条件不满足）"
  fi
}

stage_integrate_droidspaces() {
  log_stage "integrate_droidspaces" "集成 Droidspaces 支持"
  local _pwd="$PWD"
  cd "${KERNEL_ROOT}"/common
  KERNEL_VER="${KERNEL_VERSION}"
  SLOT="${DROIDSPACES}"

  # 678 -> 6_7_8, 123 -> 1_2_3, 345 -> 3_4_5
  SLOT_NAME=$(echo "$SLOT" | sed 's/\(.\)/\1_/g; s/_$//')
  echo "应用 Droidspaces SYSVIPC kABI 修复补丁 (槽位: $SLOT / $SLOT_NAME)..."
  case "$KERNEL_VER" in
    6.12)
      PATCH_FILE="$DROIDSPACES_PATCHES/kernel-6.12/001.GKI-6.12-or-above-fix_sysvipc_kabi.patch"
      ;;
    5.10|5.15|6.1|6.6)
      PATCH_FILE="$DROIDSPACES_PATCHES/below-kernel-6.12/001.GKI-below-6.12-fix_sysvipc_kabi_${SLOT_NAME}.patch"
      ;;
    *)
      echo "::warning::Droidspaces: 未适配的内核版本 $KERNEL_VER，跳过补丁"
      cd "$_pwd"
      return 0
      ;;
  esac
  if ! patch -p1 --forward < "$PATCH_FILE"; then
    echo "::warning::SYSVIPC kABI 补丁应用失败，可能已应用或上下文不匹配"
  fi

  # 5.10 及以下还需要 POSIX_MQUEUE 的 kABI 修复
  if [ "$KERNEL_VER" = "5.10" ]; then
    echo "应用 Droidspaces POSIX_MQUEUE kABI 修复补丁 (5.10)..."
    POSIX_PATCH="$DROIDSPACES_PATCHES/below-kernel-6.12/002.5.10_or_lower_use_android_abi_padding_for_posix_mqueue.patch"
    if ! patch -p1 --forward < "$POSIX_PATCH"; then
      echo "::warning::POSIX_MQUEUE kABI 补丁应用失败，可能已应用或上下文不匹配"
    fi
  fi

  # Android 16 / 6.12 的 rust_binder.ko 在启用 IPC_NS 后会引用
  # init_ipc_ns 与 put_ipc_ns，但当前 AOSP common 分支尚未导出这两个符号。
  # 这里补齐导出，避免 modpost 因 undefined symbol 失败。
  if [ "$KERNEL_VER" = "6.12" ]; then
    if [ -f "ipc/msgutil.c" ] && ! grep -qF 'EXPORT_SYMBOL(init_ipc_ns);' "ipc/msgutil.c"; then
      sed -i '/^struct msg_msgseg {/i EXPORT_SYMBOL(init_ipc_ns);' "ipc/msgutil.c"
      echo "已为 init_ipc_ns 补充符号导出"
    fi

    if [ -f "ipc/namespace.c" ] && ! grep -qF 'EXPORT_SYMBOL(put_ipc_ns);' "ipc/namespace.c"; then
      sed -i '/^static struct ns_common \*ipcns_get(/i EXPORT_SYMBOL(put_ipc_ns);' "ipc/namespace.c"
      echo "已为 put_ipc_ns 补充符号导出"
    fi
  fi

  echo "添加 Droidspaces 内核配置..."
  # 按文档规则逐个处理: 已启用则跳过, "# not set" 则替换, 不存在则追加
  enable_config() {
    local cfg="$1"
    if grep -q "^${cfg}=y" "$DEFCONFIG"; then
      echo "  已启用: $cfg"
    elif grep -q "^# ${cfg} is not set" "$DEFCONFIG"; then
      sed -i "s/^# ${cfg} is not set$/${cfg}=y/" "$DEFCONFIG"
      echo "  已切换: $cfg"
    else
      echo "${cfg}=y" >> "$DEFCONFIG"
      echo "  已添加: $cfg"
    fi
  }

  config_defined() {
    local name="${1#CONFIG_}"
    grep -RqsE --include='Kconfig*' "^[[:space:]]*(menuconfig|config)[[:space:]]+${name}$" .
  }

  enable_config_if_defined() {
    local cfg="$1"
    if config_defined "$cfg"; then
      enable_config "$cfg"
    else
      echo "  当前内核未定义: $cfg，跳过"
    fi
  }

  # 必要配置
  enable_config CONFIG_SYSVIPC
  enable_config CONFIG_POSIX_MQUEUE
  enable_config CONFIG_IPC_NS
  enable_config CONFIG_PID_NS
  enable_config CONFIG_DEVTMPFS

  # 用户命名空间：上游文档列为可选但推荐，用于修复 docker unsafe procfs 报错。
  # init/Kconfig 中无 depends on，且 struct cred 的 user_ns/ucounts 是无条件成员，
  # task_struct 等结构体不含 CONFIG_USER_NS 条件编译，因此不影响 kABI 布局，
  # 不需要像 SYSVIPC/IPC_NS 那样额外打 padding 补丁。与 wild_kernel 保持一致，全版本启用。
  enable_config CONFIG_USER_NS

  # 可选: 网络相关配置 (Docker/NAT 模式)
  enable_config_if_defined CONFIG_NETFILTER_XT_MATCH_ADDRTYPE
  enable_config_if_defined CONFIG_NETFILTER_XT_TARGET_LOG
  enable_config_if_defined CONFIG_NETFILTER_XT_MATCH_RECENT
  enable_config_if_defined CONFIG_IP_SET
  enable_config_if_defined CONFIG_IP_SET_HASH_IP
  enable_config_if_defined CONFIG_IP_SET_HASH_NET
  enable_config_if_defined CONFIG_NETFILTER_XT_SET

  # REJECT 目标在不同内核版本上的符号名可能不同，按实际存在的配置启用
  enable_config_if_defined CONFIG_NETFILTER_XT_TARGET_REJECT
  enable_config_if_defined CONFIG_IP_NF_TARGET_REJECT

  echo "Droidspaces 集成完成"

  echo "GKI6.6 普通用户联网专用配置 (Droidspaces)"
  # 专门处理 =n 类型的配置（安卓网络权限必须关闭）
  disable_config() {
    local cfg="$1"
    if grep -q "^${cfg}=n" "$DEFCONFIG"; then
      echo "  已禁用: $cfg"
    elif grep -q "^${cfg}=y" "$DEFCONFIG"; then
      sed -i "s/^${cfg}=y$/${cfg}=n/" "$DEFCONFIG"
      echo "  已关闭: $cfg"
    else
      echo "# ${cfg} is not set" >> "$DEFCONFIG"
      echo "  已添加并禁用: $cfg"
    fi
  }

  if [[ "${ANDROID_VERSION}" == "android15" && "${KERNEL_VERSION}" == "6.6" ]]; then
    # 关闭安卓严格网络控制，否则容器内普通用户无法联网
    disable_config CONFIG_ANDROID_PARANOID_NETWORK
  fi

  cd "$_pwd"
}

# 条件执行（等价原工作流 if:）
run_integrate_droidspaces() {
  if [ "$DROIDSPACES" != "不启用" ]; then
    stage_integrate_droidspaces "$@"
  else
    echo "跳过阶段: integrate_droidspaces（条件不满足）"
  fi
}

stage_inject_ntsync() {
  log_stage "inject_ntsync" "注入 NTSync 内核配置"
  local _pwd="$PWD"
  cd "${KERNEL_ROOT}"/common
  set -e
  echo "=== 开始注入 NTSync 内核补丁 ==="
  echo "Android 版本: ${ANDROID_VERSION}"
  echo "Kernel 版本: ${KERNEL_VERSION}"

  case "${ANDROID_VERSION}-${KERNEL_VERSION}" in
    android12-5.10)
      NTSYNC_PATCH="ntsync_compat_android12-5.10"
      ;;
    android13-5.15)
      NTSYNC_PATCH="ntsync_compat_android13-5.15"
      ;;
    android14-6.1)
      NTSYNC_PATCH="ntsync_compat_android14-6.1"
      ;;
    android15-6.6)
      NTSYNC_PATCH="ntsync_compat_android15-6.6"
      ;;
    android16-6.12)
      NTSYNC_PATCH="ntsync_compat_android16-6.12"
      ;;
    *)
      echo "::warning::NTSync: 未适配 ${ANDROID_VERSION} / ${KERNEL_VERSION}，跳过补丁"
      cd "$_pwd"
      return 0
      ;;
  esac

  echo "自动选择 NTSync 补丁: ${NTSYNC_PATCH}.patch"
  # 这两个补丁会直接应用到内核源码树，下载后先校验内容。
  # wget 仍以 0 落盘，随后交给 patch 去解析。统一走 fetch_remote_script，
  # 按 unified diff 的实际特征校验（diff --git / --- a/ / +++ b/ / @@ 块头）。
  local NTSYNC_RE='^(diff --git |--- a/|\+\+\+ b/|@@ )'
  fetch_remote_script \
    "https://raw.githubusercontent.com/Goldzxcbug/Droidspaces_Kernel_patch/refs/heads/main/NTsync/ntsync_base.patch" \
    ntsync_base.patch "ntsync_base.patch" "$NTSYNC_RE" true \
    || { echo "::error::下载或校验 ntsync_base.patch 失败"; exit 1; }
  fetch_remote_script \
    "https://raw.githubusercontent.com/Goldzxcbug/Droidspaces_Kernel_patch/refs/heads/main/NTsync/${NTSYNC_PATCH}.patch" \
    "${NTSYNC_PATCH}.patch" "${NTSYNC_PATCH}.patch" "$NTSYNC_RE" true \
    || { echo "::error::下载或校验 ${NTSYNC_PATCH}.patch 失败"; exit 1; }

  # 补丁来自未钉版本的 main 分支，下载/应用失败必须显式报错而非静默跳过
  patch -p1 --forward < "ntsync_base.patch" || { echo "::error::应用 ntsync_base.patch 失败"; exit 1; }
  patch -p1 --forward < "${NTSYNC_PATCH}.patch" || { echo "::error::应用 ${NTSYNC_PATCH}.patch 失败"; exit 1; }

  cd ..

  # 配置路径
  CONFIG_PATH="./common/arch/arm64/configs/gki_defconfig"
  echo "正在检查并启用 CONFIG_NTSYNC..."

  # 移除未启用标记，再追加启用项，保证重复运行时保持幂等。
  sed -i '/CONFIG_NTSYNC is not set/d' "$CONFIG_PATH"
  if ! grep -q "^CONFIG_NTSYNC=y" "$CONFIG_PATH"; then
    echo "CONFIG_NTSYNC=y" >> "$CONFIG_PATH"
    echo "✅ 已成功启用 CONFIG_NTSYNC"
  else
    echo "✅ CONFIG_NTSYNC 已处于启用状态"
  fi

  echo "=== NTSync 补丁与配置注入完成 ==="

  cd "$_pwd"
}

# 条件执行（等价原工作流 if:）
run_inject_ntsync() {
  if [ "$DROIDSPACES" != "不启用" ] && [ "$DROIDSPACES_NTSYNC" = "true" ]; then
    stage_inject_ntsync "$@"
  else
    echo "跳过阶段: inject_ntsync（条件不满足）"
  fi
}

stage_apply_unicode_fix() {
  log_stage "apply_unicode_fix" "应用 Unicode 绕过修复"
  # 该补丁来自 Numbersf/Action-Build（自定义许可，非 GPL 体系）。
  # 严格许可模式下整个跳过，产物中不含该来源代码，代价是 SUSFS 的 Unicode 绕过
  # 修复不生效（内核本身仍可正常构建与启动）。
  if [ "${STRICT_LICENSE_MODE:-false}" = "true" ]; then
    echo "跳过 Unicode 绕过修复（STRICT_LICENSE_MODE=true：排除 Numbersf/Action-Build 非标准许可来源）"
    echo "::warning::严格许可模式：Unicode 绕过修复未应用，SUSFS 的 Unicode 相关隐藏能力会减弱"
    return 0
  fi
  # 原始补丁探测同样要跳过：这个修复不属于上游 SUSFS 补丁，打上去之后编译成败
  # 反映的是"修复过的补丁"，而不是"原始补丁能不能编"，会把兼容线整体抬高一截。
  if [ "${SUSFS_RAW_PROBE:-false}" = "true" ]; then
    echo "跳过 Unicode 绕过修复（SUSFS_RAW_PROBE=true：原始补丁探测，不叠加任何修复）"
    return 0
  fi
  local _pwd="$PWD"
  local _rc=0
  cd "${KERNEL_ROOT}"/common
  if [ "${KERNEL_VERSION}" = "5.10" ] || [ "${KERNEL_VERSION}" = "5.15" ]; then
    # 上游 2023-11、2024-01、2024-03 月度分支已带有 "unicode: Don't special case ignorable code points"，
    # patch --forward 会判定为已应用并跳过，但被忽略的 hunk 仍会写成 .rej，先做幂等检查
    if [ -f fs/unicode/mkutf8data.c ] && ! grep -q 'ignore_init' fs/unicode/mkutf8data.c; then
      echo "源码已包含 Unicode 绕过修复，跳过补丁"
      cd "$_pwd"
      return 0
    fi
    patch -p1 --forward < "$ACTION_BUILD/patches/unicode_bypass_fix_6.1-.patch" || _rc=$?
  else
    patch -p1 --forward < "$ACTION_BUILD/patches/unicode_bypass_fix_6.1+.patch" || _rc=$?
  fi

  # SUSFS 主补丁或上游 ASB 已包含同款 fs/unicode 修改时，bypass 补丁的 hunk
  # 会被 patch 判定为 previously applied：源码状态正确（可正常编译），但 hunk
  # 仍被写入 .rej 并污染 Rejects 产物。此处剔除该预期冲突；
  # mkutf8data.c 仍含 ignore_init 说明存在真实缺失，保留 .rej 以便排查。
  if [ -f fs/unicode/mkutf8data.c.rej ] && [ -f fs/unicode/mkutf8data.c ] \
    && ! grep -q 'ignore_init' fs/unicode/mkutf8data.c; then
    echo "fs/unicode .rej 为已应用同款修改产生的预期冲突，剔除（构建未受影响）"
    rm -f fs/unicode/*.rej
  fi

  # patch 退出码 1 = 该 hunk 已应用过（--forward 主动跳过），正常；>=2 才是真的没打上。
  # 这个补丁属于 SUSFS 流程（仅在 ENABLE_SUSFS=true 时执行），静默失败会产出
  # 缺少 Unicode 绕过修复却看不出异常的内核，所以这里必须区分。
  if [ "$_rc" -ge 2 ]; then
    echo "::error::Unicode 绕过修复补丁应用失败（patch 退出码 $_rc），构建终止"
    exit 1
  fi

  cd "$_pwd"
}

# 条件执行（等价原工作流 if:）
run_apply_unicode_fix() {
  if [ "$ENABLE_SUSFS" = "true" ]; then
    stage_apply_unicode_fix "$@"
  else
    echo "跳过阶段: apply_unicode_fix（条件不满足）"
  fi
}

stage_setup_zram_lz4() {
  log_stage "setup_zram_lz4" "配置 ZRAM LZ4 补丁栈"
  local _pwd="$PWD"
  cd "${KERNEL_ROOT}"/common
  echo "升级 LZ4..."
  rm -f lib/lz4/lz4_compress.c lib/lz4/lz4_decompress.c lib/lz4/lz4defs.h lib/lz4/lz4hc_compress.c

  cp -r $ZZH_PATCHES/zram/lz4/* ./lib/lz4/
  cp -r $ZZH_PATCHES/zram/include/linux/* ./include/linux/
  bash $ZZH_PATCHES/zram/apply_lz4_neon.sh

  if [ -f "fs/f2fs/Makefile" ] && ! grep -qF "f2fs-\$(CONFIG_F2FS_IOSTAT) += iostat.o" "fs/f2fs/Makefile"; then
    echo "f2fs-\$(CONFIG_F2FS_IOSTAT) += iostat.o" >> "fs/f2fs/Makefile"
  fi

  # ---------- lz4k / lz4kd 补丁栈 ----------
  # 5.10 / 5.15 / 6.1 / 6.6 优先使用 SukiSU_patch 提供的版本补丁；
  # 6.12 的补丁随本仓库维护在 zram_patch/6.12，作为本地补丁来源优先选择。
  #
  # 结论写进 ZRAM_LZ4K_OK（全局，供 config_zram 复用），免得「打没打补丁」
  # 这件事在两处各判断一遍、漏掉其中一处。
  #
  # 注意：ZRAM_LZ4K_OK 只能在两个补丁都**确认落地**之后才置 1。它一旦为 1，
  # config_zram 就会把 CONFIG_CRYPTO_LZ4K* / CONFIG_ZRAM_DEF_COMP_LZ4KD=y 写进
  # defconfig；补丁没打上却写了这些符号，GKI 的 defconfig 校验会以
  # `CONFIG_CRYPTO_LZ4K: actual '', expected 'y'` 中断 —— 报出来的错和真正的原因
  # （补丁没落地）隔着好几层。所以这里把「-F 3 模糊匹配失败」从 warning 升为硬失败。
  # 兼容降级仍由调度器的 phase_skippable 决定（setup_zram_lz4 在白名单里）。
  ZRAM_LZ4K_OK=0
  local lz4kd_patch lz4k_oplus_patch
  lz4kd_patch=$(zram_patch_file lz4kd.patch)
  lz4k_oplus_patch=$(zram_patch_file lz4k_oplus.patch)

  # 单个补丁的落地断言：patch 退出码 + 零 .rej + 补丁声称的文件真的进了源码树。
  # patch -F 3 会做「模糊匹配」：上下文对不上时，它在第 3 档 fuzz 里硬塞进去，
  # 产出的是「能编译但语义可能已错位」的代码，退出码却是 0 —— 只看退出码抓不到。
  # .rej 是 patch 明确放弃的 hunk，非空即证明补丁没有完整落地。
  #
  # 目标文件清单不从脚本里写死：写死的文件名一旦随上游改名就会变成假断言（要么
  # 永远失败，要么永远为真）。这里直接解析补丁自身的 `+++ b/<path>` 头，
  # 「补丁说要动的文件」就等于「必须存在的文件」——跟随上游，不钉任何名字。
  apply_zram_patch() {
    local patch_file="$1" label="$2"
    local rej_count=0 missing_file=""
    local -a targets=()
    local t

    if ! patch -p1 -F 3 --no-backup-if-mismatch < "$patch_file"; then
      echo "::error title=${label} 未落地::${patch_file} 应用失败（上下文不匹配）"
      echo "::error::补丁未落地时不得继续：CONFIG_CRYPTO_LZ4K* 写进 defconfig 会让 defconfig 校验失败，或更糟——内核里没有该压缩算法"
      return 1
    fi

    rej_count=$(find . -maxdepth 6 -name '*.rej' -newer "$patch_file" -type f 2>/dev/null | wc -l)
    if [ "$rej_count" -gt 0 ]; then
      echo "::error title=${label} 未完全落地::${patch_file} 留下 ${rej_count} 个 .rej（hunk 被放弃）"
      find . -maxdepth 6 -name '*.rej' -newer "$patch_file" -type f 2>/dev/null | head -n 10 | while IFS= read -r r; do echo "  .rej: $r"; done
      return 1
    fi

    # 解析 `+++ b/path`；跳过 /dev/null（删除文件）与补丁头行。
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      targets+=("$t")
    done < <(sed -n 's|^+++ b/\(.*\)|\1|p' "$patch_file" | sed 's/\t.*$//' | sed '/^\/dev\/null$/d' | sort -u)

    if [ "${#targets[@]}" -eq 0 ]; then
      echo "::error title=${label} 补丁结构无法解析::${patch_file} 中解析不到任何 \`+++ b/<path>\` 头，落地校验会变成空检查"
      echo "::error::上游把补丁格式改了（例如 git-format 的元数据版式）；拒绝在无法核对的情况下继续"
      return 1
    fi

    for t in "${targets[@]}"; do
      if [ ! -e "$t" ]; then
        missing_file="$t"
        break
      fi
    done
    if [ -n "$missing_file" ]; then
      echo "::error title=${label} 落盘文件缺失::补丁声明要写入 '$missing_file'，但源码树里没有这个文件"
      echo "::error::patch 退出码为 0 却查无文件：说明 hunk 被静默丢弃或路径前缀与内核目录结构不符"
      echo "::error::本次共核对 ${#targets[@]} 个目标文件（来自补丁自身的 +++ 头）"
      return 1
    fi

    echo "${label} 落地校验通过：退出码 0、零 .rej、补丁声明的 ${#targets[@]} 个目标文件均存在"
    return 0
  }

  if zram_lz4k_available; then
    cp -r $SUKISU_PATCHES/other/zram/lz4k/include/linux/* ./include/linux/
    cp -r $SUKISU_PATCHES/other/zram/lz4k/lib/* ./lib/
    cp -r $SUKISU_PATCHES/other/zram/lz4k/crypto/* ./crypto/
    cp -r $SUKISU_PATCHES/other/zram/lz4k_oplus ./lib/

    cp "$lz4kd_patch" ./lz4kd.patch
    if ! apply_zram_patch lz4kd.patch "lz4kd.patch"; then
      cd "$_pwd"; return 1
    fi

    cp "$lz4k_oplus_patch" ./lz4k_oplus.patch
    if ! apply_zram_patch lz4k_oplus.patch "lz4k_oplus.patch"; then
      cd "$_pwd"; return 1
    fi

    # 落地断言：上面四个 cp 把上游源码树拷进内核树，这里逐一核对「拷进去的东西真的
    # 在目标位置」。判据不从脚本里写死文件名，而是**拿源目录当清单**：源目录里有什么，
    # 目标就必须有什么——上游改文件名/挪目录时两者同步变化，不会误杀。
    #
    # 必须区分 cp 的两种形态，它们的目标路径规则不同：
    #   cp -r SRC/*  DST/  →  SRC/rel  落到 DST/rel          （glob，铺平进 DST）
    #   cp -r SRC    DST/  →  SRC/rel  落到 DST/$(basename SRC)/rel（整目录带名拷入）
    # 把 lz4k_oplus 那种「整目录」当成「铺平」会去查 ./lib/lz4k.c，
    # 而实际落在 ./lib/lz4k_oplus/lz4k.c —— 又一个自造的假断言。
    #
    # （更早还写死过 lib/lz4kd.c / crypto/lz4k_compress.c：上游真实布局是
    #   lib/lz4kd/ 与 crypto/lz4kd.c，这两个路径根本不存在，断言必然失败、
    #   必然阻断每一次 zram 构建。写死的名字一旦随上游布局变化，就从「护栏」
    #   变成「永久假断言」。）
    local -a lz4k_src_dst=(
      "$SUKISU_PATCHES/other/zram/lz4k/include/linux|./include/linux|glob"
      "$SUKISU_PATCHES/other/zram/lz4k/lib|./lib|glob"
      "$SUKISU_PATCHES/other/zram/lz4k/crypto|./crypto|glob"
      "$SUKISU_PATCHES/other/zram/lz4k_oplus|./lib|dir"
    )
    local entry src dst mode dest_root rel checked=0 missing=""
    for entry in "${lz4k_src_dst[@]}"; do
      src="${entry%%|*}"
      dst="${entry#*|}"
      mode="${dst##*|}"
      dst="${dst%%|*}"
      # 源目录必须存在：zram_lz4k_available 已确认过，若此刻不在，说明拷贝路径
      # 与判定路径脱节；此时 `cd "$src"` 会静默失败、该目录贡献 0 个文件，
      # 断言会无声缩水（甚至缩到只剩别目录），必须显式拦住。
      if [ ! -d "$src" ]; then
        echo "::error title=zram 补丁栈落地校验失效::上游源码目录不存在: $src（zram_lz4k_available 判定与拷贝路径不一致）"
        cd "$_pwd"; return 1
      fi
      if [ "$mode" = "dir" ]; then
        dest_root="$dst/$(basename "$src")"
      else
        dest_root="$dst"
      fi
      local list_cmd
      if [ "$mode" = "dir" ]; then
        # cp -r SRC DST/ 会连顶层点文件一起搬
        list_cmd=(find . -mindepth 1)
      else
        # cp -r SRC/* DST/ 是 shell glob，顶层点文件不参与匹配 —— 清单必须同样排除，
        # 否则会拿一个 cp 根本不会搬的文件去要求目标存在，又是一处假阳性
        list_cmd=(find . -mindepth 1 -not -path './.*')
      fi
      while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        checked=$((checked + 1))
        if [ ! -e "$dest_root/$rel" ]; then
          missing="$dest_root/$rel（来源 $src/$rel）"
          break 2
        fi
      done < <(cd "$src" && "${list_cmd[@]}" | sed 's|^\./||' | sort)
    done
    if [ "$checked" -eq 0 ]; then
      echo "::error title=zram 补丁栈落地校验失效::四个上游源码目录里一个文件都没枚举到，落地校验会变成空检查"
      echo "::error::上游 lz4k 源码资源目录结构已变，或 zram_lz4k_available 的判定与拷贝路径不再一致"
      cd "$_pwd"; return 1
    fi
    if [ -n "$missing" ]; then
      echo "::error title=zram 补丁栈落地文件缺失::上游源码树里的文件没有拷进内核树: $missing"
      echo "::error::已核对 $checked 个上游文件；上游 lz4k 补丁栈的目录布局可能已变"
      echo "::error::ZRAM_LZ4K_OK 保持 0，不写入 CONFIG_CRYPTO_LZ4K*"
      cd "$_pwd"; return 1
    fi

    ZRAM_LZ4K_OK=1
  else
    # 正常路径在 run_setup_zram_lz4 就已经整段跳过，这里只对单独 --only 跑本阶段的情况兜底。
    ZRAM_LZ4K_OK=0
    echo "::warning::内核 ${KERNEL_VERSION} 缺少完整 lz4k 补丁栈或源码资源，跳过 lz4k / lz4kd / lz4k_oplus 补丁"
  fi

  cd "$_pwd"
}

# 本仓库补丁优先，SukiSU_patch 作为回退来源。
zram_patch_file() {
  local name="$1"
  local local_patch="$ZZH_PATCHES/zram_patch/${KERNEL_VERSION}/${name}"
  local upstream_patch="$SUKISU_PATCHES/other/zram/zram_patch/${KERNEL_VERSION}/${name}"
  if [ -f "$local_patch" ]; then
    printf '%s\n' "$local_patch"
  elif [ -f "$upstream_patch" ]; then
    printf '%s\n' "$upstream_patch"
  fi
}

# 两个版本补丁和其余 lz4k 源码资源都齐备时才启用，避免构建到 defconfig 才失败。
zram_lz4k_available() {
  [ -n "$(zram_patch_file lz4kd.patch)" ] \
    && [ -n "$(zram_patch_file lz4k_oplus.patch)" ] \
    && [ -d "$ZZH_PATCHES/zram/lz4" ] \
    && [ -d "$ZZH_PATCHES/zram/include/linux" ] \
    && [ -f "$ZZH_PATCHES/zram/apply_lz4_neon.sh" ] \
    && [ -d "${SUKISU_PATCHES}/other/zram/lz4k/include/linux" ] \
    && [ -d "${SUKISU_PATCHES}/other/zram/lz4k/lib" ] \
    && [ -d "${SUKISU_PATCHES}/other/zram/lz4k/crypto" ] \
    && [ -d "${SUKISU_PATCHES}/other/zram/lz4k_oplus" ]
}

# 条件执行（等价原工作流 if:）
run_setup_zram_lz4() {
  if [ "$USE_ZRAM" != "true" ]; then
    echo "跳过阶段: setup_zram_lz4（条件不满足）"
    return 0
  fi
  # 补丁或配套源码资源不完整时整段跳过，避免生成无法通过 defconfig 校验的半成品。
  if ! zram_lz4k_available; then
    ZRAM_LZ4K_OK=0
    echo "::warning::内核 ${KERNEL_VERSION} 没有找到完整 lz4k 补丁栈（本仓库补丁优先，SukiSU_patch 回退）或配套源码"
    echo "::warning::本次已按 USE_ZRAM=${USE_ZRAM} 请求 ZRAM，但整段跳过：补丁栈缺失，ZRAM 相关阶段与 defconfig 配置全部不写入"
    return 0
  fi
  stage_setup_zram_lz4 "$@"
}

stage_fix_66_wifi_bt() {
  log_stage "fix_66_wifi_bt" "修复 6.6 WiFi/蓝牙兼容性（三星 + 小米）"
  local _pwd="$PWD"
  cd "${KERNEL_ROOT}"/common
  ensure_line_once() {
    local file="$1"
    local line="$2"
    if [ ! -f "$file" ]; then
      echo "::error::文件不存在: $file"
      exit 1
    fi
    if ! grep -qF "$line" "$file"; then
      echo "$line" >> "$file"
    fi
  }

  GALAXY_SYMBOL_LIST="android/abi_gki_aarch64_galaxy"
  XIAOMI_SYMBOL_LIST="android/abi_gki_aarch64_xiaomi"
  DRIVERS_MAKEFILE="drivers/Makefile"
  MIN_KDP_SRC="$KERNEL_PATCHES/samsung/min_kdp/min_kdp.c"
  MIN_KDP_PATCH="$KERNEL_PATCHES/samsung/min_kdp/add-min_kdp-symbols.patch"
  MIN_KDP_DST="drivers/min_kdp.c"

  # min_kdp.c 与三星符号来自 WildKernels/kernel_patches（上游未声明许可），
  # 严格许可模式下整体跳过，只保留小米侧符号（不引入未声明许可的代码）。
  # 代价：三星机型的 WiFi/蓝牙兼容性修复不生效。
  if [ "${STRICT_LICENSE_MODE:-false}" = "true" ]; then
    echo "跳过三星 min_kdp 修补（STRICT_LICENSE_MODE=true：排除 WildKernels/kernel_patches 未声明许可来源）"
    echo "::warning::严格许可模式：三星 min_kdp 未注入，三星机型的 WiFi/蓝牙兼容性修复不生效"
  else
    ensure_line_once "$GALAXY_SYMBOL_LIST" "kdp_set_cred_non_rcu"
    ensure_line_once "$GALAXY_SYMBOL_LIST" "kdp_usecount_dec_and_test"
    ensure_line_once "$GALAXY_SYMBOL_LIST" "kdp_usecount_inc"

    if [ ! -f "$MIN_KDP_PATCH" ]; then
      echo "::error::补丁不存在: $MIN_KDP_PATCH"
      exit 1
    fi
    if patch -p1 --dry-run < "$MIN_KDP_PATCH" >/dev/null 2>&1; then
      patch -p1 --no-backup-if-mismatch < "$MIN_KDP_PATCH"
    else
      echo "min_kdp symbols patch 已应用或当前上下文不匹配，跳过。"
    fi

    if [ ! -f "$MIN_KDP_SRC" ]; then
      echo "::error::文件不存在: $MIN_KDP_SRC"
      exit 1
    fi
    cp "$MIN_KDP_SRC" "$MIN_KDP_DST"
    ensure_line_once "$DRIVERS_MAKEFILE" "obj-y += min_kdp.o"
  fi

  ensure_line_once "$XIAOMI_SYMBOL_LIST" "device_find_any_child"

  cd "$_pwd"
}

# 条件执行（等价原工作流 if:）
run_fix_66_wifi_bt() {
  if [ "$KERNEL_VERSION" = "6.6" ]; then
    stage_fix_66_wifi_bt "$@"
  else
    echo "跳过阶段: fix_66_wifi_bt（条件不满足）"
  fi
}

stage_config_zram() {
  log_stage "config_zram" "配置 ZRAM 选项"
  local _pwd="$PWD"
  CONFIG_FILE="$DEFCONFIG"

  if [ "${KERNEL_VERSION}" = "5.10" ]; then
    cat >> "$CONFIG_FILE" <<'EOF'
CONFIG_ZSMALLOC=y
CONFIG_ZRAM=y
CONFIG_MODULE_SIG=n
CONFIG_CRYPTO_LZO=y
CONFIG_ZRAM_DEF_COMP_LZ4KD=y
EOF
  fi

  if [ "${KERNEL_VERSION}" != "6.6" ] && [ "${KERNEL_VERSION}" != "5.10" ]; then
    if grep -q "CONFIG_ZSMALLOC" "$CONFIG_FILE"; then
      sed -i 's/CONFIG_ZSMALLOC=m/CONFIG_ZSMALLOC=y/g' "$CONFIG_FILE"
    else
      echo "CONFIG_ZSMALLOC=y" >> "$CONFIG_FILE"
    fi
    sed -i 's/CONFIG_ZRAM=m/CONFIG_ZRAM=y/g' "$CONFIG_FILE"
  fi

  if [ "${KERNEL_VERSION}" = "6.6" ]; then
    echo "CONFIG_ZSMALLOC=y" >> "$CONFIG_FILE"
    sed -i 's/CONFIG_ZRAM=m/CONFIG_ZRAM=y/g' "$CONFIG_FILE"
  fi

  # ZRAM / ZSMALLOC 被编进内核（=y）时，modules.bzl 里不能再留它们的 .ko 条目，
  # 否则模块清单检查会为找不到的产物报错；Android 16 的 ZRAM 也会被设为内建。
  if grep -q "^CONFIG_ZRAM=y" "$CONFIG_FILE" \
     || [ "${ANDROID_VERSION}" = "android14" ] || [ "${ANDROID_VERSION}" = "android15" ]; then
    sed -i 's/"drivers\/block\/zram\/zram\.ko",//g; s/"mm\/zsmalloc\.ko",//g' "$KERNEL_ROOT/common/modules.bzl"
  fi

  # zram.config 里的 5 个 CONFIG_CRYPTO_*（LZ4HC / LZ4K / LZ4KD / 842 / LZ4K_OPLUS）
  # 全部由 setup_zram_lz4 打的 lz4k 补丁提供。补丁没打上就写进 defconfig，GKI 的
  # defconfig 校验会以 `CONFIG_CRYPTO_LZ4K: actual '', expected 'y'` 中断构建。
  # ZRAM_LZ4K_OK 由 setup_zram_lz4 算好（无上游 lz4k 补丁的内核为 0）。
  if [ "${ZRAM_LZ4K_OK:-0}" = "1" ] \
     && grep -q "CONFIG_ZSMALLOC=y" "$CONFIG_FILE" && grep -q "CONFIG_ZRAM=y" "$CONFIG_FILE"; then
    # ZRAM_BACKEND_* 仅在 6.12+ 的 Kconfig 中声明；bazel 构建的 kernel_config
    # 会校验 fragment 中每个配置项都必须存在于 Kconfig，旧版本内核带上
    # 这些行会直接导致编译失败，因此 6.12 以下需剔除
    if [ "$(printf '%s\n' "6.12" "${KERNEL_VERSION}" | sort -V | head -1)" = "6.12" ]; then
      cat "$ZZH_PATCHES/config/zram.config" >> "$CONFIG_FILE"
    else
      grep -v '^CONFIG_ZRAM_BACKEND_' "$ZZH_PATCHES/config/zram.config" >> "$CONFIG_FILE"
    fi
  fi

  cd "$_pwd"
}

# 条件执行（等价原工作流 if:）
run_config_zram() {
  if [ "$USE_ZRAM" != "true" ]; then
    echo "跳过阶段: config_zram（条件不满足）"
    return 0
  fi
  # 补丁栈缺失时连 defconfig 都不动：CONFIG_CRYPTO_LZ4K 之类的选项得有 lz4k 代码才存在，
  # 写了就过不了 GKI 的 defconfig 校验。ZRAM_LZ4K_OK 由 setup_zram_lz4 算好。
  if [ "${ZRAM_LZ4K_OK:-0}" != "1" ]; then
    echo "跳过阶段: config_zram（${KERNEL_VERSION} 未提供 lz4k 补丁栈，见 setup_zram_lz4 的告警）"
    return 0
  fi
  stage_config_zram "$@"
}

stage_add_bbg() {
  log_stage "add_bbg" "添加 BBG 防格机补丁"
  local _pwd="$PWD"
  cd "${KERNEL_ROOT}"
  # 下载/执行失败必须显式报错；Kconfig 修改前备份，失败/未命中即回滚提示
  # BBG setup.sh 会修改内核源码树，下载后按脚本内容特征校验再执行。
  BBG_SETUP="https://github.com/vc-teahouse/Baseband-guard/raw/main/setup.sh"
  if ! fetch_remote_script "$BBG_SETUP" /tmp/bbg_setup.sh "BBG" \
      'CONFIG_BBG|baseband|Baseband|^#!|^[[:space:]]*(set|function|if|for|KERNEL_ROOT)' true; then
    echo "::error::BBG setup.sh 获取或校验失败"; return 1
  fi
  if ! bash /tmp/bbg_setup.sh; then
    echo "::error::BBG setup.sh 执行失败"; return 1
  fi
  # 安装结果断言。上游 setup.sh 的实际动作（已逐行核对 main 分支）：
  #   1. 克隆到 $KERNEL_ROOT/Baseband-guard，并在 common/security/ 下建**符号链接**
  #      baseband-guard -> 该目录（相对软链）；
  #   2. 向 common/security/Makefile 追加 `obj-$(CONFIG_BBG) += baseband-guard/`；
  #   3. 向 common/security/Kconfig 插入 `source "security/baseband-guard/Kconfig"`
  #      ——**这一行才是 CONFIG_BBG 在 Kconfig 里存在的原因**。
  # 上游一旦改目录结构或改名，这里必须硬失败：否则会写出一条没有任何代码认领的
  # CONFIG_BBG=y，被 Kconfig 静默丢弃，构建照样绿、内核里一行 BBG 都没有。
  # 只查软链目标文件不够（-f 会跟随符号链接，指向哪儿都能为真），必须查那一行 source。
  if [ ! -f common/security/baseband-guard/Kconfig ] \
      || ! grep -q 'baseband-guard' common/security/Makefile \
      || ! grep -q 'baseband-guard/Kconfig' common/security/Kconfig; then
    echo "::error::BBG 安装结果校验失败：三项落地断言至少一项不成立（上游可能改了目录结构）"
    echo "::error::  1. common/security/baseband-guard/Kconfig 存在（软链 -> Baseband-guard/Kconfig）: $([ -f common/security/baseband-guard/Kconfig ] && echo 通过 || echo 失败)"
    echo "::error::  2. common/security/Makefile 已接线 baseband-guard/: $(grep -q 'baseband-guard' common/security/Makefile && echo 通过 || echo 失败)"
    echo "::error::  3. common/security/Kconfig 已 source baseband-guard/Kconfig（CONFIG_BBG 的来源）: $(grep -q 'baseband-guard/Kconfig' common/security/Kconfig && echo 通过 || echo 失败)"
    bash /tmp/bbg_setup.sh --cleanup 2>/dev/null || true
    return 1
  fi
  echo "CONFIG_BBG=y" >> common/arch/arm64/configs/gki_defconfig
  cp common/security/Kconfig /tmp/security.Kconfig.bak
  if ! sed -i '/^config LSM$/,/^help$/{ /^[[:space:]]*default/ { /baseband_guard/! s/selinux/selinux,baseband_guard/ } }' common/security/Kconfig; then
    echo "::error::BBG 修改 security/Kconfig 失败，已回滚"; cp /tmp/security.Kconfig.bak common/security/Kconfig
    return 1
  elif ! grep -q "baseband_guard" common/security/Kconfig; then
    echo "::error::BBG 未匹配到 config LSM 段：security/Kconfig 未被修改，Kconfig default 不会含 baseband_guard（已回滚）"
    cp /tmp/security.Kconfig.bak common/security/Kconfig
    return 1
  fi

  cd "$_pwd"
}

# 条件执行（等价原工作流 if:）
run_add_bbg() {
  if [ "$USE_BBG" = "true" ]; then
    stage_add_bbg "$@"
  else
    echo "跳过阶段: add_bbg（条件不满足）"
  fi
}

stage_apply_rekernel() {
  log_stage "apply_rekernel" "应用 Re-Kernel"
  local _pwd="$PWD"
  cd "${KERNEL_ROOT}"
  set -e
  echo "Integrating Re-Kernel..."
  TMP_REKERNEL=/tmp/rekernel
  rm -rf "$TMP_REKERNEL"
  clone_with_retry https://github.com/Sakion-Team/Re-Kernel.git "$TMP_REKERNEL" --depth 1

  # 同步上游拆分后的完整驱动源码
  rm -rf common/drivers/rekernel
  mkdir -p common/drivers/rekernel
  cp -a "$TMP_REKERNEL/LKM-Source/." common/drivers/rekernel/

  # 将上游外置模块配置适配为内核内置驱动
  REKERNEL_MAKEFILE="common/drivers/rekernel/Makefile"
  sed -i 's/^obj-m := rekernel\.o$/obj-$(CONFIG_REKERNEL) += rekernel.o/' "$REKERNEL_MAKEFILE"
  grep -qF 'ccflags-$(CONFIG_REKERNEL_LEGACY_NETLINK) += -DLEGACY_NETLINK' "$REKERNEL_MAKEFILE" || \
    echo 'ccflags-$(CONFIG_REKERNEL_LEGACY_NETLINK) += -DLEGACY_NETLINK' >> "$REKERNEL_MAKEFILE"
  sed -i '/^[[:space:]]*depends on MODULES[[:space:]]*$/d' common/drivers/rekernel/Kconfig

  # 挂载到驱动树
  if ! grep -qF 'source "drivers/rekernel/Kconfig"' common/drivers/Kconfig; then
    sed -i '/^endmenu$/i source "drivers/rekernel/Kconfig"' common/drivers/Kconfig
  fi
  if ! grep -qF 'obj-$(CONFIG_REKERNEL) += rekernel/' common/drivers/Makefile; then
    echo 'obj-$(CONFIG_REKERNEL) += rekernel/' >> common/drivers/Makefile
  fi

  # 修正头文件包含路径（适配 in-tree 编译）
  sed -i 's|#include <../android/binder_internal.h>|#include "../android/binder_internal.h"|g' common/drivers/rekernel/rekernel_binder.c
  # 补齐 5.10 binder_internal.h 使用 DEFINE_SHOW_ATTRIBUTE 所需的定义
  grep -qF '#include <linux/seq_file.h>' common/drivers/rekernel/rekernel_binder.c || \
    sed -i '/#include <linux\/kprobes.h>/a #include <linux/seq_file.h>' common/drivers/rekernel/rekernel_binder.c

  # 配置 defconfig（幂等）
  grep -q '^CONFIG_REKERNEL=y$' "$DEFCONFIG" || echo "CONFIG_REKERNEL=y" >> "$DEFCONFIG"
  grep -q '^CONFIG_REKERNEL_NETWORK=y$' "$DEFCONFIG" || echo "CONFIG_REKERNEL_NETWORK=y" >> "$DEFCONFIG"

  cd "$_pwd"
}

# 条件执行（等价原工作流 if:）
run_apply_rekernel() {
  if [ "$USE_REKERNEL" = "true" ]; then
    stage_apply_rekernel "$@"
  else
    echo "跳过阶段: apply_rekernel（条件不满足）"
  fi
}

stage_config_net_enhance() {
  log_stage "config_net_enhance" "写入网络增强配置（IPSet + BBR）"

  # 幂等写入：行已存在则跳过；符号已有赋值（含 =m）或 "# not set" 则原地替换；否则追加。
  # **必须**把 =m 一并替换成 =y：BIC / WESTWOOD / HTCP 在 mainline Kconfig 里 default m，
  # 一旦编成 tcp_bic.ko 这类模块，而 GKI 的 module_outs 并未声明它们，bazel 会直接失败。
  # 这个问题只在本阶段开关打开时出现，所以内建是硬要求而非偏好。
  ensure_net_cfg() {
    local line="$1" cfg="${1%%=*}"
    if grep -qxF "$line" "$DEFCONFIG"; then
      return 0
    fi
    if grep -Eq "^${cfg}=|^# ${cfg} is not set$" "$DEFCONFIG"; then
      sed -i -E "s|^${cfg}=.*|${line}|; s|^# ${cfg} is not set$|${line}|" "$DEFCONFIG"
    else
      echo "$line" >> "$DEFCONFIG"
    fi
  }

  # 兼容性检查：子系统不存在时，后面写进去也只是无效配置，直接失败交由调度器裁决
  if [ ! -f "${KERNEL_ROOT}/common/net/ipv4/tcp_bbr.c" ]; then
    echo "::error::内核源码缺少 net/ipv4/tcp_bbr.c，无法启用 BBR"
    return 1
  fi
  if [ ! -d "${KERNEL_ROOT}/common/net/netfilter/ipset" ]; then
    echo "::error::内核源码缺少 net/netfilter/ipset，无法启用 IPSet"
    return 1
  fi

  # BBR 与队列调度。TCP_CONG_BBR / DEFAULT_BBR 都在 `if TCP_CONG_ADVANCED` 里，
  # 所以门控这一行是其余几行的前提（stage_config_kernel 里的 use_bbr 也照此办理）。
  # 实测 GKI 的 gki_defconfig 基线：只有 6.6 带 TCP_CONG_ADVANCED=y +
  # TCP_CONG_BBR=y，5.10 / 6.1 / 6.12 完全没有 TCP_CONG_* 行 —— 门控照样写，
  # 由 ensure_net_cfg 负责把符号从"不存在"变成"存在"，无需按版本分支。
  ensure_net_cfg "CONFIG_TCP_CONG_ADVANCED=y"
  ensure_net_cfg "CONFIG_TCP_CONG_BBR=y"
  ensure_net_cfg "CONFIG_DEFAULT_BBR=y"
  # CONFIG_DEFAULT_TCP_CONG 必须显式写：它是 net/ipv4/Kconfig 里真正的那个 string 符号，
  # 取值由 `default "bbr" if DEFAULT_BBR` 推导。只写 DEFAULT_BBR=y（choice 成员）时，
  # 若 gki_defconfig 基线里 choice 已解析成 DEFAULT_CUBIC，选中的默认算法可能仍是 cubic ——
  # 内核编出来了、BBR 也在，但默认跑的却是 cubic。zzh20188 的 build.yml:1314-1317
  # 正是为此同时写 choice 成员与这行 string，本仓库此前两行都缺。
  # 写作 `"bbr"`（带引号）：Kconfig 的 string 类型在 .config 里就是带引号的形式。
  ensure_net_cfg 'CONFIG_DEFAULT_TCP_CONG="bbr"'
  ensure_net_cfg "CONFIG_NET_SCH_FQ=y"
  ensure_net_cfg "CONFIG_NET_SCH_FQ_CODEL=y"

  # IPSet：GKI 各版本均未启用，全新内建。
  # IP_SET_MAX 的 65534 在内核 Kconfig 的 range（2–65534）内，无需改源码。
  ensure_net_cfg "CONFIG_IP_SET=y"
  ensure_net_cfg "CONFIG_IP_SET_MAX=65534"
  ensure_net_cfg "CONFIG_IP_SET_BITMAP_IP=y"
  ensure_net_cfg "CONFIG_IP_SET_BITMAP_IPMAC=y"
  ensure_net_cfg "CONFIG_IP_SET_BITMAP_PORT=y"
  ensure_net_cfg "CONFIG_IP_SET_HASH_IP=y"
  ensure_net_cfg "CONFIG_IP_SET_HASH_IPMAC=y"
  ensure_net_cfg "CONFIG_IP_SET_HASH_IPMARK=y"
  ensure_net_cfg "CONFIG_IP_SET_HASH_IPPORT=y"
  ensure_net_cfg "CONFIG_IP_SET_HASH_IPPORTIP=y"
  ensure_net_cfg "CONFIG_IP_SET_HASH_IPPORTNET=y"
  ensure_net_cfg "CONFIG_IP_SET_HASH_MAC=y"
  ensure_net_cfg "CONFIG_IP_SET_HASH_NET=y"
  ensure_net_cfg "CONFIG_IP_SET_HASH_NETIFACE=y"
  ensure_net_cfg "CONFIG_IP_SET_HASH_NETNET=y"
  ensure_net_cfg "CONFIG_IP_SET_HASH_NETPORT=y"
  ensure_net_cfg "CONFIG_IP_SET_HASH_NETPORTNET=y"
  ensure_net_cfg "CONFIG_IP_SET_LIST_SET=y"
  ensure_net_cfg "CONFIG_NETFILTER_XT_MATCH_ADDRTYPE=y"
  ensure_net_cfg "CONFIG_NETFILTER_XT_SET=y"

  # IPv6 NAT / 伪装
  ensure_net_cfg "CONFIG_IP6_NF_NAT=y"
  ensure_net_cfg "CONFIG_IP6_NF_TARGET_MASQUERADE=y"

  # 附加拥塞算法：理由见 ensure_net_cfg 上方注释，必须 =y
  ensure_net_cfg "CONFIG_TCP_CONG_BIC=y"
  ensure_net_cfg "CONFIG_TCP_CONG_CUBIC=y"
  ensure_net_cfg "CONFIG_TCP_CONG_WESTWOOD=y"
  ensure_net_cfg "CONFIG_TCP_CONG_HTCP=y"

  # 写入动作自检：确认 ensure_net_cfg 真的把行写/改进了 defconfig。
  # 这只证明「我们把行写进去了」，**不**证明 Kconfig 会认领这些符号（那是
  # verify_config_landing 在编译后核对生成 .config 的事），两者不可互相替代。
  local miss=()
  grep -q '^CONFIG_DEFAULT_BBR=y$' "$DEFCONFIG" || miss+=("CONFIG_DEFAULT_BBR")
  grep -q '^CONFIG_IP_SET=y$' "$DEFCONFIG" || miss+=("CONFIG_IP_SET")
  grep -q '^CONFIG_IP_SET_MAX=65534$' "$DEFCONFIG" || miss+=("CONFIG_IP_SET_MAX")
  grep -q '^CONFIG_NET_SCH_FQ=y$' "$DEFCONFIG" || miss+=("CONFIG_NET_SCH_FQ")
  grep -q '^CONFIG_NETFILTER_XT_SET=y$' "$DEFCONFIG" || miss+=("CONFIG_NETFILTER_XT_SET")
  if [ "${#miss[@]}" -gt 0 ]; then
    echo "::error::网络增强配置写入校验失败，以下符号未落盘: ${miss[*]}"
    return 1
  fi
  echo "网络增强配置已写入 defconfig"
}

run_config_net_enhance() {
  if [ "$USE_NET_ENHANCE" = "true" ]; then
    stage_config_net_enhance "$@"
  else
    echo "跳过阶段: config_net_enhance（条件不满足）"
  fi
}

stage_config_kernel() {
  log_stage "config_kernel" "配置内核选项"
  local _pwd="$PWD"
  cd "${KERNEL_ROOT}"
  cat >> "$DEFCONFIG" << 'EOF'
CONFIG_TMPFS_XATTR=y
CONFIG_TMPFS_POSIX_ACL=y
EOF

  # 禁用KSU 时源码里没有 KernelSU，CONFIG_KSU 不存在，写入会被 bazel 的 defconfig 检查拒绝
  if [ "${KSU_MODE}" != "禁用KSU" ]; then
    echo "CONFIG_KSU=y" >> "$DEFCONFIG"
  fi

  # CONFIG_KPM=y 只在变体确实提供 KPM 时才写。KPM_SUPPORTED 由 stage_add_kernelsu
  # 在源码就位后计算；不支持 KPM 的变体已在前序阶段发出警告。
  if [ "${KSU_MODE}" != "禁用KSU" ] \
     && { [ "${KSU_VARIANT}" == "SukiSU" ] || [ "${KSU_VARIANT}" == "SukiSU(40726)" ] || [ "${KSU_VARIANT}" == "SukiSU(40548)" ] || [ "${KSU_VARIANT}" == "BakaSU" ] || [ "${KSU_VARIANT}" == "Next" ]; }; then
    if { [[ "${USE_KPM}" == enabled* ]] || [[ "${USE_KPM}" == patched* ]]; } && [ "${KPM_SUPPORTED:-1}" = "1" ]; then
      echo "CONFIG_KPM=y" >> "$DEFCONFIG"
    fi
  fi

  CURRENT_SUB="${SUB_LEVEL}"
  if [[ ! "$CURRENT_SUB" =~ ^[0-9]+$ ]]; then
    CURRENT_SUB=99999
  fi
  if [[ "${KSU_VARIANT}" == "BakaSU" && "${ANDROID_VERSION}" == "android13" && "${KERNEL_VERSION}" == "5.15" && "$CURRENT_SUB" -ge 74 && "$CURRENT_SUB" -le 137 ]]; then
    {
      echo "CONFIG_KALLSYMS=y"
      echo "CONFIG_KALLSYMS_ALL=y"
    } >> "$DEFCONFIG"
    # 修复 5.15.74~5.15.137: kallsyms_on_each_symbol 仅在 LIVEPATCH 下编译，导致 BakaSU 链接失败
    KALLSYMS_C="./common/kernel/kallsyms.c"
    if [ -f "$KALLSYMS_C" ] \
      && grep -qF 'int kallsyms_on_each_symbol' "$KALLSYMS_C" \
      && grep -qF '#endif /* CONFIG_LIVEPATCH */' "$KALLSYMS_C"; then
      sed -i '/^#ifdef CONFIG_LIVEPATCH$/,/^int kallsyms_on_each_symbol/ { /^#ifdef CONFIG_LIVEPATCH$/d }' "$KALLSYMS_C"
      sed -i '/^int kallsyms_on_each_symbol/,/^#endif \/\* CONFIG_LIVEPATCH \*\// { /^#endif \/\* CONFIG_LIVEPATCH \*\//d }' "$KALLSYMS_C"
      echo "已修复 kallsyms_on_each_symbol 的 LIVEPATCH 编译限制"
    fi
  fi

  sed -i 's/check_defconfig//' ./common/build.config.gki

  # 修复 6.10+ 的 security_add_hooks 签名。
  #
  # 内核 v6.10 起 security_add_hooks 第三参从 `const char *lsm` 改成
  # `const struct lsm_id *lsmid`；KernelSU 系各变体却写死传字符串字面量，
  # 保护它的 `#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 11, 0)` 对我们编的
  # 内核恒为真，于是 6.10+ 变成把字符串塞给 struct lsm_id *，类型不匹配直接编不过。
  # v5.19~v6.6 那轮第三参还是 const char *，旧写法能凑合对上，所以雷只在 6.10 起爆。
  # 这里用宏在编译期分流，让各版本都传对类型，不必按内核版本开关补丁。
  #
  # 两个文件名都要试（各变体命名不同，且不存在时跳过）：
  #   lsm_hooks.c —— BakaSU / 官方系（Kbuild 里只在 < 6.8 时编，故实际不触发）
  #   lsm_hook.c  —— SukiSU builtin（ksu.c 用 #include 无条件把它并进来，必触发）
  if [ "${KSU_MODE}" != "禁用KSU" ]; then
    for LSM_HOOKS_C in KernelSU/kernel/hook/lsm_hooks.c \
                       KernelSU/kernel/hook/lsm_hook.c; do
      [ -f "$LSM_HOOKS_C" ] || continue
      grep -q 'KSU_LSM_ARG' "$LSM_HOOKS_C" && continue
      grep -q 'ARRAY_SIZE(ksu_hooks), "ksu"' "$LSM_HOOKS_C" || continue
      perl -0pi -e 's{security_add_hooks\(ksu_hooks,\s*ARRAY_SIZE\(ksu_hooks\),\s*"ksu"\)}{security_add_hooks(ksu_hooks, ARRAY_SIZE(ksu_hooks), KSU_LSM_ARG)}g' "$LSM_HOOKS_C"
      # 补上宏/变量定义本体。用 python 而不是 perl：早先这里用 perl -0pi 插块，
      # 结果整块文字被并进 `ksu_hooks[] = {` 那一行（预处理指令不在行首），
      # 死在 `178:49: error: expected expression` + `#endif without #if`。
      # 现在改成在数组定义前插入，定义用在哪（下面的 security_add_hooks 调用）
      # 之前，顺序天然正确。
      #
      # 锚点依然是 ksu_hooks 数组定义而不是 #include <linux/lsm_hooks.h>：
      # SukiSU builtin 的 lsm_hook.c 是被 ksu.c 用 #include 文本并入的"碎片"，
      # 文件里根本没有那行 include，锚点选错就会静默哑火、KSU_LSM_ARG 未定义。
      python3 - "$LSM_HOOKS_C" <<'PY'
import io, re, sys

path = sys.argv[1]
with io.open(path, "r", encoding="utf-8", newline="") as f:
    src = f.read()

m = re.search(r"^[ \t]*static struct security_hook_list[ \t]+ksu_hooks\[\]", src, re.M)
if not m:
    sys.exit(3)

block = (
    "/* 补记：KernelSU 上游写死传字符串字面量 \"ksu\"。\n"
    "   内核 v6.10 起 security_add_hooks 第三参改成了 const struct lsm_id *lsmid，\n"
    "   传字符串会类型不匹配直接编不过（v5.19~v6.6 还是 const char *，\n"
    "   旧写法在那几个版本能凑合编过）。这里按内核版本补实参宏。\n"
    "   字段是 name 不是 lsm：struct lsm_id 自 v6.9 起就是\n"
    "   `{ const char *name; u64 id; }`，security_add_hooks 内部只读 lsmid->name。\n"
    "   id 保持默认 0（上游也没给），本路径不读它。 */\n"
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 10, 0)\n"
    "static const struct lsm_id ksu_lsm_id = {\n"
    '    .name = "ksu"\n'
    "};\n"
    "#define KSU_LSM_ARG (&ksu_lsm_id)\n"
    "#else\n"
    '#define KSU_LSM_ARG "ksu"\n'
    "#endif\n"
)

with io.open(path, "w", encoding="utf-8", newline="") as f:
    f.write(src[: m.start()] + block + src[m.start():])
PY
      [ $? -eq 0 ] || echo "::error::为 ${LSM_HOOKS_C} 补充 security_add_hooks 宏定义失败"
      echo "已修复 6.10+ 的 security_add_hooks 签名：${LSM_HOOKS_C}"
    done
  fi

  # BBR 拥塞控制 —— 取自 ShirkNeko/GKI_KernelSU_SUSFS
  #
  # 门控必须先于开关：net/ipv4/Kconfig 里 TCP_CONG_BBR 与 DEFAULT_BBR 都写在
  # `if TCP_CONG_ADVANCED` 块内，门控不成立时这两个符号会被 Kconfig 屏蔽、
  # 根本不存在。而 GKI 的 gki_defconfig 基线里只有 6.6 带
  # CONFIG_TCP_CONG_ADVANCED=y，5.10 / 6.1 / 6.12 都没有。照上游原样只写开关
  # 不写门控，后三个版本上追加的就是没人认的死行 —— 写后校验 grep 的恰好是
  # 自己写进去的那一行，永远为真，看不出来，等于开了个空开关。
  #
  # 因此这里先打开 ADVANCED 门控。顺带必须把 BIC / WESTWOOD / HTCP 一并置 =y：
  # 这三个在 Kconfig 里是 `default m`，门控一开它们就被带进内核，编出 tcp_bic.ko
  # 之类而 GKI 的 module_outs 并未声明，bazel 会直接失败（理由同
  # stage_config_net_enhance 里关于 module_outs 的注释）。
  if [ "${USE_BBR}" = "true" ]; then
    # 保持自包含：ensure_net_cfg 定义在 stage_config_net_enhance 内部，而
    # config_kernel 阶段先于 config_net_enhance 执行，此刻它还不存在。
    ensure_bbr_cfg() {
      local line="$1" cfg="${1%%=*}"
      if grep -qxF "$line" "$DEFCONFIG"; then
        return 0
      fi
      if grep -Eq "^${cfg}=|^# ${cfg} is not set$" "$DEFCONFIG"; then
        sed -i -E "s|^${cfg}=.*|${line}|; s|^# ${cfg} is not set$|${line}|" "$DEFCONFIG"
      else
        echo "$line" >> "$DEFCONFIG"
      fi
    }

    ensure_bbr_cfg "CONFIG_TCP_CONG_ADVANCED=y"
    ensure_bbr_cfg "CONFIG_TCP_CONG_BBR=y"
    ensure_bbr_cfg "CONFIG_DEFAULT_BBR=y"
    ensure_bbr_cfg "CONFIG_TCP_CONG_BIC=y"
    ensure_bbr_cfg "CONFIG_TCP_CONG_WESTWOOD=y"
    ensure_bbr_cfg "CONFIG_TCP_CONG_HTCP=y"

    # 门控没落盘的话上面几条全是死行，宁可显式失败，也不要静默产出空开关
    if ! grep -qxF 'CONFIG_TCP_CONG_ADVANCED=y' "$DEFCONFIG"; then
      echo "::error::CONFIG_TCP_CONG_ADVANCED 未能落盘：TCP_CONG_BBR / DEFAULT_BBR 被 \`if TCP_CONG_ADVANCED\` 屏蔽，BBR 开关无效"
      return 1
    fi
    echo "启用 BBR 拥塞控制"
  fi

  cd "$_pwd"
}

run_config_kernel() { stage_config_kernel "$@"; }

stage_config_susfs() {
  log_stage "config_susfs" "添加 SUSFS 配置"
  local _pwd="$PWD"
  LINES_BEFORE=$(wc -l < "$DEFCONFIG")
  printf '%s\n' "${SUSFS_CONFIG_OPTIONS[@]}" >> "$DEFCONFIG"

  # 把本步实际追加的行导出为配置片段，随 SUSFS 集成补丁一起分发
  if [ "$SUSFS_PATCH_EXPORT" = "true" ] && [ -d "$WORKSPACE/susfs-patch" ]; then
    tail -n +$((LINES_BEFORE + 1)) "$DEFCONFIG" > "$WORKSPACE/susfs-patch/susfs.config"
    echo "已导出 SUSFS 配置片段: $(wc -l < "$WORKSPACE/susfs-patch/susfs.config") 行"
  fi

  cd "$_pwd"
}

# 条件执行（等价原工作流 if:）
run_config_susfs() {
  if [ "$ENABLE_SUSFS" = "true" ]; then
    stage_config_susfs "$@"
  else
    echo "跳过阶段: config_susfs（条件不满足）"
  fi
}

stage_verify_kconfig_decl() {
  log_stage "verify_kconfig_decl" "核对本次写入 defconfig 的功能符号是否被 Kconfig 声明"
  # 与其它阶段一致打印横幅：这一步在 CI 日志里必须是显式可见的一道门禁，
  # 而不是混在前一个阶段的输出里——它是编译前唯一能十秒内报出「符号没人认领」的地方。
  verify_kconfig_decl "$@"
}

run_verify_kconfig_decl() { stage_verify_kconfig_decl "$@"; }

stage_config_kernel_name() {
  log_stage "config_kernel_name" "配置内核名称"
  local _pwd="$PWD"
  # VERSION 会被直接内插进 perl/sed 程序文本，必须先白名单校验，
  # 否则含 ' " | $ / 等字符可逃逸引号并执行命令。
  # 校验提前到 cd 之前，失败即返回，不污染后续阶段的 cwd。
  local VERSION_INPUT
  VERSION_INPUT=$(echo "${VERSION:-}" | tr -d '[:space:]')
  if [ -n "$VERSION_INPUT" ]; then
    case "$VERSION_INPUT" in
      *[!A-Za-z0-9._-]*) echo "::error::VERSION 含非法字符，仅允许字母数字及 . _ -"; cd "$_pwd"; return 1 ;;
    esac
  fi
  cd "${KERNEL_ROOT}"
  if [ -f "build/build.sh" ]; then
    sed -i 's/-dirty//' ./common/scripts/setlocalversion
  else
    sed -i '/^[[:space:]]*"protected_exports_list"[[:space:]]*:[[:space:]]*"android\/abi_gki_protected_exports_aarch64",$/d' ./common/BUILD.bazel
    sed -i '/kmi_symbol_list_strict_mode/d' ./common/BUILD.bazel
    rm -rf ./common/android/abi_gki_protected_exports_*
    sed -i "/stable_scmversion_cmd/s/-maybe-dirty//g" ./build/kernel/kleaf/impl/stamp.bzl
  fi

  if [ -n "$VERSION_INPUT" ]; then
    CLEAN_VERSION=$(echo "$VERSION_INPUT" | sed -E 's/^[0-9]+\.[0-9]+\.[0-9]+//')
    perl -i -0777 -pe 's/(.*)echo "\$\{KERNELVERSION\}\$\{file_localversion\}\$\{config_localversion\}\$\{LOCALVERSION\}\$\{scm_version\}"/$1echo "\$\{KERNELVERSION\}'"${CLEAN_VERSION}"'"/s' ./common/scripts/setlocalversion 2>/dev/null || true
    sed -i "\$s|echo \"\$res\"|echo \"${CLEAN_VERSION}\"|" ./common/scripts/setlocalversion 2>/dev/null || true
    sed -i '/^CONFIG_LOCALVERSION=/ s/="\([^"]*\)"/="'"$CLEAN_VERSION"'"/' ./common/arch/arm64/configs/gki_defconfig
  elif [ ! -f "build/build.sh" ]; then
    cd ./common
    BID="ab$((RANDOM % 90000000 + 10000000))"
    GHASH=$(git rev-parse --verify HEAD | cut -c1-13)
    case "${ANDROID_VERSION}-${KERNEL_VERSION}" in
      "android14-6.1")  KMI_TAG="android14-11" ;;
      "android15-6.6")  KMI_TAG="android15-8" ;;
      "android16-6.12") KMI_TAG="android16-5" ;;
      *) KMI_TAG="${ANDROID_VERSION}" ;;
    esac

    if [ "${KERNEL_VERSION}" = "6.1" ]; then
      KMI_LOCAL="-${KMI_TAG}-g${GHASH}-${BID}-4k"
      sed -i "\$s|echo \"\$res\"|echo \"${KMI_LOCAL}\"|" ./scripts/setlocalversion 2>/dev/null || true
      sed -i "/^CONFIG_LOCALVERSION=/ s/=\"[^\"]*\"/=\"${KMI_LOCAL}\"/" ./arch/arm64/configs/gki_defconfig 2>/dev/null || true
    else
      SUFFIX="-${KMI_TAG}-g${GHASH}-${BID}"
      perl -i -0777 -pe 's/(.*)echo "\$\{KERNELVERSION\}\$\{file_localversion\}\$\{config_localversion\}\$\{LOCALVERSION\}\$\{scm_version\}"/$1echo "\$\{KERNELVERSION\}'"${SUFFIX}"'\$\{config_localversion\}"/s' ./scripts/setlocalversion 2>/dev/null || true
    fi
  fi

  cd "$_pwd"
}

run_config_kernel_name() { stage_config_kernel_name "$@"; }

stage_set_build_time() {
  log_stage "set_build_time" "设置自定义构建时间"
  local _pwd="$PWD"
  # 原函数内 `set -euo pipefail` 的 -u 会泄漏到后续所有阶段
  # （函数不创建子 shell），导致任一未绑定变量在编译后阶段莫名失败。
  # 改为与脚本顶层一致的 -eo pipefail，去掉 -u。
  set -eo pipefail

  local input_time="${BUILD_TIME:-}"
  if [[ -n "$input_time" && "$input_time" != "N" && "$input_time" != "n" ]]; then
    TIME_REGEX='^(Mon|Tue|Wed|Thu|Fri|Sat|Sun) (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) (0[1-9]|[12][0-9]|3[01]) ([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9] UTC [0-9]{4}$'
    if [[ ! "$input_time" =~ $TIME_REGEX ]]; then
      echo "::error title=构建时间格式错误::自定义构建时间必须形如 Thu Sep 17 00:00:00 UTC 2026，请删除多余前缀并使用两位日期。"
      return 1
    fi

    NORMALIZED_TIME="$(LC_ALL=C TZ=UTC date -u -d "$input_time" +'%a %b %d %T UTC %Y' 2>/dev/null || true)"
    if [[ "$NORMALIZED_TIME" != "$input_time" ]]; then
      echo "::error title=构建时间无效::自定义构建时间无法解析为真实 UTC 时间，或星期与日期不匹配。"
      return 1
    fi

    DATESTR="$input_time"
  else
    DATESTR="$(TZ='UTC' date +'%a %b %d %T %Z %Y')"
  fi

  echo "使用构建时间: $DATESTR"
  export KBUILD_BUILD_TIMESTAMP="$DATESTR"
  export KBUILD_BUILD_VERSION="1"

  # 统一处理 mkcompile_h 补丁
  f="$KERNEL_ROOT/common/scripts/mkcompile_h"
  if [ -f "$f" ]; then
    if [[ "${KERNEL_VERSION}" == "5.10" || "${KERNEL_VERSION}" == "5.15" ]]; then
      echo "应用 5.x 经典时间戳补丁: $f"
      perl -pi -e "s{UTS_VERSION=\"\\\$\(echo \\\$UTS_VERSION \\\$CONFIG_FLAGS \\\$TIMESTAMP \\| cut -b -\\\$UTS_LEN\)\"}{UTS_VERSION=\"#1 SMP PREEMPT $DATESTR\"}" "$f"
    else
      echo "应用 6.x mkcompile_h 补丁: $f"
      if grep -q 'UTS_VERSION=' "$f"; then
        perl -pi -e "s{UTS_VERSION=\"\\\$\\\(.*?\\\)\"}{UTS_VERSION=\"#1 SMP PREEMPT $DATESTR\"}" "$f"
      else
        perl -0777 -pi -e "s{cat <<EOF}{cat <<EOF\n#undef UTS_VERSION\n#define UTS_VERSION \"#1 SMP PREEMPT $DATESTR\" } unless /UTS_VERSION/" "$f"
    fi
  fi
fi

  cd "$_pwd"
}

run_set_build_time() { stage_set_build_time "$@"; }

compile_kernel_once() {
  local _pwd="$PWD"
  LOG_DIR="$WORKSPACE/build-logs"
  ATTEMPT_FILE="$LOG_DIR/.compile-attempt"
  mkdir -p "$LOG_DIR"

  # 为 retry 的每次执行生成独立日志
  ATTEMPT=1
  if [ -s "$ATTEMPT_FILE" ]; then
    read -r LAST_ATTEMPT < "$ATTEMPT_FILE"
    if [[ "$LAST_ATTEMPT" =~ ^[0-9]+$ ]]; then
      ATTEMPT=$((LAST_ATTEMPT + 1))
    fi
  fi
  echo "$ATTEMPT" > "$ATTEMPT_FILE"
  LOG_FILE="$LOG_DIR/compile-attempt-${ATTEMPT}.log"

  set -o pipefail
  {
    echo "编译尝试: $ATTEMPT"
    echo "开始时间: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "当前 KSU 最新提交日期: ${KSU_LATEST_COMMIT_DATE}"
    echo "当前 SUSFS 最新提交日期: ${SUSFS_LATEST_COMMIT_DATE}"
    set -ex
    cd "$KERNEL_ROOT"

    sed -i 's/BUILD_SYSTEM_DLKM=1/BUILD_SYSTEM_DLKM=0/' ./common/build.config.gki.aarch64
    sed -i '/MODULES_ORDER=android\/gki_aarch64_modules/d' ./common/build.config.gki.aarch64
    sed -i '/KMI_SYMBOL_LIST_STRICT_MODE/d' ./common/build.config.gki.aarch64

    if [ -f "build/build.sh" ]; then
      # 显式钉住输出目录：GKI 的 build/build.sh 会把 OUT_DIR / DIST_DIR 当作外部环境继承，
      # 一旦外层存在同名变量（哪怕只是补丁导出用的临时目录），产物就会落到预期之外的位置。
      OUT_DIR="$KERNEL_ROOT/out/${ANDROID_VERSION}-${KERNEL_VERSION}" \
      DIST_DIR="$KERNEL_ROOT/out/${ANDROID_VERSION}-${KERNEL_VERSION}/dist" \
      LTO=thin \
      BUILD_CONFIG=common/build.config.gki.aarch64 \
      build/build.sh CC="/usr/bin/ccache clang" || {
        echo "::error::build.sh 返回非零，列出实际产出以便定位"
        find "$KERNEL_ROOT/out" -maxdepth 3 -name Image -o -maxdepth 3 -name Image.lz4 2>/dev/null | head
        exit 1
      }
      # strings|grep 原本是阶段末条命令，在 set -ex 下若镜像中恰好
      # 不含连续字符串 'Linux version'（极少见，如镜像被定制），grep 返回 1 会令
      # 整个阶段被判失败 → 误报构建失败。成功判定仍交给 build.sh 退出码。
      # 这里用进程替换而非管道：本块顶部有 set -o pipefail，`strings | grep -q`
      # 命中时 grep 提前退出会让 strings 收到 SIGPIPE(141)，整条管道被判非零，
      # 反倒把「找到了」报成「未找到」。进程替换下只有 grep 的退出码参与判定。
      if grep -q 'Linux version' <(strings "out/${ANDROID_VERSION}-${KERNEL_VERSION}/dist/Image" 2>/dev/null); then
        echo "内核版本字符串校验通过"
      else
        echo "::warning::dist/Image 中未找到 'Linux version' 字符串，构建仍按 build.sh 退出码判定（若镜像被定制请人工确认）"
      fi
    else
      # 提取 gki_defconfig 修改到 fragment，避免 bazel trim 检查失败
      FRAG="common/arch/arm64/configs/ksu.fragment"
      diff "$DEFCONFIG.orig" "$DEFCONFIG" | grep '^>' | sed 's/^> //; s/^[[:space:]]*//' > "$FRAG" || true
      cp "$DEFCONFIG.orig" "$DEFCONFIG"
      echo "=== KSU Fragment 内容 ==="
      cat "$FRAG"
      echo "========================="
      FRAG_FLAG=""
      if [ -s "$FRAG" ]; then
        FRAG_FLAG="--defconfig_fragment=//common:arch/arm64/configs/ksu.fragment"
      fi
      LTO_FLAG="--lto=thin"
      if [ "${KERNEL_VERSION}" = "6.12" ]; then
        LTO_FLAG="--lto=none"
      fi
      tools/bazel build --disk_cache=/home/runner/.cache/bazel --config=fast $LTO_FLAG $FRAG_FLAG //common:kernel_aarch64_dist || exit 1
      # 同上：strings|grep 不当成功闸门，改为显式校验不误报；
      # 同样用进程替换避开 pipefail 下 grep -q 提前退出触发的 SIGPIPE 假失败。
      if grep -q 'Linux version' <(strings ./bazel-bin/common/kernel_aarch64/Image 2>/dev/null); then
        echo "内核版本字符串校验通过"
      else
        echo "::warning::bazel Image 中未找到 'Linux version' 字符串，构建仍按 bazel 退出码判定（若镜像被定制请人工确认）"
      fi
    fi

    echo "当前 KSU 最新提交日期: ${KSU_LATEST_COMMIT_DATE}"
    echo "当前 SUSFS 最新提交日期: ${SUSFS_LATEST_COMMIT_DATE}"
    echo "如果日期不同或相差过远则补丁失效、编译失败"
  } 2>&1 | tee "$LOG_FILE"

  BUILD_STATUS=${PIPESTATUS[0]}
  {
    echo "结束时间: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "退出码: $BUILD_STATUS"
  } >> "$LOG_FILE"
  exit "$BUILD_STATUS"

  cd "$_pwd"
}

stage_compile_kernel() {
  log_stage "compile_kernel" "编译内核"
  local attempt=1 rc=0
  export -f compile_kernel_once
  while [ "$attempt" -le "$COMPILE_MAX_ATTEMPTS" ]; do
    echo "编译尝试 $attempt/$COMPILE_MAX_ATTEMPTS"
    if timeout -k 60 "${COMPILE_TIMEOUT_MINUTES}m" bash -c "compile_kernel_once"; then
      rc=0; break
    else
      rc=$?
      echo "编译失败（退出码 $rc）"
    fi
    attempt=$((attempt + 1))
  done
  # 供 collect_fail_log 写入 summary.txt。
  export COMPILE_ATTEMPTS=$(( attempt > COMPILE_MAX_ATTEMPTS ? COMPILE_MAX_ATTEMPTS : attempt ))
  export COMPILE_EXIT_CODE=$rc
  if [ "$rc" -ne 0 ]; then export COMPILE_FAILED=1; fi
  return $rc
}

run_compile_kernel() { stage_compile_kernel "$@"; }

# 「写进 defconfig」不等于「编进内核」。
#
# config_kernel 阶段已经 sed 掉了 build.config.gki 的 check_defconfig，于是
# 「defconfig 里写了、Kconfig 里没人认领」的开关会被静默丢弃：构建绿、内核能开机、
# 功能一行都没编进去。SUSFS 侧有 verify_susfs_kconfig 核对 Kconfig 声明；
# BBG / zram / 网络增强此前谁都没核对过最终产物 —— 安装动作或写入动作成功，
# 不等于符号被 Kconfig 认领。
#
# 这里在编译结束后核对 Kbuild 真正产出的 .config，而不是回读我们自己刚写进
# defconfig 的那几行（那只是同义反复：文件里当然有我们写进去的东西）。
# 另刻意核对 CONFIG_LSM 字符串本身：security/Kconfig 里 config LSM 的 default
# 只是兜底串，若 gki_defconfig 显式写了 CONFIG_LSM="..."，stage_add_bbg 那句 sed
# 完全无效——只看 Kconfig 查不出来。
#
# 注意 SKIPPED_PHASES 必须在同一进程内可读：写 GITHUB_ENV 只对**后续 step** 生效，
# 对本进程内的 phase_was_skipped 毫无作用，故调度器同时赋值并导出该变量。
phase_was_skipped() {
  case " ${SKIPPED_PHASES:-} " in
    *" $1 "*) return 0 ;;
    *)        return 1 ;;
  esac
}

stage_verify_config_landing() {
  log_stage "verify_config_landing" "核对请求的功能是否真正编进内核（核对生成的 .config）"

  local -a expect=() fails=() skipped=()
  local e line why

  # 被 SKIP_INCOMPATIBLE 显式降级的阶段不参与校验：降级是调用方的显式选择，
  # 已在 SKIPPED_PHASES / step summary 留痕，把它再判成失败等于否定该选择。
  expect_symbol() {
    if phase_was_skipped "$2"; then
      skipped+=("$2（$3）")
      return 0
    fi
    expect+=("$1|$3")
  }

  if [ "${USE_BBG}" = "true" ]; then
    expect_symbol 'CONFIG_BBG=y' add_bbg "BBG 本体"
  fi
  # ZRAM_LZ4K_OK=0 表示补丁栈缺失、config_zram 已主动跳过（有告警），
  # 此时 defconfig 根本没被写过，不该按「BBG 式落盘」判失败。
  if [ "${USE_ZRAM}" = "true" ] && [ "${ZRAM_LZ4K_OK:-0}" = "1" ]; then
    expect_symbol 'CONFIG_ZRAM=y'                 config_zram "zram 本体"
    expect_symbol 'CONFIG_ZSMALLOC=y'             config_zram "zsmalloc 后端"
    expect_symbol 'CONFIG_CRYPTO_LZ4KD=y'         config_zram "lz4kd 压缩算法"
    expect_symbol 'CONFIG_ZRAM_DEF_COMP_LZ4KD=y'  config_zram "zram 默认压缩算法"
  fi
  if [ "${USE_NET_ENHANCE}" = "true" ]; then
    # DEFAULT_TCP_CONG 是 string，不是 choice 成员：只写 DEFAULT_BBR=y 时
    # 内核可能仍以 cubic 为默认（net/ipv4/Kconfig 的 default "bbr" if DEFAULT_BBR
    # 是推导值），必须核对这行 string 本身。
    expect_symbol 'CONFIG_DEFAULT_TCP_CONG="bbr"' config_net_enhance "BBR 设为默认拥塞控制"
    expect_symbol 'CONFIG_TCP_CONG_BBR=y'         config_net_enhance "BBR 算法本体"
    expect_symbol 'CONFIG_IP_SET=y'               config_net_enhance "IPSet"
    expect_symbol 'CONFIG_IP_SET_MAX=65534'       config_net_enhance "IPSet 容量"
    expect_symbol 'CONFIG_NET_SCH_FQ=y'           config_net_enhance "fq 队列调度"
    expect_symbol 'CONFIG_NETFILTER_XT_SET=y'     config_net_enhance "xt_set 匹配"
  fi

  if [ "${#skipped[@]}" -gt 0 ]; then
    echo "::warning::以下功能已按 SKIP_INCOMPATIBLE 显式降级，不参与落盘校验：${skipped[*]}"
  fi
  if [ "${#expect[@]}" -eq 0 ]; then
    echo "没有请求需要核对的内核功能（BBG/zram/网络增强均未启用或均已显式降级），跳过落盘校验"
    return 0
  fi

  local -a candidates=()
  local found="" c=""
  # 两套构建路径落点不同：build.sh（android12/13 走 out/），kleaf/bazel（其余走 bazel-bin/）。
  candidates=(
    "$KERNEL_ROOT/out/${ANDROID_VERSION}-${KERNEL_VERSION}/.config"
    "$KERNEL_ROOT/out/${ANDROID_VERSION}-${KERNEL_VERSION}/common/.config"
    "$KERNEL_ROOT/bazel-bin/common/kernel_aarch64/.config"
  )
  for c in "${candidates[@]}"; do
    if [ -s "$c" ]; then found="$c"; break; fi
  done
  if [ -z "$found" ]; then
    found=$(find "$KERNEL_ROOT/out" "$KERNEL_ROOT/bazel-bin" \
      -maxdepth 6 -type f -name '.config' -size +0c -print 2>/dev/null | head -n1 || true)
  fi
  if [ -z "$found" ]; then
    echo "::error title=功能落盘校验失败::找不到 Kbuild 生成的 .config，无法证明请求的功能进了内核"
    echo "::error::已查找: ${candidates[*]}，以及 out/ 与 bazel-bin/ 下 6 层内的 .config"
    return 1
  fi
  echo "核对对象（Kbuild 生成的 .config）: $found"

  for e in "${expect[@]}"; do
    line="${e%%|*}"; why="${e#*|}"
    grep -qxF "$line" "$found" \
      || fails+=("$line 不在生成的 .config 里（$why）：Kconfig 未认领该符号，被静默丢弃")
  done

  # CONFIG_LSM 是「字符串里含某个词」的形式，不能整行精确匹配。
  # 只有当 BBG 真正请求且未被降级时才核对。
  if [ "${USE_BBG}" = "true" ] && ! phase_was_skipped add_bbg; then
    grep -qE '^CONFIG_LSM="(.*,)?baseband_guard(,.*)?"' "$found" \
      || fails+=("CONFIG_LSM 不含 baseband_guard（BBG 的 LSM 挂钩）：security/Kconfig 里 config LSM 的 default 未被采用（gki_defconfig 已显式写 CONFIG_LSM 时那句 sed 无效）")
  fi

  if [ "${#fails[@]}" -gt 0 ]; then
    echo "::error title=功能落盘校验失败::${#fails[@]} 项请求的功能未落进生成的 .config，不会编进内核"
    printf '  - %s\n' "${fails[@]}"
    echo "::error::此处中断，不产出「声称启用、实际没有」的可刷产物"
    return 1
  fi
  echo "功能落盘校验通过：生成的 .config 已认领全部 ${#expect[@]} 项请求"
}

run_verify_config_landing() { stage_verify_config_landing "$@"; }

stage_collect_fail_log() {
  log_stage "collect_fail_log" "整理编译失败日志"
  local _pwd="$PWD"
  LOG_DIR="$WORKSPACE/build-logs"
  mkdir -p "$LOG_DIR"

  {
    echo "Android 版本: ${ANDROID_VERSION}"
    echo "内核版本: ${KERNEL_VERSION}.${SUB_LEVEL}"
    echo "安全补丁级别: ${OS_PATCH_LEVEL}"
    echo "KernelSU 变体: ${KSU_VARIANT}"
    echo "配置名称: ${CONFIG:-未知}"
    echo "Git 提交: $GITHUB_SHA"
    echo "工作流地址: $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
    echo "编译尝试次数: ${COMPILE_ATTEMPTS:-未知}"
    echo "最终退出码: ${COMPILE_EXIT_CODE:-未知}"
    echo "KSU 提交日期: ${KSU_LATEST_COMMIT_DATE:-未知}"
    echo "SUSFS 提交日期: ${SUSFS_LATEST_COMMIT_DATE:-未知}"
  } > "$LOG_DIR/summary.txt"

  printf '%s\n' "${KSU_VARIANT}_kernel-${CONFIG}-Build-Logs" > "$LOG_DIR/artifact-name.txt"

  df -h "$WORKSPACE" > "$LOG_DIR/disk-usage.txt" 2>&1 || true
  ccache -s > "$LOG_DIR/ccache-stats.txt" 2>&1 || true

  cd "$_pwd"
}

# 条件执行（等价原工作流 if:）
run_collect_fail_log() {
  if [ "$COMPILE_FAILED" = "1" ]; then
    stage_collect_fail_log "$@"
  else
    echo "跳过阶段: collect_fail_log（条件不满足）"
  fi
}

stage_patch_kpm_image() {
  log_stage "patch_kpm_image" "修补 Image（KPM）"
  local _pwd="$PWD"

  # 移植自 ShirkNeko/GKI_KernelSU_SUSFS 的 patch_kpm_image()
  # 用 SukiSU_patch 的 kpm/patch_linux 对编译产物 Image 打补丁，使其具备加载
  # KPM 模块的能力。仅在开启 KPM 且非 6.6 内核时执行。
  case "${USE_KPM}" in
    enabled*|patched*) ;;
    *)
      echo "KPM 未开启，跳过镜像修补"
      cd "$_pwd"
      return 0
      ;;
  esac

  # 变体内核不提供 KPM 时整段跳过：Image 里压根没有 KPM 支持，修补毫无意义，
  # 反而可能改坏产物。KPM_SUPPORTED 由 stage_add_kernelsu 算好。
  if [ "${KPM_SUPPORTED:-1}" = "0" ]; then
    # 别写成"变体不提供 KPM"：KPM_SUPPORTED=0 有两个来源（变体不带 KPM 代码、
    # 或内核 ≥ 6.10 带不动那段代码），这里两种都落在这条分支上，写死一种会误导。
    echo "跳过 KPM 镜像修补：本次构建未启用 KPM（变体不提供或内核版本过新，见 stage_add_kernelsu 的告警）"
    cd "$_pwd"
    return 0
  fi

  if [ "${KERNEL_VERSION}" = "6.6" ]; then
    echo "6.6 内核不支持 KPM 镜像修补，跳过"
    cd "$_pwd"
    return 0
  fi

  # patch_linux 来自 SukiSU-Ultra/SukiSU_patch（上游未声明许可）。
  # 严格许可模式下不使用该工具，保留未修补的原始 Image（KPM 模块加载能力不生效）。
  if [ "${STRICT_LICENSE_MODE:-false}" = "true" ]; then
    echo "跳过 KPM 镜像修补（STRICT_LICENSE_MODE=true：排除 SukiSU_patch 未声明许可的 patch_linux）"
    echo "::warning::严格许可模式：Image 未做 KPM 修补，内核将无法加载 KPM 模块"
    cd "$_pwd"
    return 0
  fi

  local image_dir
  if [ "${ANDROID_VERSION}" = "android12" ] || [ "${ANDROID_VERSION}" = "android13" ]; then
    image_dir="$KERNEL_ROOT/out/${ANDROID_VERSION}-${KERNEL_VERSION}/dist"
  else
    image_dir="$KERNEL_ROOT/bazel-bin/common/kernel_aarch64"
  fi

  if [ ! -d "$image_dir" ]; then
    echo "::warning::未找到镜像目录 $image_dir，跳过 KPM 修补"
    cd "$_pwd"
    return 0
  fi

  cd "$image_dir"
  echo "在 $image_dir 执行 KPM 镜像修补"

  if [ ! -s Image ]; then
    echo "::warning::Image 不存在或为空，跳过 KPM 修补"
    cd "$_pwd"
    return 0
  fi
  orig_size=$(stat -c %s Image)

  # 解析锚点：环境变量 → config/kpm_patch_sha256 → 空
  local kpm_expected="${EXPECTED_KPM_PATCH_SHA256:-}"
  local kpm_pin_file="$WORKSPACE/config/kpm_patch_sha256"
  if [ -z "$kpm_expected" ] && [ -f "$kpm_pin_file" ]; then
    kpm_expected=$(tr -d '[:space:]' < "$kpm_pin_file")
    [ -n "$kpm_expected" ] && echo "KPM 锚点来源: $kpm_pin_file"
  fi
  if [ -z "$kpm_expected" ]; then
    echo "::warning::未配置 KPM 修补工具 sha256 锚点（EXPECTED_KPM_PATCH_SHA256 与 config/kpm_patch_sha256 均为空），本次为零锚点运行：上游变更无法被察觉。可用 scripts/tools/pin_kpm_patch.sh 生成锚点。"
  fi

  # 下载后显式校验，chmod 755（原 777 过度放权），可选 sha256 比对
  if ! curl -LSsf "$KPM_PATCH_URL" -o patch; then
    echo "::warning::下载 KPM 修补工具失败，跳过（不影响其余产物）"
  else
    chmod 755 patch
    KPM_SHA=$(sha256sum patch | awk '{print $1}')
    echo "KPM 修补工具 sha256: $KPM_SHA"
    # 无论是否配置锚点都回显可复制的 pin 值，便于事后取证与生成锚点
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      printf 'KPM 修补工具（`patch_linux`）sha256：`%s`\n' "$KPM_SHA" >> "$GITHUB_STEP_SUMMARY" 2>/dev/null || true
    fi
    if [ -n "$kpm_expected" ]; then
      if [ "$KPM_SHA" != "$kpm_expected" ]; then
        echo "::error::KPM 修补工具 sha256 不匹配（期望 $kpm_expected，实际 $KPM_SHA），拒绝执行 KPM 修补并中止构建"
        rm -f patch
        cd "$_pwd"
        return 1
      fi
      echo "KPM 修补工具 sha256 校验通过（锚点一致）"
    fi
    if ! ./patch; then
      echo "::warning::KPM 修补脚本返回非零，请查看上方输出"
    elif [ -f oImage ]; then
      # 安全性校验：修补产物必须与原始 Image 体积相当。
      # patch 工具失败时会产出一个很小的残缺 oImage，一旦直接替换，
      # 后续打包出的 AnyKernel3 里就会是一个几百 KB 的假内核。
      new_size=$(stat -c %s oImage)
      if [ "$new_size" -lt $((orig_size * 80 / 100)) ]; then
        echo "::warning::oImage 体积异常（原始 ${orig_size} 字节 -> 修补后 ${new_size} 字节），判定为修补失败，保留原始 Image"
        rm -f oImage
      else
        mv oImage Image
        echo "已用修补产物 oImage 替换 Image（${orig_size} -> ${new_size} 字节）"
      fi
    else
      echo "::warning::未生成 oImage，KPM 修补未生效，保留原始 Image"
    fi
  fi
  rm -f patch

  cd "$_pwd"
}

run_patch_kpm_image() { stage_patch_kpm_image "$@"; }

# ---------------------------------------------------------------------------
# 按最终 Image 重建 Image.lz4。
#
# 背景：KPM 镜像修补会 `mv oImage Image` 替换掉最终 Image，但同目录的 Image.lz4
# 仍是旧 Image 的压缩结果。boot-lz4.img 直接拿它打包 → 刷进手机的是未打补丁的内核。
#
# 为什么不 `make O=... Image.lz4` 让 kbuild 重压：本脚本从不直接调用 make，内核由
# build/build.sh（或 bazel）构建，手工复现 ARCH/CROSS_COMPILE/CC/LLVM/LZ4 全套环境
# 一旦漏参数，等于用一个新的不确定性替换旧的不确定性。
#
# 做法：读取 kbuild 为 if_changed 落下的 .Image.lz4.cmd —— 里面是它上次生成时完全
# 展开后的命令行，-l / -12 / --favor-decSpeed / size_append 一并在内 —— 在 objtree
# 下原样重放（.cmd 里的相对路径锚在 objtree 上，CWD 不对就会读到错的/不存在的输入）；
# 读不到就退回标准 legacy 参数。无论走哪条，都必须通过两道产出侧硬校验：
#   1. 首 4 字节是 LZ4 legacy 帧魔数 02 21 4C 18（现代帧 bootloader 拒收 → 变砖）
#   2. 解压后与最终 Image 逐字节相同（证明内容就是最终内核）
# 任一道不过 → 返回非零，调用方不产出 boot-lz4.img。
#
# 关于 .cmd 的转义，有两个必须处理的坑（否则 eval 必失败）：
#   1) kbuild 用 `printf '%s\n' 'cmd_$@ := $(make-cmd)'` 写出该文件，make-cmd 会把
#      命令里的每个 `'` 转成 `'\''`（escsq），使整条命令能被单引号包裹。这层转义
#      只在 make 的 printf 上下文里成立；直接 eval 会得到引号不配对的语法错误。
#      这里先做反转义还原成原始命令。
#   2) `$(size_append)` 展开后是一串常量 `printf '\273\326\002\000'`（无路径），
#      不会在下面的路径替换中被误伤；但它记录的是 kbuild 生成时的 Image 大小，
#      KPM 修补后可能过期。它写在压缩流之外，lz4 -dc 不会吐出这 4 字节，
#      因此不影响校验 2 —— 保留原样即可。
# ---------------------------------------------------------------------------
rebuild_image_lz4() {
  local final_image="$1"   # 最终 Image 的绝对路径
  local output="$2"        # 目标 Image.lz4 的绝对路径
  local kernel_root="$3"   # 内核源码树根（用于搜索 kbuild 的 .cmd）
  local lz4_bin="" cmdfile="" objtree="" target="" cmd="" tmpdir="" tmp_out="" magic="" image_size=""
  local probe_out="" probe_rc="" probe_sz=""

  _lz4_bail() {
    echo "::warning::Image.lz4 重建失败：$1"
    rm -rf "$tmpdir"
    return 1
  }

  [ -s "$final_image" ] || { _lz4_bail "最终 Image 不存在或为空: $final_image"; return 1; }

  for b in lz4 lz4c; do
    if command -v "$b" >/dev/null 2>&1; then lz4_bin="$b"; break; fi
  done
  [ -n "$lz4_bin" ] || { _lz4_bail "找不到可用的 lz4 / lz4c"; return 1; }

  tmpdir=$(mktemp -d) || { _lz4_bail "无法创建临时目录"; return 1; }
  cp -f "$final_image" "$tmpdir/Image" || { _lz4_bail "无法复制 Image 到临时目录"; return 1; }
  tmp_out="$tmpdir/Image.lz4"

  # objtree：.cmd 里的相对路径全部锚在这里
  objtree="${kernel_root}/out/${ANDROID_VERSION}-${KERNEL_VERSION}"
  cmdfile="${objtree}/arch/arm64/boot/.Image.lz4.cmd"
  if [ ! -s "$cmdfile" ]; then
    # 限定到当前版本子目录，避免多 Android/Kernel 版本 out/ 共存时命中其他分支的 .cmd
    cmdfile=$(find "$objtree" -name '.Image.lz4.cmd' -print -quit 2>/dev/null)
  fi

  if [ -n "$cmdfile" ] && [ -s "$cmdfile" ]; then
    target=$(sed -n 's/^cmd_\([^ ]*\) := .*/\1/p' "$cmdfile" | head -n1)
    cmd=$(sed -n 's/^cmd_[^ ]* := //p' "$cmdfile" | head -n1)
  fi

  if [ -n "$target" ] && [ -n "$cmd" ]; then
    # 反转义 kbuild 的 escsq：'\'' → '
    # （kbuild 为把整条命令塞进单引号，把每个 ' 写成 '\''；eval 前必须还原）
    cmd=${cmd//"'\\''"/"'"}
    # 只替换独立的输入/输出路径，避免误伤引号内的常量与其它 token：
    #   输出 .lz4 → 临时 .lz4（先替换更长的那段，否则会被输入替换吃掉）
    #   输入 Image → 临时 Image
    cmd=${cmd//"$target"/"$tmp_out"}
    cmd=${cmd//"${target%.lz4}"/"$tmpdir/Image"}
  else
    # 没有 .cmd 也能干活：legacy 路径不依赖它，只是少了一条回退途径
    cmd=""
  fi

  local _saved_pwd="$PWD"
  local _legacy_cmd="cat $tmpdir/Image | $lz4_bin -l -9 - - > $tmp_out"
  local _used=""

  # 产出校验：魔数 + 与最终 Image 逐字节一致。两种压缩途径共用同一套判定，
  # 任一不过就换另一条途径重试，两条都不行才放弃（宁缺勿错）。
  # 失败时把「产物大小 + 末 4 字节 + 解压字节数」记进 _lz4_reason，
  # 让最终告警能自证是哪一步挂了，而不是一句笼统的"内容不一致"。
  local _lz4_reason=""
  _lz4_compress_probe() {
    # 先记录最后一字节：lz4 legacy 产物的末 4 字节必然是原始大小（小端）。
    # 若它等于 Image 大小而全文仍对不上，说明是 lz4 把尾块补零/截断，
    # 这正是"体积一致但 cmp 失败"的典型形态。
    probe_sz=$(stat -c %s "$tmp_out" 2>/dev/null || echo "?")
    local _tail4; _tail4=$(tail -c 4 "$tmp_out" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')
    probe_out=$("$lz4_bin" -dc "$tmp_out" 2>&1 >/dev/null)
    probe_rc=$?
    _lz4_reason="产物 ${probe_sz} 字节，末4字节 ${_tail4:-无}"
    if [ "$probe_rc" -ne 0 ]; then
      _lz4_reason="$_lz4_reason；lz4 -d 退出码 $probe_rc（$probe_out）"
      return 1
    fi
    return 0
  }

  _lz4_produced_ok() {
    [ -s "$tmp_out" ] || { _lz4_reason="产物不存在或为空"; return 1; }
    magic=$(od -An -tx1 -N4 "$tmp_out" 2>/dev/null | tr -d ' \n')
    if [ "$magic" != "02214c18" ]; then
      _lz4_reason="帧魔数 ${magic:-无} ≠ 02214c18（非 legacy，GKI bootloader 会拒收）"
      return 1
    fi
    _lz4_compress_probe || return 1
    image_size=$(stat -c %s "$final_image")
    local _decoded; _decoded=$("$lz4_bin" -dc "$tmp_out" 2>/dev/null | wc -c)
    if [ "$_decoded" != "$image_size" ]; then
      _lz4_reason="$_lz4_reason；解压 ${_decoded} 字节 ≠ Image ${image_size} 字节"
      return 1
    fi
    if ! "$lz4_bin" -dc "$tmp_out" 2>/dev/null | cmp -s - "$final_image"; then
      # 体积一致但内容不一致 → 差异在内部，定位首个不同字节的偏移，便于判断
      # 是压缩器行为异常还是源 Image 在中途被换掉
      local _off; _off=$("$lz4_bin" -dc "$tmp_out" 2>/dev/null | cmp -l - "$final_image" 2>/dev/null | head -n1 | awk '{print $1}')
      _lz4_reason="$_lz4_reason；解压结果与最终 Image 内容不一致（首个差异偏移 ${_off:-未知}，总长一致 ${image_size} 字节）"
      return 1
    fi
    return 0
  }

  # 途径 1：标准 legacy 参数（-l -9）。这是主路径。
  # 为什么不让 kbuild 的原命令当主路径：它的 `-12 --favor-decSpeed` 配合
  # `$(size_append)` 在压缩流尾部追加的 4 字节原始长度，会让校验器（要逐字节
  # 比对解压结果）报错 —— 那 4 字节不在 lz4 帧内。而 -l -9 产出的是标准 legacy
  # 帧，GKI bootloader 认，解压结果与 Image 完全一致。压缩率差异只影响体积，
  # 不影响可刷性，不值得为几十 KB 冒 boot 变砖的风险。
  cd "$_saved_pwd" 2>/dev/null || cd /
  rm -f "$tmp_out"
  if ! ( eval "$_legacy_cmd" ) 2>/tmp/lz4-rebuild.log; then
    { _lz4_bail "legacy 重压失败: $(tail -n1 /tmp/lz4-rebuild.log 2>/dev/null)"; return 1; }
  fi
  if _lz4_produced_ok; then
    _used="legacy -l -9"
  else
    # 途径 2：退回重放 kbuild 记录的原始命令（可能含 size_append 尾巴，
    # 校验更严，能过就用它，毕竟与官方构建产物参数一致）
    if [ -s "$cmdfile" ] && [ -n "$cmd" ]; then
      echo "::warning::标准 legacy 重压未通过校验（${_lz4_reason}），回退重放 kbuild 原命令"
      cd "$_saved_pwd" 2>/dev/null || cd /
      rm -f "$tmp_out"
      [ -d "$objtree" ] && cd "$objtree" 2>/dev/null || true
      if ( eval "$cmd" ) 2>/tmp/lz4-rebuild.log; then
        cd "$_saved_pwd" 2>/dev/null || cd /
        _lz4_produced_ok && _used="kbuild .cmd"
      else
        cd "$_saved_pwd" 2>/dev/null || cd /
      fi
    fi
    if [ -z "$_used" ]; then
      _lz4_bail "两条压缩途径均未产出合格 Image.lz4（${_lz4_reason}；lz4=$($lz4_bin --version 2>&1 | head -n1)）"
      return 1
    fi
  fi

  # 无论走哪条路径，出口都必须回到调用方的工作目录
  cd "$_saved_pwd" 2>/dev/null || cd /
  cp -f "$tmp_out" "$output" || { _lz4_bail "无法写入 $output"; return 1; }
  rm -rf "$tmpdir"
  echo "Image.lz4 已按最终 Image 重建并通过双重校验（$(stat -c %s "$output") 字节，legacy 帧，来源: ${_used}）"
  return 0
}

# AnyKernel3 刷机包文件名：打包与拷贝两条路径必须一致
anykernel3_zip_name() {
  echo "${ANDROID_VERSION}-${KERNEL_VERSION}.${NAME_SUBLEVEL}-${OS_PATCH_LEVEL}-AnyKernel3.zip"
}

stage_prepare_boot() {
  log_stage "prepare_boot" "准备 Boot 镜像"
  local _pwd="$PWD"
  mkdir -p bootimgs

  if [ "${ANDROID_VERSION}" == "android12" ] || [ "${ANDROID_VERSION}" == "android13" ]; then
    SRC_DIR="$KERNEL_ROOT/out/${ANDROID_VERSION}-${KERNEL_VERSION}/dist"
  else
    SRC_DIR="$KERNEL_ROOT/bazel-bin/common/kernel_aarch64"
  fi

  # 兜底校验：走到这一步时 Image 必须已编译出来且体积合理。
  # 曾经因为上游阶段误用 exit 0 提前"成功"退出，编译一次都没跑却照样打包，
  # 产出一个只含 AnyKernel3 模板的空壳刷机包，因此这里做硬性体积校验。
  if [ ! -s "$SRC_DIR/Image" ]; then
    echo "::error::未找到内核镜像: $SRC_DIR/Image（编译可能并未真正执行）"
    return 1
  fi
  IMAGE_SIZE=$(stat -c %s "$SRC_DIR/Image")
  MIN_IMAGE_SIZE=$((10 * 1024 * 1024))
  if [ "$IMAGE_SIZE" -lt "$MIN_IMAGE_SIZE" ]; then
    echo "::error::内核镜像体积异常: ${IMAGE_SIZE} 字节（预期大于 10MB），拒绝打包"
    return 1
  fi
  echo "内核镜像校验通过: ${IMAGE_SIZE} 字节"

  cp "$SRC_DIR/Image" ./bootimgs/
  cp "$SRC_DIR/Image" ./
  # 原写法 `gzip ... > ./Image.gz` 是多余的覆盖式重定向：一旦 gzip 失败，
  # 也会留下一个 0 字节的 Image.gz，进而被打进 boot-gz.img。去掉并做非空校验。
  gzip -n -k -f -9 ./Image
  if [ ! -s ./Image.gz ]; then
    echo "::error::Image.gz 生成失败或为空，拒绝继续打包"
    return 1
  fi

  # Image.lz4 必须与"最终" Image 对应：KPM 镜像修补会替换 Image，
  # 沿用编译期产出的 lz4 会把未打补丁的内核打进 boot-lz4.img。
  # 重建失败（含找不到 lz4、校验不过）时不产出 lz4 镜像，宁缺勿错。
  export LZ4_KERNEL_READY=0
  if rebuild_image_lz4 "$PWD/Image" "$PWD/Image.lz4" "$KERNEL_ROOT"; then
    cp ./Image.lz4 ./bootimgs/
    export LZ4_KERNEL_READY=1
  else
    echo "::warning::本次不打包 boot-lz4.img：错误的 lz4 会让刷机者拿到旧内核"
    rm -f ./Image.lz4 ./bootimgs/Image.lz4
  fi

  cd "$_pwd"
}

run_prepare_boot() { stage_prepare_boot "$@"; }

stage_make_anykernel3() {
  log_stage "make_anykernel3" "创建 AnyKernel3 压缩包"
  local _pwd="$PWD"
  cd "$ANYKERNEL3"
  ZIP_NAME="$(anykernel3_zip_name)"
  mv ../Image ./Image
  # B-4：用 . 而非 ./*，否则以 . 开头的隐藏条目会被通配符漏掉；顺带排除 .git*
  zip -r "../$ZIP_NAME" . -x '*.git*'

  cd "$_pwd"
}

# 条件执行（等价原工作流 if:）
run_make_anykernel3() {
  if [ "$ARTIFACT_UPLOAD_MODE" = "上传全部" ]; then
    stage_make_anykernel3 "$@"
  else
    echo "跳过阶段: make_anykernel3（条件不满足）"
  fi
}

stage_prepare_anykernel3() {
  log_stage "prepare_anykernel3" "准备 AnyKernel3 目录"
  local _pwd="$PWD"
  mv ./Image "$ANYKERNEL3/Image"

  # make_anykernel3 只在「上传全部」模式下执行，而本阶段只在非「上传全部」
  # 模式下执行，两者条件互斥 —— 非「上传全部」时 Image 被搬进 AnyKernel3 目录
  # 却没有任何一步打包，结果是一个刷机包都不产出。这里补上打包。
  local _zip
  _zip="$(anykernel3_zip_name)"
  # B-4：用 . 而非 ./*，否则以 . 开头的隐藏条目会被通配符漏掉；顺带排除 .git*
  ( cd "$ANYKERNEL3" && zip -r "../$_zip" . -x '*.git*' )
  if [ ! -s "$_zip" ]; then
    echo "::error::AnyKernel3 刷机包生成失败或为空: $_zip"
    cd "$_pwd"
    return 1
  fi
  echo "已生成 AnyKernel3 刷机包: $_zip"

  cd "$_pwd"
}

# 条件执行（等价原工作流 if:）
run_prepare_anykernel3() {
  if [ "$ARTIFACT_UPLOAD_MODE" != "上传全部" ]; then
    stage_prepare_anykernel3 "$@"
  else
    echo "跳过阶段: prepare_anykernel3（条件不满足）"
  fi
}

stage_build_boot_a12() {
  log_stage "build_boot_a12" "构建 Boot 镜像 (Android 12)"
  local _pwd="$PWD"
  cd bootimgs
  GKI_URL=https://dl.google.com/android/gki/gki-certified-boot-android12-5.10-${OS_PATCH_LEVEL}_${REVISION}.zip
  FALLBACK_URL=https://dl.google.com/android/gki/gki-certified-boot-android12-5.10-2023-01_r1.zip

  status=$(curl -sL -w "%{http_code}" "$GKI_URL" -o /dev/null)
  if [ "$status" = "200" ]; then
    curl -Lo gki-kernel.zip "$GKI_URL"
  else
    curl -Lo gki-kernel.zip "$FALLBACK_URL"
  fi

  unzip gki-kernel.zip && rm gki-kernel.zip
  $UNPACK_BOOTIMG --boot_img="$(pwd)/boot-5.10.img"

  gzip -n -k -f -9 ./Image
  [ -s ./Image.gz ] || { echo "::error::Image.gz 生成失败或为空"; return 1; }

  $MKBOOTIMG --header_version 4 --kernel Image --output boot.img --ramdisk out/ramdisk --os_version 12.0.0 --os_patch_level "${OS_PATCH_LEVEL}"
  $AVBTOOL add_hash_footer --partition_name boot --partition_size $((64 * 1024 * 1024)) --image boot.img --algorithm SHA256_RSA2048 --key $BOOT_SIGN_KEY_PATH
  cp ./boot.img ../${ANDROID_VERSION}-${KERNEL_VERSION}.${NAME_SUBLEVEL}-${OS_PATCH_LEVEL}-boot.img

  $MKBOOTIMG --header_version 4 --kernel Image.gz --output boot-gz.img --ramdisk out/ramdisk --os_version 12.0.0 --os_patch_level "${OS_PATCH_LEVEL}"
  $AVBTOOL add_hash_footer --partition_name boot --partition_size $((64 * 1024 * 1024)) --image boot-gz.img --algorithm SHA256_RSA2048 --key $BOOT_SIGN_KEY_PATH
  cp ./boot-gz.img ../${ANDROID_VERSION}-${KERNEL_VERSION}.${NAME_SUBLEVEL}-${OS_PATCH_LEVEL}-boot-gz.img

  if [ "${LZ4_KERNEL_READY:-0}" = "1" ] && [ -s ./Image.lz4 ]; then
    $MKBOOTIMG --header_version 4 --kernel Image.lz4 --output boot-lz4.img --ramdisk out/ramdisk --os_version 12.0.0 --os_patch_level "${OS_PATCH_LEVEL}"
    $AVBTOOL add_hash_footer --partition_name boot --partition_size $((64 * 1024 * 1024)) --image boot-lz4.img --algorithm SHA256_RSA2048 --key $BOOT_SIGN_KEY_PATH
    cp ./boot-lz4.img ../${ANDROID_VERSION}-${KERNEL_VERSION}.${NAME_SUBLEVEL}-${OS_PATCH_LEVEL}-boot-lz4.img
  else
    echo "::warning::跳过 boot-lz4.img（Image.lz4 未就绪）"
  fi

  cd "$_pwd"
}

# 条件执行（等价原工作流 if:）
run_build_boot_a12() {
  # 「仅 AnyKernel3」模式用户只拿刷机包，boot 镜像编译纯属浪费 runner，
  # 且上传步骤本就不收集非「上传全部」模式的 *.img，这里在阶段层直接跳过。
  if [ "$ANDROID_VERSION" = "android12" ] && [ "$ARTIFACT_UPLOAD_MODE" = "上传全部" ]; then
    stage_build_boot_a12 "$@"
  else
    echo "跳过阶段: build_boot_a12（条件不满足或仅 AnyKernel3 模式无需 boot 镜像）"
  fi
}

stage_build_boot_a13plus() {
  log_stage "build_boot_a13plus" "构建 Boot 镜像 (Android 13+)"
  local _pwd="$PWD"
  cd bootimgs
  gzip -n -k -f -9 ./Image
  [ -s ./Image.gz ] || { echo "::error::Image.gz 生成失败或为空"; return 1; }

  $MKBOOTIMG --header_version 4 --kernel Image --output boot.img
  $AVBTOOL add_hash_footer --partition_name boot --partition_size $((64 * 1024 * 1024)) --image boot.img --algorithm SHA256_RSA2048 --key $BOOT_SIGN_KEY_PATH
  cp ./boot.img ../${ANDROID_VERSION}-${KERNEL_VERSION}.${NAME_SUBLEVEL}-${OS_PATCH_LEVEL}-boot.img

  $MKBOOTIMG --header_version 4 --kernel Image.gz --output boot-gz.img
  $AVBTOOL add_hash_footer --partition_name boot --partition_size $((64 * 1024 * 1024)) --image boot-gz.img --algorithm SHA256_RSA2048 --key $BOOT_SIGN_KEY_PATH
  cp ./boot-gz.img ../${ANDROID_VERSION}-${KERNEL_VERSION}.${NAME_SUBLEVEL}-${OS_PATCH_LEVEL}-boot-gz.img

  if [ "${LZ4_KERNEL_READY:-0}" = "1" ] && [ -s ./Image.lz4 ]; then
    $MKBOOTIMG --header_version 4 --kernel Image.lz4 --output boot-lz4.img
    $AVBTOOL add_hash_footer --partition_name boot --partition_size $((64 * 1024 * 1024)) --image boot-lz4.img --algorithm SHA256_RSA2048 --key $BOOT_SIGN_KEY_PATH
    cp ./boot-lz4.img ../${ANDROID_VERSION}-${KERNEL_VERSION}.${NAME_SUBLEVEL}-${OS_PATCH_LEVEL}-boot-lz4.img
  else
    echo "::warning::跳过 boot-lz4.img（Image.lz4 未就绪）"
  fi

  cd "$_pwd"
}

# 条件执行（等价原工作流 if:）
run_build_boot_a13plus() {
  # 同上，仅「上传全部」模式才构建 boot 镜像
  if { [ "$ANDROID_VERSION" = "android13" ] || [ "$ANDROID_VERSION" = "android14" ] || [ "$ANDROID_VERSION" = "android15" ] || [ "$ANDROID_VERSION" = "android16" ]; } && [ "$ARTIFACT_UPLOAD_MODE" = "上传全部" ]; then
    stage_build_boot_a13plus "$@"
  else
    echo "跳过阶段: build_boot_a13plus（条件不满足或仅 AnyKernel3 模式无需 boot 镜像）"
  fi
}

stage_collect_conflicts() {
  log_stage "collect_conflicts" "收集补丁冲突文件"
  local _pwd="$PWD"
  REJECTS_DIR="$WORKSPACE/patch-rejects"
  mkdir -p "$REJECTS_DIR"

  mapfile -t REJS < <(
    find "$KERNEL_ROOT" -type f -name '*.rej' | sort | while IFS= read -r rej; do
      if git -C "$(dirname "$rej")" ls-files --error-unmatch -- "$(basename "$rej")" >/dev/null 2>&1 \
        && git -C "$(dirname "$rej")" diff --quiet -- "$(basename "$rej")" 2>/dev/null; then
        echo "跳过上游自带的 .rej: ${rej#"$KERNEL_ROOT"/}" >&2
        continue
      fi
      echo "$rej"
    done
  )
  REJ_COUNT=${#REJS[@]}
  echo "发现 $REJ_COUNT 个 .rej 文件"
  export REJ_COUNT="$REJ_COUNT"

  if [ "$REJ_COUNT" -gt 0 ]; then
    for REJ in "${REJS[@]}"; do
      REL="${REJ#"$KERNEL_ROOT"/}"
      DEST="$REJECTS_DIR/$REL"
      mkdir -p "$(dirname "$DEST")"
      cp "$REJ" "$DEST"

      ORIG="${REJ%.rej}"
      if [ -f "$ORIG" ]; then
        cp "$ORIG" "${DEST%.rej}"
      fi
      echo "$REL" >> "$REJECTS_DIR/index.txt"
    done
  fi

  cd "$_pwd"
}

run_collect_conflicts() { stage_collect_conflicts "$@"; }

# ---------------------------- 状态导出 ----------------------------
# GitHub Actions 各 step 是独立进程，产物上传步骤依赖 CONFIG / SUSFS_PATCH_EXPORT
# / REJ_COUNT 等变量，必须写回 $GITHUB_ENV 才能跨 step 传递。
# 本地构建时 GITHUB_ENV 未设置，直接跳过，不影响离线使用。
export_state() {
  [ -n "${GITHUB_ENV:-}" ] || return 0
  {
    echo "CONFIG=${CONFIG:-}"
    echo "ARTIFACT_SUFFIX=${ARTIFACT_SUFFIX:-}"
    echo "KERNEL_ROOT=${KERNEL_ROOT:-}"
    echo "DEFCONFIG=${DEFCONFIG:-}"
    echo "SUSFS_PATCH_EXPORT=${SUSFS_PATCH_EXPORT:-false}"
    echo "REJ_COUNT=${REJ_COUNT:-0}"
    echo "COMPILE_FAILED=${COMPILE_FAILED:-0}"
  } >> "$GITHUB_ENV" 2>/dev/null || true
}
# 无论成功或失败都导出，保证 always() 的上传步骤能拿到值
trap export_state EXIT

# ---------------------------- 主流程 ----------------------------
PHASES=(
  summary
  cleanup_disk
  init_env
  show_config
  install_deps
  setup_ccache
  download_toolchain
  gen_sign_key
  setup_git
  clone_deps
  sync_kernel_source
  apply_stock_config
  extract_sublevel
  apply_cve_patch
  fix_glibc
  add_oneplus8e
  resolve_ksu_branch
  add_kernelsu
  clone_susfs
  apply_sukisu_compat
  config_sukisu_manager
  susfs_baseline
  apply_susfs
  bakasu_susfs_gate
  gen_susfs_patch
  clone_droidspaces
  backup_defconfig
  integrate_nomount
  integrate_droidspaces
  inject_ntsync
  apply_unicode_fix
  setup_zram_lz4
  fix_66_wifi_bt
  config_zram
  add_bbg
  apply_rekernel
  config_kernel
  config_net_enhance
  config_susfs
  config_kernel_name
  set_build_time
  # UAPI 对齐放在所有内核源码改写之后、编译之前的最后一步：它是纯常量改写，
  # 放最后可以保证不被 SUSFS/compat 补丁以「上下文已变」为由顶掉或反过来顶掉它们。
  sync_ksu_uapi
  # 编译前的最后一道一致性门禁：核对本次写进 defconfig 的功能符号是否真被 Kconfig 声明，
  # 复现被 sed 掉的 build.config.gki::check_defconfig 的一部分作用。
  # 放在这里（所有 defconfig 写入之后、编译之前）才能十秒内报出「符号没人认领」，
  # 而不是等 15 分钟编译完再靠 verify_config_landing 发现功能根本没编进去。
  verify_kconfig_decl
  compile_kernel
  verify_config_landing
  collect_fail_log
  patch_kpm_image
  prepare_boot
  make_anykernel3
  prepare_anykernel3
  build_boot_a12
  build_boot_a13plus
  collect_conflicts
)

list_phases() {
  local i=1
  for p in "${PHASES[@]}"; do
    printf "  %2d. %s\n" "$i" "$p"
    i=$((i + 1))
  done
}

usage() {
  cat <<'EOF'
用法: build_kernel.sh [选项]

  --all                运行全部阶段（默认）
  --only <阶段>        只运行指定阶段
  --from <阶段>        从指定阶段开始运行到结束
  --list               列出全部阶段
  --help               显示本帮助

参数通过环境变量传入，常用:
  ANDROID_VERSION KERNEL_VERSION SUB_LEVEL OS_PATCH_LEVEL
  KSU_VARIANT KSU_MODE ENABLE_SUSFS USE_ZRAM USE_BBR USE_KPM
  USE_BBG USE_REKERNEL USE_NET_ENHANCE SKIP_INCOMPATIBLE USE_NOMOUNT SUPP_OP DROIDSPACES DROIDSPACES_NTSYNC
  CVE_2026_43499_PATCH EXPORT_SUSFS_PATCHES ARTIFACT_UPLOAD_MODE
EOF
}

# REVISION / OS_PATCH_LEVEL 会被直接内插进 curl URL（如 GKI_URL）、
# 产物文件名、git 分支名与 mkbootimg --os_patch_level。若缺失白名单，含 $(...) 的
# 输入会在双引号内触发命令替换（命令注入）。这里做早期 fail-closed 校验，任何阶段
# 运行前即拦截；白名单为：字母数字及 . _ -。
validate_inputs() {
  local v val

  # KSU_MODE 白名单：合法值只有「关闭」与「禁用KSU」。
  # 历史上 6 个 workflow 曾发出过「禁用SUSFS」这类非法值：它不等于「禁用KSU」，
  # 脚本里所有 `!= "禁用KSU"` 的判断都会把它当成「KSU 启用」静默放行 —— 语义靠猜，
  # 且一旦有人以为它真的禁用了 SUSFS 就会埋雷。这里 fail-closed。
  # 注：SUSFS 的启停由 ENABLE_SUSFS 独立控制，不通过 KSU_MODE 表达。
  case "${KSU_MODE:-}" in
    关闭|禁用KSU) ;;
    "")
      echo "::error::KSU_MODE 为空，合法值：关闭 / 禁用KSU"
      exit 1
      ;;
    *)
      echo "::error::KSU_MODE 非法值：'${KSU_MODE}'（合法值：关闭 / 禁用KSU）"
      echo "::error::SUSFS 的启停由 ENABLE_SUSFS 独立控制，不要写进 KSU_MODE"
      exit 1
      ;;
  esac

  # SUB_LEVEL 会被拼进产物文件名（anykernel3_zip_name / boot.*.img 的 cp 目标），
  # 同时也是 LTS 模式下由 data json 覆写的变量。这里对传入值做白名单；
  # JSON 覆写路径另有针对性校验（见 sync_kernel_source 阶段）。
  # 合法形态：数字子版本，或 LTS 占位符 X、x.y 系列的 y。
  for v in OS_PATCH_LEVEL REVISION; do
    val="${!v}"
    if [ -n "$val" ]; then
      case "$val" in
        *[!A-Za-z0-9._-]*) echo "::error::$v 含非法字符，仅允许字母数字及 . _ -（命令注入防护）"; exit 1 ;;
      esac
    fi
  done

  if [ -n "${SUB_LEVEL:-}" ]; then
    case "$SUB_LEVEL" in
      X) ;;  # LTS 占位符，后续会被 data json 覆写
      *[!0-9A-Za-z]*) echo "::error::SUB_LEVEL 含非法字符：'${SUB_LEVEL}'（仅允许数字，或 LTS 占位符 X）"; exit 1 ;;
    esac
  fi
}

# 允许被「兼容跳过」降级处理的阶段白名单。
# 只收录「这项没了内核照样能正常编出来」的可选增强项。以下刻意**不在**名单内：
#   - susfs_baseline / apply_susfs / config_susfs：SUSFS 是本仓库的核心能力，
#     半途跳过会产出一个「能开机、但根本没隐藏」的内核，比直接失败危险得多；
#   - add_oneplus8e：跳过会产出对一加设备不完整的内核；
#   - compile_kernel 等主干阶段：失败就是失败，没有跳过的余地。
phase_skippable() {
  case "$1" in
    setup_zram_lz4|config_zram) return 0 ;;
    add_bbg|apply_rekernel|integrate_nomount|apply_sukisu_compat) return 0 ;;
    clone_droidspaces|integrate_droidspaces|inject_ntsync) return 0 ;;
    apply_cve_patch|apply_unicode_fix|patch_kpm_image) return 0 ;;
    config_net_enhance) return 0 ;;
    *) return 1 ;;
  esac
}

main() {
  validate_inputs
  local mode="all" target=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --all)  mode="all" ;;
      --only) mode="only"; target="${2:-}"; shift ;;
      --from) mode="from"; target="${2:-}"; shift ;;
      --list) list_phases; exit 0 ;;
      --help|-h) usage; exit 0 ;;
      *) echo "未知参数: $1" >&2; usage; exit 1 ;;
    esac
    shift
  done

  if [ "$mode" = "only" ]; then
    if ! declare -F "run_${target}" >/dev/null; then
      echo "未知阶段: $target" >&2; exit 1
    fi
    "run_${target}"
    return
  fi

  # --from 的 target 必须校验：拼不上任何阶段时 started 恒为 false，
  # 循环全程 continue，最后却 exit 0 —— 变成「什么都没跑却报成功」的假成功。
  # 用循环而非 `printf ... | grep -qx`：本脚本有 set -o pipefail，grep -q 命中
  # 时提前退出会让 printf 收到 SIGPIPE(141)，整条管道被判非零，
  # 于是「阶段名合法」反被报成「未知起始阶段」并 exit 1。
  if [ "$mode" = "from" ]; then
    local found_target=false
    for p in "${PHASES[@]}"; do
      if [ "$p" = "$target" ]; then found_target=true; break; fi
    done
    if [ "$found_target" != true ]; then
      echo "未知起始阶段: ${target}" >&2
      echo "可用阶段：" >&2
      printf '  %s\n' "${PHASES[@]}" >&2
      exit 1
    fi
  fi

  local started=false
  local failed_phase=""
  for p in "${PHASES[@]}"; do
    if [ "$mode" = "from" ]; then
      if [ "$p" = "$target" ]; then started=true; fi
      if [ "$started" != true ]; then continue; fi
    fi
    if ! "run_${p}"; then
      # 兼容跳过：只对白名单内的可选增强项生效，且必须由调用方显式开启。
      # 命中时打印告警、写进 step summary 与产物说明，然后继续下一个阶段。
      if [ "$SKIP_INCOMPATIBLE" = "true" ] && phase_skippable "$p"; then
        echo "::warning title=阶段已跳过::$p 执行失败，已跳过该功能（构建未中断）"
        if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
          echo "> ⏭️ **$p** 已自动跳过：执行失败（构建未中断）" >> "$GITHUB_STEP_SUMMARY"
        fi
        # 同一进程内的阶段（尤其 verify_config_landing）要能读到这个变量：
        # 写 GITHUB_ENV 只对**后续 step** 生效，对本进程内的 `phase_was_skipped`
        # 毫无作用 —— 之前只写 GITHUB_ENV，导致「已跳过」在后续校验里读成「没跳过」，
        # 把一次合规降级误判成落盘失败。这里同时赋值给 shell 变量并导出。
        SKIPPED_PHASES="${SKIPPED_PHASES:+$SKIPPED_PHASES }$p"
        export SKIPPED_PHASES
        echo "SKIPPED_PHASES=$SKIPPED_PHASES" >> "${GITHUB_ENV:-/dev/null}"
        continue
      fi
      echo "::error::阶段 $p 执行失败"
      failed_phase="$p"
      break
    fi
  done

  # 失败收尾：compile_kernel 之后紧邻的 collect_fail_log 原本永远跑不到
  # —— 上一阶段失败就 exit 1 了，导致 summary.txt / disk-usage.txt /
  # ccache-stats.txt 从不生成，build-logs 只剩裸编译日志。
  # 这里在退出前补跑一次，保证排障上下文完整。
  if [ -n "$failed_phase" ]; then
    if [ "$COMPILE_FAILED" = "1" ] && [ "$failed_phase" != "collect_fail_log" ]; then
      echo "编译失败，补跑 collect_fail_log 收集排障信息..."
      run_collect_fail_log || echo "::warning::collect_fail_log 补跑失败，忽略"
    fi
    exit 1
  fi
}

main "$@"
