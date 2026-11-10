#!/usr/bin/env python3
"""只读、有界解析 Starcat ZIP、目录和历史 JSONL，区分事实与证据缺口。"""

import argparse
from collections import Counter, defaultdict
import datetime as dt
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import sys
import zipfile

MAX_FILES, MAX_FILE, MAX_TOTAL, MAX_EVENTS = 2048, 16 << 20, 64 << 20, 100_000
PUBLIC_KEYS = set(("schemaVersion eventID sequence sessionID environmentID operationID "
                   "parentOperationID requestID serverTraceID timestamp firstSeen lastSeen "
                   "occurrenceCount level visibility category operation phase outcome "
                   "durationMs statusCode errorCode").split())


def redact(text):
    """仅输出有界摘要，对历史资料补做常见凭据与路径过滤。"""
    value = str(text)
    for pattern, replacement in [
        (r"(?i)Bearer\s+[A-Za-z0-9._~+/=-]+", "Bearer <redacted>"),
        (r"(?i)\b(?:github_pat_|gh[pousr]_|sk-(?:proj-)?)[A-Za-z0-9_-]{8,}", "<redacted>"),
        (r"(?i)\b(api[_-]?key|token|license[_-]?key|authorization|cookie)\s*[:=]\s*\S+", r"\1=<redacted>"),
        (r"(?:file://)?/Users/[^\s\"<>]+", "<local-path>"),
        (r"[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}", "<email>"),
    ]:
        value = re.sub(pattern, replacement, value)
    return value[:1024]


def timestamp(value):
    """无时区或损坏时间保留为未知，不伪造排序依据。"""
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        return parsed.astimezone(dt.timezone.utc) if parsed.tzinfo else None
    except (ValueError, TypeError, AttributeError):
        return None


def safe_path(name):
    """不解压仍拒绝歧义路径，确保清单引用不会指向包外。"""
    path = PurePosixPath(name)
    if "\\" in name or path.is_absolute() or ".." in path.parts or "\x00" in name:
        raise ValueError("诊断包路径不安全")
    return str(path)


def load_files(source):
    """限制文件数和展开体积，目录输入不跟随符号链接。"""
    files, total = {}, 0

    def add(name, size, reader):
        nonlocal total
        name = safe_path(name)
        if name in files:
            raise ValueError("诊断包文件重复")
        if size > MAX_FILE or total + size > MAX_TOTAL:
            raise ValueError("诊断数据超过安全读取上限")
        payload = reader()
        if len(payload) != size:
            raise ValueError("文件大小不一致")
        files[name], total = payload, total + size

    if source.is_file() and source.suffix.lower() == ".zip":
        with zipfile.ZipFile(source) as archive:
            if len(archive.infolist()) > MAX_FILES:
                raise ValueError("文件数量超限")
            for entry in archive.infolist():
                safe_path(entry.filename)
                if not entry.is_dir():
                    add(entry.filename, entry.file_size, lambda e=entry: archive.read(e))
    elif source.is_file():
        add(source.name, source.stat().st_size, source.read_bytes)
    elif source.is_dir():
        for count, child in enumerate(source.rglob("*"), 1):
            if count > MAX_FILES:
                raise ValueError("文件数量超限")
            if child.is_symlink():
                raise ValueError("不读取符号链接")
            if child.is_file():
                add(child.relative_to(source).as_posix(), child.stat().st_size, child.read_bytes)
    else:
        raise ValueError("找不到诊断输入")
    return files


