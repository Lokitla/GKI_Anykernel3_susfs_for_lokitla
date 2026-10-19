# SPDX-License-Identifier: GPL-2.0-or-later

# 仅供本地全量重建，CI 不使用：任何 workflow 都不调用本脚本（CI 走增量
# 的 update_data.py）。上游接口变动时两边需各自维护，别把 CI 指向这里。

import json
import os

from gki_fetch import TARGETS, fetch_lts, parse_version, json_path


def update_lts():
    for (android_ver, kernel_ver) in TARGETS:
        path = json_path(android_ver, kernel_ver)
        print(f"\n=== {android_ver} / {kernel_ver} ===")

        if not os.path.exists(path):
            print(f"  JSON not found: {path}, skip")
            continue

        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)

        lts_label = f"{android_ver}-{kernel_ver}-lts"
        print(f"  [{lts_label}] ", end="", flush=True)
        lts_text = fetch_lts(android_ver, kernel_ver)
        if lts_text is None:
            print("not found, skip")
            continue

        ver = parse_version(lts_text)
        if ver is None:
            print("parse failed, skip")
            continue

        version, patchlevel, sublevel = ver
        lts_value = f"{version}.{patchlevel}.{sublevel}"
        old_lts = data.get("lts")
        if old_lts == lts_value:
            print(f"-> {lts_value} (unchanged)")
            continue

        data["lts"] = lts_value
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
        print(f"-> {lts_value} (was {old_lts})")

    print("\nDone.")


if __name__ == "__main__":
    update_lts()
