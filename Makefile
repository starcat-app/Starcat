# Starcat 开发期常用命令汇总。
#
# 用途：把日常排错 / 复位 / 启动用的几条裸 shell 命令固化下来，避免每次手敲；
#       同时让 path、目标名集中维护，新增子命令只需在本文件追加 target。
#
# 设计取舍：
# - 所有 target 都标 .PHONY —— 它们是「动作」而不是产物文件，避免与同名文件冲突。
# - APP_SUPPORT 走变量是因为「沙盒 Container 内的 Application Support」路径含空格，
#   shell 行内必须用双引号包变量；定义处不带引号（否则引号会被当成路径字符）。
# - 默认 target 设为 help，单独 `make` 时不会误触 destructive 操作。
#
# 跑测 / 单测命令仍按 AGENTS.md「如何跑单测」一节用 xcodebuild，
# 因为 IDE/CLI 抢 testmanagerd 的提示需要场景化判断，不适合做成一键。

# --- 路径常量 ---

# macOS 沙盒下 Starcat 的真实数据根。注意：不是 ~/Library/Application Support/，
# 而是 Containers/<bundle-id>/Data/... ——沙盒应用永远走 Container 视图。
APP_SUPPORT := $(HOME)/Library/Containers/com.starcat.app/Data/Library/Application Support/com.starcat.app

# Direct / 非 App Store Debug App 的数据根。当前 App Support 子目录由
# `AppConstants.bundleIdentifier` 决定，仍是 com.starcat.app。
DEBUG_APP_SUPPORT := $(HOME)/Library/Application Support/com.starcat.app

# 脚本入口参数。示例：
#   make build-dmg VERSION=0.1.0
#   make release VERSION=v0.1.0 RELEASE_FLAGS="--dry-run"
#   make linguist LINGUIST_ARGS="--local /tmp/languages.yml"
VERSION ?= 0.0.1
RELEASE_FLAGS ?=
LINGUIST_ARGS ?=

# --- 默认 target：不带参数跑 `make` 时显示帮助，避免误触 reset-db ---

.DEFAULT_GOAL := help

.PHONY: help run-appstore run-direct test reset-db reset-anysearch-cache reset-chat-cache reset-all show-data clean start-supports build-dmg release release-dry-run pr-helper bump-version linguist sync-fly-secrets setup-production-api-keys deploy-pages deploy-nginx

help: ## 列出所有可用命令
	@echo "Starcat 常用命令："
	@echo ""
	@echo "  make run-appstore           执行 scripts/run-debug-appstore.sh（App Store / 沙盒 Debug）"
	@echo "  make run-direct             执行 scripts/run-debug-direct.sh（Direct / 非 App Store Debug）"
	@echo "  make test                   跑全量单测（xcodegen + xcodebuild test）"
	@echo "  make build-dmg VERSION=0.1.0 打包 Release DMG（调用 scripts/build-dmg.sh）"
	@echo "  make release VERSION=v0.1.0  发版总入口：tag + DMG + push tag（调用 scripts/release.sh）"
	@echo "  make release-dry-run VERSION=v0.1.0  演练发版流程，不实际改动"
	@echo "  make pr-helper              PR 自动化：dev → main 创建/合并/清理（要求工作区干净）"
	@echo "  make bump-version           手动调试版本号脚本（正常由 Xcode build phase 调用）"
	@echo "  make linguist               生成 Linguist 语言元数据（可传 LINGUIST_ARGS）"
	@echo "  make reset-db               清空本地数据库（删除 users/ 目录下所有 sqlite，下次启动重建）"
	@echo "  make reset-anysearch-cache  清空 AnySearch 离线缓存（global / ai-summary 子目录）"
	@echo "  make reset-chat-cache       清空 AI 聊天历史（用户对话记录，不可恢复）"
	@echo "  make reset-all              聚合：reset-db + reset-anysearch-cache（故意不含 chat-cache）"
	@echo "  make show-data              在 Finder 中打开 App Store / Direct 两个 App Support 目录"
	@echo "  make clean                  删除 build/ 目录（清掉 xcodebuild 的 DerivedData 与产物）"
	@echo "  make start-supports         启动 supports/ 目录下的所有后端服务（trending / wiki / weekly / sharing / recommend / discovery）"
	@echo "  make sync-fly-secrets              从 supports 各 API .env 并行同步 secrets 到 Fly.io"
	@echo "  make setup-production-api-keys    从 supports 各 API .env 写入 Configs/Secrets.xcconfig（每服务独立 key）"
	@echo "  make deploy-pages                部署 pages/ 静态资源到 aliyun:/var/www/starcat/"
	@echo "  make deploy-nginx                上传 nginx 配置到 aliyun 并重载 nginx"
	@echo ""

run-appstore: ## App Store / 沙盒 Debug
	@bash scripts/run-debug-appstore.sh

run-direct: ## Direct / 非 App Store Debug
	@bash scripts/run-debug-direct.sh

test: ## 跑全量单测（先 xcodegen 同步项目，再 xcodebuild test）
	@echo "⚠️  提醒：跑测前请先关闭 Xcode IDE（Cmd+Q），否则会与 xcodebuild 抢 testmanagerd 导致挂起。"
	@echo "    详见 AGENTS.md「如何跑单测」一节。"
	@echo ""
	xcodegen generate
	xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' test

## 打包 Release DMG（VERSION=0.1.0）
build-dmg: 
	# 内部会跑 xcodegen + xcodebuild Release；脚本要求版本号为 X.Y.Z。
	@bash scripts/build-dmg.sh "$(VERSION)"

