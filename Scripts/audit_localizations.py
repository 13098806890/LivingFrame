#!/usr/bin/env python3
"""Audit localized strings, Swift source keys, and Xcode locale registration."""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter
from pathlib import Path
from typing import Any


ENTRY_RE = re.compile(r'^\s*("(?:\\.|[^"\\])*")\s*=\s*("(?:\\.|[^"\\])*")\s*;\s*$')
SWIFT_STRING_RE = re.compile(r'"(?:\\.|[^"\\])*"')
LOCALIZED_CALL_RE = re.compile(r'NSLocalizedString\s*\(\s*("(?:\\.|[^"\\])*")')
CHINESE_RE = re.compile(r'[\u3400-\u9fff]')
FORMAT_RE = re.compile(
    r'%(?:\d+\$)?[-+#0 \']*(?:\d+|\*)?(?:\.(?:\d+|\*))?'
    r'(?:hh|h|ll|l|q|z|t|j|L)?[@diuoxXfFeEgGaAcCsSpn%]'
)
COMMENT_RE = re.compile(r'^\s*(?://|/\*|\*)')
LOCALE_REF_RE = re.compile(r'(?P<locale>[A-Za-z0-9-]+)\.lproj/(?P<name>Localizable|InfoPlist)\.strings')
UNTRANSLATED_ALLOWLIST = {
    "GIF", "Live Photo", "GIFBloom", "logo", "%d%%", "15 fps", "30 fps",
    "16:9", "1:1", "3:4", "4:3", "4:5", "9:16",
}


def decode_string(literal: str) -> str:
    """Decode the quoted strings-file literal using JSON-compatible escapes."""
    return json.loads(literal)


def parse_strings(path: Path) -> tuple[dict[str, str], list[str]]:
    entries: dict[str, str] = {}
    problems: list[str] = []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as exc:
        return entries, [f"无法读取 UTF-8 文件：{exc}"]

    for number, line in enumerate(lines, start=1):
        if not line.strip() or COMMENT_RE.match(line):
            continue
        match = ENTRY_RE.match(line)
        if not match:
            problems.append(f"第 {number} 行不是有效的 key = value; 条目")
            continue
        try:
            key, value = (decode_string(part) for part in match.groups())
        except json.JSONDecodeError as exc:
            problems.append(f"第 {number} 行转义无效：{exc}")
            continue
        if key in entries:
            problems.append(f"第 {number} 行重复定义 key：{key}")
        entries[key] = value
    return entries, problems


def swift_string_value(literal: str) -> str:
    """Decode common Swift literal escapes without treating interpolation as JSON."""
    body = literal[1:-1]
    body = body.replace(r"\(", "\u0000INTERPOLATION\u0000")
    try:
        value = json.loads('"' + body + '"')
    except json.JSONDecodeError:
        value = body.replace(r'\"', '"').replace(r'\\', '\\')
    return value.replace("\u0000INTERPOLATION\u0000", r"\(")


def source_localization_keys(root: Path) -> tuple[set[str], list[dict[str, str]]]:
    keys: set[str] = set()
    unclassified: list[dict[str, str]] = []
    # User-facing SwiftUI and app service strings live in LivingFrame. The core
    # package and its tests also contain Chinese fixture names and resource
    # paths, which are not localization keys.
    source_roots = [root / "LivingFrame"]
    for source_root in source_roots:
        if not source_root.exists():
            continue
        for path in sorted(source_root.rglob("*.swift")):
            try:
                lines = path.read_text(encoding="utf-8").splitlines()
            except (OSError, UnicodeError):
                continue
            context: list[str] = []
            for number, line in enumerate(lines, start=1):
                if COMMENT_RE.match(line):
                    context = (context + [line])[-12:]
                    continue
                context = (context + [line])[-12:]
                for literal in SWIFT_STRING_RE.findall(line):
                    value = swift_string_value(literal)
                    if not CHINESE_RE.search(value):
                        continue
                    window = "\n".join(context)
                    if "LogStore.log(" in window or "Logger." in window:
                        continue
                    # A directly displayed/localized Chinese string is a required catalog key.
                    # Other Chinese literals are surfaced for manual classification.
                    if "Text(verbatim:" in window:
                        continue
                    keys.add(value)
                    if "\\(" in value:
                        unclassified.append({"file": str(path.relative_to(root)), "line": str(number), "text": value,
                                             "reason": "含 Swift 字符串插值，需人工确认 Localizable.strings 对应 key"})
    return keys, unclassified


