#!/usr/bin/env python3

from __future__ import annotations

import json
import os
import re
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict
from pathlib import Path


def normalize(path_str: str) -> str:
    return str(Path(path_str)).replace("\\", "/")


def split_csv_env(name: str) -> list[str]:
    raw = os.environ.get(name, "")
    if not raw.strip():
        return []
    return [item.strip().replace("\\", "/").strip("/") for item in re.split(r"[,;]", raw) if item.strip()]


def default_include_prefixes(repo_root: Path) -> list[str]:
    configured = split_csv_env("KANO_CPP_INFRA_COVERAGE_INCLUDE_PREFIXES")
    if configured:
        return configured
    if (repo_root / "code").is_dir():
        return ["code"]
    return []


def default_exclude_patterns() -> list[str]:
    configured = split_csv_env("KANO_CPP_INFRA_COVERAGE_EXCLUDE_REGEX")
    if configured:
        return configured
    return [
        r"(^|/)(out|build|cmake-build-[^/]*|_deps|thirdparty|third_party|vendor|vcpkg_installed|\.vcpkg)(/|$)",
        r"(^|/)(catch2|ftxui)(/|$)",
    ]


def is_first_party_file(rel_path: str, include_prefixes: list[str], exclude_regexes: list[re.Pattern[str]]) -> bool:
    rel_path = rel_path.replace("\\", "/").lstrip("./")
    for exclude_regex in exclude_regexes:
        if exclude_regex.search(rel_path):
            return False
    if include_prefixes:
        return any(rel_path == prefix or rel_path.startswith(prefix.rstrip("/") + "/") for prefix in include_prefixes)
    return True


def line_hits_from_segments(segments: list[list[int]]) -> dict[int, int]:
    hits: dict[int, int] = {}
    for seg in segments:
        if len(seg) < 5:
            continue
        line_no = int(seg[0])
        count = int(seg[2])
        has_count = bool(seg[3])
        is_gap = bool(seg[4])
        if line_no <= 0 or not has_count or is_gap:
            continue
        hits[line_no] = max(hits.get(line_no, 0), count)
    return hits


def main() -> int:
    if len(sys.argv) != 4:
        print("usage: llvm_json_to_cobertura.py <llvm-export.json> <repo-root> <out.xml>", file=sys.stderr)
        return 1

    json_path = Path(sys.argv[1])
    repo_root = Path(sys.argv[2]).resolve()
    out_xml = Path(sys.argv[3])
    include_prefixes = default_include_prefixes(repo_root)
    exclude_regexes = [re.compile(pattern, re.IGNORECASE) for pattern in default_exclude_patterns()]

    payload = json.loads(json_path.read_text(encoding="utf-8"))
    file_hits: dict[str, dict[int, int]] = {}
    for data in payload.get("data", []):
        for file_entry in data.get("files", []):
            filename = normalize(file_entry.get("filename", ""))
            if filename:
                file_hits[filename] = line_hits_from_segments(file_entry.get("segments", []))

    coverage = ET.Element("coverage", attrib={
        "line-rate": "0",
        "branch-rate": "0",
        "lines-covered": "0",
        "lines-valid": "0",
        "branches-covered": "0",
        "branches-valid": "0",
        "complexity": "0",
        "version": "llvm-json-to-cobertura",
    })
    sources = ET.SubElement(coverage, "sources")
    ET.SubElement(sources, "source").text = normalize(str(repo_root))
    packages_el = ET.SubElement(coverage, "packages")

    package_files: dict[str, list[tuple[str, dict[int, int]]]] = defaultdict(list)
    total_lines_valid = 0
    total_lines_covered = 0

    for filename, hits in sorted(file_hits.items()):
        resolved = Path(filename).resolve()
        rel_path = normalize(str(resolved.relative_to(repo_root))) if resolved.is_relative_to(repo_root) else filename
        if not is_first_party_file(rel_path, include_prefixes, exclude_regexes):
            continue
        package_name = rel_path.rsplit("/", 1)[0] if "/" in rel_path else "."
        package_files[package_name].append((rel_path, hits))

    for package_name, files in sorted(package_files.items()):
        package_lines_valid = 0
        package_lines_covered = 0
        package_el = ET.SubElement(packages_el, "package", attrib={
            "name": package_name,
            "line-rate": "0",
            "branch-rate": "0",
            "complexity": "0",
            "lines-covered": "0",
            "lines-valid": "0",
        })
        classes_el = ET.SubElement(package_el, "classes")

        for rel_path, hits in files:
            lines_valid = len(hits)
            lines_covered = sum(1 for count in hits.values() if count > 0)
            package_lines_valid += lines_valid
            package_lines_covered += lines_covered
            class_el = ET.SubElement(classes_el, "class", attrib={
                "name": Path(rel_path).name,
                "filename": rel_path,
                "line-rate": str(lines_covered / lines_valid if lines_valid else 0),
                "branch-rate": "0",
                "complexity": "0",
                "lines-covered": str(lines_covered),
                "lines-valid": str(lines_valid),
            })
            lines_el = ET.SubElement(class_el, "lines")
            for line_no, hit_count in sorted(hits.items()):
                ET.SubElement(lines_el, "line", attrib={"number": str(line_no), "hits": str(hit_count), "branch": "false"})

        package_el.set("lines-covered", str(package_lines_covered))
        package_el.set("lines-valid", str(package_lines_valid))
        package_el.set("line-rate", str(package_lines_covered / package_lines_valid if package_lines_valid else 0))
        total_lines_valid += package_lines_valid
        total_lines_covered += package_lines_covered

    coverage.set("lines-covered", str(total_lines_covered))
    coverage.set("lines-valid", str(total_lines_valid))
    coverage.set("line-rate", str(total_lines_covered / total_lines_valid if total_lines_valid else 0))
    ET.indent(coverage)
    out_xml.write_text(ET.tostring(coverage, encoding="unicode"), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