def collect(files):
    """解析损坏项时保留其他证据，显式报告缺失与历史限制。"""
    gaps, events, manifest = [], [], {}
    entries = [(name, payload) for name, payload in files.items()
               if PurePosixPath(name).name == "manifest.json"]
    if len(entries) > 1:
        raise ValueError("多个 manifest，证据范围不明确")
    if entries:
        name, payload = entries[0]
        try:
            manifest = json.loads(payload)
            if not isinstance(manifest, dict):
                raise ValueError()
        except (ValueError, UnicodeDecodeError):
            manifest = {}
            gaps.append("manifest 无法解析")
        listed = manifest.get("files", [])
        if not isinstance(listed, list):
            gaps.append("manifest 文件清单无效")
            listed = []
        for item in listed:
            if not isinstance(item, dict) or not isinstance(item.get("path"), str):
                gaps.append("manifest 文件条目无效")
                continue
            key = str(PurePosixPath(name).parent / safe_path(item["path"]))
            data = files.get(key)
            if data is None:
                gaps.append("文件缺失：" + redact(item["path"]))
            elif ("bytes" in item and item["bytes"] != len(data)) or (
                    item.get("sha256") and item["sha256"] != hashlib.sha256(data).hexdigest()):
                gaps.append("文件校验失败：" + redact(item["path"]))
    else:
        gaps.append("没有 manifest，可能是历史 JSONL 或部分附件，无法核验完整性")
    bad = 0
    for name, payload in files.items():
        base = PurePosixPath(name).name
        if not (base == "events.jsonl" or
                (base.startswith("diagnostic-log") and base.endswith(".jsonl")) or
                (len(files) == 1 and base.endswith(".jsonl"))):
            continue
        for line in payload.splitlines():
            if not line.strip():
                continue
            try:
                event = json.loads(line)
                if not isinstance(event, dict) or not all(
                        isinstance(event.get(k), str) for k in ("timestamp", "category", "operation")):
                    raise ValueError()
                events.append(event)
            except (ValueError, UnicodeDecodeError):
                bad += 1
            if len(events) > MAX_EVENTS:
                raise ValueError("事件数量超限")
    if bad:
        gaps.append(f"{bad} 行损坏或缺少必要字段")
    if any(e.get("schemaVersion", 1) == 1 for e in events):
        gaps.append("包含历史事件，缺少的会话、操作和版本信息不能补造")
    if not events:
        gaps.append("没有可解析事件，不能认定应用没有问题")
    collectors = manifest.get("collectors", [])
    if isinstance(collectors, dict):
        collectors = [dict(value, name=key) for key, value in collectors.items() if isinstance(value, dict)]
    if isinstance(collectors, list):
        for item in collectors:
            if isinstance(item, dict) and item.get("status") not in ("collected", "notApplicable"):
                gaps.append(f"采集项 {redact(item.get('name', 'unknown'))}：{redact(item.get('status', 'unknown'))}")
    return events, manifest, gaps


def public_event(event):
    """默认时间线不复制自由文本、客户描述和任意上下文。"""
    return {key: redact(value) if isinstance(value, str) else value
            for key, value in event.items() if key in PUBLIC_KEYS
            and isinstance(value, (str, int, float, bool, type(None)))}


def analyze(source, args):
    """按显式关联生成事实摘要，恢复只认同一操作的后续成功。"""
    events, manifest, gaps = collect(load_files(source))
    minimum = dt.datetime.min.replace(tzinfo=dt.timezone.utc)
    selected = []
    for event in events:
        if any(wanted and event.get(key) != wanted for key, wanted in [
                ("category", args.module), ("operationID", args.operation_id),
                ("requestID", args.request_id), ("errorCode", args.error_code)]):
            continue
        when = timestamp(event.get("timestamp"))
        if args.since and (not when or when < args.since):
            continue
        if args.until and (not when or when > args.until):
            continue
        selected.append(event)
    selected.sort(key=lambda e: timestamp(e.get("timestamp")) or minimum)
    groups, cancelled = defaultdict(list), 0
    for event in selected:
        if event.get("outcome") == "cancelled" or "CancellationError" in str(event.get("underlying", "")):
            cancelled += 1
        elif event.get("outcome") not in ("succeeded", "skipped") and (
                event.get("level") in ("warning", "error", "critical") or event.get("outcome") == "failed"):
            groups[tuple(str(event.get(k, "")) for k in ("category", "operation", "errorCode", "statusCode"))].append(event)
    incidents = []
    for key, group in groups.items():
        operation_ids = {e["operationID"] for e in group if isinstance(e.get("operationID"), str)}
        last = timestamp(group[-1].get("lastSeen", group[-1].get("timestamp")))
        recovered = last is not None and any(
            e.get("outcome") == "succeeded" and isinstance(e.get("operationID"), str)
            and e["operationID"] in operation_ids
            and (timestamp(e.get("timestamp")) or minimum) > last for e in events)
        count = sum(c if isinstance(c := e.get("occurrenceCount", 1), int) and not isinstance(c, bool) and c > 0
                    else 1 for e in group)
        incidents.append(dict(module=redact(key[0]), operation=redact(key[1]), errorCode=redact(key[2]),
                              statusCode=redact(key[3]), count=count,
                              firstSeen=redact(group[0].get("firstSeen", group[0].get("timestamp"))),
                              lastSeen=redact(group[-1].get("lastSeen", group[-1].get("timestamp"))),
                              operationIDs=sorted(redact(s) for s in operation_ids)[:20],
                              serverTraceIDs=sorted({redact(e["serverTraceID"]) for e in group
                                                     if e.get("serverTraceID")})[:20],
                              recovery="后续同一操作成功" if recovered else "未找到关联恢复证据"))
    if any(e.get("operation") in ("metricPayload", "diagnosticPayload") for e in selected):
        gaps.append("MetricKit 通知不等于附件已保存，需核对系统采集项")
    if any(timestamp(e.get("timestamp")) is None for e in selected):
        gaps.append("部分事件时间无效或缺少时区")
    return dict(reportID=redact(manifest.get("exportID", "unknown")),
                availableEvents=len(events), selectedEvents=len(selected),
                actualRange=dict(first=redact(selected[0]["timestamp"]) if selected else None,
                                 last=redact(selected[-1]["timestamp"]) if selected else None),
                modules=dict(Counter(redact(e["category"]) for e in selected)),
                cancelledEvents=cancelled, incidents=sorted(incidents, key=lambda i: -i["count"])[:50],
                evidenceGaps=list(dict.fromkeys(gaps)), timeline=[public_event(e) for e in selected[-args.limit:]],
                timelineTruncated=len(selected) > args.limit)


