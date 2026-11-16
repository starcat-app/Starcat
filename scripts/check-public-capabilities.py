#!/usr/bin/env python3
"""核对已登记公共能力；静态一致性不代替领域测试或发现未登记业务。"""

from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[1]
BASELINE = {
    "get_capabilities", "get_overview_statistics", "get_ai_usage_statistics",
    "get_knowledge_base_statistics", "search_repos", "global_search_repos",
    "semantic_search", "get_repo", "get_repo_context", "get_repo_summary",
    "generate_repo_summary", "get_readme", "list_tags", "list_repos_by_tag",
    "get_repo_note", "star_repo", "unstar_repo", "upsert_repo_note",
    "set_repo_status", "create_tag", "add_repo_tags", "batch_organize_repos",
    "remove_repo_tags", "set_repo_tags",
}


def read(relative: str) -> str:
    """只读取源码和专项登记，不打开凭据、数据库或用户配置。"""
    return (ROOT / relative).read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def main() -> None:
    """验证目录、执行分派、文档、永久规则与配套工作区的固定入口。"""
    directory = "Starcat/Features/MCP/"
    registry = read(directory + "StarcatMCPToolRegistry.swift")
    catalog = read(directory + "StarcatMCPPublicCatalog.swift")
    facade = read(directory + "StarcatMCPPublicFacade.swift")
    for filename in [
        "StarcatMCPAppOperations.swift", "StarcatMCPLocalOperations.swift",
        "StarcatMCPRAGOperations.swift", "StarcatMCPAgentOperations.swift",
        "StarcatMCPCodeGraphOperations.swift",
    ]:
        source = read(directory + filename)
        catalog += "\n" + source
        facade += "\n" + source
    document = read("docs/4-工程进度/CLI与MCP能力开放专项/能力覆盖清单.md")
    existing = re.findall(r'name:\s*"starcat\.([a-z][a-z0-9_]*)"', registry)
    additional = re.findall(r'\.init\(name:\s*"([a-z][a-z0-9_]*)"', catalog)
    registered = set(existing + additional)
    require(len(registered) == len(existing + additional), "公共目录存在重名工具")
    require(BASELINE <= registered, f"基线工具被移除：{sorted(BASELINE - registered)}")
    dispatched = set()
    for group in re.findall(r'^\s*case\s+((?:"[^"]+"(?:,\s*)?)+)\s*:', facade, re.M):
        dispatched.update(re.findall(r'"([^"]+)"', group))
    dispatched.update(re.findall(r'\bname\s*==\s*"([a-z][a-z0-9_]*)"', facade))
    require(set(additional) <= dispatched, f"新增工具缺少执行器：{sorted(set(additional) - dispatched)}")
    documented = set(re.findall(r'`starcat\.([a-z][a-z0-9_]*)`', document))
    require(documented == registered, f"文档与目录不一致：{sorted(documented ^ registered)}")
    identifiers = re.findall(r'^\| ((?:CAP|RES|REVIEW|FUTURE|UI)-\d+) \|', document, re.M)
    require(len(identifiers) == len(set(identifiers)), "覆盖清单编号重复")
    rows = [line for line in document.splitlines() if re.match(r"\| CAP-\d+ \|", line)]
    require(all(any(f"| {decision} |" in line for decision in [
        "已有覆盖", "本次开放", "暂缓开放", "不适用"
    ]) for line in rows), "覆盖动作存在未评估结论")
    require('defaultValue: false' not in "\n".join(
        line for line in registry.splitlines() if '"dry_run"' in line
    ), "已有写入仍使用省略即执行的默认行为")
    require('"contract_version": .int(3)' in registry, "缺少当前公共契约版本")
    require('"write_default": .string("app_contract")' in registry, "缺少 App 默认执行契约")
    require('"preview_supported"' in registry, "缺少逐工具预览声明")
    for target in [
        "AGENTS.md", "supports/starcat-cli/AGENTS.md", "supports/starcat-skill/AGENTS.md",
        "docs/4-工程进度/任务录入规范.md",
    ]:
        require("CLI与MCP能力暴露规范" in read(target), f"{target} 缺少永久规则入口")
    cli = read("supports/starcat-cli/internal/cli/runner.go")
    for name in ['case "tools"', 'case "resources"', 'case "browser-host"']:
        require(name in cli, f"CLI 缺少入口：{name}")
    for phrase in [
        "tools list", "tools describe", "tools call", "resources list", "resources read"
    ]:
        require(phrase in read("supports/starcat-skill/references/commands.md"),
                f"Skill 未登记命令：{phrase}")
    for uri in ["starcat://capabilities", "starcat://tags", "starcat://repos/"]:
        require(uri in read(directory + "StarcatMCPFacade.swift"), f"资源被移除：{uri}")
    print(f"PASS: {len(BASELINE)} baseline + {len(registered) - len(BASELINE)} added = {len(registered)} tools")
    print(f"PASS: {len(identifiers)} registered tool/resource/review/planning records")
    print("Static dual-entry registration matches dispatch and documentation; no whole-App coverage percentage is inferred.")
    print("Runtime availability, real App connections and GUI acceptance require separate evidence.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
