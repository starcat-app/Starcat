# Creem 双环境配置

> 目标：长期保留 Test Mode 与 Live Mode 两套支付环境。测试跑通后不删除测试配置，后续发版前继续用 staging 做 smoke test。

## 支付 2.0 改造 Checklist

> 状态: 进行中。目标是把 Creem 试用、License seat、支付成功页、取消订阅、落地页 checkout 和 Direct/App Store 文案边界一次性收口。

- [x] **14 天 Pro 试用文案** — Monthly subscription 在 Creem Dashboard 配置 14 天 trial；落地页 Pricing / FAQ 明确说明试用期包含全部 Pro 功能，到期后按 $3.99/月续费。
- [x] **许可证 seat 展示** — 当前 License Keys activation limit 暂定 2 台 Mac；后端标准化返回 `activationLimit/activationUsed`，App 已可接收，落地页和成功页都明确展示。
- [x] **支付成功页重做** — 成功页属于 `supports/starcat-license-api`，不是 `pages`；生产环境只展示 Order、License Key 和许可证可用数，测试环境折叠显示 checkout/subscription/customer 等调试信息。
- [~] **Monthly → Lifetime 保护** — Lifetime 权益优先级高于 Monthly；成功页 deep link 会保留旧月订阅 id，App 已提供取消入口，自动化提示待补。
- [x] **App 内取消订阅入口** — Direct 版 Pro 设置页添加“取消月订阅”入口，调用 Starcat License API；后端再调用 Creem `POST /v1/subscriptions/{id}/cancel`，默认 `mode=scheduled`、`onExecute=cancel`。
- [x] **落地页 checkout 入口** — `supports/starcat-site/direct/index.html` 和 `supports/starcat-site/direct/index-zh.html` 的 Pro Buy 按钮调用 Starcat License API `/v1/direct/checkout`，只传 `plan` 和 `requestID`；页面不直连 Creem / Waffo。
- [x] **nginx 安全加固** — `supports/starcat-site/direct/starcat.ink.conf` 只处理静态站安全头、缓存、gzip 和敏感文件拒绝访问；不处理支付回跳。
- [x] **文档和验证** — 同步 README 与本文件；后端跑 `go test ./...`，App 跑 `xcodebuild build`，落地页 HTML 解析、diff 检查、静态资源部署和 nginx 远端语法检查均已完成。

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
3. 创建三个 Product：
   - `Starcat Pro Monthly`：`$3.99/month`
   - `Starcat Pro Yearly`：`$29.99/year`
   - `Starcat Pro Lifetime`：`$39.99` one-time
4. 复制 Test Mode 下的：
   - API Key：写入 staging 后端 `CREEM_API_KEY`
   - Monthly Product ID：写入 staging 后端 `CREEM_PRODUCT_MONTHLY_ID`
   - Yearly Product ID：写入 staging 后端 `CREEM_PRODUCT_YEARLY_ID`
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
   - `Starcat Pro Monthly`：`$3.99/month`
   - `Starcat Pro Yearly`：`$29.99/year`
   - `Starcat Pro Lifetime`：`$39.99` one-time