def markdown(report):
    """生成有界首读报告，原始客户内容不进入渲染。"""
    lines = ["# Starcat 诊断分析", "", f"报告：{report['reportID']}",
             f"可用事件：{report['availableEvents']}；筛选事件：{report['selectedEvents']}",
             f"时间范围：{report['actualRange']}", f"取消相关：{report['cancelledEvents']}", "", "## 故障证据", ""]
    for item in report["incidents"]:
        lines.append(f"- {item['module']} / {item['operation']}：{item['count']} 次，"
                     f"HTTP={item['statusCode'] or 'unknown'}，错误码={item['errorCode'] or 'unknown'}；{item['recovery']}")
        if item["serverTraceIDs"]:
            lines.append("  trace：" + ", ".join(item["serverTraceIDs"]))
    if not report["incidents"]:
        lines.append("选定范围未找到故障记录，请同时核对证据缺口")
    lines += ["", "## 证据缺口", ""] + ["- " + gap for gap in report["evidenceGaps"]]
    lines += ["", "## 时间线", "", "```json"]
    lines += [json.dumps(e, ensure_ascii=False, sort_keys=True) for e in report["timeline"]]
    return "\n".join(lines + ["```", "", f"时间线截断：{report['timelineTruncated']}", ""])


def iso_argument(value):
    """无效筛选时间必须报错，避免误以为已经缩小分析范围。"""
    result = timestamp(value)
    if result is None:
        raise argparse.ArgumentTypeError("使用包含时区的 ISO8601 时间")
    return result


def main(argv=None):
    """仅在明确 output 参数下写报告，错误时返回非零状态。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    for option in ("module", "operation-id", "request-id", "error-code"):
        parser.add_argument("--" + option)
    parser.add_argument("--since", type=iso_argument)
    parser.add_argument("--until", type=iso_argument)
    parser.add_argument("--limit", type=int, default=100)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    if not 1 <= args.limit <= 1000:
        parser.error("--limit 必须在 1 至 1000 之间")
    if args.since and args.until and args.since > args.until:
        parser.error("开始时间晚于结束时间")
    try:
        report = analyze(args.source, args)
        text = json.dumps(report, ensure_ascii=False, indent=2) + "\n" if args.json else markdown(report)
        if args.output:
            args.output.write_text(text, encoding="utf-8")
        else:
            sys.stdout.write(text)
        return 0
    except (OSError, ValueError, zipfile.BadZipFile, RuntimeError) as error:
        print("诊断分析失败：" + redact(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
