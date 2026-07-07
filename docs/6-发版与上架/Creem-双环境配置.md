# Creem 双环境配置

> 目标：长期保留 Test Mode 与 Live Mode 两套支付环境。测试跑通后不删除测试配置，后续发版前继续用 staging 做 smoke test。

## 环境分层

| 层级 | 测试环境 | 生产环境 |
|------|----------|----------|
| Creem Dashboard | Test Mode | Live Mode |
| Creem API Base URL | `https://test-api.creem.io/v1` | `https://api.creem.io/v1` |
| Starcat License API | `https://starcat-license-api-staging.fly.dev` | `https://starcat-license-api.fly.dev` |
| Creem Webhook URL | `https://starcat-license-api-staging.fly.dev/v1/webhooks/creem` | `https://starcat-license-api.fly.dev/v1/webhooks/creem` |
| App build selector | `STARCAT_LICENSE_API_ENVIRONMENT = test` | `STARCAT_LICENSE_API_ENVIRONMENT = live` |

Creem 官方文档说明：Test Mode 是完全隔离环境，API、支付、webhook 和数据不影响生产；Test Mode 使用 `https://test-api.creem.io/v1`，Live Mode 使用 `https://api.creem.io/v1`。

## Creem Dashboard 配置

### 1. Test Mode

1. 打开 Creem Dashboard。
2. 左下角切换到 `Test Mode`。
3. 创建两个 Product：
   - `Starcat Pro Monthly`：`$9.99/month`
   - `Starcat Pro Lifetime`：`$39.99` one-time
4. 复制 Test Mode 下的：
   - API Key：写入 staging 后端 `CREEM_API_KEY`
   - Monthly Product ID：写入 staging 后端 `CREEM_PRODUCT_MONTHLY_ID`
   - Lifetime Product ID：写入 staging 后端 `CREEM_PRODUCT_LIFETIME_ID`
5. 添加 webhook：
   - URL：`https://starcat-license-api-staging.fly.dev/v1/webhooks/creem`
   - Secret：复制到 staging 后端 `CREEM_WEBHOOK_SECRET`
   - Events：
     - `checkout.completed`
     - `subscription.active`
     - `subscription.paid`
     - `subscription.canceled`
     - `subscription.scheduled_cancel`
     - `subscription.past_due`
     - `subscription.expired`
     - `subscription.update`
     - `subscription.trialing`
     - `subscription.paused`
     - `refund.created`
     - `dispute.created`

### 2. Live Mode

1. 关闭 `Test Mode`，回到 Live Mode。
2. 创建同名生产 Product：
   - `Starcat Pro Monthly`：`$9.99/month`
   - `Starcat Pro Lifetime`：`$39.99` one-time
3. 复制 Live Mode 下的 API Key 和两个 Product ID。
4. 添加生产 webhook：
   - URL：`https://starcat-license-api.fly.dev/v1/webhooks/creem`
   - Secret：复制到生产后端 `CREEM_WEBHOOK_SECRET`
   - Events 与 Test Mode 相同。

## 后端环境文件

`supports/starcat-license-api` 使用两份本地私密环境文件管理 test/live 配置：

| 文件 | 用途 | 是否提交 |
|------|------|----------|
| `.env` | staging / Creem Test Mode | 不提交 |
| `.env.prod` | production / Creem Live Mode | 不提交 |
| `.env.example` | staging 模板 | 提交 |
| `.env.prod.example` | production 模板 | 提交 |

`.env.prod` 必须只保存 Live Mode 配置，不能混入 `creem_test_` key 或 test product id。

创建 production 配置：

```bash
cd supports/starcat-license-api
cp .env.prod.example .env.prod
```

填写 `.env.prod`：

```env
PORT=5010
API_KEYS=<live-client-api-key>
CREEM_API_BASE_URL=https://api.creem.io/v1
CREEM_API_KEY=<creem-live-api-key>
CREEM_WEBHOOK_SECRET=<live-webhook-secret>
CREEM_PRODUCT_MONTHLY_ID=<live-monthly-product-id>
CREEM_PRODUCT_LIFETIME_ID=<live-lifetime-product-id>
STARCAT_SUCCESS_URL=https://starcat-license-api.fly.dev/payment/success
```

