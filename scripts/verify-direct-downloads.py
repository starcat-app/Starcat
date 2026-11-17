#!/usr/bin/env python3
"""只读核验 Direct 双语下载契约，供正式、Beta 发布及恢复入口共用。

回读线上页面与已测试的共享脚本，核对两个 feed 与 GitHub 的完整 tag、附件和大小。
不生成页面、不上传文件，也不把 HTTP 200 当作下载内容已更新的证据。
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import xml.etree.ElementTree as ET
from html.parser import HTMLParser
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
ASSET = re.compile(
    r"https://github\.com/starcat-app/Starcat/releases/download/v([^/]+)/Starcat-([^/]+)-arm64\.dmg"
)


class DownloadPage(HTMLParser):
    """提取下载挂载点与模块入口，不执行页面中的支付或统计代码。"""

    def __init__(self, source: bytes):
        super().__init__()
        self.hooks = set()
        self.modules = []
        self.feed(source.decode("utf-8"))

    def handle_starttag(self, tag, attrs):
        attributes = dict(attrs)
        self.hooks.update(key for key in attributes if key.startswith("data-download-"))
        if tag == "script" and attributes.get("type") == "module":
            self.modules.append(attributes.get("src"))


def fetch(url: str) -> bytes:
    """读取有超时和有限重试；继承发布入口的代理配置，不执行任何远程写操作。"""
    return subprocess.run(
        ["curl", "-fsSL", "--connect-timeout", "15", "--max-time", "45",
         "--retry", "2", "--retry-max-time", "90", url],
        check=True, capture_output=True,
    ).stdout


def feed_releases(source: bytes) -> dict:
    """按 GitHub tag 建索引；开发 feed 的稳定条目仍保留正式身份。"""
    releases = {}
    for item in ET.fromstring(source).findall("./channel/item"):
        enclosure = item.find("enclosure")
        if enclosure is None:
            continue
        url = enclosure.get("url", "")
        match = ASSET.fullmatch(url)
        version = item.findtext(SPARKLE + "shortVersionString", "")
        if not match or match[1].split("-")[0] != version or match[2] != version:
            raise ValueError(f"feed 附件与版本不一致: {url}")
        releases[match[1]] = {
            "url": url, "size": int(enclosure.get("length", "0")),
            "version": version, "build": item.findtext(SPARKLE + "version", ""),
        }
    if not releases:
        raise ValueError("feed 没有可下载条目")
    return releases


def version_key(tag: str):
    """营销版本按数字比较，预发布序号保留自然数顺序。"""
    version, _, suffix = tag.partition("-")
    sequence = re.search(r"\.(\d+)$", suffix)
    stage = 0 if suffix.startswith("dev.") else 1
    return tuple(map(int, version.split("."))), not bool(suffix), stage, int(sequence[1]) if sequence else 0


def verify(version: str, site_root: Path, base_url: str, read=fetch) -> list[str]:
    """页面、共享实现和两个发布渠道全部匹配才允许发布入口报告完成。"""
    required = {
        "data-download-open", "data-download-link", "data-download-version",
        "data-download-development-version", "data-download-development-meta",
        "data-download-development-link", "data-download-history",
    }
    for page in ("index.html", "index-zh.html"):
        parsed = DownloadPage(read(f"{base_url}/{page}"))
        if not required.issubset(parsed.hooks) or "/downloads.js" not in parsed.modules:
            raise ValueError(f"线上 {page} 缺少稳定版/开发版下载入口或共享脚本")
    if read(f"{base_url}/downloads.js") != (site_root / "downloads.js").read_bytes():
        raise ValueError("线上下载脚本与本地已验证实现不同，需定向部署双语首页和 downloads.js")

    stable = feed_releases(read(f"{base_url}/appcast.xml"))
    development = feed_releases(read(f"{base_url}/appcast-development.xml"))
    catalog = stable | development
    if version not in catalog:
        raise ValueError(f"线上下载 feed 缺少本次版本: v{version}")
    published = json.loads(read("https://api.github.com/repos/starcat-app/Starcat/releases?per_page=100"))
    channels = {False: {}, True: {}}
    for release in published:
        if release.get("draft"):
            continue
        tag = release["tag_name"].removeprefix("v")
        assets = [asset for asset in release.get("assets", []) if ASSET.fullmatch(asset["browser_download_url"])]
        if assets:
            channels[bool(release["prerelease"])][tag] = assets[0]
    if not channels[False] or version not in (channels[False] | channels[True]):
        raise ValueError(f"GitHub 缺少公开正式版或本次发布的 DMG: v{version}")
    checked = []
    for prerelease, github in channels.items():
        if not github:
            continue
        tag = max(github, key=version_key)
        feed = development if prerelease else stable
        candidates = [identity for identity in feed if ("-" in identity) == prerelease]
        if not candidates or max(candidates, key=version_key) != tag:
            raise ValueError(f"官网{'开发' if prerelease else '正式'}下载未对齐 GitHub 最新版本: v{tag}")
        asset = github[tag]
        if feed[tag]["url"] != asset["browser_download_url"] or feed[tag]["size"] != asset["size"]:
            raise ValueError(f"官网附件与 GitHub 不同: v{tag}")
        checked.append(f"v{tag}: {feed[tag]['url']}")
    return checked


def main():
    """CLI 只做回读，适用于新发布、--resume 和独立官网修复验收。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True, help="完整发布身份，如 1.9.5-beta.1")
    parser.add_argument("--site-root", type=Path, default=ROOT / "supports/starcat-site/direct")
    parser.add_argument("--base-url", default="https://starcat.ink")
    args = parser.parse_args()
    try:
        checked = verify(args.version.removeprefix("v"), args.site_root, args.base_url.rstrip("/"))
    except (ValueError, OSError, subprocess.CalledProcessError, ET.ParseError) as error:
        parser.exit(1, f"Direct 双语下载校验失败: {error}\n")
    print("Direct 双语下载、双 feed 与 GitHub 附件核验通过\n" + "\n".join(checked))


if __name__ == "__main__":
    main()
