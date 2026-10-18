# SPDX-License-Identifier: GPL-2.0-or-later
# 一次性迁移留档（不参与构建）。见同目录 README.md；请勿在新改动中复用。
#!/usr/bin/env python3
"""生成融合后的 build.yml：保留 Actions 专属能力，核心构建委托给 build_kernel.sh。"""
import yaml

SRC = "/root/.codebuddy/artifact/merge_analysis/repo_zzh/.github/workflows/build.yml"
OUT = "/workspace/GKI_KernelSU_SUSFS_Merged/.github/workflows/build.yml"

INPUT_MAP = {
    "android_version": "ANDROID_VERSION", "kernel_version": "KERNEL_VERSION",
    "sub_level": "SUB_LEVEL", "os_patch_level": "OS_PATCH_LEVEL",
    "ksu_variant": "KSU_VARIANT", "ksu_mode": "KSU_MODE", "version": "VERSION",
    "revision": "REVISION", "build_time": "BUILD_TIME", "use_zram": "USE_ZRAM",
    "use_bbg": "USE_BBG", "use_kpm": "USE_KPM", "use_rekernel": "USE_REKERNEL",
    "cve_2026_43499_patch": "CVE_2026_43499_PATCH",
    "export_susfs_patches": "EXPORT_SUSFS_PATCHES", "enable_susfs": "ENABLE_SUSFS",
    "supp_op": "SUPP_OP", "droidspaces": "DROIDSPACES",
    "droidspaces_ntsync": "DROIDSPACES_NTSYNC",
    "artifact_upload_mode": "ARTIFACT_UPLOAD_MODE",
}

HEADER = """# =============================================================================
# GKI 内核构建工作流
# -----------------------------------------------------------------------------
# 核心构建逻辑已抽取至 scripts/build_kernel.sh（与 Python CLI build.py 共用），
# 本文件只保留 GitHub Actions 专属能力：缓存、产物上传、失败日志、Telegram 通知。
# 修改构建逻辑请改 scripts/build_kernel.sh，不要在本文件里重写 shell。
# =============================================================================
"""


