"""Starcat `.xcstrings` / `.xcloc` 同步脚本回归测试。

这些测试只使用临时目录，避免首次验证时误写真实 String Catalog 或公开语言包。
重点锁定多语言扩展后最危险的边界：部分导出不能误删其他包、在途翻译不能丢失、
未审核翻译不能进入运行时 Catalog，以及批量导入失败时必须保持零写入。
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path


SCRIPT_PATH = Path(__file__).resolve().parents[1] / "starcat-localization.py"
SPEC = importlib.util.spec_from_file_location("starcat_localization", SCRIPT_PATH)
assert SPEC and SPEC.loader
localization = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(localization)


class StarcatLocalizationTests(unittest.TestCase):
    """验证公开语言包与运行时 String Catalog 的交换契约。"""

    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.catalog_path = self.root / "Localizable.xcstrings"
        self.repo_path = self.root / "starcat-localization"
        self.repo_path.mkdir()
        self.write_manifest(["en", "zh-Hans", "ja", "pt-BR", "zh-Hant"])
        self.write_catalog(
            {
                "greeting": {
                    "en": ("translated", "Hello %@"),
                    "zh-Hans": ("translated", "你好 %@"),
                },
                "plain": {
                    "en": ("translated", "Plain text"),
                    "zh-Hans": ("translated", "普通文本"),
                },
            }
        )

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def write_manifest(self, locales: list[str]) -> None:
        payload = {
            "schemaVersion": 1,
            "sourceLocale": "en",
            "locales": [
                {
                    "id": locale,
                    "englishName": locale,
                    "nativeName": locale,
                    "direction": "ltr",
                    "releaseStatus": "released" if locale in {"en", "zh-Hans"} else "draft",
                }
                for locale in locales
            ],
        }
        (self.repo_path / "locales.json").write_text(
            json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        (self.repo_path / "nontranslatable-keys.json").write_text(
            '{"schemaVersion":1,"keys":{}}\n',
            encoding="utf-8",
        )

    def write_catalog(self, values: dict[str, dict[str, tuple[str, str]]]) -> None:
        strings: dict[str, object] = {}
        for key, locale_values in values.items():
            strings[key] = {
                "localizations": {
                    locale: {
                        "stringUnit": {
                            "state": state,
                            "value": value,
                        }
                    }
                    for locale, (state, value) in locale_values.items()
                }
            }
        payload = {
            "sourceLanguage": "en",
            "strings": strings,
            "version": "1.0",
        }
        self.catalog_path.write_text(
            localization.serialize_catalog(payload),
            encoding="utf-8",
        )

    def export(self, *locales: str) -> int:
        return localization.export_packages(
            argparse.Namespace(
                catalog=str(self.catalog_path),
                repo=str(self.repo_path),
                locale=list(locales) or None,
            )
        )

    def package_path(self, locale: str) -> Path:
        return self.repo_path / "Translation Packages" / f"{locale}.xcloc"

    def xliff_path(self, locale: str) -> Path:
        return self.package_path(locale) / "Localized Contents" / f"{locale}.xliff"

    def set_xliff_unit(
        self,
        locale: str,
        key: str,
        *,
        source: str | None = None,
        target: str,
        state: str,
    ) -> None:
        tree = ET.parse(self.xliff_path(locale))
        namespace = {"x": localization.XLIFF_NAMESPACE}
        for unit in tree.findall(".//x:trans-unit", namespace):
            if unit.attrib.get("id") != key:
                continue
            if source is not None:
                source_node = unit.find("x:source", namespace)
                assert source_node is not None
                source_node.text = source
            target_node = unit.find("x:target", namespace)
            assert target_node is not None
            target_node.text = target
            target_node.attrib["state"] = state
            tree.write(self.xliff_path(locale), encoding="utf-8", xml_declaration=True)
            return
        self.fail(f"missing XLIFF unit: {key}")

    def test_partial_export_does_not_delete_other_packages(self) -> None:
        self.export("ja", "pt-BR")
        marker = self.package_path("pt-BR") / "keep.txt"
        marker.write_text("keep", encoding="utf-8")

        self.export("ja")

        self.assertEqual(marker.read_text(encoding="utf-8"), "keep")
        self.assertTrue(self.package_path("ja").is_dir())

    def test_export_preserves_inflight_target_and_downgrades_changed_source(self) -> None:
        self.export("ja")
        self.set_xliff_unit(
            "ja",
            "greeting",
            target="こんにちは %@",
            state="translated",
        )
        self.write_catalog(
            {
                "greeting": {
                    "en": ("translated", "Welcome %@"),
                    "zh-Hans": ("translated", "欢迎 %@"),
                },
                "plain": {
                    "en": ("translated", "Plain text"),
                    "zh-Hans": ("translated", "普通文本"),
                },
            }
        )

        self.export("ja")

        units = localization.read_xliff_units(self.package_path("ja"), "ja")
        self.assertEqual(units["greeting"].target, "こんにちは %@")
        self.assertEqual(units["greeting"].state, "needs-review-translation")
        self.assertEqual(units["greeting"].source, "Welcome %@")

    def test_import_skips_unreviewed_target(self) -> None:
        self.export("ja")
        self.set_xliff_unit(
            "ja",
            "greeting",
            target="こんにちは %@",
            state="needs-review-translation",
        )

        result = localization.import_package_paths(
            self.catalog_path,
            [self.package_path("ja")],
        )

        self.assertEqual(result.changed, 0)
        catalog = localization.load_catalog(self.catalog_path)
        self.assertNotIn("ja", catalog["strings"]["greeting"].get("localizations", {}))

    def test_import_rejects_unknown_key_without_writing(self) -> None:
        self.export("ja")
        tree = ET.parse(self.xliff_path("ja"))
        namespace = {"x": localization.XLIFF_NAMESPACE}
        body = tree.find(".//x:body", namespace)
        assert body is not None
        unit = ET.SubElement(body, f"{{{localization.XLIFF_NAMESPACE}}}trans-unit", {"id": "unknown.key"})
        ET.SubElement(unit, f"{{{localization.XLIFF_NAMESPACE}}}source").text = "Unknown"
        target = ET.SubElement(unit, f"{{{localization.XLIFF_NAMESPACE}}}target", {"state": "translated"})
        target.text = "不明"
        tree.write(self.xliff_path("ja"), encoding="utf-8", xml_declaration=True)
        original = self.catalog_path.read_text(encoding="utf-8")

        with self.assertRaises(localization.LocalizationError):
            localization.import_package_paths(
                self.catalog_path,
                [self.package_path("ja")],
            )

        self.assertEqual(self.catalog_path.read_text(encoding="utf-8"), original)

    def test_import_rejects_placeholder_mismatch(self) -> None:
        self.export("ja")
        self.set_xliff_unit(
            "ja",
            "greeting",
            target="こんにちは",
            state="translated",
        )

        with self.assertRaises(localization.LocalizationError):
            localization.import_package_paths(
                self.catalog_path,
                [self.package_path("ja")],
            )

    def test_import_all_is_transactional(self) -> None:
        self.export("ja", "pt-BR")
        self.set_xliff_unit(
            "ja",
            "greeting",
            target="こんにちは %@",
            state="translated",
        )
        self.set_xliff_unit(
            "pt-BR",
            "greeting",
            target="Olá",
            state="translated",
        )
        original = self.catalog_path.read_text(encoding="utf-8")

        with self.assertRaises(localization.LocalizationError):
            localization.import_package_paths(
                self.catalog_path,
                [self.package_path("ja"), self.package_path("pt-BR")],
            )

        self.assertEqual(self.catalog_path.read_text(encoding="utf-8"), original)

    def test_catalog_writer_preserves_xcode_colon_style(self) -> None:
        catalog = localization.load_catalog(self.catalog_path)
        localization.save_catalog(self.catalog_path, catalog)
        text = self.catalog_path.read_text(encoding="utf-8")

        self.assertIn('"sourceLanguage" : "en"', text)
        self.assertIn('"greeting" : {', text)
        self.assertNotIn('"sourceLanguage": "en"', text)

    def test_script_and_region_locales_round_trip(self) -> None:
        self.export("pt-BR", "zh-Hant")

        for locale in ("pt-BR", "zh-Hant"):
            package = self.package_path(locale)
            contents = json.loads((package / "contents.json").read_text(encoding="utf-8"))
            units = localization.read_xliff_units(package, locale)
            self.assertEqual(contents["targetLocale"], locale)
            self.assertEqual(len(units), 2)


if __name__ == "__main__":
    unittest.main()
