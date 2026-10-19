#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# 一次性迁移留档（不参与构建）。见同目录 README.md；请勿在新改动中复用。
"""生成 scripts/build_kernel.sh —— YAML 与 Python CLI 共用的单一构建真相源。"""
import re
import yaml

SRC = "/root/.codebuddy/artifact/merge_analysis/repo_zzh/.github/workflows/build.yml"
OUT = "/workspace/GKI_KernelSU_SUSFS_Merged/scripts/build_kernel.sh"

INPUT_MAP = {
    "android_version": "ANDROID_VERSION",
    "kernel_version": "KERNEL_VERSION",
    "sub_level": "SUB_LEVEL",
    "os_patch_level": "OS_PATCH_LEVEL",
    "ksu_variant": "KSU_VARIANT",
    "ksu_mode": "KSU_MODE",
    "version": "VERSION",
    "revision": "REVISION",
    "build_time": "BUILD_TIME",
    "use_zram": "USE_ZRAM",
    "use_bbg": "USE_BBG",
    "use_kpm": "USE_KPM",
    "use_rekernel": "USE_REKERNEL",
    "cve_2026_43499_patch": "CVE_2026_43499_PATCH",
    "export_susfs_patches": "EXPORT_SUSFS_PATCHES",
    "enable_susfs": "ENABLE_SUSFS",
    "supp_op": "SUPP_OP",
    "droidspaces": "DROIDSPACES",
    "droidspaces_ntsync": "DROIDSPACES_NTSYNC",
    "artifact_upload_mode": "ARTIFACT_UPLOAD_MODE",
}

DEFAULTS = {
    "ANDROID_VERSION": "android14",
    "KERNEL_VERSION": "6.1",
    "SUB_LEVEL": "124",
    "OS_PATCH_LEVEL": "2025-02",
    "KSU_VARIANT": "BakaSU",
    "KSU_MODE": "关闭",
    "VERSION": "",
    "REVISION": "",
    "BUILD_TIME": "",
    "USE_ZRAM": "false",
    "USE_BBR": "false",
    "USE_BBG": "false",
    "USE_KPM": "false",
    "USE_REKERNEL": "false",
    "CVE_2026_43499_PATCH": "false",
    "EXPORT_SUSFS_PATCHES": "false",
    "ENABLE_SUSFS": "true",
    "SUPP_OP": "false",
    "DROIDSPACES": "off",
    "DROIDSPACES_NTSYNC": "false",
    "ARTIFACT_UPLOAD_MODE": "上传全部",
}

# step 名 -> 函数名
FN = {
    "构建信息摘要": "summary", "清理磁盘空间": "cleanup_disk",
    "初始化构建环境": "init_env", "显示配置信息": "show_config",
    "安装编译依赖": "install_deps", "配置 ccache": "setup_ccache",
    "下载工具链": "download_toolchain", "生成签名密钥": "gen_sign_key",
    "配置 Git": "setup_git", "克隆依赖仓库": "clone_deps",
    "初始化并同步内核源码": "sync_kernel_source",
    "应用 Stock Config 伪装": "apply_stock_config",
    "提取实际子版本号": "extract_sublevel",
    "自动应用 CVE-2026-43499 rtmutex 修复链": "apply_cve_patch",
    "修复 glibc 2.38 兼容性": "fix_glibc",
    "添加一加 8E 处理器支持": "add_oneplus8e",
    "确定 KernelSU 分支": "resolve_ksu_branch",
    "添加 KernelSU": "add_kernelsu",
    "配置 SukiSU 管理器信息": "config_sukisu_manager",
    "记录 SUSFS 基线快照": "susfs_baseline",
    "应用 SUSFS 补丁": "apply_susfs",
    "生成 SUSFS 集成补丁": "gen_susfs_patch",
    "克隆 Droidspaces 补丁仓库": "clone_droidspaces",
    "备份基准 defconfig": "backup_defconfig",
    "集成 Droidspaces 支持": "integrate_droidspaces",
    "注入 NTSync 内核配置": "inject_ntsync",
    "应用 Unicode 绕过修复": "apply_unicode_fix",
    "配置 ZRAM LZ4 补丁栈": "setup_zram_lz4",
    "修复 6.6 WiFi/蓝牙兼容性（三星 + 小米）": "fix_66_wifi_bt",
    "配置 ZRAM 选项": "config_zram",
    "添加 BBG 防格机补丁": "add_bbg",
    "应用 Re-Kernel": "apply_rekernel",
    "配置内核选项": "config_kernel",
    "添加 SUSFS 配置": "config_susfs",
    "配置内核名称": "config_kernel_name",
    "设置自定义构建时间": "set_build_time",
    "编译内核": "compile_kernel",
    "整理编译失败日志": "collect_fail_log",
    "准备 Boot 镜像": "prepare_boot",
    "创建 AnyKernel3 压缩包": "make_anykernel3",
    "准备 AnyKernel3 目录": "prepare_anykernel3",
    "构建 Boot 镜像 (Android 12)": "build_boot_a12",
    "构建 Boot 镜像 (Android 13+)": "build_boot_a13plus",
    "收集补丁冲突文件": "collect_conflicts",
}

