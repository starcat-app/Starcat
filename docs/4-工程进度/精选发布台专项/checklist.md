# 精选发布台专项 Checklist

> 状态：已完成。代码、文档、测试与专项工程进度已通过最终一致性审查。

## A. 需求与架构

- [x] 固化自然语言、多项目、AI 甄别与人工发布验收范围
- [x] 对齐 `starcat-weekly-import` 的拆分、检索、证据判断与确认流程
- [x] 将 AI 甄别会话与 Weekly 发布会话拆分
- [x] 保留集中式 GitHub 用户权限策略和独立安全凭据存储

## B. AI 项目甄别

- [x] 使用已配置 AI 模型拆分自然语言和混合项目清单
- [x] 生成逐项目检索式并调用开放网络搜索
- [x] 结合 GitHub Search、canonical 元数据与 README 构造证据
- [x] 输出 `confirmed`、`needs_review`、`not_found`
- [x] 拒绝 AI 未经 GitHub 核验的虚构仓库
- [x] 支持候选确认和手工 GitHub URL 二次核验
- [x] 确保窗口启动和识别阶段不调用 weekly-api

## C. 分类、发布与去重

- [x] 动态读取 weekly-api 人工导入分类
- [x] 支持在发布台创建人工分类并立即选中
- [x] 一次提交全部已勾选且已确认的仓库
- [x] 批次幂等键忽略输入文案和仓库顺序
- [x] weekly-api 使用 `source_code + owner/repo` 稳定事件键去重
- [x] 轮询并展示全部批次状态与 item 错误
- [x] 重新打开窗口可恢复最近批次

## D. UI 与集成

- [x] Weekly 工具栏只向允许用户展示入口
- [x] Weekly 工具栏使用红色圆形精选发布入口图标
- [x] 单实例独立 macOS Window
- [x] 完成“输入 / 审阅 / 发布”三栏工作台
- [x] 展示 AI 阶段进度、证据、候选、批量预览和新增分类 Sheet
- [x] 完成中英文 String Catalog 与 UI 规范自检

## E. 测试、文档与验收

- [x] 客户端 5 个专项 Suite、25 项测试通过
- [x] weekly-api 分类创建与稳定去重测试通过
- [x] Starcat 与 weekly-api 全量单元测试通过
- [x] 需求、技术设计和决策文档与实现一致
- [x] 完成 Agent 项目识别机制详解文档
- [x] 完成 11 轮审查并保存独立报告
- [x] 所有审查问题修复且无功能遗留
- [x] 更新最终完成结果报告
