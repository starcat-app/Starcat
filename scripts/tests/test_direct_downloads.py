#!/usr/bin/env python3
"""Direct 下载发布门禁的隔离测试，所有线上内容由内存中的固定数据提供。"""

import copy
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("downloads", ROOT / "scripts/verify-direct-downloads.py")
downloads = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(downloads)


def attachment(tag):
    """构造与 GitHub Release 相同的版本化 DMG 地址。"""
    return f"https://github.com/starcat-app/Starcat/releases/download/v{tag}/Starcat-{tag.split('-')[0]}-arm64.dmg"


def feed(*tags):
    """包含营销版本相同的 Beta N，防止校验退化为只比营销版本。"""
    items = "".join(
        f'<item><sparkle:shortVersionString>{tag.split("-")[0]}</sparkle:shortVersionString>'
        f'<sparkle:version>202611120142</sparkle:version>'
        f'<enclosure url="{attachment(tag)}" length="100" /></item>' for tag in tags
    )
    return f'<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>{items}</channel></rss>'.encode()


class DownloadContractTests(unittest.TestCase):
    """回读内容错误时直接失败；这些测试不会连接任何发布服务。"""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.site = Path(self.temp.name)
        self.script = b"tested shared download module"
        (self.site / "downloads.js").write_bytes(self.script)
        hooks = (
            "open", "link", "version", "development-version",
            "development-meta", "development-link", "history",
        )
        html = ('<script type="module" src="/downloads.js"></script>' +
                "".join(f'<div data-download-{hook}></div>' for hook in hooks)).encode()
        self.responses = {
            "https://site/index.html": html,
            "https://site/index-zh.html": html,
            "https://site/downloads.js": self.script,
            "https://site/appcast.xml": feed("1.9.1"),
            "https://site/appcast-development.xml": feed("1.9.5-beta.2", "1.9.5-beta.1", "1.9.1"),
        }
        self.github = [
            {"tag_name": f"v{tag}", "draft": False, "prerelease": "-" in tag,
             "assets": [{"browser_download_url": attachment(tag), "size": 100}]}
            for tag in ("1.9.1", "1.9.5-beta.1", "1.9.5-beta.2")
        ]

    def verify(self):
        """调用真实门禁函数，只替换网络读取。"""
        def read(url):
            if url.startswith("https://api.github.com/"):
                return json.dumps(self.github).encode()
            return self.responses[url]
        return downloads.verify("1.9.5-beta.2", self.site, "https://site", read)

    def test_both_channels_match_and_development_feed_does_not_relabel_stable(self):
        self.assertEqual(len(self.verify()), 2)

    def test_either_language_missing_development_entry_blocks_completion(self):
        for page in ("index.html", "index-zh.html"):
            with self.subTest(page=page):
                original = self.responses[f"https://site/{page}"]
                self.responses[f"https://site/{page}"] = original.replace(b"data-download-development-link", b"old")
                with self.assertRaisesRegex(ValueError, page):
                    self.verify()
                self.responses[f"https://site/{page}"] = original

    def test_old_shared_script_blocks_completion(self):
        self.responses["https://site/downloads.js"] = b"old stable-only implementation"
        with self.assertRaisesRegex(ValueError, "脚本"):
            self.verify()

    def test_same_marketing_version_with_missing_beta_sequence_blocks_completion(self):
        self.responses["https://site/appcast-development.xml"] = feed("1.9.5-beta.1", "1.9.1")
        with self.assertRaisesRegex(ValueError, "本次版本"):
            self.verify()

    def test_newer_github_prerelease_missing_from_feed_blocks_completion(self):
        newer = copy.deepcopy(self.github[-1])
        newer["tag_name"] = "v1.9.5-beta.10"
        newer["assets"][0]["browser_download_url"] = attachment("1.9.5-beta.10")
        self.github.append(newer)
        with self.assertRaisesRegex(ValueError, "GitHub 最新版本"):
            self.verify()

    def test_github_attachment_size_mismatch_blocks_completion(self):
        self.github[-1]["assets"][0]["size"] = 999
        with self.assertRaisesRegex(ValueError, "附件与 GitHub"):
            self.verify()

    def test_draft_does_not_require_a_public_download(self):
        draft = copy.deepcopy(self.github[-1])
        draft["tag_name"] = "v9.9.9-beta.1"
        draft["draft"] = True
        self.github.append(draft)
        self.assertEqual(len(self.verify()), 2)

    def test_feed_filename_must_match_marketing_version(self):
        self.responses["https://site/appcast.xml"] = feed("1.9.1").replace(b"Starcat-1.9.1", b"Starcat-1.8.0")
        with self.assertRaisesRegex(ValueError, "附件与版本"):
            self.verify()


if __name__ == "__main__":
    unittest.main()
