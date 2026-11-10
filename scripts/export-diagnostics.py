#!/usr/bin/env python3
"""应用无法启动时，从明确选择的 diagnostics 目录导出安全基础证据，不打开业务库。"""

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import tempfile
import uuid
import zipfile


MAX_EVENTS = 100_000
EVENT_KEYS = set(("schemaVersion eventID sequence sessionID environmentID operationID "
                  "parentOperationID requestID serverTraceID timestamp level visibility "
                  "category operation phase outcome durationMs impact occurrenceCount firstSeen lastSeen "
                  "statusCode errorCode").split())


def safe_scalar(value):
    """应急导出不复制自由文本，只接受有界协议标识和数字。"""
    if isinstance(value, str):
        if re.fullmatch(r"[A-Za-z0-9_.:+<>-]{0,160}", value) and not re.search(
                r"(?i)(gh[pousr]_|github_pat_|sk-proj-|sk-[A-Za-z0-9]{8})", value):
            return value
        return "<redacted>"
    if isinstance(value, float) and not math.isfinite(value):
        return None
    return value if isinstance(value, (int, float, bool, type(None))) else None


def export(source, destination):
    """只读已知 JSONL，单文件最多 2MB、最多 21 个，损坏行明确计数。"""
    if source.is_symlink() or not source.is_dir() or source.name != "diagnostics":
        raise ValueError("请选择 Starcat 的 diagnostics 目录")
    events, missing, files_read, damaged = [], [], 0, 0
    for path in sorted(source.glob("diagnostic-log*.jsonl"))[:21]:
        if path.is_symlink() or path.stat().st_size > 2 * 1024 * 1024:
            missing.append("日志超限或是符号链接")
            continue
        files_read += 1
        for line in path.read_bytes().splitlines():
            try:
                event = json.loads(line)
                if not isinstance(event, dict):
                    raise ValueError()
                safe = {k: safe_scalar(v) for k, v in event.items() if k in EVENT_KEYS}
                if not all(isinstance(safe.get(k), str) for k in ("timestamp", "category", "operation")):
                    raise ValueError()
                # 安全字段由应用控制，但历史输入仍只接受数字和布尔，避免夹带正文。
                safe["fields"] = {k: v for k, v in event.get("fields", {}).items()
                                  if re.fullmatch(r"[A-Za-z]{1,80}", k)
                                  and isinstance(v, (int, float, bool))
                                  and (not isinstance(v, float) or math.isfinite(v))}
                events.append(safe)
                if len(events) >= MAX_EVENTS:
                    missing.append("事件数量达到读取上限，后续记录未采集")
                    break
            except (ValueError, TypeError, AttributeError, UnicodeDecodeError):
                damaged += 1
        if len(events) >= MAX_EVENTS:
            break
    identifier = str(uuid.uuid4())
    payloads = {
        "events.jsonl": ("\n".join(json.dumps(e, sort_keys=True) for e in events) + "\n").encode(),
        "report.md": (
            "# Starcat 应急诊断\n\n"
            f"报告编号：{identifier}\n\n"
            f"读取文件：{files_read}；可解析事件：{len(events)}；损坏行：{damaged}\n\n"
            "应用未参与此次采集。未读取业务数据库、账号凭据、AI 正文或原始附件。\n"
            "环境、实时模块状态、系统附件与会话结束原因未采集；空结果不能证明没有故障。\n"
            "应急导出过滤了历史自由文本与字符串上下文，分析时须保留此证据限制。\n"
        ).encode(),
    }
    manifest = dict(schemaVersion=2, exportID=identifier, mode="emergency",
                    damagedLines=damaged, limitations=missing,
                    collectors=[dict(name="events", status="truncated" if missing else "collected" if files_read else "notCollected"),
                                dict(name="runtime", status="notCollected"),
                                dict(name="system", status="notCollected")],
                    files=[dict(path=k, bytes=len(v), sha256=hashlib.sha256(v).hexdigest())
                           for k, v in payloads.items()])
    payloads["manifest.json"] = json.dumps(manifest, ensure_ascii=False, indent=2).encode()
    # 临时产物与目标位于同一卷，只有完整 ZIP 生成并检验后才替换用户已有文件。
    with tempfile.TemporaryDirectory(prefix=".starcat-emergency-", dir=destination.parent) as temporary:
        staging = Path(temporary) / "bundle.zip"
        with zipfile.ZipFile(staging, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for name, value in payloads.items():
                archive.writestr(name, value)
        with zipfile.ZipFile(staging) as archive:
            if archive.testzip() is not None:
                raise ValueError("压缩校验失败")
        os.replace(staging, destination)
    return identifier


def main():
    """用户显式提供源目录与目标；不自动搜索任意用户目录或绕过文件权限。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        identifier = export(args.source, args.output)
        print("应急诊断包已生成，报告编号：" + identifier)
        return 0
    except (ValueError, OSError, zipfile.BadZipFile) as error:
        print("应急导出失败：" + type(error).__name__)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
