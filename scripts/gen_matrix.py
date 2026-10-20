#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""从 .github/workflows/config/matrix.json 生成构建矩阵。

两种模式：
  auto —— 自动更新（Auto_Trigger → main.yml）使用的裁剪矩阵，19 组合。
          只保留仍在维护、仍有人刷机的最新子版本，剔除早期已弃用版本。
  full —— 手动触发（直接在 Actions 里跑 kernel-*.yml）使用的全量矩阵，91 组合。
          保留全部历史子版本，方便按需回编旧版本。

用法：
    python3 scripts/gen_matrix.py --mode auto --android android12 --github-output
    python3 scripts/gen_matrix.py --mode full --list
"""
import argparse
import json
import os
import sys
from pathlib import Path

MATRIX_PATH = Path(__file__).resolve().parent.parent / ".github" / "workflows" / "config" / "matrix.json"
MODES = ("auto", "full")

_SUB_ORDER = lambda s: (9999 if s == "X" else int(s), s)  # noqa: E731  X(LTS) 排最后


def load_raw() -> dict:
    if not MATRIX_PATH.is_file():
        print(f"::error::矩阵文件不存在: {MATRIX_PATH}", file=sys.stderr)
        sys.exit(1)
    with MATRIX_PATH.open(encoding="utf-8") as f:
        return json.load(f)


def _load_mode(data: dict, mode: str) -> dict:
    if mode not in data:
        print(f"::error::矩阵文件中没有模式 {mode}（可选: {', '.join(MODES)}）", file=sys.stderr)
        sys.exit(1)

    out = data[mode]
    if not isinstance(out, dict) or not out:
        print(f"::error::模式 {mode} 的矩阵为空或格式错误", file=sys.stderr)
        sys.exit(1)
    return out


def build_entries(data: dict) -> list:
    """展开成扁平清单，每项含 android / kernel / sub_level / os_patch_level / revision。"""
    out = []
    for key, configs in data.items():
        try:
            android, kernel = key.split("-", 1)
        except ValueError:
            print(f"::error::矩阵键名不合法（应为 androidN-kernel）: {key}", file=sys.stderr)
            sys.exit(1)
        for cfg in configs:
            entry = {
                "android": android,
                "kernel": kernel,
                "sub_level": str(cfg["sub_level"]),
                "os_patch_level": str(cfg["os_patch_level"]),
            }
            if cfg.get("revision"):
                entry["revision"] = str(cfg["revision"])
            out.append(entry)

    out.sort(key=lambda e: (
        int(e["android"].replace("android", "")),
        float(e["kernel"]),
        _SUB_ORDER(e["sub_level"]),
    ))
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", default="auto", choices=MODES,
                    help="auto = 自动更新裁剪矩阵；full = 手动触发全量矩阵")
    ap.add_argument("--android", help="只输出指定安卓版本，如 android12")
    ap.add_argument("--list", action="store_true", help="只打印汇总，不输出 JSON")
    ap.add_argument("--github-output", action="store_true", help="写入 $GITHUB_OUTPUT")
    args = ap.parse_args()

    raw = load_raw()
    entries = build_entries(_load_mode(raw, args.mode))
    if args.android:
        filtered = [e for e in entries if e["android"] == args.android]
        if not filtered:
            # 先确认这个安卓版本在任意模式里存在：不存在说明是版本号写错了，
            # 属于配置错误，必须报错；存在但本模式没有（如 auto 不含 6.12）
            # 才是正常的空矩阵，交给下游 job 自行跳过。
            known = set()
            for mode_name, mode_data in raw.items():
                if mode_name.startswith("_") or not isinstance(mode_data, dict):
                    continue
                for key in mode_data:
                    known.add(key.split("-", 1)[0])
            if args.android not in known:
                print(f"::error::未知安卓版本 {args.android}（已知: {', '.join(sorted(known))}）",
                      file=sys.stderr)
                sys.exit(1)

            if args.github_output:
                out_file = os.environ.get("GITHUB_OUTPUT")
                if not out_file:
                    print("::error::$GITHUB_OUTPUT 未设置", file=sys.stderr)
                    sys.exit(1)
                with open(out_file, "a", encoding="utf-8") as f:
                    f.write("matrix=[]\n")
                    f.write("count=0\n")
            elif not args.list:
                print("[]")
            print(f"[{args.mode}] {args.android} 不在矩阵中，输出空矩阵（共 0 个组合）", file=sys.stderr)
            return
        entries = filtered

    per_android: dict = {}
    for e in entries:
        per_android.setdefault(f"{e['android']}-{e['kernel']}", []).append(e["sub_level"])

    if args.github_output:
        out_file = os.environ.get("GITHUB_OUTPUT")
        if not out_file:
            print("::error::$GITHUB_OUTPUT 未设置", file=sys.stderr)
            sys.exit(1)
        # android / kernel 不写进 matrix：下游 kernel-a1x 的 android_version 与
        # kernel_version 都是写死的字面量，只消费 sub_level / os_patch_level /
        # revision。每项少两个键，91 项的矩阵就少一大截，也避免两份真相漂移。
        payload_entries = [{k: v for k, v in e.items() if k not in ("android", "kernel")}
                           for e in entries]
        payload = json.dumps(payload_entries, ensure_ascii=False, separators=(",", ":"))
        with open(out_file, "a", encoding="utf-8") as f:
            f.write(f"matrix={payload}\n")
            f.write(f"count={len(entries)}\n")
    elif not args.list:
        print(json.dumps(entries, ensure_ascii=False, separators=(",", ":")))

    # 汇总打印，便于 CI 日志核对
    print(f"[{args.mode}] 共 {len(entries)} 个组合", file=sys.stderr)
    for k in sorted(per_android):
        print(f"  {k}: {', '.join(per_android[k])}", file=sys.stderr)


if __name__ == "__main__":
    main()
