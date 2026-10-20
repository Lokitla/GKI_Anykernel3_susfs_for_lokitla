#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""GKI 内核本地构建 CLI —— 与 GitHub Actions 共用同一份构建逻辑。

真正的构建逻辑在 scripts/build_kernel.sh，本脚本只负责：
  1. 解析命令行参数
  2. 从 data/ 读取支持的版本组合并校验
  3. 组装环境变量并调用 build_kernel.sh

这样本地构建与 Actions 构建始终行为一致，不存在两套逻辑。

示例:
    python3 build.py --list-configs
    python3 build.py --android android14 --kernel 6.1 --sub-level 124 --os-patch 2025-02
    python3 build.py --matrix android14-6.1
    python3 build.py --all --ksu-variant SukiSU --zram
    python3 build.py --android android14 --kernel 6.1 --sub-level 124 --os-patch 2025-02 --dry-run

注意：首次构建会安装编译依赖（需要 sudo），并确保磁盘有 40GB 以上可用空间。
"""
import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SCRIPT = ROOT / "scripts" / "build_kernel.sh"
DATA_DIR = ROOT / "data"

KSU_VARIANTS = ["SukiSU", "SukiSU(40726)", "SukiSU(40548)", "BakaSU", "FinaSU", "Official", "Next"]
DROIDSPACES_CHOICES = ["不启用", "678", "123", "345"]
ARTIFACT_MODES = ["上传全部", "仅 AnyKernel3"]
# CLI 的 KPM 取值 → 与 Actions 下拉选项完全一致的文案，避免两边各说各话
KPM_MODES = {
    "disabled": "disabled (关闭)",
    "enabled": "enabled (开启)",
    "patched": "patched (开启并修补)",
}


def load_configs():
    """读取 data/<android>/<kernel>.json，返回 {(android, kernel): [entry...]}。"""
    configs = {}
    if not DATA_DIR.is_dir():
        return configs
    for path in sorted(DATA_DIR.glob("*/*.json")):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except Exception as e:  # noqa: BLE001
            print(f"警告: 无法解析 {path}: {e}", file=sys.stderr)
            continue
        android = data.get("android_version")
        kernel = data.get("kernel_version")
        if not android or not kernel:
            continue
        configs[(android, kernel)] = {
            "lts": data.get("lts", ""),
            "entries": data.get("entries", []),
        }
    return configs


def sub_level_of(kernel_full: str) -> str:
    """6.1.124 -> 124"""
    return kernel_full.split(".")[-1] if kernel_full else ""


def list_configs(configs):
    print("支持的构建组合（数据来源: data/）\n")
    total = 0
    for (android, kernel), info in sorted(configs.items()):
        entries = info["entries"]
        total += len(entries)
        print(f"{android} / {kernel}   (LTS: {info['lts'] or '-'})")
        if not entries:
            print("  (无可用版本)")
            continue
        line = []
        for e in entries:
            line.append(f"{sub_level_of(e['kernel'])}@{e['date']}")
        for i in range(0, len(line), 6):
            print("   " + "  ".join(line[i:i + 6]))
        print()
    print(f"合计 {total} 个版本组合")
    print("格式: <子版本号>@<OS补丁级别>，例如 124@2025-02 表示 sub-level 124、补丁级别 2025-02")


def resolve_entry(configs, android, kernel, sub_level=None, os_patch=None):
    """根据 sub_level / os_patch 定位具体版本；两者都省略时取该分支最新一版。"""
    info = configs.get((android, kernel))
    if not info:
        raise SystemExit(f"错误: 不支持的组合 {android} / {kernel}，用 --list-configs 查看支持列表")
    entries = info["entries"]
    if not entries:
        raise SystemExit(f"错误: {android}/{kernel} 没有可用版本")

    if sub_level:
        for e in entries:
            if sub_level_of(e["kernel"]) == str(sub_level):
                return e
        raise SystemExit(f"错误: {android}/{kernel} 没有子版本 {sub_level}")
    if os_patch:
        for e in entries:
            if e["date"] == os_patch:
                return e
        raise SystemExit(f"错误: {android}/{kernel} 没有补丁级别 {os_patch}")
    return entries[-1]  # 默认最新


def build_env(args, android, kernel, sub_level, os_patch):
    """组装传给 build_kernel.sh 的环境变量。"""
    env = os.environ.copy()
    mapping = {
        "ANDROID_VERSION": android,
        "KERNEL_VERSION": kernel,
        "SUB_LEVEL": str(sub_level),
        "OS_PATCH_LEVEL": os_patch,
        "KSU_VARIANT": args.ksu_variant,
        "KSU_MODE": "关闭",
        "KSU_BRANCH_MODE": args.ksu_branch_mode or "auto",
        "VERSION": args.version or "",
        "REVISION": args.revision or "",
        "BUILD_TIME": args.build_time or "",
        "USE_ZRAM": str(args.zram).lower(),
        "USE_BBR": str(args.bbr).lower(),
        # 与 Actions 的下拉选项保持一致：脚本只认 "enabled (开启)" / "patched (开启并修补)"，
        # 早期 CLI 直接传 "true"，脚本匹配不到，--kpm 会静默失效。
        "USE_KPM": KPM_MODES.get(args.kpm or "", "disabled (关闭)"),
        "USE_BBG": str(args.bbg).lower(),
        "USE_REKERNEL": str(args.rekernel).lower(),
        "USE_NET_ENHANCE": str(args.net_enhance).lower(),
        "SKIP_INCOMPATIBLE": str(args.skip_incompatible).lower(),
        # [移植] NoMount 挂载元模块：与 Actions 的 use_nomount 对齐，
        # 否则本地 CLI 无法开启该阶段（USE_NOMOUNT 恒为 false）。
        "USE_NOMOUNT": str(args.nomount).lower(),
        "ENABLE_SUSFS": str(not args.no_susfs).lower(),
        "SUPP_OP": str(args.op8e).lower(),
        "DROIDSPACES": args.droidspaces,
        "DROIDSPACES_NTSYNC": str(args.ntsync).lower(),
        "CVE_2026_43499_PATCH": str(args.cve_patch).lower(),
        "EXPORT_SUSFS_PATCHES": str(args.export_susfs_patches).lower(),
        "EXPECTED_KPM_PATCH_SHA256": args.kpm_patch_sha256 or "",
        # 提交锁定：与 CI 的 sukisu_commit / susfs_commit 对齐。此前 CLI 未构造这两个
        # 变量，本地无法复现"CI 锁定提交、本地走默认分支"的场景，排查结论会失真。
        "SUKISU_COMMIT": args.sukisu_commit or "",
        "SUSFS_COMMIT": args.susfs_commit or "",
        "ARTIFACT_UPLOAD_MODE": args.artifact_mode,
        "WORKSPACE": str(args.workspace),
    }
    env.update({k: v for k, v in mapping.items() if v is not None})
    # 本地构建：明确告诉脚本不是 Actions 环境（会跳过 runner 专属的清盘动作）
    env["GITHUB_ACTIONS"] = "false"
    return env


def phase_args(args):
    if args.only:
        return ["--only", args.only]
    if args.frm:
        return ["--from", args.frm]
    return ["--all"]


def run_build(env, args, label):
    cmd = [str(SCRIPT)] + phase_args(args)
    print(f"\n>>> 构建 {label}")
    print(f"    命令: {' '.join(cmd)}")
    if args.dry_run:
        print("    [dry-run] 未实际执行")
        return True
    try:
        subprocess.run(cmd, env=env, cwd=str(args.workspace), check=True)
        return True
    except subprocess.CalledProcessError as e:
        print(f"构建失败（退出码 {e.returncode}）: {label}", file=sys.stderr)
        return False
    except KeyboardInterrupt:
        print("\n已中断", file=sys.stderr)
        raise SystemExit(130)


def main():
    parser = argparse.ArgumentParser(
        description="GKI 内核本地构建 CLI（与 GitHub Actions 共用 scripts/build_kernel.sh）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__)
    parser.add_argument("--android", "-a", help="Android 版本，如 android14")
    parser.add_argument("--kernel", "-k", help="内核版本，如 6.1")
    parser.add_argument("--sub-level", "-s", help="子版本号，如 124；省略则用最新")
    parser.add_argument("--os-patch", help="OS 补丁级别，如 2025-02")
    parser.add_argument("--revision", help="Android 12 revision（可选）")
    parser.add_argument("--ksu-variant", default="BakaSU", choices=KSU_VARIANTS,
                        metavar="变体", help="KernelSU 变体（默认 BakaSU）")
    parser.add_argument("--ksu-branch-mode", default="auto", choices=["auto", "main", "builtin"],
                        metavar="{auto,main,builtin}",
                        help="SukiSU 拉取分支（仅 SukiSU 生效）：auto=跟随 SUSFS 开关自动选"
                             "（默认），main=纯管理器分支，builtin=内核内置实现")
    parser.add_argument("--version", help="自定义版本名")
    parser.add_argument("--build-time", help="自定义构建时间")

    parser.add_argument("--zram", action=argparse.BooleanOptionalAction, default=True,
                        help="ZRAM (LZ4KD) 增强算法（默认开启，--no-zram 关闭）")
    parser.add_argument("--bbr", action="store_true", help="设置 BBR 为默认拥塞算法")
    parser.add_argument("--kpm", nargs="?", choices=KPM_MODES, const="patched", default="patched",
                        metavar="{disabled,enabled,patched}",
                        help="KPM 模块支持（默认 patched 开启并修补；--kpm disabled 关闭）")
    parser.add_argument("--kpm-patch-sha256", help="KPM 修补工具(patch_linux)的 sha256 锚点，"
                        "传入后做 fail-closed 比对，不符即拒绝执行（留空则不校验）")
    parser.add_argument("--sukisu-commit", help="SukiSU 提交 hash：内核与管理器统一使用该 commit"
                        "（仅 SukiSU 变体生效；留空则用 config/config 的 sukisu= 或分支最新）")
    parser.add_argument("--susfs-commit", help="SUSFS 提交 hash：内核 SUSFS 修补使用该 commit"
                        "（留空则用 config/config 的对应分支行或分支最新）")
    parser.add_argument("--bbg", action="store_true", help="启用 Baseband-guard")
    parser.add_argument("--rekernel", action="store_true", help="启用 Re-Kernel")
    parser.add_argument("--net-enhance", action="store_true",
                        help="启用网络增强（IPSet + BBR + FQ 队列 + IPv6 NAT + 附加拥塞算法，"
                             "均为内核既有配置的启用）")
    parser.add_argument("--skip-incompatible", action="store_true",
                        help="可选功能失败时自动跳过而非中断构建（SUSFS 与一加 8E 除外）")
    parser.add_argument("--nomount", action="store_true", help="启用 NoMount 挂载元模块")
    parser.add_argument("--no-susfs", action="store_true", help="禁用 SUSFS")
    parser.add_argument("--op8e", action="store_true", help="启用一加 8E 支持（非一加勿开）")
    parser.add_argument("--droidspaces", default="不启用", choices=DROIDSPACES_CHOICES,
                        metavar="槽位", help="Droidspaces 容器支持（默认 不启用）")
    parser.add_argument("--ntsync", action="store_true", help="启用 NTSync 支持（需先启用 Droidspaces）")
    parser.add_argument("--cve-patch", action="store_true", help="应用 CVE-2026-43499 修复")
    parser.add_argument("--export-susfs-patches", action="store_true", help="导出 SUSFS 集成补丁")
    parser.add_argument("--artifact-mode", default="上传全部", choices=ARTIFACT_MODES)

    parser.add_argument("--all", action="store_true", help="构建全部版本组合")
    parser.add_argument("--matrix", "-m", help="构建指定组合的全部子版本，如 android14-6.1")
    parser.add_argument("--list-configs", action="store_true", help="列出支持的版本组合")
    parser.add_argument("--dry-run", action="store_true", help="只打印将要执行的构建")
    parser.add_argument("--only", help="只运行指定阶段（调试用）")
    parser.add_argument("--from", dest="frm", help="从指定阶段开始运行（调试用）")
    parser.add_argument("--list-phases", action="store_true", help="列出构建阶段")
    parser.add_argument("--workspace", "-w", default=str(ROOT), help="工作目录")

    args = parser.parse_args()
    configs = load_configs()

    if args.list_configs:
        list_configs(configs)
        return 0

    # scripts/build_kernel.sh 是 bash 脚本，非 POSIX 平台无法执行；
    # 直接 subprocess.run 会抛 OSError traceback，这里提前给出可读提示。
    if os.name != "posix":
        sys.exit("错误: 本地构建需要 Linux/WSL 环境；详见 docs/local-build.md")

    if args.list_phases:
        subprocess.run([str(SCRIPT), "--list"])
        return 0

    if not SCRIPT.is_file():
        raise SystemExit(f"错误: 找不到构建脚本 {SCRIPT}")

    workspace = Path(args.workspace)
    workspace.mkdir(parents=True, exist_ok=True)

    # 构建任务列表
    tasks = []
    if args.all:
        for (android, kernel), info in sorted(configs.items()):
            for e in info["entries"]:
                tasks.append((android, kernel, sub_level_of(e["kernel"]), e["date"]))
    elif args.matrix:
        if "-" not in args.matrix:
            raise SystemExit("错误: --matrix 格式应为 android14-6.1")
        android, kernel = args.matrix.rsplit("-", 1)
        android = android if android.startswith("android") else "android" + android
        info = configs.get((android, kernel))
        if not info:
            raise SystemExit(f"错误: 不支持的矩阵 {android}-{kernel}")
        for e in info["entries"]:
            tasks.append((android, kernel, sub_level_of(e["kernel"]), e["date"]))
    else:
        if not args.android or not args.kernel:
            raise SystemExit("错误: 需要 --android 与 --kernel，或使用 --all / --matrix / --list-configs")
        entry = resolve_entry(configs, args.android, args.kernel, args.sub_level, args.os_patch)
        tasks.append((args.android, args.kernel, sub_level_of(entry["kernel"]), entry["date"]))

    print(f"待构建: {len(tasks)} 个版本")
    if args.dry_run:
        print("[dry-run 模式：不会真正执行]\n")

    failed = []
    for i, (android, kernel, sub, patch) in enumerate(tasks, 1):
        print(f"\n[{i}/{len(tasks)}] {android} {kernel}.{sub} ({patch})")
        env = build_env(args, android, kernel, sub, patch)
        if not run_build(env, args, f"{android}-{kernel}.{sub}-{patch}"):
            failed.append(f"{android}-{kernel}.{sub}-{patch}")
            if not args.all and not args.matrix:
                break

    print("\n" + "=" * 50)
    if failed:
        print(f"完成 {len(tasks) - len(failed)}/{len(tasks)}，失败 {len(failed)} 个:")
        for f in failed:
            print(f"  - {f}")
        return 1
    print(f"全部完成（{len(tasks)} 个）" if not args.dry_run else "校验通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
