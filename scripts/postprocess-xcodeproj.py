#!/usr/bin/env python3
"""Post-process XcodeGen output for Starcat.

XcodeGen owns Starcat.xcodeproj, but version 2.45.4 serializes nested
SystemCapabilities dictionaries as strings when they are placed in target
attributes. Xcode does not treat that as a real capability declaration.

This script is intentionally narrow: after `xcodegen generate`, it adds
In-App Purchase to the App Store target and Associated Domains to both shipping
targets. The Direct target must not receive In-App Purchase because it uses
external licensing and payments.
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


def add_system_capability(project_text: str, target_id: str, capability_name: str) -> str:
    """Add one capability to the target attributes block if missing."""
    block_pattern = re.compile(
        rf"(\n\t\t\t\t\t{target_id} = \{{\n)(.*?)(\n\t\t\t\t\t\}};)",
        re.DOTALL,
    )
    match = block_pattern.search(project_text)
    if not match:
        raise RuntimeError(f"Cannot find TargetAttributes block for {target_id}")

    prefix, body, suffix = match.groups()
    if capability_name in body:
        return project_text

    capability_entry = (
        f"\t\t\t\t\t\t\t{capability_name} = {{\n"
        "\t\t\t\t\t\t\t\tenabled = 1;\n"
        "\t\t\t\t\t\t\t};\n"
    )

    system_capabilities_line = "\t\t\t\t\t\tSystemCapabilities = {\n"
    if system_capabilities_line in body:
        body = body.replace(
            system_capabilities_line,
            system_capabilities_line + capability_entry,
            1,
        )
    else:
        capability_block = (
            system_capabilities_line
            + capability_entry
            + "\t\t\t\t\t\t};\n"
        )

        provisioning_line = "\t\t\t\t\t\tProvisioningStyle = Automatic;\n"
        if provisioning_line in body:
            body = body.replace(provisioning_line, provisioning_line + capability_block, 1)
        else:
            body = capability_block + body

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

    updated = add_system_capability(project_text, store_target_id, "com.apple.InAppPurchase")
    # Xcode 的 PBXProject 内部仍用 SafariKeychain 标识 Associated Domains；
    # 真正签名能力由 entitlements 的 com.apple.developer.associated-domains 表达。
    updated = add_system_capability(updated, store_target_id, "com.apple.SafariKeychain")
    updated = add_system_capability(updated, direct_target_id, "com.apple.SafariKeychain")
    assert_direct_target_is_clean(updated, direct_target_id)

    if updated != project_text:
        PROJECT_FILE.write_text(updated)
        print("[postprocess-xcodeproj] synchronized Starcat target capabilities")
    else:
        print("[postprocess-xcodeproj] target capabilities already synchronized")

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"[postprocess-xcodeproj] {error}", file=sys.stderr)
        raise SystemExit(1)