## Fly 后端部署

### 1. staging 后端

staging 后端必须只使用 Creem Test Mode 的 key、product id 和 webhook secret。

```bash
fly apps create starcat-license-api-staging

fly secrets set \
  API_KEYS="<staging-client-api-key>" \
  CREEM_API_KEY="<creem-test-api-key>" \
  CREEM_API_BASE_URL="https://test-api.creem.io/v1" \
  CREEM_PRODUCT_MONTHLY_ID="<test-monthly-product-id>" \
  CREEM_PRODUCT_LIFETIME_ID="<test-lifetime-product-id>" \
  STARCAT_SUCCESS_URL="https://starcat-license-api-staging.fly.dev/payment/success" \
  CREEM_WEBHOOK_SECRET="<test-webhook-secret>" \
  -a starcat-license-api-staging
```

### 2. production 后端

production 后端必须只使用 Creem Live Mode 的 key、product id 和 webhook secret。

#### 2.1 创建 production app

首次部署时创建 Fly app：

```bash
cd supports/starcat-license-api
fly apps create starcat-license-api --org personal
```

如果提示 app 已存在，直接进入下一步。

#### 2.2 同步 `.env.prod` 到 Fly secrets

不要手写复制 secret，统一从 `.env.prod` 读取并写入 Fly：

```bash
cd supports/starcat-license-api

set -a
source .env.prod
set +a

: "${API_KEYS:?missing API_KEYS}"
: "${CREEM_API_KEY:?missing CREEM_API_KEY}"
: "${CREEM_API_BASE_URL:?missing CREEM_API_BASE_URL}"
: "${CREEM_PRODUCT_MONTHLY_ID:?missing CREEM_PRODUCT_MONTHLY_ID}"
: "${CREEM_PRODUCT_LIFETIME_ID:?missing CREEM_PRODUCT_LIFETIME_ID}"
: "${CREEM_WEBHOOK_SECRET:?missing CREEM_WEBHOOK_SECRET}"

fly secrets set \
  API_KEYS="$API_KEYS" \
  CREEM_API_KEY="$CREEM_API_KEY" \
  CREEM_API_BASE_URL="$CREEM_API_BASE_URL" \
  CREEM_PRODUCT_MONTHLY_ID="$CREEM_PRODUCT_MONTHLY_ID" \
  CREEM_PRODUCT_LIFETIME_ID="$CREEM_PRODUCT_LIFETIME_ID" \
  STARCAT_SUCCESS_URL="${STARCAT_SUCCESS_URL:-https://starcat-license-api.fly.dev/payment/success}" \
  CREEM_WEBHOOK_SECRET="$CREEM_WEBHOOK_SECRET" \
  -a starcat-license-api
```

#### 2.3 部署 production

当前 `fly.toml` 默认 app 是 staging。部署 production 时必须用 `-a starcat-license-api` 显式覆盖 app 名：

```bash
fly deploy -a starcat-license-api
```

部署完成后检查：

```bash
fly status -a starcat-license-api
fly secrets list -a starcat-license-api
curl -fsS https://starcat-license-api.fly.dev/healthz
```

#### 2.4 Production checkout smoke test

使用 `.env.prod` 里的 `API_KEYS` 调 production checkout。只验证接口能返回 Creem hosted URL，不要随意完成真实扣款。

```bash
set -a
source .env.prod
set +a

curl -sS -X POST 'https://starcat-license-api.fly.dev/v1/direct/checkout' \
  -H "Authorization: Bearer $API_KEYS" \
  -H 'Content-Type: application/json' \
  -d '{"plan":"monthly","customer_email":"ops@starcat.ink"}'
```

预期响应包含：

```json
{
  "provider": "creem",
  "url": "https://..."
}
```

Lifetime 同理：

