# starcat-weekly-api 人工录入契约

## 配置

- 生产 Base URL：固定为 `https://starcat-weekly-api.fly.dev`。
- 生产 Admin Key：从 Starcat 仓库的 `supports/starcat-weekly-api/.env` 读取 `ADMIN_API_KEYS`；多值时使用第一个非空 Key。
- 测试模式：只有用户明确说明测试时才启用 `--test`，并通过 `--base-url` / `STARCAT_WEEKLY_BASE_URL` 和 `STARCAT_WEEKLY_ADMIN_KEY` 注入测试配置。
- Header：`Authorization: Bearer <Admin Key>`。
- 所有写请求与来源能力查询都使用 Admin Key，不使用客户端公开 API Key。
- 不得输出 Admin Key、完整 Authorization header，或要求用户把生产 Key 导出到 shell。

## 查询允许来源

```http
GET /internal/sources?manual_import=true
```

只可选择同时满足以下条件的来源：

```json
{
  "enabled": true,
  "manual_import_enabled": true
}
```

当前产品已实现的人工来源为 `ai_intelligence`。后续来源必须先完成 weekly-api 固定目录、Starcat 展示与 local-admin 运维入口，再随服务端响应开放。

## 创建批次

```http
POST /internal/imports
Content-Type: application/json
```

```json
{
  "source_code": "ai_intelligence",
  "idempotency_key": "ai-intelligence:2026-07-16:example",
  "repositories": [
    {
      "owner": "Zackriya-Solutions",
      "repo": "meetily",
      "title": "Meetily - 本地优先的 AI 会议助手",
      "source_url": "https://example.com/original-news"
    }
  ]
}
```

响应为 `202 Accepted`，`data.batch_id` 是后续查询依据。同一个 `idempotency_key` 重放时返回原批次，不会重复建批。未显式提供 key 时，`submit_import.py` 会根据规范化后的完整 payload 生成稳定 SHA-256 内容指纹；dry-run、正式提交和网络结果未知后的重放必须复用同一个 key。

## 查询批次

```http
GET /internal/imports/{batch_id}
```

批次状态：

- `pending`：已持久化，等待 Worker；
- `processing`：正在调用 GitHub API 补全；
- `success`：全部成功；
- `partial_success`：部分仓库经三次失败后被剔除；
- `failed`：全部失败或控制任务失败。

单项状态：`pending / processing / retrying / success / discarded`。失败重试由服务端 Worker 负责，Skill 不应在客户端短周期重复 POST。

## 限制

- 每批 1 至 200 个仓库；
- `owner`、`repo` 必填；
- `source_url` 可省略；提供时必须是带 host 的绝对 `http` 或 `https` URL；
- 只有固定允许来源可写；
- POST 事务内不会调用 GitHub API；
- Worker 由 commit 后内存信号尽快唤醒，并每 15 分钟扫描数据库兜底。
