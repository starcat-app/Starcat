#!/usr/bin/env python3
"""安全同步 Starcat String Catalog 与公开 `.xcloc` 语言包。

运行时单一来源是 `Starcat/Resources/Localizable.xcstrings`，公开协作仓库按语言
保存一个 `.xcloc`。脚本刻意区分“在途翻译”和“已批准翻译”：

- export 会保留旧包里的在途 target；源文案变化时降级为待复核。
- import 默认只接受 `translated`、`final`、`signed-off`。
- import 仅在实际写入前备份原始 Catalog，并输出可恢复路径。
- import-all 先验证全部包，再一次性写回，任一包失败都不会留下半成品。
- audit/report 读取公开仓库 manifest，给本地和 CI 提供一致的质量视图。

常用命令：

    supports/scripts/starcat-localization.py export
    supports/scripts/starcat-localization.py export --locale ja
    supports/scripts/starcat-localization.py import --package <path>
    supports/scripts/starcat-localization.py import-all
    supports/scripts/starcat-localization.py audit
    supports/scripts/starcat-localization.py report --format json

仓库规则：

- 所有说明使用中文；命令、locale、key、路径保持技术字面量。
- 公开仓库只维护每语言一个 `.xcloc`，不把它当作 App 运行时来源。
- 未批准 target 不得伪装成 `translated`，也不得据此开放正式语言选择器。
- export 改变已批准 package 内容时，必须使 `translationApproval` 失效。
"""

from __future__ import annotations

import argparse
import collections
import copy
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, NamedTuple


PROJECT_NAME = "Starcat"
CATALOG_RELATIVE_PATH = Path("Starcat/Resources/Localizable.xcstrings")
CATALOG_BACKUP_RELATIVE_PATH = Path("supports/backups/localization")
PACKAGE_DIR_NAME = "Translation Packages"
MANIFEST_NAME = "locales.json"
NONTRANSLATABLE_NAME = "nontranslatable-keys.json"
XLIFF_NAMESPACE = "urn:oasis:names:tc:xliff:document:1.2"

APPROVED_STATES = frozenset({"translated", "final", "signed-off"})
KNOWN_STATES = frozenset(
    {
        "needs-translation",
        "new",
        "needs-review-translation",
        "translated",
        "final",
        "signed-off",
    }
)
PRINTF_TOKEN_RE = re.compile(r"%%|%(?:\d+\$)?(?:lld|ld|@|d|f)")
BRACE_TOKEN_RE = re.compile(r"\{[A-Za-z][A-Za-z0-9_]*\}")
PROPERTY_LINE_RE = re.compile(r'^(\s*)"((?:\\.|[^"\\])*)":', re.MULTILINE)
EMPTY_OBJECT_LINE_RE = re.compile(
    r'^(\s*)"((?:\\.|[^"\\])*)" : \{\}(,?)$',
    re.MULTILINE,
)


class LocalizationError(RuntimeError):
    """表示会破坏本地化交换契约的可预期错误。"""


class TranslationUnit(NamedTuple):
    """一个 XLIFF trans-unit 的最小交换数据。"""

    source: str
    target: str
    state: str


class ImportResult(NamedTuple):
    """一次事务性导入的结果摘要。"""

    changed: int
    skipped: int
    backup_path: Path | None


class LocaleReport(NamedTuple):
    """单个 locale 的质量统计。"""

    locale: str
    total: int
    translated: int
    review: int
    missing: int
    excluded: int
    completion: float
    release_status: str


def repo_root() -> Path:
    """根据脚本位置定位 Starcat 主仓库，避免依赖调用者当前目录。"""

    return Path(__file__).resolve().parents[2]


def default_catalog_path() -> Path:
    return repo_root() / CATALOG_RELATIVE_PATH


def default_catalog_backup_dir() -> Path:
    """备份放在主仓库已有的忽略目录，避免进入 App 资源或 Git diff。"""

    return repo_root() / CATALOG_BACKUP_RELATIVE_PATH


def default_localization_repo() -> Path:
    return repo_root() / "supports" / "starcat-localization"


def display_path(path: Path) -> str:
    """优先展示主仓库相对路径，临时测试目录则保留绝对路径。"""

    try:
        return str(path.relative_to(repo_root()))
    except ValueError:
        return str(path)