```bash
curl -sS -X POST 'https://starcat-license-api.fly.dev/v1/direct/checkout' \
  -H "Authorization: Bearer $API_KEYS" \
  -H 'Content-Type: application/json' \
  -d '{"plan":"lifetime","customer_email":"ops@starcat.ink"}'
```

#### 2.5 配置 Creem Live webhook

生产部署完成后，在 Creem Live Mode 添加 webhook：

```text
URL: https://starcat-license-api.fly.dev/v1/webhooks/creem
Secret: 与 .env.prod 的 CREEM_WEBHOOK_SECRET 一致
```

Events 与 Test Mode 相同。配置后在 Creem Dashboard 发送测试事件，确认投递目标是 production URL。

## App 构建配置

Starcat 客户端不直接调用 Creem，只调用 Starcat License API。两套 License API 配置写在 `Configs/Secrets.xcconfig`。

```xcconfig
STARCAT_LICENSE_API_ENVIRONMENT = test

STARCAT_LICENSE_API_TEST_BASE_URL = https:/$()/starcat-license-api-staging.fly.dev
STARCAT_LICENSE_API_TEST_KEY = <staging-client-api-key>

STARCAT_LICENSE_API_LIVE_BASE_URL = https:/$()/starcat-license-api.fly.dev
STARCAT_LICENSE_API_LIVE_KEY = <live-client-api-key>
```

说明：

- `STARCAT_LICENSE_API_ENVIRONMENT = test` 时，App 使用 `*_TEST_*`。
- `STARCAT_LICENSE_API_ENVIRONMENT = live` 时，App 使用 `*_LIVE_*`。
- `project.yml` 已设置 Direct Debug 默认 `test`，Direct Release 默认 `live`。
- `https:/$()/...` 是 xcconfig 写 URL 的安全写法，避免 `//` 被解析为注释，构建后会展开为 `https://...`。

## 本地验证流程

### 1. 生成工程

```bash
rtk xcodegen generate
```

### 2. 跑后端测试

```bash
cd supports/starcat-license-api
go test ./...
```

### 3. 跑客户端 Direct License 单测

```bash
xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' \
  -only-testing:StarcatTests/DirectLicenseAPITests test
```

### 4. 手动测试 checkout

Debug / Direct 测试包应连接 staging：

1. 打开 Starcat Direct build。
2. 进入 Settings → Pro。
3. 点击 `购买月付版` 或 `购买买断版`。
4. 浏览器应打开 Creem Test Mode checkout。
5. 使用 Creem Test Mode 测试卡完成支付。
6. 在 Creem Dashboard 确认 webhook 已投递到 staging URL。
7. 用收据里的 license key 回到 Starcat 激活 Pro。

Creem Test Mode 测试卡：

```text
Card number: 4111 1111 1111 1111
Expiry: 任意未来日期，例如 12/34
CVC/CVV: 任意 3 位，例如 123
Cardholder name: 任意测试名，例如 Test User
```

测试卡只允许在 Creem Test Mode checkout 中使用。Live Mode 不要使用测试卡，也不要为了 smoke test 随意完成真实扣款。

## 上线前检查

- Creem Live Mode 已创建 Monthly 和 Lifetime 产品。
- `supports/starcat-license-api/.env.prod` 已填写 Live Mode 的 API key、product id 和 webhook secret。
- `starcat-license-api` 生产 Fly app 使用 `https://api.creem.io/v1`。
- 生产 webhook URL 是 `https://starcat-license-api.fly.dev/v1/webhooks/creem`。
- Direct Release 构建里 `STARCAT_LICENSE_API_ENVIRONMENT = live`。
- `STARCAT_LICENSE_API_LIVE_KEY` 与生产后端 `API_KEYS` 中至少一个值一致。
- staging 和 production 的 Creem key / product id / webhook secret 没有混用。

## 参考

- Creem Test Mode: https://docs.creem.io/getting-started/test-mode
- Creem API Introduction: https://docs.creem.io/api-reference/introduction
- Creem Checkout API: https://docs.creem.io/features/checkout/checkout-api
- Creem Webhooks: https://docs.creem.io/code/webhooks