## 发版总入口（VERSION=v0.1.0 RELEASE_FLAGS="--skip-push"）
release: 
	# release.sh 会打本地 tag、构建 DMG，并按参数决定是否 push tag。
	# 这是发版动作，必须显式传 VERSION，避免误用默认 0.0.1 发版。
	@if [ "$(origin VERSION)" = "file" ]; then \
		echo "请显式传版本号，例如：make release VERSION=v0.1.0"; \
		exit 1; \
	fi
	@bash scripts/release.sh "$(VERSION)" $(RELEASE_FLAGS)

## 演练发版流程（VERSION=v0.1.0）
release-dry-run: 
	@if [ "$(origin VERSION)" = "file" ]; then \
		echo "请显式传版本号，例如：make release-dry-run VERSION=v0.1.0"; \
		exit 1; \
	fi
	@bash scripts/release.sh "$(VERSION)" --dry-run $(RELEASE_FLAGS)

pr-helper: ## PR 自动化脚本（要求 dev 分支 + 工作区干净）
	# 会推送 dev、创建 PR、尝试合并并清理远端 dev；运行前请确认当前分支与工作区状态。
	@bash scripts/pr-helper.sh

bump-version: ## 手动调试版本号脚本（正常由 Xcode build phase 调用）
	@bash scripts/bump-version.sh

linguist: ## 生成 Linguist 语言元数据（LINGUIST_ARGS="--local file.yml"）
	@python3 scripts/generate_linguist_metadata.py $(LINGUIST_ARGS)

show-data: ## 在 Finder 中打开沙盒 / 非沙盒两个 App Support 目录
	@open -R "$(APP_SUPPORT)/users"
	@open -R "$(DEBUG_APP_SUPPORT)/users"
	
reset-db: ## 清空所有本地数据库文件（destructive）
	@echo "即将删除：$(APP_SUPPORT)/users"
	@rm -rf "$(APP_SUPPORT)/users"
	@echo "已清空 users/ 目录，下次启动 Starcat 会按当前 V1 schema 重建。"

reset-anysearch-cache: ## 清空 AnySearch 离线缓存（destructive，但可重拉）
	# 真实写入位置见 `DiskAnySearchCache.rootURL()` —— Application Support/com.starcat.app/anysearch-cache/
	# 内部分 `global/<sha256[:2]>/<sha256>.json`（⌘K 弹层）+ `ai-summary/<repo-id>.json`（AI 摘要）两类。
	# 清掉后 cache miss 会重新走网络，仅影响响应时延 / AnySearch + AI 摘要 API 配额。
	@echo "即将删除：$(APP_SUPPORT)/anysearch-cache"
	@rm -rf "$(APP_SUPPORT)/anysearch-cache"
	@echo "已清空 anysearch-cache/，后续 ⌘K 搜索与 AI 摘要会按 cache miss 重新拉取。"

reset-chat-cache: ## 清空 AI 聊天历史（destructive，不可恢复）
	# 真实写入位置见 `DiskChatHistoryStore.rootURL()` —— Application Support/com.starcat.app/chat-history/
	# 结构：<owner>/<repo>/<sessionUUID>/{metadata.json, chunks/*.json}。
	# ⚠️ 这是用户与 AI 的真实对话历史，删了找不回来；reset-db 至少 starred 可重同步，这个不行。
	@echo "⚠️  即将删除：$(APP_SUPPORT)/chat-history"
	@echo "    这会清空所有 owner/repo 下的 AI 聊天记录，删除后无法恢复。"
	@rm -rf "$(APP_SUPPORT)/chat-history"
	@echo "已清空 chat-history/。"

reset-all: reset-db reset-anysearch-cache reset-chat-cache ## 聚合 reset-db + reset-anysearch-cache
	# 用 Make prerequisites 串行执行：上面两个 target 按声明顺序跑完后再进本 recipe。
	# 故意不带 reset-chat-cache —— 那是用户与 AI 的真实对话历史，"清掉所有缓存" 应该是
	# 安全动作；要清聊天记录请显式 `make reset-chat-cache`。
	@echo ""
	@echo "✅ 已聚合执行 reset-db + reset-anysearch-cache。"
	@echo "   AI 聊天历史（chat-history/）保留，如需清理请显式跑 make reset-chat-cache。"

clean: ## 删除 build/ 目录（清掉 xcodebuild 的 DerivedData 与产物）
	@echo "即将删除：$(CURDIR)/build"
	@rm -rf build
	@echo "已删除 build/，下次 make run-appstore 或 make run-direct 会重新跑 xcodegen + 全量构建。"

## 启动 supports/ 目录下的后端服务总入口
start-supports: ## 启动 supports/ 目录下的后端服务总入口
	# Make 每条 recipe 行独立 shell，cd 与执行必须在同一行用 && 串起来，
	# 否则 cd 在子 shell 退出后失效，./start-all.sh 会找不到。
	cd supports && ./start-all.sh

stop-supports: ## 停止 supports/ 目录下的后端服务总入口
	cd supports && ./start-all.sh --stop

sync-fly-secrets: ## 从 supports 各 API .env 同步 fly secrets
	@$(MAKE) -C supports fly-secrets-all

setup-production-api-keys: ## 从 supports 各 API .env 写入 Secrets.xcconfig（每服务独立 key）
	@bash scripts/sync-production-api-keys-from-env.sh

deploy-pages: ## 部署 pages/ 静态资源到 aliyun:/var/www/starcat/
	@cd pages && ./deploy.sh

deploy-nginx: ## 上传 nginx 配置到 aliyun 并重载 nginx
	@cd pages && ./deploy.sh -n
