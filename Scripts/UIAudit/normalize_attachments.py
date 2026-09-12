#!/usr/bin/env python3

import json
import re
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: normalize_attachments.py <attachments-directory>", file=sys.stderr)
        return 2

    directory = Path(sys.argv[1])
    manifest_path = directory / "manifest.json"
    if not manifest_path.is_file():
        print(f"warning: attachment manifest not found: {manifest_path}", file=sys.stderr)
        return 0

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    rows = []
    for test in manifest:
        for attachment in test.get("attachments", []):
            source_name = attachment.get("exportedFileName")
            suggested_name = attachment.get("suggestedHumanReadableName")
            if not source_name or not suggested_name:
                continue

            normalized_name = re.sub(
                r"_\d+_[0-9A-Fa-f-]{36}(?=\.[^.]+$)",
                "",
                suggested_name,
            )
            source = directory / source_name
            destination = directory / normalized_name
            if source.is_file() and source != destination:
                source.replace(destination)
            attachment["normalizedFileName"] = normalized_name
            rows.append((normalized_name, source_name))

    (directory / "normalized-manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    (directory / "index.tsv").write_text(
        "normalizedFileName\texportedFileName\n"
        + "".join(f"{normalized}\t{exported}\n" for normalized, exported in rows),
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