# if 条件 -> shell 条件（人工转译，保证语义等价）
COND = {
    "apply_cve_patch": '[ "$CVE_2026_43499_PATCH" = "true" ]',
    "add_oneplus8e": '[ "$SUPP_OP" = "true" ]',
    "resolve_ksu_branch": '[ "$KSU_MODE" != "禁用KSU" ]',
    "add_kernelsu": '[ "$KSU_MODE" != "禁用KSU" ]',
    "config_sukisu_manager": '[ "$KSU_MODE" != "禁用KSU" ] && { [ "$KSU_VARIANT" = "SukiSU" ] || [ "$KSU_VARIANT" = "SukiSU(40726)" ] || [ "$KSU_VARIANT" = "SukiSU(40548)" ]; }',
    "susfs_baseline": '[ "$EXPORT_SUSFS_PATCHES" = "true" ] && [ "$ENABLE_SUSFS" = "true" ] && [ "$KSU_MODE" != "禁用KSU" ] && { [ "$KSU_VARIANT" = "SukiSU" ] || [ "$KSU_VARIANT" = "BakaSU" ]; }',
    "apply_susfs": '[ "$ENABLE_SUSFS" = "true" ]',
    "gen_susfs_patch": '[ "$SUSFS_PATCH_EXPORT" = "true" ]',
    "clone_droidspaces": '[ "$DROIDSPACES" != "off" ]',
    "integrate_droidspaces": '[ "$DROIDSPACES" != "off" ]',
    "inject_ntsync": '[ "$DROIDSPACES" != "off" ] && [ "$DROIDSPACES_NTSYNC" = "true" ]',
    "apply_unicode_fix": '[ "$ENABLE_SUSFS" = "true" ]',
    "setup_zram_lz4": '[ "$USE_ZRAM" = "true" ]',
    "fix_66_wifi_bt": '[ "$KERNEL_VERSION" = "6.6" ]',
    "config_zram": '[ "$USE_ZRAM" = "true" ]',
    "add_bbg": '[ "$USE_BBG" = "true" ]',
    "apply_rekernel": '[ "$USE_REKERNEL" = "true" ]',
    "config_susfs": '[ "$ENABLE_SUSFS" = "true" ]',
    "make_anykernel3": '[ "$ARTIFACT_UPLOAD_MODE" = "上传全部" ]',
    "prepare_anykernel3": '[ "$ARTIFACT_UPLOAD_MODE" != "上传全部" ]',
    "build_boot_a12": '[ "$ANDROID_VERSION" = "android12" ]',
    "build_boot_a13plus": '[ "$ANDROID_VERSION" = "android13" ] || [ "$ANDROID_VERSION" = "android14" ] || [ "$ANDROID_VERSION" = "android15" ] || [ "$ANDROID_VERSION" = "android16" ]',
    "download_toolchain": '[ "${TOOLCHAIN_CACHE_HIT:-false}" != "true" ]',
    "collect_fail_log": '[ "$COMPILE_FAILED" = "1" ]',
}

