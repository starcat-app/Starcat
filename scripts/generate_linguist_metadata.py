#!/usr/bin/env python3
"""
生成 GitHub Linguist 语言元数据的 Swift 代码。

用法:
    python3 scripts/generate_linguist_metadata.py

    # 下载固定提交的 Linguist YAML 并生成 Swift 代码
    python3 scripts/generate_linguist_metadata.py

    # 或使用本地文件
    python3 scripts/generate_linguist_metadata.py --local /path/to/languages.yml

输出:
    Starcat/Shared/Components/LinguistLanguages.generated.swift

许可证:
    GitHub Linguist: MIT License
    https://github.com/github/linguist
"""

import yaml
import urllib.request
import argparse
import json
import sys
from pathlib import Path

# 默认输入使用完整 commit，避免后续生成时跟随 master 自动换版。
# 现存 2026-05-31 生成文件尚未重新生成，不能把此提交冒充其历史输入。
LINGUIST_YAML_URL = "https://raw.githubusercontent.com/github/linguist/d456527fe93355baa28c3c29d542c97282b61bc7/lib/linguist/languages.yml"


def fetch_linguist_yaml(url: str) -> dict:
    """使用明确输入地址获取语言数据，让 --url 与默认固定提交采用同一路径"""
    print(f"Fetching {url}...")
    try:
        with urllib.request.urlopen(url, timeout=30) as response:
            content = response.read().decode('utf-8')
        return yaml.safe_load(content)
    except Exception as e:
        print(f"Error fetching: {e}", file=sys.stderr)
        sys.exit(1)


def generate_swift_code(languages: dict, source: str) -> str:
    """记录本次真实输入，避免把本地文件或自选 URL 标成默认上游"""
    lines = [
        "// ⚠️ 自动生成的文件，请勿手动修改",
        "// 运行: python3 scripts/generate_linguist_metadata.py 更新",
        "//",
        f"// 数据来源: {source}",
        f"// 生成时间: {__import__('datetime').date.today()}",
        f"// 语言数量: {len(languages)}",
        "",
        "import Foundation",
        "",
        "/// GitHub Linguist 语言元数据",
        "/// 来源: https://github.com/github/linguist",
        "public struct LinguistLanguage: Codable, Equatable {",
        "    public let type: String",
        "    public let color: String?",
        "    public let aliases: [String]",
        "",
        "    public init(type: String, color: String?, aliases: [String] = []) {",
        "        self.type = type",
        "        self.color = color",
        "        self.aliases = aliases",
        "    }",
        "}",
        "",
        "/// GitHub Linguist 语言元数据表",
        "/// key: 语言名, value: LinguistLanguage",
        "public let linguistLanguages: [String: LinguistLanguage] = [",
    ]

    for name, meta in sorted(languages.items()):
        color = meta.get('color')
        lang_type = meta.get('type', 'programming')
        # Swift 字符串数组需要双引号；Python list 的 repr 会产生非法单引号。
        aliases = json.dumps(meta.get('aliases', []), ensure_ascii=False)

        # 转义 Swift 字符串中的特殊字符
        escaped_name = name.replace('\\', '\\\\').replace('"', '\\"').replace('\n', ' ')

        if color:
            lines.append(f'    "{escaped_name}": LinguistLanguage(type: "{lang_type}", color: "{color}", aliases: {aliases}),')
        else:
            lines.append(f'    "{escaped_name}": LinguistLanguage(type: "{lang_type}", color: nil, aliases: {aliases}),')

    lines.extend([
        "]",
        "",
        "/// 根据语言名获取元数据",
        "public func linguistLanguage(for name: String) -> LinguistLanguage? {",
        "    return linguistLanguages[name]",
        "}",
    ])

    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(description='生成 GitHub Linguist 语言元数据的 Swift 代码')
    parser.add_argument('--url', default=LINGUIST_YAML_URL, help='Linguist YAML URL')
    parser.add_argument('--output', default='Starcat/Shared/Components/LinguistLanguages.generated.swift',
                        help='输出文件路径')
    parser.add_argument('--local', metavar='FILE', help='使用本地 YAML 文件而非下载')
    args = parser.parse_args()

    # 获取数据
    if args.local:
        print(f"Loading local file: {args.local}")
        with open(args.local, 'r', encoding='utf-8') as f:
            languages = yaml.safe_load(f)
        source = f"local: {Path(args.local).name}"
    else:
        languages = fetch_linguist_yaml(args.url)
        source = args.url

    # 生成代码
    swift_code = generate_swift_code(languages, source)

    # 写入文件
    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    with open(output_path, 'w', encoding='utf-8') as f:
        f.write(swift_code)

    print(f"Generated {len(languages)} languages to {output_path}")

    # 统计
    with_color = sum(1 for m in languages.values() if m.get('color'))
    print(f"  - With color: {with_color}")
    print(f"  - Without color: {len(languages) - with_color}")


if __name__ == '__main__':
    main()
