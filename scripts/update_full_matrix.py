#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Append newly published monthly kernels to the manually triggered full matrix.

The auto matrix is intentionally curated and is left unchanged. For each
kernel family, this script appends only data entries newer than the latest
monthly entry already in the full matrix, preserving historical selections.
"""

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MATRIX_FILE = ROOT / ".github" / "workflows" / "config" / "matrix.json"
DATA_FILES = {
    "android12-5.10": "android12/5.10.json",
    "android13-5.15": "android13/5.15.json",
    "android14-6.1": "android14/6.1.json",
    "android15-6.6": "android15/6.6.json",
    "android16-6.12": "android16/6.12.json",
}


def main() -> int:
    original = MATRIX_FILE.read_text(encoding="utf-8")
    matrix = json.loads(original)
    full = matrix.get("full")
    if not isinstance(full, dict):
        raise ValueError("matrix.json 缺少 full 矩阵")

    added = 0
    for key, relative_path in DATA_FILES.items():
        entries = full.get(key)
        if not isinstance(entries, list):
            raise ValueError(f"full 矩阵缺少有效条目: {key}")

        monthly = [item for item in entries if item.get("os_patch_level") != "lts"]
        latest_date = max((item["os_patch_level"] for item in monthly), default="")
        data = json.loads((ROOT / "data" / relative_path).read_text(encoding="utf-8"))
        new_entries = []
        for item in data.get("entries", []):
            date = item.get("date", "")
            kernel = item.get("kernel", "")
            if not date or date <= latest_date or not kernel:
                continue
            entry = {
                "sub_level": kernel.rsplit(".", 1)[-1],
                "os_patch_level": date,
            }
            if item.get("revision"):
                entry["revision"] = item["revision"]
            new_entries.append(entry)

        if new_entries:
            insertion = next(
                (i for i, item in enumerate(entries) if item.get("os_patch_level") == "lts"),
                len(entries),
            )
            entries[insertion:insertion] = new_entries
            added += len(new_entries)
            print(f"{key}: 新增 {len(new_entries)} 项，最新 {new_entries[-1]['os_patch_level']}")

    rendered = json.dumps(matrix, indent=2, ensure_ascii=False) + "\n"
    # Keep the repository's compact one-line objects inside matrix arrays.
    rendered = re.sub(
        r"(?m)^(\s*)\{\n((?:\s+\"[^\"]+\": \"[^\"]*\",?\n)+)\s*\}",
        lambda match: match.group(1) + "{" + ", ".join(
            line.strip().rstrip(",") for line in match.group(2).splitlines()
        ) + "}",
        rendered,
    )
    if rendered != original:
        MATRIX_FILE.write_text(rendered, encoding="utf-8")
    print(f"full 矩阵新增 {added} 个季度版本；auto 矩阵保持原样")
    return 0


if __name__ == "__main__":
    main()