# ---------------------------------------------------------------------------
# 增量增强：在 zzh20188 原逻辑之上，补入 ShirkNeko 独有的能力。
# 这里以「追加到指定阶段末尾」的方式注入，保证重新生成时可复现、不与原逻辑分叉。
# ---------------------------------------------------------------------------
ENHANCEMENTS = {
    "summary": """
# [融合] BBR 开关展示（zzh20188 原摘要没有该项）
echo "BBR 拥塞控制: ${USE_BBR}"
""",
    "config_kernel": """
# [融合] BBR 拥塞控制 —— 取自 ShirkNeko/GKI_KernelSU_SUSFS
if [ "${USE_BBR}" = "true" ]; then
  echo "启用 BBR 拥塞控制"
  if grep -q '^CONFIG_TCP_CONG_BBR=' "$DEFCONFIG"; then
    sed -i 's/^CONFIG_TCP_CONG_BBR=.*/CONFIG_TCP_CONG_BBR=y/' "$DEFCONFIG"
  else
    echo "CONFIG_TCP_CONG_BBR=y" >> "$DEFCONFIG"
  fi
  if grep -q '^CONFIG_DEFAULT_BBR=' "$DEFCONFIG"; then
    sed -i 's/^CONFIG_DEFAULT_BBR=.*/CONFIG_DEFAULT_BBR=y/' "$DEFCONFIG"
  else
    echo "CONFIG_DEFAULT_BBR=y" >> "$DEFCONFIG"
  fi
fi
""",
}

# 只能在 GitHub Actions runner 上执行的阶段。
# cleanup_disk 会 rm -rf 一批系统目录（/opt/hostedtoolcache、node_modules 等），
# 在个人机器上执行会破坏本机环境，因此本地构建必须跳过。
ACTIONS_ONLY = {"cleanup_disk"}

# Actions 专属 step，不进入脚本
SKIP_NAMES = {
    "检出代码仓库", "恢复 ccache 缓存", "恢复 bazel 磁盘缓存", "缓存工具链",
    "上传编译失败日志", "上传 SUSFS 集成补丁", "上传 AnyKernel3 刷入包",
    "上传全部构建产物", "上传补丁冲突文件",
}


def mk_export(key: str, val: str) -> str:
    """生成 export 语句，无引号的值统一加引号，避免含空格时出错。"""
    val = val.strip()
    if '"' in val or "'" in val:
        return "export %s=%s" % (key, val)
    return 'export %s="%s"' % (key, val)


def indent(text: str, pad: str = "  ") -> str:
    """缩进代码块，但跳过 heredoc 内部与结束标记——结束标记必须顶格匹配。"""
    out = []
    heredoc_end = None
    for ln in text.split("\n"):
        if heredoc_end is not None:
            out.append(ln)  # heredoc 内部原样保留
            if ln.strip() == heredoc_end:
                heredoc_end = None
            continue
        if "<<" in ln and "<<<" not in ln:
            m = re.search(r"<<-?\s*['\"]?([A-Za-z_][A-Za-z_0-9]*)['\"]?", ln)
            if m:
                heredoc_end = m.group(1)
        out.append((pad + ln) if ln.strip() else ln)
    return "\n".join(out)


def conv(t):
    t = re.sub(r"\$\{\{\s*inputs\.([A-Za-z_0-9]+)\s*\}\}",
               lambda m: "${%s}" % INPUT_MAP.get(m.group(1), m.group(1).upper()), t)
    t = re.sub(r"\$\{\{\s*env\.([A-Za-z_0-9]+)\s*\}\}", r"${\1}", t)
    # 仓库变量 / 密钥：CLI 场景改由同名环境变量提供，缺省为空
    t = re.sub(r"\$\{\{\s*vars\.([A-Za-z_0-9]+)\s*\}\}", r"${\1:-}", t)
    t = re.sub(r"\$\{\{\s*secrets\.([A-Za-z_0-9]+)\s*\}\}", r"${\1:-}", t)
    t = t.replace("${GITHUB_WORKSPACE}", "${WORKSPACE}").replace("$GITHUB_WORKSPACE", "$WORKSPACE")
    return t


def conv_env(t):
    # cat >> $GITHUB_ENV << EOF ... EOF  ->  export
    pat = re.compile(
        r"cat\s*>>\s*(?:\$GITHUB_ENV|\$\{GITHUB_ENV\})\s*<<-?\s*['\"]?(\w+)['\"]?\n(.*?)\n\s*\1",
        re.DOTALL)

    def repl(m):
        out = []
        for raw in m.group(2).split("\n"):
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            out.append(mk_export(k.strip(), v.strip()))
        return "\n".join(out)

    t = pat.sub(repl, t)

    def echo_repl(m):
        return mk_export(m.group(1), m.group(2))

    # 允许 GITHUB_ENV 被单/双引号包裹
    t = re.sub(r'echo\s+"([A-Za-z_0-9]+)=([^"]*)"\s*>>\s*["\']?(?:\$GITHUB_ENV|\$\{GITHUB_ENV\})["\']?',
               echo_repl, t)
    t = re.sub(r"echo\s+'([A-Za-z_0-9]+)=([^']*)'\s*>>\s*[\"']?(?:\$GITHUB_ENV|\$\{GITHUB_ENV\})[\"']?",
               echo_repl, t)
    # echo "path" >> $GITHUB_PATH  ->  直接改 PATH
    t = re.sub(r'echo\s+"([^"]+)"\s*>>\s*["\']?\$GITHUB_PATH["\']?',
               r'export PATH="\1:$PATH"', t)
    t = re.sub(r"\s*>>\s*[\"']?(?:\$GITHUB_ENV|\$\{GITHUB_ENV\})[\"']?", "", t)
    return t