def package_localization_keys(root: Path) -> tuple[set[str], list[str]]:
    """Read literal NSLocalizedString keys from the app's bundled Swift package."""
    keys: set[str] = set()
    problems: list[str] = []
    package_root = root / "Packages" / "LivingFrameCore" / "Sources"
    if not package_root.exists():
        return keys, problems
    for path in sorted(package_root.rglob("*.swift")):
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as exc:
            problems.append(f"{path.relative_to(root)} 无法读取：{exc}")
            continue
        for match in LOCALIZED_CALL_RE.finditer(text):
            try:
                value = swift_string_value(match.group(1))
            except (ValueError, TypeError):
                problems.append(f"{path.relative_to(root)} 存在无法解析的 NSLocalizedString key")
                continue
            if value:
                keys.add(value)
    return keys, problems


def project_regions(project: Path) -> tuple[set[str], set[str], set[str], list[str]]:
    text = project.read_text(encoding="utf-8")
    match = re.search(r"knownRegions\s*=\s*\((.*?)\);", text, re.S)
    problems: list[str] = []
    known: set[str] = set()
    if not match:
        problems.append("project.pbxproj 缺少 knownRegions")
    else:
        known = {item.strip().strip('"') for item in match.group(1).split(",") if item.strip()}
    registered: dict[str, set[str]] = {}
    for ref in LOCALE_REF_RE.finditer(text):
        registered.setdefault(ref.group("locale"), set()).add(ref.group("name"))
    localizable = {locale for locale, names in registered.items() if "Localizable" in names}
    infoplist = {locale for locale, names in registered.items() if "InfoPlist" in names}
    return known, localizable, infoplist, problems


