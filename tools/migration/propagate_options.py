#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# 一次性迁移留档（不参与构建）。见同目录 README.md；请勿在新改动中复用。
"""把新增的三个选项贯通到上层 workflow（按唯一锚点插入，保留注释与格式）。"""
from pathlib import Path

WF_DIR = Path("/workspace/GKI_KernelSU_SUSFS_Merged/.github/workflows")

NEW_INPUTS = """      use_bbr:
        description: "设置 BBR 为默认 TCP 拥塞算法（融合自 ShirkNeko）"
        required: false
        type: boolean
        default: false
      send_telegram:
        description: "构建结束后发送 Telegram 通知（需配置 secrets）"
        required: false
        type: boolean
        default: false
      use_release_cache:
        description: "用 GitHub Release 存储 ccache（融合自 ShirkNeko）"
        required: false
        type: boolean
        default: false"""

NEW_WITH = """      use_bbr: ${{ inputs.use_bbr || false }}
      send_telegram: ${{ inputs.send_telegram || false }}
      use_release_cache: ${{ inputs.use_release_cache || false }}"""

KERNEL_FILES = [
    "kernel-a12-5-10.yml", "kernel-a13-5-15.yml", "kernel-a14-6-1.yml",
    "kernel-a15-6-6.yml", "kernel-a16-6-12.yml", "kernel-custom.yml",
]


def insert_inputs(text: str) -> str:
    """在 workflow 的 inputs 段末尾（jobs: 之前）插入新选项。"""
    if "      use_bbr:" in text:
        return text
    lines = text.split("\n")
    for i, ln in enumerate(lines):
        if ln == "jobs:":
            lines.insert(i, NEW_INPUTS)
            break
    return "\n".join(lines)


def insert_after(text: str, anchor: str) -> str:
    """在每个以 anchor 开头的行之后插入传参（anchor 必须是唯一可识别的）。"""
    out = []
    for ln in text.split("\n"):
        out.append(ln)
        if ln.startswith(anchor):
            out.append(NEW_WITH)
    return "\n".join(out)


def main():
    for name in KERNEL_FILES:
        p = WF_DIR / name
        text = p.read_text(encoding="utf-8")
        text = insert_inputs(text)
        # with 块里带表达式的那一行才是传参（inputs 段那行以冒号结尾，不会误匹配）
        text = insert_after(text, "      artifact_upload_mode: ${{")
        p.write_text(text, encoding="utf-8")
        print("已更新: %-24s (use_bbr x%d)" % (name, text.count("use_bbr")))

    p = WF_DIR / "main.yml"
    text = p.read_text(encoding="utf-8")
    text = insert_inputs(text)
    text = insert_after(text, "      called_from_main: true")
    p.write_text(text, encoding="utf-8")
    print("已更新: %-24s (use_bbr x%d)" % ("main.yml", text.count("use_bbr")))


if __name__ == "__main__":
    main()