def main():
    wf = yaml.safe_load(open(SRC, encoding="utf-8"))
    steps = wf["jobs"]["build-kernel"]["steps"]

    funcs = []
    order = []
    compile_cmd = None

    for st in steps:
        name = st.get("name", "")
        if name in SKIP_NAMES:
            continue
        fn = FN.get(name)
        if not fn:
            continue
        wd = st.get("working-directory", "")
        wd = conv(wd)

        if "uses" in st and "nick-fields/retry" in st["uses"]:
            compile_cmd = conv(st["with"]["command"])
            body = compile_cmd
        elif "run" in st:
            body = st["run"]
        else:
            continue

        body = conv(body)
        body = conv_env(body)
        funcs.append((fn, name, wd, body))
        order.append(fn)

    # ---------- 组装脚本 ----------
    L = []
    L.append("""#!/usr/bin/env bash
# =============================================================================
# GKI 内核构建核心脚本 —— YAML 工作流与 Python CLI 共用的单一真相源
#
# 本脚本由 .github/workflows/build.yml 自动提取生成，逻辑与原工作流等价。
# 请勿直接手工编辑本文件的阶段函数：修改请改 build.yml 后重新生成，
# 或同步修改 build.py 与工作流，避免两套逻辑分叉。
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

# ---------------------------- 参数与默认值 ----------------------------""")

    for k, v in DEFAULTS.items():
        L.append(': "${%s:=%s}"' % (k, v))
    L.append(': "${WORKSPACE:=$(pwd)}"')
    L.append(': "${COMPILE_TIMEOUT_MINUTES:=30}"')
    L.append(': "${COMPILE_MAX_ATTEMPTS:=3}"')
    # Actions 上下文本地缺省值：在 Actions 中用真值，本地构建时降级为占位
    L.append(': "${GITHUB_SHA:=$(git -C "$WORKSPACE" rev-parse HEAD 2>/dev/null || echo unknown)}"')
    L.append(': "${GITHUB_RUN_ID:=local}"')
    L.append(': "${GITHUB_SERVER_URL:=}"')
    L.append(': "${GITHUB_REPOSITORY:=}"')
    L.append(': "${MANAGER_STR:=}"')
    L.append('export WORKSPACE GITHUB_SHA GITHUB_RUN_ID GITHUB_SERVER_URL GITHUB_REPOSITORY MANAGER_STR')
    for k in DEFAULTS:
        L.append('export %s' % k)

    L.append("""
# ---------------------------- 运行时状态 ----------------------------
export COMPILE_FAILED=0
export SUSFS_PATCH_EXPORT=false
export REJ_COUNT=0
export TOOLCHAIN_CACHE_HIT="${TOOLCHAIN_CACHE_HIT:-false}"

log_stage() {
  echo ""
  echo "================================================================"
  echo "  [$1] $2"
  echo "================================================================"
}

# ---------------------------- 阶段函数 ----------------------------""")

    for fn, name, wd, body in funcs:
        if fn == "compile_kernel":
            # 编译单独处理：拆出 once 函数 + 重试包装
            L.append("compile_kernel_once() {")
            L.append('  local _pwd="$PWD"')
            if wd:
                L.append('  cd %s' % wd)
            L.append(indent(body))
            L.append('  cd "$_pwd"')
            L.append("}")
            L.append("")
            L.append("stage_compile_kernel() {")
            L.append('  log_stage "%s" "%s"' % (fn, name))
            L.append('  local attempt=1 rc=0')
            L.append('  export -f compile_kernel_once')
            L.append('  while [ "$attempt" -le "$COMPILE_MAX_ATTEMPTS" ]; do')
            L.append('    echo "编译尝试 $attempt/$COMPILE_MAX_ATTEMPTS"')
            L.append('    if timeout -k 60 "${COMPILE_TIMEOUT_MINUTES}m" bash -c "compile_kernel_once"; then')
            L.append('      rc=0; break')
            L.append('    else')
            L.append('      rc=$?')
            L.append('      echo "编译失败（退出码 $rc）"')
            L.append('    fi')
            L.append('    attempt=$((attempt + 1))')
            L.append('  done')
            L.append('  if [ "$rc" -ne 0 ]; then export COMPILE_FAILED=1; fi')
            L.append('  return $rc')
            L.append("}")
        else:
            L.append("stage_%s() {" % fn)
            L.append('  log_stage "%s" "%s"' % (fn, name))
            L.append('  local _pwd="$PWD"')
            if wd:
                L.append('  cd %s' % wd)
            L.append(indent(body))
            if fn in ENHANCEMENTS:
                L.append(indent(ENHANCEMENTS[fn]))
            L.append('  cd "$_pwd"')
            L.append("}")

        # 条件包装函数
        if fn in ACTIONS_ONLY:
            L.append("")
            L.append("# 安全门：仅 GitHub Actions runner 执行，本地构建跳过以免破坏系统")
            L.append("run_%s() {" % fn)
            L.append('  if [ "${GITHUB_ACTIONS:-false}" = "true" ]; then')
            L.append('    stage_%s "$@"' % fn)
            L.append("  else")
            L.append('    echo "跳过阶段: %s（仅 GitHub Actions runner 执行）"' % fn)
            L.append("  fi")
            L.append("}")
        elif fn in COND:
            L.append("")
            L.append("# 条件执行（等价原工作流 if:）")
            L.append("run_%s() {" % fn)
            L.append("  if %s; then" % COND[fn])
            L.append('    stage_%s "$@"' % fn)
            L.append("  else")
            L.append('    echo "跳过阶段: %s（条件不满足）"' % fn)
            L.append("  fi")
            L.append("}")
        else:
            L.append("")
            L.append("run_%s() { stage_%s \"$@\"; }" % (fn, fn))
        L.append("")

    # 状态回写：Actions 的产物上传步骤依赖这些变量，需写回 $GITHUB_ENV 跨 step 传递
    L.append("""# ---------------------------- 状态导出 ----------------------------
# GitHub Actions 各 step 是独立进程，产物上传步骤依赖 CONFIG / SUSFS_PATCH_EXPORT
# / REJ_COUNT 等变量，必须写回 $GITHUB_ENV 才能跨 step 传递。
# 本地构建时 GITHUB_ENV 未设置，直接跳过，不影响离线使用。
export_state() {
  [ -n "${GITHUB_ENV:-}" ] || return 0
  {
    echo "CONFIG=${CONFIG:-}"
    echo "KERNEL_ROOT=${KERNEL_ROOT:-}"
    echo "DEFCONFIG=${DEFCONFIG:-}"
    echo "SUSFS_PATCH_EXPORT=${SUSFS_PATCH_EXPORT:-false}"
    echo "REJ_COUNT=${REJ_COUNT:-0}"
    echo "COMPILE_FAILED=${COMPILE_FAILED:-0}"
  } >> "$GITHUB_ENV" 2>/dev/null || true
}
# 无论成功或失败都导出，保证 always() 的上传步骤能拿到值
trap export_state EXIT

# ---------------------------- 主流程 ----------------------------""")

    # 主流程
    L.append("PHASES=(")
    for fn in order:
        L.append("  %s" % fn)
    L.append(")")
    L.append("""
list_phases() {
  local i=1
  for p in "${PHASES[@]}"; do
    printf "  %2d. %s\\n" "$i" "$p"
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
  USE_BBG USE_REKERNEL SUPP_OP DROIDSPACES DROIDSPACES_NTSYNC
  CVE_2026_43499_PATCH EXPORT_SUSFS_PATCHES ARTIFACT_UPLOAD_MODE
EOF
}

main() {
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

  local started=false
  for p in "${PHASES[@]}"; do
    if [ "$mode" = "from" ]; then
      if [ "$p" = "$target" ]; then started=true; fi
      if [ "$started" != true ]; then continue; fi
    fi
    "run_${p}" || {
      echo "::error::阶段 $p 执行失败"
      exit 1
    }
  done
}

main "$@"
""")
    text = "\n".join(L) + "\n"
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(text)
    print("生成: %s" % OUT)
    print("阶段数: %d" % len(order))
    print("行数: %d" % text.count("\n"))


if __name__ == "__main__":
    main()