def main():
    wf = yaml.safe_load(open(SRC, encoding="utf-8"))
    job = wf["jobs"]["build-kernel"]
    inputs = wf[True]["workflow_call"]["inputs"] if True in wf else wf["on"]["workflow_call"]["inputs"]

    # 新增融合选项
    inputs["use_bbr"] = {
        "description": "设置 BBR 为默认 TCP 拥塞算法（融合自 ShirkNeko）",
        "required": False, "type": "boolean", "default": False,
    }
    inputs["send_telegram"] = {
        "description": "构建结束后发送 Telegram 通知（需配置 secrets）",
        "required": False, "type": "boolean", "default": False,
    }
    inputs["use_release_cache"] = {
        "description": "用 GitHub Release 存储 ccache（突破 actions/cache 容量与过期限制，融合自 ShirkNeko）",
        "required": False, "type": "boolean", "default": False,
    }

    cache_key = ("${{ github.ref_name }}-${{ inputs.android_version }}"
                 "-${{ inputs.kernel_version }}-${{ inputs.sub_level }}")
    steps = [
        {"name": "检出代码仓库", "uses": "actions/checkout@v7"},
        # [融合] ShirkNeko 的 Release 缓存：默认关闭，与下面的 actions/cache 可共存
        {"name": "恢复 Release 缓存（可选）", "if": "${{ inputs.use_release_cache }}",
         "uses": "./.github/actions/cache-restore",
         "with": {"cache_path": "/home/runner/.ccache",
                  "cache_key": cache_key,
                  "cache_bucket": "ccache-cache"}},
        {"name": "恢复 ccache 缓存", "uses": "actions/cache@v5", "with": {
            "path": "~/.ccache",
            "key": "${{ inputs.android_version }}-${{ inputs.kernel_version }}-${{ inputs.sub_level }}-ccache-${{ github.sha }}",
            "restore-keys": "${{ inputs.android_version }}-${{ inputs.kernel_version }}-${{ inputs.sub_level }}-ccache-",
        }},
        {"name": "恢复 bazel 磁盘缓存",
         "if": "inputs.android_version != 'android12' && inputs.android_version != 'android13'",
         "uses": "actions/cache@v5", "with": {
             "path": "~/.cache/bazel",
             "key": "${{ inputs.android_version }}-${{ inputs.kernel_version }}-${{ inputs.sub_level }}-bazel-${{ github.sha }}",
             "restore-keys": "${{ inputs.android_version }}-${{ inputs.kernel_version }}-${{ inputs.sub_level }}-bazel-\n${{ inputs.android_version }}-${{ inputs.kernel_version }}-bazel-",
         }},
        {"name": "缓存工具链", "id": "cache-toolchain", "uses": "actions/cache@v5", "with": {
            "path": "kernel-build-tools\nmkbootimg", "key": "toolchain-${{ runner.os }}-v1",
        }},
        {"name": "构建内核", "id": "build", "run": "./scripts/build_kernel.sh --all"},
    ]
    # 注入 env
    env = {}
    for k, v in INPUT_MAP.items():
        if k in inputs:
            env[v] = "${{ inputs.%s }}" % k
    env["USE_BBR"] = "${{ inputs.use_bbr }}"
    env["TOOLCHAIN_CACHE_HIT"] = "${{ steps.cache-toolchain.outputs.cache-hit }}"
    env["WORKSPACE"] = "${{ github.workspace }}"
    steps[-1]["env"] = env

    steps += [
        {"name": "保存 Release 缓存（可选）",
         "if": "${{ inputs.use_release_cache && !cancelled() }}",
         "uses": "./.github/actions/cache-save",
         "with": {"cache_path": "/home/runner/.ccache",
                  "cache_key": cache_key,
                  "cache_bucket": "ccache-cache",
                  "github_token": "${{ secrets.GITHUB_TOKEN }}"}},
        {"name": "上传编译失败日志", "if": "${{ always() }}",
         "uses": "actions/upload-artifact@v6", "with": {
             "name": "${{ inputs.ksu_variant }}_kernel-${{ env.CONFIG }}-Build-Logs",
             "path": "build-logs/", "if-no-files-found": "ignore",
             "retention-days": 7, "compression-level": 9}},
        {"name": "上传 SUSFS 集成补丁",
         "if": "success() && env.SUSFS_PATCH_EXPORT == 'true'",
         "uses": "actions/upload-artifact@v6", "with": {
             "name": "SUSFS-Patch-${{ inputs.ksu_variant }}-${{ env.CONFIG }}-${{ inputs.os_patch_level }}",
             "path": "susfs-patch/", "if-no-files-found": "warn", "compression-level": 9}},
        {"name": "上传 AnyKernel3 刷入包",
         "if": "inputs.artifact_upload_mode != '上传全部'",
         "uses": "actions/upload-artifact@v6", "with": {
             "name": "${{ inputs.ksu_variant }}_kernel-${{ env.CONFIG }}-AnyKernel3",
             "path": "AnyKernel3/*", "compression-level": 9}},
        {"name": "上传全部构建产物",
         "if": "inputs.artifact_upload_mode == '上传全部'",
         "uses": "actions/upload-artifact@v6", "with": {
             "name": "${{ inputs.ksu_variant }}_kernel-${{ env.CONFIG }}",
             "path": "*AnyKernel3.zip\n*.img", "compression-level": 9}},
        {"name": "上传补丁冲突文件", "if": "always() && env.REJ_COUNT > 0",
         "uses": "actions/upload-artifact@v6", "with": {
             "name": "${{ inputs.ksu_variant }}_kernel-${{ env.CONFIG }}-Rejects",
             "path": "patch-rejects/", "if-no-files-found": "ignore", "compression-level": 9}},
        {"name": "发送 Telegram 通知", "if": "${{ inputs.send_telegram }}",
         "env": dict({
             "TELEGRAM_BOT_TOKEN": "${{ secrets.TELEGRAM_BOT_TOKEN }}",
             "TELEGRAM_CHAT_ID": "${{ secrets.TELEGRAM_CHAT_ID }}",
             "TELEGRAM_MESSAGE_THREAD_ID": "${{ secrets.TELEGRAM_MESSAGE_THREAD_ID }}",
         }, **{v: "${{ inputs.%s }}" % k for k, v in INPUT_MAP.items() if k in inputs},
             **{"USE_BBR": "${{ inputs.use_bbr }}", "WORKSPACE": "${{ github.workspace }}"}),
         # 通知失败不应让整个构建标红
         "run": "python3 scripts/telegram_notify.py single || true"},
    ]

    new = {
        "name": job.get("name", "内核构建流程"),
        "on": {"workflow_call": {"inputs": inputs}},
        "jobs": {"build-kernel": {
            "name": job.get("name"),
            "runs-on": job.get("runs-on", "ubuntu-latest"),
            "timeout-minutes": job.get("timeout-minutes", 60),
            "env": job.get("env", {}),
            "steps": steps,
        }},
    }

    with open(OUT, "w", encoding="utf-8") as f:
        f.write(HEADER)
        yaml.safe_dump(new, f, allow_unicode=True, sort_keys=False,
                       default_flow_style=False, width=200)
    print("生成: %s" % OUT)
    print("inputs: %d, steps: %d" % (len(inputs), len(steps)))


if __name__ == "__main__":
    main()
