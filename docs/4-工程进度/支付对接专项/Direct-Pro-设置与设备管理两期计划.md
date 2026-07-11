# Direct Pro 设置与设备管理两期计划

> 状态：计划确认中。本文只记录 Direct 版 Pro 设置、许可证通行证、设备管理和 Sparkle 更新入口的实施边界，不包含代码改动。

## 目标

Direct 版需要把 Pro 授权体验从“输入许可证 + 按钮操作”升级为更完整的产品化设置页：

- Pro 用户看到类似通行证的授权卡片，能确认当前授权状态、套餐、许可证尾号和设备额度。
- 单独的许可证入口支持查看许可证信息、管理当前 Mac，后续扩展为管理所有已激活设备。
- Sparkle 更新能力不只出现在顶部菜单，也出现在设置页和菜单栏图标右键菜单。
- 所有能力只出现在 `StarcatDirect`，不得进入 App Store 构建。

## 当前现状

### Direct / App Store 边界

- `StarcatDirect` target 独立于 App Store target，bundle id 为 `com.starcat.app.direct`。
- `StarcatDirect` 才链接 Sparkle；App Store target 不链接 Sparkle。
- `DistributionChannel` 通过 `STARCAT_DISTRIBUTION` 判断渠道，缺省回退 App Store，避免误暴露 Direct 能力。
- `DistributionGate` 已定义 `automaticUpdates` 和 `directLicense`，适合作为本需求的统一门控。

### Direct 许可证

- 客户端已有 `DirectLicenseManager`，负责激活、校验、解绑当前设备、创建 checkout、取消订阅。
- 本地安全存储已有 `licenseKey`、`instanceID`、`subscriptionID`、`customerID`、`productID`、`plan`。
- `DirectLicenseSnapshot` 已包含 `activationUsed`、`activationLimit`、`licenseKeySuffix`、`expiresAt`。
- 当前 Pro 设置页只是 Form 结构，包含购买入口、许可证输入、验证、解绑当前设备和取消订阅。
- `DirectLicenseAPI.customerPortal(_:)` 已存在，但设置页还没有入口暴露。

### 后端 License API

- `starcat-license-api` 目前提供：
  - `POST /v1/direct/licenses/activate`
  - `POST /v1/direct/licenses/validate`
  - `POST /v1/direct/licenses/deactivate`
  - `POST /v1/direct/customer-portal`
  - `POST /v1/direct/subscriptions/cancel`
- 后端当前可以解绑“当前本机保存的 `instanceID`”，但没有“列出所有设备 / 解绑指定设备”的 Starcat API。
- 后端 Creem provider 已能解析 Creem 返回的 `instance` 字段，但目前只把第一个 instance 映射为 `instanceID`，没有向客户端返回完整设备列表。

### Sparkle 更新

- `DirectUpdateController` 当前只暴露 `canCheckForUpdates` 和 `checkForUpdates(_:)`。
- 顶部菜单已在 Direct 版显示“检查更新”。
- 菜单栏图标右键菜单尚未显示“检查更新”。
- 设置页尚未显示自动检查更新、自动下载更新等开关。

## Creem 官方能力边界

Creem License Keys 支持：

- 为 product 启用 License Key Management，并设置 activation limit。
- 用户购买后获得唯一 license key，可在订单确认页、邮件和 customer portal 查看。
- `POST /v1/licenses/activate`：用 `key + instance_name` 激活新设备或实例，并返回 `instance.id`。
- `POST /v1/licenses/validate`：用 `key + instance_id` 校验授权状态。
- `POST /v1/licenses/deactivate`：用 `key + instance_id` 移除指定设备激活，并释放 activation slot。
- Customer Portal 可用于账单、订阅和许可证自助查看。

约束：

- Creem API Key 不能进客户端，仍必须由 `starcat-license-api` 转发。
- 客户端不能直接依赖 Creem 私有字段；需要后端标准化为 Starcat 自己的 DTO。
- 当前 Starcat 激活时传给 Creem 的 `deviceID` 默认是 bundle id，不适合作为用户可读设备名。设备管理正式上线前，需要改成稳定且可读的安装标识。

## 第一期：Direct 设置页产品化

目标：不等待完整设备列表能力，先把 Direct 版 Pro 设置页变成可用、可信、好理解的授权中心。

### 交付项

1. 重做 Direct Pro 区域
   - 在 `ProSettingsView` 中将 Direct 分支拆出独立子视图，例如 `DirectProSettingsView`。
   - 保留 App Store StoreKit 分支，避免两套 UI 互相污染。
   - Direct 版展示 Pro Pass 卡片：状态、套餐、许可证尾号、设备额度、到期时间、最近校验时间。

2. 授权操作收口
   - 未激活时展示购买入口和许可证输入。
   - 已激活时展示“验证授权”“解绑当前 Mac”“复制许可证尾号 / 查看授权信息”。
   - 解绑操作只处理当前 Mac，不伪装成完整设备管理。

3. Customer Portal 入口
   - 在 `DirectLicenseManager` 增加创建 customer portal URL 的方法。
   - 设置页提供“管理账单与订阅”入口。
   - 对缺少 `customerID` 的旧本机状态，优先提示重新从支付成功页激活或联系支持，不做猜测。

