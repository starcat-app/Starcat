#!/usr/bin/env python3
"""Post-process XcodeGen output for Starcat.

XcodeGen owns Starcat.xcodeproj, but version 2.45.4 serializes nested
SystemCapabilities dictionaries as strings when they are placed in target
attributes. Xcode does not treat that as a real capability declaration.

This script is intentionally narrow: after `xcodegen generate`, it adds the
In-App Purchase capability to the App Store target only. The Direct target must
not receive this capability because it uses external licensing and payments.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path


PROJECT_FILE = Path("Starcat.xcodeproj/project.pbxproj")


def find_native_target_id(project_text: str, target_name: str) -> str:
    """Return the PBXNativeTarget id for the exact target name."""
    pattern = re.compile(
        rf"\n\t\t([A-F0-9]{{24}}) /\* {re.escape(target_name)} \*/ = \{{\n"
        r"\t\t\tisa = PBXNativeTarget;",
    )
    match = pattern.search(project_text)
    if not match:
        raise RuntimeError(f"Cannot find PBXNativeTarget named {target_name}")
    return match.group(1)


def add_in_app_purchase_capability(project_text: str, target_id: str) -> str:
    """Add In-App Purchase to the target attributes block if missing."""
    block_pattern = re.compile(
        rf"(\n\t\t\t\t\t{target_id} = \{{\n)(.*?)(\n\t\t\t\t\t\}};)",
        re.DOTALL,
    )
    match = block_pattern.search(project_text)
    if not match:
        raise RuntimeError(f"Cannot find TargetAttributes block for {target_id}")

    prefix, body, suffix = match.groups()
    if "com.apple.InAppPurchase" in body:
        return project_text

    capability = (
        "\t\t\t\t\t\tSystemCapabilities = {\n"
        "\t\t\t\t\t\t\tcom.apple.InAppPurchase = {\n"
        "\t\t\t\t\t\t\t\tenabled = 1;\n"
        "\t\t\t\t\t\t\t};\n"
        "\t\t\t\t\t\t};\n"
    )

    provisioning_line = "\t\t\t\t\t\tProvisioningStyle = Automatic;\n"
    if provisioning_line in body:
        body = body.replace(provisioning_line, provisioning_line + capability, 1)
    else:
        body = capability + body

    return project_text[: match.start()] + prefix + body + suffix + project_text[match.end() :]


def assert_direct_target_is_clean(project_text: str, direct_target_id: str) -> None:
    """Fail fast if the Direct target accidentally receives StoreKit capability."""
    block_pattern = re.compile(
        rf"\n\t\t\t\t\t{direct_target_id} = \{{\n(.*?)\n\t\t\t\t\t\}};",
        re.DOTALL,
    )
    match = block_pattern.search(project_text)
    if match and "com.apple.InAppPurchase" in match.group(1):
        raise RuntimeError("StarcatDirect must not have In-App Purchase capability")


def main() -> int:
    if not PROJECT_FILE.exists():
        raise RuntimeError(f"Missing generated project file: {PROJECT_FILE}")

    project_text = PROJECT_FILE.read_text()
    store_target_id = find_native_target_id(project_text, "Starcat")
    direct_target_id = find_native_target_id(project_text, "StarcatDirect")

    updated = add_in_app_purchase_capability(project_text, store_target_id)
    assert_direct_target_is_clean(updated, direct_target_id)

    if updated != project_text:
        PROJECT_FILE.write_text(updated)
        print("[postprocess-xcodeproj] enabled In-App Purchase for Starcat target")
    else:
        print("[postprocess-xcodeproj] In-App Purchase already enabled for Starcat target")

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"[postprocess-xcodeproj] {error}", file=sys.stderr)
        raise SystemExit(1)
