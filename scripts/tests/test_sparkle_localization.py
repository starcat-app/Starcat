#!/usr/bin/env python3
"""隔离验证双语 appcast 与真实 Sparkle 的语言桥接；不打开窗口、不联网或发布。"""

import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from appcast_xml_util import SPARKLE_NS, STARCAT_NS

SPEC = importlib.util.spec_from_file_location("sparkle_notes", ROOT / "scripts/inject-appcast-release-notes.py")
sparkle = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(sparkle)

ENGLISH = "## 1.9.5\n\n### New\n\n- Repository Skills: Install complete directories.\n"
CHINESE = "## 1.9.5\n\n### 新增\n\n- 仓库技能：安装完整目录。\n"
APPCAST = f"""<rss xmlns:sparkle="{SPARKLE_NS}"><channel><item>
<sparkle:shortVersionString>1.9.5</sparkle:shortVersionString>
<sparkle:version>202611120900</sparkle:version>
<enclosure url="https://example.invalid/Starcat-1.9.5.dmg" length="42"
sparkle:edSignature="unchanged-signature" />
</item><item><sparkle:shortVersionString>1.8.0</sparkle:shortVersionString>
<description><![CDATA[Original historical notes]]></description>
</item></channel></rss>"""


class BilingualAppcastTests(unittest.TestCase):
    """断言发布输出、快照来源和缺失译文门禁，不匹配脚本实现。"""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.appcast = self.root / "appcast.xml"
        self.appcast.write_text(APPCAST)

    def inject(self, **overrides):
        """仅修改临时 XML，和真实发布使用同一注入入口。"""
        options = dict(changelog_en=ENGLISH, changelog_zh=CHINESE, version="1.9.5",
                       more_url_en="https://starcat.ink/changelog.html",
                       more_url_zh="https://starcat.ink/changelog-zh.html", dry_run=False)
        options.update(overrides)
        return sparkle.inject(self.appcast, **options)

    def test_both_descriptions_and_application_language_fields_have_identical_bodies(self):
        self.inject()
        item = ET.parse(self.appcast).find("./channel/item")
        descriptions = item.findall("description")
        self.assertEqual([node.get("{http://www.w3.org/XML/1998/namespace}lang")
                          for node in descriptions], ["en", "zh-Hans"])
        for node in descriptions:
            language = node.get("{http://www.w3.org/XML/1998/namespace}lang")
            self.assertEqual(node.text, item.find(f"{{{STARCAT_NS}}}releaseNotes-{language}").text)
        self.assertIn("Repository Skills", descriptions[0].text)
        self.assertIn("仓库技能", descriptions[1].text)
        self.assertIn("changelog-zh.html", descriptions[1].text)
        self.assertEqual(self.appcast.read_text().count("<description xml:lang="), 2)
        self.assertIn("<![CDATA[", self.appcast.read_text())
        self.assertIn("starcat:releaseNotes-zh-Hans", self.appcast.read_text())

    def test_missing_either_translation_does_not_write_partial_output(self):
        original = self.appcast.read_bytes()
        for language in ["changelog_en", "changelog_zh"]:
            with self.subTest(language=language), self.assertRaisesRegex(ValueError, "中英文"):
                self.inject(**{language: "## 2.0.0\n\nFuture version.\n"})
            self.assertEqual(self.appcast.read_bytes(), original)

    def test_history_signature_and_repeated_injection_are_preserved(self):
        self.inject(version=None)
        first = self.appcast.read_bytes()
        self.inject(version=None)
        self.assertEqual(self.appcast.read_bytes(), first)
        items = ET.parse(self.appcast).findall("./channel/item")
        self.assertEqual(items[1].findtext("description"), "Original historical notes")
        self.assertEqual(items[0].find("enclosure").get(f"{{{SPARKLE_NS}}}edSignature"),
                         "unchanged-signature")
        self.assertEqual(items[0].find("enclosure").get("length"), "42")

    def test_missing_target_and_dry_run_do_not_change_the_feed(self):
        original = self.appcast.read_bytes()
        self.inject(dry_run=True)
        self.assertEqual(self.appcast.read_bytes(), original)
        with self.assertRaises(SystemExit):
            self.inject(version="9.9.9")
        self.assertEqual(self.appcast.read_bytes(), original)

    def test_cli_reads_chinese_from_the_same_snapshot(self):
        (self.root / "CHANGELOG.md").write_text(ENGLISH)
        (self.root / "CHANGELOG-ZH.md").write_text(CHINESE)
        result = subprocess.run(
            [sys.executable, str(ROOT / "scripts/inject-appcast-release-notes.py"),
             "--appcast", str(self.appcast), "--changelog-en", str(self.root / "CHANGELOG.md"),
             "--version", "1.9.5"], capture_output=True, text=True
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("仓库技能", ET.parse(self.appcast).find("./channel/item").findall("description")[1].text)

    def test_cli_missing_snapshot_translation_stops_before_writing(self):
        (self.root / "CHANGELOG.md").write_text(ENGLISH)
        original = self.appcast.read_bytes()
        result = subprocess.run(
            [sys.executable, str(ROOT / "scripts/inject-appcast-release-notes.py"),
             "--appcast", str(self.appcast), "--changelog-en", str(self.root / "CHANGELOG.md"),
             "--version", "1.9.5"], capture_output=True, text=True
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("中文 CHANGELOG", result.stderr)
        self.assertEqual(self.appcast.read_bytes(), original)


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("xcrun"), "需要 macOS Swift 工具链")
class SparkleRuntimeTests(unittest.TestCase):
    """直接链接锁定的 Sparkle，验证原生字符串、说明 getter 与安全编码保持一致。"""

    def test_real_framework_language_switching_and_original_fallback(self):
        framework_root = (ROOT / "build/DerivedData-NoSandbox/SourcePackages/artifacts/sparkle/"
                          "Sparkle/Sparkle.xcframework/macos-arm64_x86_64")
        if not (framework_root / "Sparkle.framework").is_dir():
            self.skipTest("请先通过标准 Direct 构建解析 Sparkle 依赖")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "main.swift"
            source.write_text(SWIFT_PROBE)
            executable = root / "localization-probe"
            env = dict(os.environ, DEVELOPER_DIR=os.environ.get(
                "STARCAT_STABLE_XCODE_DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer"))
            result = subprocess.run(
                ["xcrun", "--sdk", "macosx", "swiftc", "-swift-version", "5",
                 "-module-cache-path", str(root / "module-cache"), "-F", str(framework_root),
                 "-framework", "Sparkle", "-Xlinker", "-rpath", "-Xlinker", str(framework_root),
                 str(ROOT / "Starcat/Core/Updates/DirectUpdateLocalization.swift"),
                 str(source), "-o", str(executable)], env=env, capture_output=True, text=True
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(executable)], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("Sparkle localization passed", result.stdout)


# 单独进程使用易失偏好，不改用户配置；只读取资源和模型，不创建 App / Window。
SWIFT_PROBE = r'''
import Foundation
import ObjectiveC.runtime
import Sparkle

let defaults = UserDefaults.standard
func select(_ language: String) {
    defaults.setVolatileDomain(["AppLocaleOverride": language], forName: UserDefaults.argumentDomain)
}
let framework = Bundle(for: SPUUpdater.self)
precondition(Bundle(identifier: "org.sparkle-project.Sparkle") === framework)
let mainClass = object_getClass(Bundle.main)
let originalMainText = Bundle.main.localizedString(forKey: "Install Update", value: nil, table: nil)
let dictionary: [String: Any] = [
    "sparkle:version": "202611120900",
    "sparkle:shortVersionString": "1.9.5",
    "enclosure": [
        "url": "https://example.invalid/Starcat.dmg", "length": "42",
        "sparkle:edSignature": Data(repeating: 0, count: 64).base64EncodedString()
    ],
    "description": ["content": "Original notes"],
    "starcat:releaseNotes-en": "<p>Repository Skills</p>",
    "starcat:releaseNotes-zh-Hans": "<p>仓库技能</p>"
]
let item = SUAppcastItem(dictionary: dictionary)!
let originalClass = object_getClass(item)
let originalProperties = item.propertiesDictionary
DirectUpdateLocalization.install()
DirectUpdateLocalization.install()

select("en")
precondition(framework.localizedString(forKey: "Install Update", value: nil, table: "Sparkle") == "Install Update")
precondition(item.itemDescription == "<p>Repository Skills</p>")
select("zh-Hans")
for key in [
    "Software Update", "A new version of %@ is available!",
    "%@ %@ is now available—you have %@. Would you like to download it now?",
    "Automatically download and install updates in the future",
    "Skip This Version", "Remind Me Later", "Install Update"
] {
    let chinese = framework.localizedString(forKey: key, value: nil, table: "Sparkle")
    precondition(chinese != key && chinese.range(of: "\\p{Han}", options: .regularExpression) != nil,
                 "Sparkle string was not localized: \(key)")
}
precondition(item.itemDescription == "<p>仓库技能</p>")
select("en")
precondition(item.itemDescription == "<p>Repository Skills</p>")
precondition(framework.localizedString(forKey: "Install Update", value: nil, table: "Sparkle") == "Install Update")
select("zh-Hant")
precondition(item.itemDescription == "<p>仓库技能</p>")
select("system")
let expected = DirectUpdateLocalization.releaseNotes(in: dictionary)!
precondition(item.itemDescription == expected)
precondition(object_getClass(item) === originalClass)
precondition(object_getClass(Bundle.main) === mainClass)
precondition(Bundle.main.localizedString(forKey: "Install Update", value: nil, table: nil) == originalMainText)
precondition(NSDictionary(dictionary: item.propertiesDictionary) == NSDictionary(dictionary: originalProperties))
precondition(item.versionString == "202611120900" && item.contentLength == 42)
let encoded = try NSKeyedArchiver.archivedData(withRootObject: item, requiringSecureCoding: true)
let decoded = try NSKeyedUnarchiver.unarchivedObject(ofClass: SUAppcastItem.self, from: encoded)!
precondition(decoded.itemDescription == expected && decoded.fileURL == item.fileURL)
precondition(NSDictionary(dictionary: decoded.propertiesDictionary) == NSDictionary(dictionary: originalProperties))
var legacyDictionary = dictionary
legacyDictionary.removeValue(forKey: "starcat:releaseNotes-en")
legacyDictionary.removeValue(forKey: "starcat:releaseNotes-zh-Hans")
let legacy = SUAppcastItem(dictionary: legacyDictionary)!
precondition(legacy.itemDescription == "Original notes")
print("Sparkle localization passed")
'''


if __name__ == "__main__":
    unittest.main()