def load_json(path: Path) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise LocalizationError(f"缺少文件：{path}") from error
    except json.JSONDecodeError as error:
        raise LocalizationError(f"JSON 无效：{path}: {error}") from error
    if not isinstance(payload, dict):
        raise LocalizationError(f"JSON 顶层必须是 object：{path}")
    return payload


def load_catalog(path: Path) -> dict[str, Any]:
    catalog = load_json(path)
    if not isinstance(catalog.get("strings"), dict):
        raise LocalizationError(f"String Catalog 缺少 strings object：{path}")
    return catalog


def serialize_catalog(catalog: dict[str, Any]) -> str:
    """序列化为 Xcode String Catalog 使用的 `"key" : value` 风格。

    普通 `json.dump` 会输出 `"key": value`，造成整文件格式噪音。这里仅调整
    JSON object 属性行的冒号空格，不触碰字符串 value 内部内容。
    """

    text = json.dumps(catalog, ensure_ascii=False, indent=2)
    text = PROPERTY_LINE_RE.sub(r'\1"\2" :', text)
    # Xcode 会把空的 string entry 展开成两行空 object；保持这个细节可确保
    # import 没有把整份 1.7MB Catalog 制造成格式 diff。
    text = EMPTY_OBJECT_LINE_RE.sub(r'\1"\2" : {\n\n\1}\3', text)
    return text + "\n"


def save_catalog(path: Path, catalog: dict[str, Any]) -> None:
    """同目录临时文件 + `os.replace` 原子写回，避免中断留下半个 Catalog。"""

    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.",
        suffix=".tmp",
        dir=path.parent,
    )
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(serialize_catalog(catalog))
        os.replace(temporary_path, path)
    finally:
        temporary_path.unlink(missing_ok=True)


def backup_catalog(path: Path, backup_dir: Path) -> Path:
    """原子保存导入前的 Catalog 原始字节，并返回可人工恢复的备份路径。"""

    original = path.read_bytes()
    digest = hashlib.sha256(original).hexdigest()[:12]
    timestamp = (
        datetime.now(timezone.utc)
        .replace(microsecond=0)
        .strftime("%Y%m%dT%H%M%SZ")
    )
    backup_dir.mkdir(parents=True, exist_ok=True)
    backup_path = backup_dir / f"{path.name}.{timestamp}.{digest}.bak"
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{backup_path.name}.",
        suffix=".tmp",
        dir=backup_dir,
    )
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(original)
        os.replace(temporary_path, backup_path)
    finally:
        temporary_path.unlink(missing_ok=True)
    return backup_path


def save_json(path: Path, payload: dict[str, Any]) -> None:
    """原子写普通 JSON；manifest 不使用 String Catalog 的特殊冒号风格。"""

    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.",
        suffix=".tmp",
        dir=path.parent,
    )
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        os.replace(temporary_path, path)
    finally:
        temporary_path.unlink(missing_ok=True)


def load_manifest(localization_repo: Path) -> dict[str, Any]:
    manifest = load_json(localization_repo / MANIFEST_NAME)
    source_locale = manifest.get("sourceLocale")
    locales = manifest.get("locales")
    if not isinstance(source_locale, str) or not source_locale:
        raise LocalizationError(f"{MANIFEST_NAME} 缺少 sourceLocale")
    if not isinstance(locales, list) or not locales:
        raise LocalizationError(f"{MANIFEST_NAME} 缺少 locales")

    seen: set[str] = set()
    for item in locales:
        if not isinstance(item, dict):
            raise LocalizationError(f"{MANIFEST_NAME} locales 项必须是 object")
        locale = item.get("id")
        if not isinstance(locale, str) or not locale:
            raise LocalizationError(f"{MANIFEST_NAME} locale 缺少 id")
        if locale in seen:
            raise LocalizationError(f"{MANIFEST_NAME} 重复 locale：{locale}")
        seen.add(locale)
        if item.get("direction") not in {"ltr", "rtl"}:
            raise LocalizationError(f"{locale} direction 必须是 ltr 或 rtl")
        if item.get("releaseStatus") not in {"draft", "review", "released"}:
            raise LocalizationError(f"{locale} releaseStatus 无效")
        for field in ("englishName", "nativeName"):
            if not isinstance(item.get(field), str) or not item[field]:
                raise LocalizationError(f"{locale} 缺少 {field}")

    if source_locale not in seen:
        raise LocalizationError(f"sourceLocale {source_locale} 不在 locales 中")
    return manifest