3. 复制 Live Mode 下的 API Key 和三个 Product ID。
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
PAYMENT_PROVIDER_PRIMARY=creem
PAYMENT_PROVIDER_FALLBACKS=
PAYMENT_PROVIDER_FALLBACK_MODE=off
CREEM_API_BASE_URL=https://api.creem.io/v1
CREEM_API_KEY=<creem-live-api-key>
CREEM_WEBHOOK_SECRET=<live-webhook-secret>
CREEM_PRODUCT_MONTHLY_ID=<live-monthly-product-id>
CREEM_PRODUCT_YEARLY_ID=<live-yearly-product-id>
CREEM_PRODUCT_LIFETIME_ID=<live-lifetime-product-id>
STARCAT_SUCCESS_URL=https://starcat-license-api.fly.dev/payment/success
```

### Payment Router 配置

`starcat-license-api` 的 checkout 入口由 payment router 统一调度，Creem 只是当前启用的 provider。落地页和 macOS App 都只调用 Starcat License API，不直接知道 Creem / Waffo 的支付 URL 或 product id。

```env
PAYMENT_PROVIDER_PRIMARY=creem
PAYMENT_PROVIDER_FALLBACKS=
PAYMENT_PROVIDER_FALLBACK_MODE=off
```

- `PAYMENT_PROVIDER_PRIMARY`：当前主支付渠道。当前可用值为 `creem`；`waffo` 只预留 adapter，未接真实 API 前不要设为 primary。
- `PAYMENT_PROVIDER_FALLBACKS`：逗号分隔的 fallback provider。当前默认留空。
- `PAYMENT_PROVIDER_FALLBACK_MODE`：默认 `off`。只有在完成第二支付渠道端到端验收后，才允许改成 `auto`。
- 自动 fallback 只允许发生在 checkout 创建前失败的场景；checkout 一旦在某个 provider 创建，后续成功页、license key 和 webhook 必须继续由同一 provider 完成。
- `POST /v1/direct/checkout` 是公开入口，因为静态落地页无法安全保存 Bearer key；该接口只接受 `plan=monthly|yearly|lifetime`，真实 product id 仍只保存在服务端。`customer-portal`、`subscriptions/cancel`、`licenses/*` 继续要求 `Authorization: Bearer ...`。

Waffo 配置项已预留，但真实 Waffo provider 尚未接入，当前必须保持为空：

```env
WAFFO_API_KEY=
WAFFO_WEBHOOK_SECRET=
WAFFO_PRODUCT_MONTHLY_ID=
WAFFO_PRODUCT_YEARLY_ID=
WAFFO_PRODUCT_LIFETIME_ID=
```

切换支付渠道时只改 Fly secrets，不改落地页：

```bash
fly secrets set PAYMENT_PROVIDER_PRIMARY=creem PAYMENT_PROVIDER_FALLBACK_MODE=off -a starcat-license-api
```

回滚同理，把 `PAYMENT_PROVIDER_PRIMARY` 改回上一个已验收 provider，并保持 `PAYMENT_PROVIDER_FALLBACK_MODE=off`。

## Fly 后端部署

### 1. staging 后端

staging 后端必须只使用 Creem Test Mode 的 key、product id 和 webhook secret。

```bash
fly apps create starcat-license-api-staging

fly secrets set \
  API_KEYS="<staging-client-api-key>" \
  PAYMENT_PROVIDER_PRIMARY="creem" \
  PAYMENT_PROVIDER_FALLBACKS="" \
  PAYMENT_PROVIDER_FALLBACK_MODE="off" \
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
  PAYMENT_PROVIDER_PRIMARY="${PAYMENT_PROVIDER_PRIMARY:-creem}" \
  PAYMENT_PROVIDER_FALLBACKS="${PAYMENT_PROVIDER_FALLBACKS:-}" \
  PAYMENT_PROVIDER_FALLBACK_MODE="${PAYMENT_PROVIDER_FALLBACK_MODE:-off}" \
  CREEM_API_KEY="$CREEM_API_KEY" \
  CREEM_API_BASE_URL="$CREEM_API_BASE_URL" \
  CREEM_PRODUCT_MONTHLY_ID="$CREEM_PRODUCT_MONTHLY_ID" \
  CREEM_PRODUCT_LIFETIME_ID="$CREEM_PRODUCT_LIFETIME_ID" \
  STARCAT_SUCCESS_URL="${STARCAT_SUCCESS_URL:-https://starcat-license-api.fly.dev/payment/success}" \
  CREEM_WEBHOOK_SECRET="$CREEM_WEBHOOK_SECRET" \
  -a starcat-license-api
```

`API_KEYS` 不能为空。Fly `secrets list` 只能证明 secret 名称存在，不能证明值非空；如果启动日志出现 `API_KEYS env is required`，优先检查 `.env.prod` 里的 `API_KEYS` 是否为空。

#### 2.3 部署 production

当前 `fly.toml` 默认 app 是 staging。部署 production 时必须用 `-a starcat-license-api` 显式覆盖 app 名：

```bash
fly deploy -a starcat-license-api --depot=false --ha=false
```

`--depot=false` 用于绕过当前账号可能遇到的 Depot builder 401；`--ha=false` 保持单 machine，避免早期配置验证阶段创建多台未验证实例。生产流量上来后再按需要开启多机。

部署完成后检查：

```bash
fly status -a starcat-license-api
fly secrets list -a starcat-license-api
curl -fsS https://starcat-license-api.fly.dev/healthz
```

#### 2.3.1 部署落地页

测试 / 生产落地页已经拆成两套域名和两套静态目录，完整说明见 [`Direct-测试与生产环境隔离.md`](Direct-测试与生产环境隔离.md)。

落地页部署脚本默认使用 `~/.ssh/config` 里的 `aliyun` alias。如果本机 alias 绑定了错误私钥，可以用 `DEPLOY_SSH_KEY` 显式指定：

```bash
# 测试环境：test.starcat.ink -> starcat-license-api-staging
cd supports/starcat-site/direct-test
DEPLOY_SSH_KEY="$HOME/.ssh/server" ./deploy.sh

# 生产环境：starcat.ink -> starcat-license-api
cd ../direct
DEPLOY_SSH_KEY="$HOME/.ssh/server" ./deploy.sh
```

执行 `deploy.sh` 会先同步对应 nginx 配置并执行 `nginx -t && systemctl reload nginx`，再同步对应静态资源。生产目录 `supports/starcat-site/direct` 固定 production checkout，测试目录 `supports/starcat-site/direct-test` 固定 staging checkout。

#### 2.4 Production checkout smoke test

`/v1/direct/checkout` 是给静态落地页使用的公开入口，不需要 `Authorization`；真实 product id 和 Creem API key 仍只保存在后端。只验证接口能返回 Creem hosted URL，不要随意完成真实扣款。

```bash
curl -sS -X POST 'https://starcat-license-api.fly.dev/v1/direct/checkout' \
  -H 'Content-Type: application/json' \
  -d '{"plan":"monthly","requestID":"smoke-monthly"}'
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
  -H 'Content-Type: application/json' \
  -d '{"plan":"lifetime","requestID":"smoke-lifetime"}'
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

## Direct License 授权校验策略

Direct License 校验是应用内部行为，不向用户暴露“请联网重新验证”之类的提示。用户只需要看到自己是不是 Pro；网络波动不应该打扰已购买用户。

### 核心原则

- 首次激活必须联网：输入授权码或从支付成功页回跳时，必须调用 License API 激活，拿到 `licenseKey + instanceID + productID` 以及可选的 `subscriptionID/customerID` 后才保存本地凭据。
- 冷启动立即恢复 Pro：只要本地存在 `licenseKey + instanceID`，启动时立即恢复 Pro 标识和 Pro 门控，不等待网络。
- 后台静默校验：App 启动后在后台 validate，校验过程不弹窗、不阻塞、不在普通 UI 上提示“正在验证”。
- 网络失败不影响 Pro：DNS 失败、超时、服务器 5xx、离线、后端暂时不可用，都只记录日志和本地状态，不撤销 Pro。
- 只有明确授权失效才撤销：只有后端明确返回 `revoked`、`expired`、`disabled` 或 `license_not_found`，才撤销本地 Pro 权益。
- 用户可见 UI 保持简单：Pro 设置页只显示当前 Pro 状态、计划类型、授权设备数和取消月订阅入口，不显示校验失败、grace period 或内部错误细节。

### 内部状态

客户端内部状态建议收敛为：

```swift
enum DirectLicenseRuntimeState {
    case none
    case localActive
    case verifiedActive
    case revoked
    case expired
}
```

- `none`：没有本地授权。
- `localActive`：本地有授权，冷启动立即恢复 Pro。
- `verifiedActive`：后台校验确认有效。
- `revoked`：服务端明确撤销。
- `expired`：服务端明确过期。

网络失败不进入用户可见状态，只记录内部调度和诊断字段：

```text
lastValidationAttemptAt
lastValidationSuccessAt
lastValidationFailureAt
lastValidationErrorCode
lastRemoteStatus
```

### 本地保存字段

继续保存：

```text
direct_license_key
direct_license_instance_id
direct_license_subscription_id
direct_license_customer_id
direct_license_product_id
```

后续补充内部字段：

```text
direct_license_plan
direct_license_last_validation_attempt_at
direct_license_last_validation_success_at
direct_license_last_validation_failure_at
direct_license_last_validation_error_code
direct_license_last_remote_status
```

### 静默校验规则

启动逻辑：

```text
if no local credential:
    Pro = false

if local credential exists:
    Pro = true immediately

    if shouldValidateNow(plan):
        run validate in background
```

自动校验频率：

| 授权类型 | 自动校验频率 | 网络失败处理 | 明确失效结果 |
|----------|--------------|--------------|--------------|
| Monthly | 最多 24 小时一次 | 保留 Pro，静默重试 | 立即撤销 |
| Lifetime | 最多 7 天一次 | 保留 Pro，静默重试 | 立即撤销 |

校验结果处理：

```text
active:
    Pro = true
    save success time
    runtimeState = verifiedActive

revoked / disabled / license_not_found:
    Pro = false
    clear or mark credential invalid
    runtimeState = revoked

expired:
    Pro = false
    runtimeState = expired

network / timeout / 5xx / temporary malformed response:
    Pro unchanged
    save failure metadata
    continue silent retry later
```

### Monthly 到 Lifetime

如果用户先买 Monthly 后买 Lifetime：

1. Lifetime 激活成功后，Pro 以 Lifetime 为准。
2. 保留旧 monthly `subscriptionID`。
3. Pro 设置页显示“取消月订阅续费”入口。
4. 用户点击后调用后端 scheduled cancel。
5. 取消失败只显示一次操作失败，不影响 Lifetime Pro。

### 后端契约

后端 validate 应尽量返回明确状态：

```json
{
  "status": "active | expired | revoked | inactive",
  "provider": "creem",
  "productID": "...",
  "instanceID": "...",
  "activationUsed": 1,
  "activationLimit": 2,
  "validatedAt": "..."
}
```

如果 Creem 或网络不可用：

```http
502 PROVIDER_UNAVAILABLE
```

客户端视为临时失败，不撤销 Pro。

如果 license 明确不存在：

```http
404 LICENSE_NOT_FOUND
```

客户端视为明确失效，撤销 Pro。

## 本地验证流程

### 0. Direct 支付回跳与取消订阅链路

- Creem checkout `success_url` 必须指向 License API：staging 使用 `https://starcat-license-api-staging.fly.dev/payment/success`，production 使用 `https://starcat-license-api.fly.dev/payment/success`。
- 支付成功页从 Creem retrieve checkout 结果中读取 license key、order、subscription、customer。
- 成功页按钮打开 `starcat://license/activate?...`，把 license key 与 `subscription_id` 交给 Starcat；license validate 本身不返回 `subscription_id`，所以这里是取消月订阅能力的关键数据来源。
- Starcat Direct 版 Pro 设置页只在本机保存过 `subscription_id` 时显示“取消月订阅续费”入口。
- 取消订阅入口调用 `POST /v1/direct/subscriptions/cancel`，后端再调用 Creem `POST /v1/subscriptions/{id}/cancel`。
- 默认取消参数是 `mode=scheduled`、`onExecute=cancel`，即预约在当前账期结束时取消，不立即撤销本期 Pro 权益。

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

- Creem Live Mode 已创建 Monthly、Yearly 和 Lifetime 产品。
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
