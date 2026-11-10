#!/usr/bin/env python3
"""校验 Direct 正式版/Beta 的最终产物，供只上传的恢复入口共用。

恢复不依赖当前 HEAD、分支或工作区状态；可信边界是已推送的原 tag、
最终 DMG 摘要、公证票据，以及指向同一附件的 Sparkle 清单。
本工具只读，不创建 tag、不重新签名、不 staple，也不修改任何产物。
"""

from __future__ import annotations

import argparse
import hashlib
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def checked_command(*args: str) -> str:
    """外部校验只执行一次；保留失败输出，交由调用者修复后续跑。"""
    result = subprocess.run(args, capture_output=True, text=True, timeout=60)
    if result.returncode:
        raise RuntimeError(
            f"{' '.join(args)} 失败 ({result.returncode})\n"
            f"{result.stdout}{result.stderr}"
        )
    return result.stdout.strip()


def verify(version: str, dmg: Path, checksum: Path, appcast: Path, remote: str) -> str:
    """在任何上传之前校验全部输入，并返回原 tag 的源码 commit。"""
    if not re.fullmatch(r"\d+\.\d+\.\d+(?:-beta\.[1-9]\d*)?", version):
        raise ValueError("版本必须是 X.Y.Z 或 X.Y.Z-beta.N")
    marketing_version = version.split("-beta.", 1)[0]
    if dmg.name != f"Starcat-{marketing_version}-arm64.dmg" or checksum.name != dmg.name + ".sha256":
        raise ValueError("DMG/SHA256 文件名必须与营销版本一致")
    digest = hashlib.sha256()
    with dmg.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    if not re.fullmatch(
        rf"{digest.hexdigest()}\s+\*?{re.escape(dmg.name)}",
        checksum.read_text().strip(),
    ):
        raise ValueError("最终 DMG 与 SHA256 不一致，禁止恢复上传")

    items = ET.parse(appcast).findall("./channel/item")
    if len(items) != 1:
        raise ValueError("当前版本 appcast 必须恰好包含一个 item")
    item = items[0]
    enclosure = item.find("enclosure")
    expected_url = (
        f"https://github.com/starcat-app/Starcat/releases/download/v{version}/{dmg.name}"
    )
    if enclosure is None or enclosure.get("url") != expected_url:
        raise ValueError("当前版本 appcast 下载地址与发布 tag 不一致")
    if item.findtext(f"{SPARKLE}shortVersionString") != marketing_version:
        raise ValueError("当前版本 appcast 营销版本不一致")
    if not (item.findtext(f"{SPARKLE}version") or "").isdigit():
        raise ValueError("当前版本 appcast 缺少数值构建号")
    if enclosure.get("length") != str(dmg.stat().st_size):
        raise ValueError("当前版本 appcast 大小与最终 DMG 不一致")
    if not enclosure.get(f"{SPARKLE}edSignature"):
        raise ValueError("当前版本 appcast 缺少 Sparkle 签名")
    if not (item.findtext("description") or "").strip():
        raise ValueError("当前版本 appcast 缺少更新说明")

    # 比较 tag 对象而非 HEAD：脚本修复提交可以晚于打包提交，但不能替换原 tag。
    ref = f"refs/tags/v{version}"
    local_tag = checked_command("git", "rev-parse", "--verify", ref)
    commit = checked_command("git", "rev-parse", "--verify", f"{ref}^{{commit}}")
    remote_refs = checked_command("git", "ls-remote", "--exit-code", remote, ref)
    if remote_refs.split() != [local_tag, ref]:
        raise ValueError("本地与远端 tag 不一致或远端 tag 不存在，禁止恢复上传")
    print(f"[release-artifacts] tag=v{version} commit={commit}", flush=True)
    print(f"[release-artifacts] sha256={digest.hexdigest()}", flush=True)

    print("[release-artifacts] 校验已有公证票据和 Gatekeeper 接受状态", flush=True)
    checked_command("xcrun", "stapler", "validate", str(dmg))
    checked_command(
        "spctl", "--assess", "--type", "open",
        "--context", "context:primary-signature", "--verbose", str(dmg),
    )
    print("[release-artifacts] 最终产物校验通过，可以恢复上传", flush=True)
    return commit


def main() -> None:
    """为两个发布脚本提供无写操作的共同恢复门禁。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--dmg", required=True, type=Path)
    parser.add_argument("--sha256", required=True, type=Path)
    parser.add_argument("--appcast", required=True, type=Path)
    parser.add_argument("--remote", default="origin")
    args = parser.parse_args()
    try:
        verify(args.version, args.dmg, args.sha256, args.appcast, args.remote)
    except (OSError, ValueError, RuntimeError, ET.ParseError, subprocess.TimeoutExpired) as error:
        print(f"[release-artifacts] ERROR: {error}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