def manifest_locale_items(manifest: dict[str, Any]) -> list[dict[str, Any]]:
    return list(manifest["locales"])


def manifest_locale_ids(manifest: dict[str, Any]) -> list[str]:
    return [item["id"] for item in manifest_locale_items(manifest)]


def load_nontranslatable_keys(localization_repo: Path) -> dict[str, str]:
    payload = load_json(localization_repo / NONTRANSLATABLE_NAME)
    keys = payload.get("keys")
    if not isinstance(keys, dict):
        raise LocalizationError(f"{NONTRANSLATABLE_NAME} 缺少 keys object")
    invalid = [
        key
        for key, reason in keys.items()
        if not isinstance(key, str) or not isinstance(reason, str) or not reason.strip()
    ]
    if invalid:
        raise LocalizationError(f"{NONTRANSLATABLE_NAME} 存在空 key/reason：{invalid[:3]}")
    return dict(keys)


def string_unit(localization: dict[str, Any] | None) -> dict[str, Any] | None:
    if not localization:
        return None
    unit = localization.get("stringUnit")
    return unit if isinstance(unit, dict) else None


def localized_value(entry: dict[str, Any], locale: str) -> str | None:
    localizations = entry.get("localizations", {})
    unit = string_unit(localizations.get(locale))
    if not unit:
        return None
    value = unit.get("value")
    return value if isinstance(value, str) else None


def localized_state(entry: dict[str, Any], locale: str) -> str:
    localizations = entry.get("localizations", {})
    unit = string_unit(localizations.get(locale))
    if unit and isinstance(unit.get("state"), str):
        return unit["state"]
    return "needs-translation"


def source_value(entry: dict[str, Any], source_locale: str, key: str) -> str:
    """Xcode 对无显式 source localization 的条目以 key 本身作为 source。"""

    return localized_value(entry, source_locale) or key


