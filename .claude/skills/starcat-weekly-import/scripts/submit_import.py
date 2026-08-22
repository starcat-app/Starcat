#!/usr/bin/env python3
"""校验并提交 Starcat Weekly 人工情报批次。

默认只打印规范化 payload；必须显式传入 --confirm 才会访问管理接口。
生产提交固定使用 Starcat 聚合 API 的 Weekly 服务，并从 starcat-api 的本地 .env 读取管理员 Key；
只有显式 --test 才允许调用方注入测试地址和测试 Key。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Mapping
from pathlib import Path
from typing import Any


OWNER_PATTERN = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$")
REPO_PATTERN = re.compile(r"^[A-Za-z0-9._-]{1,100}$")
TERMINAL_STATUSES = {"success", "partial_success", "failed"}
PRODUCTION_BASE_URL = "https://starcat-api.fly.dev"
PRODUCTION_SERVICE_HEADER = "X-SC-Svc"
PRODUCTION_SERVICE_NAME = "weekly"
PRODUCTION_ADMIN_KEY_NAME = "WEEKLY_ADMIN_API_KEYS"
# 从脚本自身定位 Starcat 根目录，避免依赖调用命令时的当前工作目录。
STARCAT_ROOT = Path(__file__).resolve().parents[4]
PRODUCTION_ENV_FILE = STARCAT_ROOT / "supports" / "starcat-api" / ".env"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="校验或提交 Starcat Weekly 人工情报批次")
    parser.add_argument("--test", action="store_true", help="显式启用测试模式，允许注入非生产服务配置")
    parser.add_argument("--base-url", default="", help="测试服务地址；仅可与 --test 一起使用")
    parser.add_argument("--input", required=True, help="JSON 文件路径")
    parser.add_argument("--confirm", action="store_true", help="确认访问 API 并提交")
    parser.add_argument("--poll", action="store_true", help="提交后轮询到终态")
    parser.add_argument("--poll-interval", type=float, default=5.0)
    parser.add_argument("--poll-timeout", type=float, default=600.0)
    return parser.parse_args()


def load_production_admin_key(path: Path = PRODUCTION_ENV_FILE) -> str:
    """从 starcat-api 的 .env 读取第一个 WEEKLY_ADMIN_API_KEYS 值。

    这里不通过 shell source 加载文件，避免把 .env 内容当成命令执行；只解析本任务需要的
    Weekly 管理密钥，并兼容常见的单引号或双引号包裹形式。
    """
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except FileNotFoundError as error:
        raise ValueError(f"生产配置文件不存在: {path}") from error

    for raw_line in lines:
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, raw_value = line.split("=", 1)
        if name.removeprefix("export ").strip() != PRODUCTION_ADMIN_KEY_NAME:
            continue
        value = raw_value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
            value = value[1:-1]
        key = next((item.strip() for item in value.split(",") if item.strip()), "")
        if key:
            return key
        break
    raise ValueError(f"生产配置文件缺少非空 {PRODUCTION_ADMIN_KEY_NAME}: {path}")


def resolve_runtime_config(
    args: argparse.Namespace,
    environ: Mapping[str, str] = os.environ,
    production_env_file: Path = PRODUCTION_ENV_FILE,
) -> tuple[str, str]:
    """按显式模式解析服务地址和管理员 Key，防止生产任务误投到测试环境。"""
    if not args.test:
        if args.base_url.strip():
            raise ValueError("--base-url 仅允许和 --test 一起使用；默认提交固定使用生产服务")
        return PRODUCTION_BASE_URL, load_production_admin_key(production_env_file)

    base_url = args.base_url.strip() or environ.get("STARCAT_WEEKLY_BASE_URL", "").strip()
    if not base_url:
        raise ValueError("测试模式缺少 --base-url 或 STARCAT_WEEKLY_BASE_URL")
    key = environ.get("STARCAT_WEEKLY_ADMIN_KEY", "").strip()
    if not key:
        raise ValueError("测试模式缺少环境变量 STARCAT_WEEKLY_ADMIN_KEY")
    return base_url, key


def load_and_validate(path: str) -> dict[str, Any]:
    payload = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError("输入必须是 JSON object")
    source_code = str(payload.get("source_code", "ai_intelligence")).strip()
    repositories = payload.get("repositories")
    if not isinstance(repositories, list) or not 1 <= len(repositories) <= 200:
        raise ValueError("repositories 数量必须在 1 到 200 之间")

    normalized: list[dict[str, str]] = []
    seen: set[str] = set()
    for index, item in enumerate(repositories):
        if not isinstance(item, dict):
            raise ValueError(f"repositories[{index}] 必须是 object")
        owner = str(item.get("owner", "")).strip()
        repo = str(item.get("repo", "")).strip()
        if not OWNER_PATTERN.fullmatch(owner) or not REPO_PATTERN.fullmatch(repo):
            raise ValueError(f"repositories[{index}] 不是合法 owner/repo: {owner}/{repo}")
        key = f"{owner}/{repo}".lower()
        if key in seen:
            continue
        seen.add(key)
        record = {"owner": owner, "repo": repo}
        for optional in ("title", "source_url"):
            value = str(item.get(optional, "")).strip()
            if value:
                if optional == "source_url" and not is_safe_source_url(value):
                    raise ValueError(f"repositories[{index}].source_url 必须是绝对 http/https URL")
                record[optional] = value
        normalized.append(record)
    if not normalized:
        raise ValueError("去重后没有可提交仓库")
    idempotency_key = str(payload.get("idempotency_key", "")).strip()
    if not idempotency_key:
        # 同一规范化 payload 必须在 dry-run、正式提交和超时重放时得到相同 key。
        # 显式 key 仍优先，方便调用方把同一仓库列表作为不同情报事件再次录入。
        canonical = json.dumps(
            {"source_code": source_code, "repositories": normalized},
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        )
        digest = hashlib.sha256(canonical.encode("utf-8")).hexdigest()[:20]
        idempotency_key = f"{source_code}:auto:{digest}"
    return {
        "source_code": source_code,
        "idempotency_key": idempotency_key,
        "repositories": normalized,
    }


def is_safe_source_url(value: str) -> bool:
    parsed = urllib.parse.urlparse(value)
    return (
        parsed.scheme.lower() in {"http", "https"}
        and bool(parsed.netloc)
        and parsed.username is None
        and parsed.password is None
    )


def api_request(base_url: str, key: str, method: str, path: str, body: dict[str, Any] | None = None) -> dict[str, Any]:
    url = urllib.parse.urljoin(base_url.rstrip("/") + "/", path.lstrip("/"))
    data = None if body is None else json.dumps(body, ensure_ascii=False).encode("utf-8")
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Authorization", f"Bearer {key}")
    # 聚合 Host 上存在同路径的多个业务 API；显式服务头是 Weekly 路由的唯一可靠依据。
    # 独立 weekly-api 会忽略未知头，因此测试环境直接指向独立服务时也保持兼容。
    request.add_header(PRODUCTION_SERVICE_HEADER, PRODUCTION_SERVICE_NAME)
    request.add_header("Accept", "application/json")
    if data is not None:
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"API {method} {path} 返回 {error.code}: {detail}") from error


def assert_source_allowed(base_url: str, key: str, source_code: str) -> None:
    response = api_request(base_url, key, "GET", "/internal/sources?manual_import=true")
    sources = response.get("data", [])
    allowed = {
        item.get("code")
        for item in sources
        if item.get("enabled") is True and item.get("manual_import_enabled") is True
    }
    if source_code not in allowed:
        raise RuntimeError(f"来源 {source_code!r} 不在服务端允许的人工录入列表中: {sorted(allowed)}")


def poll_batch(base_url: str, key: str, batch_id: str, interval: float, timeout: float) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    while True:
        response = api_request(base_url, key, "GET", f"/internal/imports/{batch_id}")
        batch = response.get("data", {})
        if batch.get("status") in TERMINAL_STATUSES:
            return response
        if time.monotonic() >= deadline:
            raise TimeoutError(f"批次 {batch_id} 在 {timeout:g}s 内未进入终态")
        time.sleep(max(interval, 1.0))


def main() -> int:
    args = parse_args()
    try:
        payload = load_and_validate(args.input)
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        if not args.confirm:
            print("仅完成本地校验；传入 --confirm 后才会访问 API。", file=sys.stderr)
            return 0
        base_url, key = resolve_runtime_config(args)
        assert_source_allowed(base_url, key, payload["source_code"])
        response = api_request(base_url, key, "POST", "/internal/imports", payload)
        print(json.dumps(response, ensure_ascii=False, indent=2))
        if args.poll:
            batch_id = response.get("data", {}).get("batch_id")
            if not batch_id:
                raise RuntimeError("POST 响应缺少 data.batch_id")
            terminal = poll_batch(base_url, key, batch_id, args.poll_interval, args.poll_timeout)
            print(json.dumps(terminal, ensure_ascii=False, indent=2))
        return 0
    except (OSError, ValueError, RuntimeError, TimeoutError, json.JSONDecodeError) as error:
        print(f"错误: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
