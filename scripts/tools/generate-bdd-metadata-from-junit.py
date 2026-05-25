#!/usr/bin/env python3
from __future__ import annotations

import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def parse_tags(name: str) -> list[str]:
    return [item.strip() for item in re.findall(r'\[([^\]]+)\]', name) if item.strip()]


def extract_feature(tags: list[str]) -> str:
    for tag in tags:
        if tag.startswith('feature:'):
            return tag.split(':', 1)[1].strip()
    return 'unknown'


def extract_scenario_id(tags: list[str]) -> str:
    for tag in tags:
        if tag.startswith('scenario:'):
            return tag.split(':', 1)[1].strip()
    return ''


def strip_tag_suffix(name: str) -> str:
    return re.sub(r'\s*\[[^\]]+\]\s*', ' ', name).strip()


def main() -> int:
    if len(sys.argv) != 4:
        raise SystemExit('usage: generate-bdd-metadata-from-junit.py <tests.xml> <bdd-dir> <test-binary-name>')
    xml_path = Path(sys.argv[1])
    out_dir = Path(sys.argv[2])
    binary_name = sys.argv[3]
    if not xml_path.is_file():
        raise SystemExit(f'tests.xml not found: {xml_path}')

    root = ET.parse(xml_path).getroot()
    cases = root.findall('.//testcase')
    out_dir.mkdir(parents=True, exist_ok=True)

    for case in cases:
        name = str(case.attrib.get('name', 'unnamed'))
        tags = parse_tags(name)
        scenario_id = extract_scenario_id(tags)
        if not scenario_id:
            continue
        feature = extract_feature(tags)
        scenario_title = strip_tag_suffix(name)
        featured = 'featured' in tags
        out_path = out_dir / f'{scenario_id}.json'
        if out_path.exists():
            continue
        metadata = {
            'style': 'bdd',
            'layer': 'functional',
            'feature': feature,
            'scenarioId': scenario_id,
            'scenarioTitle': scenario_title,
            'featured': featured,
            'docVisibility': 'public' if featured else 'internal',
            'automationStatus': 'automated',
            'diagramType': 'flowchart',
            'sourceTestName': scenario_title,
            'sourceTestBinary': binary_name,
            'tags': tags,
            'steps': [
                f'Given scenario {scenario_id} preconditions',
                f'When {scenario_title} executes',
                'Then expected outcome is observed',
            ],
            'actors': ['user', 'kano-git'],
            'traces': [],
            'relatedArtifacts': [],
            'environment': {},
            'lane': '',
            'project': 'kano-git-master-skill',
            'domain': feature,
        }
        out_path.write_text(json.dumps(metadata, indent=2) + '\n', encoding='utf-8')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