def audit(root: Path) -> dict[str, Any]:
    localization_root = root / "LivingFrame" / "Localization"
    project = root / "LivingFrame.xcodeproj" / "project.pbxproj"
    locales = sorted(path.name[:-6] for path in localization_root.glob("*.lproj") if path.is_dir())
    findings: list[dict[str, str]] = []
    report: dict[str, Any] = {"schema_version": 1, "locales": locales, "locale_results": {}, "findings": findings}

    if "en" not in locales:
        findings.append({"severity": "error", "code": "missing-baseline", "message": "缺少 en.lproj"})
        return report

    baseline_ui, ui_parse = parse_strings(localization_root / "en.lproj" / "Localizable.strings")
    baseline_plist, plist_parse = parse_strings(localization_root / "en.lproj" / "InfoPlist.strings")
    for problem in ui_parse + plist_parse:
        findings.append({"severity": "error", "code": "baseline-syntax", "message": problem})

    all_ui: dict[str, dict[str, str]] = {}
    for locale in locales:
        folder = localization_root / f"{locale}.lproj"
        ui, ui_problems = parse_strings(folder / "Localizable.strings")
        plist, plist_problems = parse_strings(folder / "InfoPlist.strings")
        all_ui[locale] = ui
        missing_ui = sorted(set(baseline_ui) - set(ui))
        extra_ui = sorted(set(ui) - set(baseline_ui))
        missing_plist = sorted(set(baseline_plist) - set(plist))
        extra_plist = sorted(set(plist) - set(baseline_plist))
        format_mismatches = [
            key for key in sorted(set(baseline_ui) & set(ui))
            if Counter(FORMAT_RE.findall(baseline_ui[key])) != Counter(FORMAT_RE.findall(ui[key]))
        ]
        empty_values = [key for key, value in ui.items() if not value.strip()]
        required_token_mismatches = []
        for key, value in ui.items():
            required_tokens = []
            if "HEVC-alpha" in key:
                required_tokens.append("HEVC-alpha")
            if "Live Photo" in key:
                required_tokens.append("Live Photo")
            if any(token not in value for token in required_tokens):
                required_token_mismatches.append(key)
        if missing_ui or extra_ui or missing_plist or extra_plist or format_mismatches or required_token_mismatches or empty_values or ui_problems or plist_problems:
            findings.append({
                "severity": "error", "code": "locale-catalog", "locale": locale,
                "message": "目录 key、占位符、空值或语法存在问题",
                "missing_ui_keys": missing_ui, "extra_ui_keys": extra_ui,
                "missing_infoplist_keys": missing_plist, "extra_infoplist_keys": extra_plist,
                "format_mismatches": format_mismatches, "required_token_mismatches": required_token_mismatches,
                "empty_values": empty_values,
                "syntax_problems": ui_problems + plist_problems,
            })
        untranslated = [
            key for key, value in ui.items()
            if locale not in {"en", "zh-Hans", "zh-Hant"}
            and value == baseline_ui.get(key)
            and value not in UNTRANSLATED_ALLOWLIST
            and not re.fullmatch(r"\d+(?: fps|:\d+)", value)
        ]
        report["locale_results"][locale] = {
            "ui_key_count": len(ui), "infoplist_key_count": len(plist),
            "missing_ui_keys": len(missing_ui), "extra_ui_keys": len(extra_ui),
            "missing_infoplist_keys": len(missing_plist), "extra_infoplist_keys": len(extra_plist),
            "format_mismatches": len(format_mismatches),
            "required_token_mismatches": len(required_token_mismatches),
            "syntax_problems": len(ui_problems) + len(plist_problems),
            "untranslated_english_candidates": untranslated,
        }

    source_keys, unclassified = source_localization_keys(root)
    package_keys, package_problems = package_localization_keys(root)
    source_keys.update(package_keys)
    missing_source = sorted(key for key in source_keys if key not in baseline_ui)
    if missing_source:
        findings.append({"severity": "error", "code": "source-keys", "message": "源码中的中文文案未进入 Localizable.strings",
                         "missing_keys": missing_source})
    if unclassified:
        findings.append({"severity": "warning", "code": "interpolated-source-keys", "message": "请人工确认 Swift 插值字符串的 catalog key",
                         "items": unclassified})
    if package_problems:
        findings.append({"severity": "error", "code": "package-source-keys", "message": "Swift package 本地化 key 无法完整读取",
                         "problems": package_problems})
    report["source_chinese_literal_count"] = len(source_keys)
    report["source_missing_keys"] = missing_source
    report["source_interpolation_review"] = unclassified
    report["baseline_ui_key_count"] = len(baseline_ui)
    report["baseline_infoplist_key_count"] = len(baseline_plist)

    if project.is_file():
        known, ui_refs, plist_refs, project_problems = project_regions(project)
        discovered = set(locales)
        missing_known = sorted(discovered - known)
        missing_ui_refs = sorted(discovered - ui_refs)
        missing_plist_refs = sorted(discovered - plist_refs)
        for locale in missing_known:
            findings.append({"severity": "error", "code": "project-region", "locale": locale,
                             "message": "未登记到 project.pbxproj knownRegions"})
        for locale in missing_ui_refs:
            findings.append({"severity": "error", "code": "project-ui-resource", "locale": locale,
                             "message": "未登记 Localizable.strings 变体资源"})
        for locale in missing_plist_refs:
            findings.append({"severity": "error", "code": "project-plist-resource", "locale": locale,
                             "message": "未登记 InfoPlist.strings 变体资源"})
        for problem in project_problems:
            findings.append({"severity": "error", "code": "project-config", "message": problem})
        report["project"] = {"known_regions": sorted(known), "localizable_refs": sorted(ui_refs),
                             "infoplist_refs": sorted(plist_refs)}
    else:
        findings.append({"severity": "error", "code": "missing-project", "message": "找不到 LivingFrame.xcodeproj/project.pbxproj"})

    report["summary"] = {
        "locale_count": len(locales), "ui_key_count": len(baseline_ui),
        "infoplist_key_count": len(baseline_plist),
        "error_count": sum(item.get("severity") == "error" for item in findings),
        "warning_count": sum(item.get("severity") == "warning" for item in findings),
        "english_candidate_count_by_locale": {
            locale: len(result["untranslated_english_candidates"])
            for locale, result in report["locale_results"].items()
        },
    }
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1], help="LivingFrame repository root")
    parser.add_argument("--output-json", type=Path, help="Write the full audit result to this path")
    args = parser.parse_args()
    result = audit(args.root.resolve())
    rendered = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
    if args.output_json:
        args.output_json.parent.mkdir(parents=True, exist_ok=True)
        args.output_json.write_text(rendered, encoding="utf-8")
    print(json.dumps(result["summary"], ensure_ascii=False, indent=2))
    for finding in result["findings"]:
        print(f"[{finding['severity']}] {finding['code']}: {finding['message']}")
    return 1 if result["summary"]["error_count"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