4. Sparkle 更新设置
   - 在 Direct 设置页增加更新区：
     - 检查更新
     - 自动检查更新
     - 自动下载 / 准备更新
   - `DirectUpdateController` 补充 Sparkle 设置读写封装。
   - 所有 Sparkle API 访问保持 `#if canImport(Sparkle)`，App Store 构建保持 no-op。

5. 菜单栏图标菜单
   - `StatusBarController` 右键菜单在 Direct 且 Sparkle 已配置时显示“检查更新”。
   - 禁用条件复用 `DirectUpdateController.canCheckForUpdates`。

### 验收标准

- App Store target 中不出现 Direct checkout、license 激活、Sparkle 更新设置入口。
- Direct Debug 指向 test License API；Direct Release 指向 live License API。
- 已激活 Direct 用户能在设置页看到授权状态、套餐、许可证尾号、设备额度。
- 未激活 Direct 用户能从设置页进入 checkout 或输入 license key 激活。
- “解绑当前 Mac”只清理当前本机实例，不影响文案中承诺的其他设备。
- 顶部菜单和菜单栏图标菜单都能触发 Sparkle 检查更新。

### 不做事项

- 不实现完整设备列表。
- 不实现解绑其他设备。
- 不改变 Creem 产品价格、seat 配置和 webhook 事件。
- 不修改 App Store 版 StoreKit 购买流程。

## 第二期：完整设备管理

目标：让 Direct 用户可以查看许可证下的所有激活设备，并解绑指定设备。

### 后端交付项

1. 增加标准化设备模型
   - 新增 `LicenseDevice` DTO，字段建议包含：
     - `instanceID`
     - `name`
     - `status`
     - `createdAt`
     - `isCurrentDevice`
   - `LicenseSnapshot` 保留汇总字段，同时可以返回 `devices`。

2. 增加设备列表接口
   - 新增 Starcat API，例如 `POST /v1/direct/licenses/devices`。
   - 请求使用 `licenseKey + instanceID` 或 `customerID` 做授权上下文。
   - 后端调用 Creem API 后标准化返回，不把 Creem 原始响应透给客户端。

3. 支持解绑指定设备
   - 现有 deactivate 已能接收 `licenseKey + instanceID`。
   - 需要补 UI 语义：如果解绑的是当前 Mac，客户端清理本地 credential；如果解绑其他设备，只刷新列表。

4. 改进设备命名
   - 激活时的 `instance_name` 改为用户可读但不暴露敏感硬件序列号的名称。
   - 建议格式：`<Mac 名称> · Starcat <短安装ID>`。
   - 安装 ID 存本地 Keychain 或应用支持目录；不要使用硬件序列号作为 license 身份。

### 客户端交付项

1. 新增设备列表模型和 API 方法
   - `DirectLicenseDevice`
   - `DirectLicenseDevicesResponse`
   - `DirectLicenseAPI.devices(...)`

2. 新增设备管理界面
   - 从 Pro Pass 或许可证详情进入。
   - 显示当前许可证 seat 使用量和设备列表。
   - 当前 Mac 明确标记。
   - 解绑其他设备前二次确认。

3. 状态刷新
   - 激活、验证、解绑后刷新 snapshot 和 devices。
   - 网络失败时保留当前本地 Pro 状态，但设备列表显示刷新失败提示。

### 验收标准

- 用户能看到当前许可证已激活的设备列表。
- 用户能解绑非当前 Mac，seat 数量随后更新。
- 用户解绑当前 Mac 后，本机 Direct Pro 状态被清理。
- Creem API Key 仍只存在后端。
- App Store 构建不包含设备管理入口。

## 风险与决策点

- **Creem instance 列表来源**：需要用测试许可证确认 validate / activate / customer licenses 哪个接口最稳定返回完整 instance 列表。
- **设备命名隐私**：不能上传硬件序列号；只使用用户可见 Mac 名称和随机安装 ID。
- **旧激活实例名称不可读**：当前已激活的实例名可能是 bundle id。因为还没有正式线上用户，可以在测试阶段删除旧测试激活或重新激活，不做历史兼容。
- **自动安装语义**：Sparkle 的 `automaticallyDownloadsUpdates` 更接近自动下载 / 准备更新，最终安装仍可能需要用户确认或重启；设置文案应避免承诺“完全静默安装”。

## 推荐执行顺序

1. 第一期 UI 与 Sparkle 设置入口。
2. 第一期 customer portal 入口。
3. Direct Debug 手动验证购买成功页 deep link、许可证激活、验证、解绑当前 Mac。
4. 第二期后端设备模型和列表接口。
5. 第二期客户端设备管理 sheet。
6. 测试环境完整验证后，再部署生产后端并打 Direct Release。

## 参考

- Creem License Keys: `https://docs.creem.io/features/addons/licenses`
- Creem validate license: `https://docs.creem.io/api-reference/endpoint/validate-license`
- Creem API full index: `https://docs.creem.io/llms-full.txt`
- Direct 双环境文档：`docs/6-发版与上架/Direct-测试与生产环境隔离.md`
- Creem 双环境文档：`docs/6-发版与上架/Creem-双环境配置.md`