def write_contents_json(package_path: Path, source_language: str, locale: str) -> None:
    contents = {
        "developmentRegion": source_language,
        "project": f"{PROJECT_NAME}.xcodeproj",
        "targetLocale": locale,
        "toolInfo": {
            "toolID": "com.starcat.localization-script",
            "toolName": "starcat-localization.py",
            "toolVersion": "2.0",
        },
        "version": "1.0",
    }
    (package_path / "contents.json").write_text(
        json.dumps(contents, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def read_package_locale(package_path: Path, *, enforce_directory: bool = True) -> str:
    contents = load_json(package_path / "contents.json")
    locale = contents.get("targetLocale")
    if not isinstance(locale, str) or not locale:
        raise LocalizationError(f"contents.json 缺少 targetLocale：{package_path}")
    directory_locale = package_path.name.removesuffix(".xcloc")
    if enforce_directory and locale != directory_locale:
        raise LocalizationError(
            f"package 目录 locale {directory_locale} 与 targetLocale {locale} 不一致"
        )
    return locale


def xliff_file_attributes(package_path: Path, locale: str) -> tuple[str, str]:
    xliff_path = package_path / "Localized Contents" / f"{locale}.xliff"
    try:
        tree = ET.parse(xliff_path)
    except FileNotFoundError as error:
        raise LocalizationError(f"缺少 XLIFF：{xliff_path}") from error
    except ET.ParseError as error:
        raise LocalizationError(f"XLIFF 无效：{xliff_path}: {error}") from error
    namespace = {"x": XLIFF_NAMESPACE}
    file_node = tree.find(".//x:file", namespace)
    if file_node is None:
        raise LocalizationError(f"XLIFF 缺少 file node：{xliff_path}")
    return (
        file_node.attrib.get("source-language", ""),
        file_node.attrib.get("target-language", ""),
    )


def read_xliff_units(package_path: Path, locale: str) -> dict[str, TranslationUnit]:
    xliff_path = package_path / "Localized Contents" / f"{locale}.xliff"
    try:
        tree = ET.parse(xliff_path)
    except FileNotFoundError as error:
        raise LocalizationError(f"缺少 XLIFF：{xliff_path}") from error
    except ET.ParseError as error:
        raise LocalizationError(f"XLIFF 无效：{xliff_path}: {error}") from error

    namespace = {"x": XLIFF_NAMESPACE}
    units: dict[str, TranslationUnit] = {}
    for node in tree.findall(".//x:trans-unit", namespace):
        key = node.attrib.get("id")
        if not key:
            raise LocalizationError(f"XLIFF 存在无 id trans-unit：{xliff_path}")
        if key in units:
            raise LocalizationError(f"XLIFF 重复 key：{locale}:{key}")
        source_node = node.find("x:source", namespace)
        target_node = node.find("x:target", namespace)
        if source_node is None or target_node is None:
            raise LocalizationError(f"XLIFF unit 缺少 source/target：{locale}:{key}")
        state = target_node.attrib.get("state", "needs-translation")
        if state not in KNOWN_STATES:
            raise LocalizationError(f"XLIFF state 无效：{locale}:{key}:{state}")
        units[key] = TranslationUnit(
            source=source_node.text or "",
            target=target_node.text or "",
            state=state,
        )
    return units


def merged_unit(
    *,
    key: str,
    entry: dict[str, Any],
    source_locale: str,
    locale: str,
    existing: TranslationUnit | None,
) -> TranslationUnit:
    current_source = source_value(entry, source_locale, key)
    if locale == source_locale:
        return TranslationUnit(current_source, current_source, "translated")

    catalog_target = localized_value(entry, locale)
    if catalog_target:
        return TranslationUnit(
            current_source,
            catalog_target,
            localized_state(entry, locale),
        )

    if existing and existing.target:
        state = existing.state
        if existing.source != current_source:
            state = "needs-review-translation"
        return TranslationUnit(current_source, existing.target, state)

    return TranslationUnit(current_source, "", "needs-translation")


def build_xliff(
    catalog: dict[str, Any],
    locale: str,
    existing_units: dict[str, TranslationUnit] | None = None,
) -> ET.ElementTree:
    source_language = catalog.get("sourceLanguage", "en")
    root = ET.Element(f"{{{XLIFF_NAMESPACE}}}xliff", {"version": "1.2"})
    file_node = ET.SubElement(
        root,
        f"{{{XLIFF_NAMESPACE}}}file",
        {
            "original": str(CATALOG_RELATIVE_PATH),
            "source-language": source_language,
            "target-language": locale,
            "datatype": "plaintext",
        },
    )
    body = ET.SubElement(file_node, f"{{{XLIFF_NAMESPACE}}}body")
    existing_units = existing_units or {}

    # 已有包的 unit 顺序来自贡献者当前基线。保留这个顺序可以让删除旧 key 时只产生
    # 删除 diff；新 key 统一按 Catalog 排序追加，避免每次 export 重排整份 XLIFF。
    existing_order = [
        key
        for key in existing_units
        if key in catalog["strings"]
    ]
    new_keys = sorted(set(catalog["strings"]) - set(existing_units))
    for key in existing_order + new_keys:
        entry = catalog["strings"][key]
        unit_data = merged_unit(
            key=key,
            entry=entry,
            source_locale=source_language,
            locale=locale,
            existing=existing_units.get(key),
        )
        unit = ET.SubElement(body, f"{{{XLIFF_NAMESPACE}}}trans-unit", {"id": key})
        ET.SubElement(unit, f"{{{XLIFF_NAMESPACE}}}source").text = unit_data.source
        target = ET.SubElement(
            unit,
            f"{{{XLIFF_NAMESPACE}}}target",
            {"state": unit_data.state},
        )
        target.text = unit_data.target
        comment = entry.get("comment")
        if isinstance(comment, str) and comment:
            ET.SubElement(unit, f"{{{XLIFF_NAMESPACE}}}note").text = comment

    ET.indent(root, space="  ")
    return ET.ElementTree(root)


def existing_xliff_namespace_prefix(path: Path) -> str:
    """读取旧 XLIFF 的 namespace 表示法，避免纯前缀变化重写整份 XML。"""

    if not path.is_file():
        return ""
    opening = path.read_bytes()[:512]
    if b'<xliff xmlns="' in opening:
        return ""
    match = re.search(br"<([A-Za-z_][\w.-]*):xliff\s", opening)
    return match.group(1).decode("ascii") if match else ""


def write_xliff(tree: ET.ElementTree, path: Path, namespace_prefix: str) -> None:
    """按旧包的 default / prefixed namespace 风格写回 XLIFF。"""

    if not namespace_prefix:
        ET.register_namespace("", XLIFF_NAMESPACE)
        tree.write(path, encoding="utf-8", xml_declaration=True)
        return

    # ElementTree 禁止显式注册 `ns0` 这类保留前缀，因此先用安全前缀写出，再只替换
    # XML tag/namespace 声明。target 文本不会参与替换。
    temporary_prefix = "xlf"
    ET.register_namespace(temporary_prefix, XLIFF_NAMESPACE)
    tree.write(path, encoding="utf-8", xml_declaration=True)
    payload = path.read_bytes()
    payload = payload.replace(
        f"xmlns:{temporary_prefix}=".encode(),
        f"xmlns:{namespace_prefix}=".encode(),
    )
    payload = payload.replace(
        f"{temporary_prefix}:".encode(),
        f"{namespace_prefix}:".encode(),
    )
    path.write_bytes(payload)


def build_source_snapshot(catalog: dict[str, Any]) -> bytes:
    """生成公开 `.xcloc` 共用的轻量 source snapshot。

    运行时 Catalog 导入 18 种语言后会包含全部 target。如果把它原样复制到每个
    `.xcloc`，同一套译文会重复 18 份并制造百万行 diff。公开包只需要 Starcat 的
    双语 source 基线；各目标语言继续由对应 XLIFF 独立承载。
    """

    source_locale = catalog.get("sourceLanguage", "en")
    snapshot_locales = {source_locale, "zh-Hans"}
    snapshot = copy.deepcopy(catalog)
    for entry in snapshot["strings"].values():
        localizations = entry.get("localizations")
        if not isinstance(localizations, dict):
            continue
        entry["localizations"] = {
            locale: value
            for locale, value in localizations.items()
            if locale in snapshot_locales
        }
    return serialize_catalog(snapshot).encode("utf-8")


def replace_package_atomically(temporary: Path, target: Path) -> None:
    """目录替换时保留可回滚 backup，避免中断后丢失贡献者语言包。"""

    backup = target.with_name(f".{target.name}.backup")
    if backup.exists():
        shutil.rmtree(backup)
    try:
        if target.exists():
            target.rename(backup)
        temporary.rename(target)
    except Exception:
        if not target.exists() and backup.exists():
            backup.rename(target)
        raise
    else:
        if backup.exists():
            shutil.rmtree(backup)


def export_one_package(
    catalog: dict[str, Any],
    source_snapshot: bytes,
    package_root: Path,
    locale: str,
) -> bool:
    """导出一个包，并返回 source/target/state 是否发生语义变化。"""

    target = package_root / f"{locale}.xcloc"
    existing_units = read_xliff_units(target, locale) if target.exists() else {}
    existing_xliff_path = target / "Localized Contents" / f"{locale}.xliff"
    namespace_prefix = existing_xliff_namespace_prefix(existing_xliff_path)
    existing_snapshot_path = (
        target
        / "Source Contents"
        / PROJECT_NAME
        / "Localizable"
        / "Localizable.xcstrings"
    )
    existing_snapshot = (
        existing_snapshot_path.read_bytes()
        if existing_snapshot_path.is_file()
        else None
    )
    temporary = Path(tempfile.mkdtemp(prefix=f".{locale}.xcloc.", dir=package_root))
    try:
        localized_contents = temporary / "Localized Contents"
        source_contents = temporary / "Source Contents" / PROJECT_NAME / "Localizable"
        localized_contents.mkdir(parents=True)
        source_contents.mkdir(parents=True)
        (source_contents / "Localizable.xcstrings").write_bytes(source_snapshot)
        write_xliff(
            build_xliff(catalog, locale, existing_units),
            localized_contents / f"{locale}.xliff",
            namespace_prefix,
        )
        write_contents_json(temporary, catalog["sourceLanguage"], locale)

        # 替换真实包前先回读，确保刚生成的结构本身可解析且 locale 一致。
        generated_locale = read_package_locale(temporary, enforce_directory=False)
        source_locale, target_locale = xliff_file_attributes(temporary, generated_locale)
        generated_units = read_xliff_units(temporary, generated_locale)
        if source_locale != catalog["sourceLanguage"] or target_locale != locale:
            raise LocalizationError(f"生成包 locale 不一致：{locale}")
        if set(generated_units) != set(catalog["strings"]):
            raise LocalizationError(f"生成包 key 集合不一致：{locale}")
        content_changed = (
            existing_snapshot != source_snapshot
            or existing_units != generated_units
        )
        replace_package_atomically(temporary, target)
        return content_changed
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)


def export_packages(args: argparse.Namespace) -> int:
    catalog_path = Path(args.catalog).resolve()
    localization_repo = Path(args.repo).resolve()
    catalog = load_catalog(catalog_path)
    manifest = load_manifest(localization_repo)
    if catalog.get("sourceLanguage") != manifest["sourceLocale"]:
        raise LocalizationError(
            "Catalog sourceLanguage 与 locales.json sourceLocale 不一致："
            f"{catalog.get('sourceLanguage')} != {manifest['sourceLocale']}"
        )

    manifest_ids = manifest_locale_ids(manifest)
    locales = list(args.locale) if args.locale else manifest_ids
    unknown = [locale for locale in locales if locale not in manifest_ids]
    if unknown:
        raise LocalizationError(f"locale 不在 {MANIFEST_NAME}：{', '.join(unknown)}")

    package_root = localization_repo / PACKAGE_DIR_NAME
    package_root.mkdir(parents=True, exist_ok=True)
    source_snapshot = build_source_snapshot(catalog)
    items_by_locale = {
        item["id"]: item
        for item in manifest_locale_items(manifest)
    }
    for locale in locales:
        content_changed = export_one_package(
            catalog,
            source_snapshot,
            package_root,
            locale,
        )
        item = items_by_locale[locale]
        if content_changed and "translationApproval" in item:
            del item["translationApproval"]
            # 每个 package 导出后立即使其批准失效，避免后续 locale 失败时留下
            # “内容已改变但批准记录仍有效”的危险状态。
            save_json(localization_repo / MANIFEST_NAME, manifest)
            print(f"invalidated translationApproval: {locale}")
        print(f"exported {display_path(package_root / f'{locale}.xcloc')}")
    return 0


def token_signature(text: str) -> tuple[list[str], collections.Counter[str]]:
    printf_tokens = PRINTF_TOKEN_RE.findall(text)
    brace_tokens = BRACE_TOKEN_RE.findall(text)
    non_positional = [token for token in printf_tokens if "$" not in token]
    return non_positional, collections.Counter(printf_tokens + brace_tokens)


def placeholder_error(source: str, target: str) -> str | None:
    source_order, source_tokens = token_signature(source)
    target_order, target_tokens = token_signature(target)
    if source_tokens != target_tokens:
        return f"token 集合不一致：source={dict(source_tokens)} target={dict(target_tokens)}"
    if source_order != target_order:
        return f"非位置参数顺序不一致：source={source_order} target={target_order}"
    return None


def validate_package_for_import(
    package_path: Path,
    catalog: dict[str, Any],
) -> tuple[str, dict[str, TranslationUnit]]:
    locale = read_package_locale(package_path)
    source_locale, target_locale = xliff_file_attributes(package_path, locale)
    if source_locale != catalog.get("sourceLanguage"):
        raise LocalizationError(
            f"{locale} source-language {source_locale} 与 Catalog 不一致"
        )
    if target_locale != locale:
        raise LocalizationError(
            f"{locale} target-language {target_locale} 与 contents.json 不一致"
        )

    units = read_xliff_units(package_path, locale)
    catalog_keys = set(catalog["strings"])
    package_keys = set(units)
    unknown = sorted(package_keys - catalog_keys)
    missing = sorted(catalog_keys - package_keys)
    if unknown:
        raise LocalizationError(f"{locale} 存在未知 key：{unknown[:5]}")
    if missing:
        raise LocalizationError(f"{locale} 缺少 key：{missing[:5]}")

    for key, unit in units.items():
        if not unit.target:
            continue
        error = placeholder_error(unit.source, unit.target)
        if error:
            raise LocalizationError(f"{locale}:{key} 占位符错误：{error}")
    return locale, units


def import_package_paths(
    catalog_path: Path,
    package_paths: list[Path],
    *,
    allow_unreviewed: bool = False,
    backup_dir: Path | None = None,
) -> ImportResult:
    """预检全部包，备份原文件后一次性写回；失败时 Catalog 保持不变。"""

    catalog = load_catalog(catalog_path)
    validated = [
        validate_package_for_import(package_path.resolve(), catalog)
        for package_path in package_paths
    ]
    changed = 0
    skipped = 0
    for locale, units in validated:
        for key, incoming in units.items():
            if not incoming.target:
                skipped += 1
                continue
            if incoming.state not in APPROVED_STATES and not allow_unreviewed:
                skipped += 1
                continue
            entry = catalog["strings"][key]
            localizations = entry.setdefault("localizations", {})
            localization = localizations.setdefault(locale, {})
            unit = localization.setdefault("stringUnit", {})
            target_state = (
                incoming.state
                if incoming.state in APPROVED_STATES
                else "needs-review-translation"
            )
            if unit.get("value") == incoming.target and unit.get("state") == target_state:
                continue
            unit["state"] = target_state
            unit["value"] = incoming.target
            changed += 1

    backup_path = None
    if changed:
        backup_path = backup_catalog(
            catalog_path,
            (backup_dir or default_catalog_backup_dir()).resolve(),
        )
        save_catalog(catalog_path, catalog)
    return ImportResult(
        changed=changed,
        skipped=skipped,
        backup_path=backup_path,
    )


def import_packages(args: argparse.Namespace) -> int:
    catalog_path = Path(args.catalog).resolve()
    package_paths = [Path(path).resolve() for path in args.package]
    result = import_package_paths(
        catalog_path,
        package_paths,
        allow_unreviewed=args.allow_unreviewed,
        backup_dir=default_catalog_backup_dir(),
    )
    if result.backup_path is not None:
        print(f"backup: {display_path(result.backup_path)}")
    print(
        f"updated {result.changed} localization values; "
        f"skipped {result.skipped} unreviewed/empty values in {display_path(catalog_path)}"
    )
    return 0


def import_all_packages(args: argparse.Namespace) -> int:
    repo = Path(args.repo).resolve()
    manifest = load_manifest(repo)
    package_root = repo / PACKAGE_DIR_NAME
    packages = [package_root / f"{locale}.xcloc" for locale in manifest_locale_ids(manifest)]
    missing = [str(path) for path in packages if not path.is_dir()]
    if missing:
        raise LocalizationError(f"缺少 manifest 语言包：{missing[:3]}")
    args.package = [str(path) for path in packages]
    return import_packages(args)


def analyze_repository(
    catalog: dict[str, Any],
    localization_repo: Path,
) -> tuple[list[LocaleReport], list[str]]:
    manifest = load_manifest(localization_repo)
    exclusions = load_nontranslatable_keys(localization_repo)
    catalog_keys = set(catalog["strings"])
    errors: list[str] = []
    stale_exclusions = sorted(set(exclusions) - catalog_keys)
    if stale_exclusions:
        errors.append(f"stale nontranslatable keys：{stale_exclusions[:5]}")

    package_root = localization_repo / PACKAGE_DIR_NAME
    expected = manifest_locale_ids(manifest)
    actual = sorted(path.name.removesuffix(".xcloc") for path in package_root.glob("*.xcloc"))
    if set(actual) != set(expected):
        missing = sorted(set(expected) - set(actual))
        extra = sorted(set(actual) - set(expected))
        if missing:
            errors.append(f"缺少语言包：{missing}")
        if extra:
            errors.append(f"manifest 外语言包：{extra}")

    reports: list[LocaleReport] = []
    source_snapshot: str | None = None
    for item in manifest_locale_items(manifest):
        locale = item["id"]
        package = package_root / f"{locale}.xcloc"
        if not package.is_dir():
            reports.append(
                LocaleReport(locale, len(catalog_keys), 0, 0, len(catalog_keys), 0, 0.0, item["releaseStatus"])
            )
            continue
        try:
            package_locale = read_package_locale(package)
            source_locale, target_locale = xliff_file_attributes(package, package_locale)
            units = read_xliff_units(package, package_locale)
            embedded_path = (
                package
                / "Source Contents"
                / PROJECT_NAME
                / "Localizable"
                / "Localizable.xcstrings"
            )
            embedded_text = embedded_path.read_text(encoding="utf-8")
            load_catalog(embedded_path)
            if source_snapshot is None:
                source_snapshot = embedded_text
            elif embedded_text != source_snapshot:
                errors.append(f"{locale} source snapshot 与其他包不一致")
            if source_locale != manifest["sourceLocale"] or target_locale != locale:
                errors.append(f"{locale} XLIFF locale 不一致")
            if set(units) != catalog_keys:
                errors.append(f"{locale} key 集合与 Catalog 不一致")
        except (LocalizationError, OSError) as error:
            errors.append(str(error))
            continue

        translated = 0
        review = 0
        missing = 0
        excluded = 0
        for key in catalog["strings"]:
            if key in exclusions:
                excluded += 1
                continue
            unit = units[key]
            if not unit.target or unit.state in {"needs-translation", "new"}:
                missing += 1
            elif unit.state == "needs-review-translation":
                review += 1
            elif unit.state in APPROVED_STATES:
                translated += 1
            else:
                review += 1
            if unit.target:
                token_error = placeholder_error(unit.source, unit.target)
                if token_error:
                    errors.append(f"{locale}:{key} 占位符错误：{token_error}")

        denominator = max(1, len(catalog_keys) - excluded)
        completion = translated / denominator * 100
        report = LocaleReport(
            locale=locale,
            total=len(catalog_keys),
            translated=translated,
            review=review,
            missing=missing,
            excluded=excluded,
            completion=completion,
            release_status=item["releaseStatus"],
        )
        reports.append(report)
        if item["releaseStatus"] == "released" and (review or missing):
            errors.append(
                f"released locale {locale} 仍有 review={review}, missing={missing}"
            )
    return reports, errors


def report_payload(reports: list[LocaleReport]) -> list[dict[str, Any]]:
    return [
        {
            "locale": report.locale,
            "total": report.total,
            "translated": report.translated,
            "review": report.review,
            "missing": report.missing,
            "excluded": report.excluded,
            "completion": round(report.completion, 2),
            "releaseStatus": report.release_status,
        }
        for report in reports
    ]


def print_reports(reports: list[LocaleReport], output_format: str) -> None:
    if output_format == "json":
        print(json.dumps(report_payload(reports), ensure_ascii=False, indent=2))
        return
    print("Locale     Total  Translated  Review  Missing  Excluded  Completion  Release")
    for report in reports:
        print(
            f"{report.locale:<10} {report.total:>5}  {report.translated:>10}  "
            f"{report.review:>6}  {report.missing:>7}  {report.excluded:>8}  "
            f"{report.completion:>9.2f}%  {report.release_status}"
        )


def audit_repository(args: argparse.Namespace) -> int:
    catalog = load_catalog(Path(args.catalog).resolve())
    reports, errors = analyze_repository(catalog, Path(args.repo).resolve())
    print_reports(reports, "table")
    if errors:
        print("\n阻断项：", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 2
    print("\naudit passed")
    return 0


def report_repository(args: argparse.Namespace) -> int:
    catalog = load_catalog(Path(args.catalog).resolve())
    reports, errors = analyze_repository(catalog, Path(args.repo).resolve())
    print_reports(reports, args.format)
    if errors and args.format == "table":
        print(f"\n当前有 {len(errors)} 个 audit 阻断项；report 仅展示状态。")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="安全导出、导入和审计 Starcat `.xcloc` 语言包。",
    )
    parser.add_argument(
        "--catalog",
        default=str(default_catalog_path()),
        help="Starcat/Resources/Localizable.xcstrings 路径。",
    )
    parser.add_argument(
        "--repo",
        default=str(default_localization_repo()),
        help="supports/starcat-localization 路径。",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    export_parser = subparsers.add_parser("export", help="导出每语言一个 `.xcloc`。")
    export_parser.add_argument(
        "--locale",
        action="append",
        help="只更新指定 locale；可重复。默认按 locales.json 导出全部语言。",
    )
    export_parser.set_defaults(func=export_packages)

    import_parser = subparsers.add_parser("import", help="导入一个或多个已审核语言包。")
    import_parser.add_argument("--package", action="append", required=True, help="`.xcloc` 路径。")
    import_parser.add_argument(
        "--allow-unreviewed",
        action="store_true",
        help="危险：显式导入未审核 target，并保持 needs-review 状态。",
    )
    import_parser.set_defaults(func=import_packages)

    import_all_parser = subparsers.add_parser("import-all", help="按 manifest 导入全部语言包。")
    import_all_parser.add_argument(
        "--allow-unreviewed",
        action="store_true",
        help="危险：显式导入未审核 target，并保持 needs-review 状态。",
    )
    import_all_parser.set_defaults(func=import_all_packages)

    audit_parser = subparsers.add_parser("audit", help="执行只读结构与发布门禁审计。")
    audit_parser.set_defaults(func=audit_repository)

    report_parser = subparsers.add_parser("report", help="输出每种语言完成度。")
    report_parser.add_argument("--format", choices=("table", "json"), default="table")
    report_parser.set_defaults(func=report_repository)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        return args.func(args)
    except LocalizationError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
