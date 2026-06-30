# =============================================================================
# supports/Makefile — 自建后端 API 的 Fly.io 运维快捷命令
# =============================================================================
#
# 前提：已安装 flyctl 并 `fly auth login`；各子项目目录下有填好的 .env。
# 环境变量说明见 docs/fly-io-环境变量.md
#
# 示例：
#   make fly-secrets-all          # 从各 API .env 同步 secrets 到 Fly
#   make fly-secrets-trending     # 只同步 trending
#   make fly-status-all           # 查看全部 App 状态 + healthz
#   make fly-deploy-all           # 部署全部 App（remote build）
#   make fly-backup-trending      # 拉取有状态服务 /data 卷到 supports/backups/
#   make fly-restore-trending LOCAL_DB=./starcat-trending-api/trending.db
# =============================================================================

APIS := sharing trending weekly wiki recommend discovery
STATEFUL_APIS := sharing trending weekly wiki discovery
FLY_APPS := $(foreach s,$(APIS),starcat-$(s)-api)
SCRIPTS := scripts
FLY_SECRETS_SYNC := bash $(SCRIPTS)/fly-secrets-sync.sh
FLY_BACKUP_DATA := bash $(SCRIPTS)/fly-backup-data.sh
FLY_RESTORE_DATA := bash $(SCRIPTS)/fly-restore-data.sh

.DEFAULT_GOAL := help

.PHONY: help fly-secrets-list fly-secrets-all fly-status-all fly-health-all fly-deploy-all
.PHONY: $(foreach s,$(APIS),fly-secrets-$(s) fly-deploy-$(s) fly-status-$(s))
.PHONY: $(foreach s,$(STATEFUL_APIS),fly-wipe-data-$(s) fly-backup-$(s) fly-restore-$(s))
.PHONY: fly-backup-all

help: ## 显示帮助
	@echo "supports/ Fly.io 运维命令："
	@echo ""
	@echo "  make fly-secrets-all        从各 API .env 并行同步 fly secrets"
	@echo "  make fly-secrets-trending   只同步 starcat-trending-api"
	@echo "  make fly-secrets-sharing    只同步 starcat-sharing-api"
	@echo "  make fly-secrets-weekly     只同步 starcat-weekly-api"
	@echo "  make fly-secrets-wiki       只同步 starcat-wiki-api"
	@echo "  make fly-secrets-recommend  只同步 starcat-recommend-api"
	@echo "  make fly-secrets-discovery  只同步 starcat-discovery-api"
	@echo "  make fly-secrets-list       列出全部 App 已配置的 secret 名称（不含值）"
	@echo "  make fly-status-all         fly status × 全部 App"
	@echo "  make fly-health-all         curl /healthz × 全部 App"
	@echo "  make fly-deploy-all         fly deploy --remote-only × 全部 App"
	@echo "  make fly-backup-all         备份有状态 App 的 /data → supports/backups/"
	@echo "  make fly-backup-trending    只备份 starcat-trending-api"
	@echo "  make fly-restore-trending   本地库/备份 tar 覆盖 Fly /data（需 LOCAL_DB 或 RESTORE_ARCHIVE）"
	@echo "  make fly-wipe-data-all      ⚠️  SSH 清空有状态 App 的 /data 卷（删库重建）"
	@echo ""
	@echo "  FLY_BACKUP_STOP=1 make fly-backup-trending   短暂停机后备份（SQLite 更一致）"
	@echo "  make fly-restore-trending LOCAL_DB=./starcat-trending-api/trending.db"
	@echo "  make fly-restore-trending RESTORE_ARCHIVE=supports/backups/.../data.tar.gz"
	@echo "  FLY_RESTORE_YES=1 make fly-restore-trending LOCAL_DB=...   跳过交互确认"
	@echo ""
	@echo "文档：docs/fly-io-环境变量.md"

# --- secrets 同步（从各项目 .env → fly secrets set）---

fly-secrets-all: ## 并行同步全部 App secrets
	@set -e; \
	pids=""; \
	for app in $(FLY_APPS); do \
		echo ">>> [parallel] $$app"; \
		$(FLY_SECRETS_SYNC) "$$app" & \
		pids="$$pids $$!"; \
	done; \
	fail=0; \
	for pid in $$pids; do \
		wait $$pid || fail=1; \
	done; \
	if [ $$fail -ne 0 ]; then \
		echo "✗ 部分 fly secrets 同步失败"; \
		exit 1; \
	fi; \
	echo "✓ 全部 fly secrets 同步完成"

fly-secrets-sharing: ## 同步 starcat-sharing-api secrets
	$(FLY_SECRETS_SYNC) starcat-sharing-api

fly-secrets-trending: ## 同步 starcat-trending-api secrets
	$(FLY_SECRETS_SYNC) starcat-trending-api

fly-secrets-weekly: ## 同步 starcat-weekly-api secrets
	$(FLY_SECRETS_SYNC) starcat-weekly-api

fly-secrets-wiki: ## 同步 starcat-wiki-api secrets
	$(FLY_SECRETS_SYNC) starcat-wiki-api

fly-secrets-recommend: ## 同步 starcat-recommend-api secrets
	$(FLY_SECRETS_SYNC) starcat-recommend-api

fly-secrets-discovery: ## 同步 starcat-discovery-api secrets
	$(FLY_SECRETS_SYNC) starcat-discovery-api

fly-secrets-list: ## 列出全部 App 的 secret 名称
	@for app in $(FLY_APPS); do \
		echo "=== $$app ==="; \
		fly secrets list -a "$$app" || true; \
		echo ""; \
	done

# --- 状态 / 健康检查 ---

fly-status-all: $(foreach s,$(APIS),fly-status-$(s)) ## 查看全部 App 状态

fly-status-sharing:
	@fly status -a starcat-sharing-api

fly-status-trending:
	@fly status -a starcat-trending-api

fly-status-weekly:
	@fly status -a starcat-weekly-api

fly-status-wiki:
	@fly status -a starcat-wiki-api

fly-status-recommend:
	@fly status -a starcat-recommend-api

fly-status-discovery:
	@fly status -a starcat-discovery-api

fly-health-all: ## curl 全部 App 的 /healthz
	@for app in $(FLY_APPS); do \
		printf '%s: ' "$$app"; \
		curl -fsS "https://$$app.fly.dev/healthz" && echo "ok" || echo "FAILED"; \
	done

# --- 部署 ---

fly-deploy-all: $(foreach s,$(APIS),fly-deploy-$(s)) ## 部署全部 App
	@echo "✓ 全部 deploy 完成"

fly-deploy-sharing:
	cd starcat-sharing-api && fly deploy --remote-only --ha=false

fly-deploy-trending:
	cd starcat-trending-api && fly deploy --remote-only --ha=false

fly-deploy-weekly:
	cd starcat-weekly-api && fly deploy --remote-only --ha=false

fly-deploy-wiki:
	cd starcat-wiki-api && fly deploy --remote-only --ha=false

fly-deploy-recommend:
	cd starcat-recommend-api && fly deploy --remote-only --ha=false

fly-deploy-discovery:
	cd starcat-discovery-api && fly deploy --remote-only --ha=false

# --- 备份持久化卷（/data → supports/backups/<app>/<timestamp>/）---

fly-backup-all: $(foreach s,$(STATEFUL_APIS),fly-backup-$(s)) ## 顺序备份有状态 App /data
	@echo "✓ 全部 backup 完成 → supports/backups/"

fly-backup-sharing:
	$(FLY_BACKUP_DATA) starcat-sharing-api

fly-backup-trending:
	$(FLY_BACKUP_DATA) starcat-trending-api

fly-backup-weekly:
	$(FLY_BACKUP_DATA) starcat-weekly-api

fly-backup-wiki:
	$(FLY_BACKUP_DATA) starcat-wiki-api

fly-backup-discovery:
	$(FLY_BACKUP_DATA) starcat-discovery-api

# --- 恢复持久化卷（本地 .db 或 backup tar → Fly /data）---

fly-restore-sharing:
	@test -n "$(LOCAL_DB)$(RESTORE_ARCHIVE)" || (echo "✗ 需要 LOCAL_DB= 或 RESTORE_ARCHIVE=" >&2; exit 1)
	$(FLY_RESTORE_DATA) starcat-sharing-api

fly-restore-trending:
	@test -n "$(LOCAL_DB)$(RESTORE_ARCHIVE)" || (echo "✗ 需要 LOCAL_DB= 或 RESTORE_ARCHIVE=" >&2; exit 1)
	$(FLY_RESTORE_DATA) starcat-trending-api

fly-restore-weekly:
	@test -n "$(LOCAL_DB)$(RESTORE_ARCHIVE)" || (echo "✗ 需要 LOCAL_DB= 或 RESTORE_ARCHIVE=" >&2; exit 1)
	$(FLY_RESTORE_DATA) starcat-weekly-api

fly-restore-wiki:
	@test -n "$(LOCAL_DB)$(RESTORE_ARCHIVE)" || (echo "✗ 需要 LOCAL_DB= 或 RESTORE_ARCHIVE=" >&2; exit 1)
	$(FLY_RESTORE_DATA) starcat-wiki-api

fly-restore-discovery:
	@test -n "$(LOCAL_DB)$(RESTORE_ARCHIVE)" || (echo "✗ 需要 LOCAL_DB= 或 RESTORE_ARCHIVE=" >&2; exit 1)
	$(FLY_RESTORE_DATA) starcat-discovery-api

# --- 危险操作：清空持久化卷（SQLite + weekly-repo）---

fly-wipe-data-all: $(foreach s,$(STATEFUL_APIS),fly-wipe-data-$(s)) ## ⚠️ 清空有状态 App /data
	@echo "✓ 全部 /data 已清空，请 fly machine restart 或等待自动重启"

fly-wipe-data-sharing:
	@$(MAKE) --no-print-directory _fly-wipe-data APP=starcat-sharing-api

fly-wipe-data-trending:
	@$(MAKE) --no-print-directory _fly-wipe-data APP=starcat-trending-api

fly-wipe-data-weekly:
	@$(MAKE) --no-print-directory _fly-wipe-data APP=starcat-weekly-api

fly-wipe-data-wiki:
	@$(MAKE) --no-print-directory _fly-wipe-data APP=starcat-wiki-api

fly-wipe-data-discovery:
	@$(MAKE) --no-print-directory _fly-wipe-data APP=starcat-discovery-api

_fly-wipe-data:
	@echo "⚠️  Wiping /data on $(APP) ..."
	@mid=$$(fly machine list -a "$(APP)" --json | python3 -c "import json,sys; m=json.load(sys.stdin); print(m[0]['id'] if m else '')"); \
	test -n "$$mid"; \
	state=$$(fly machine list -a "$(APP)" --json | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['state'])"); \
	if [ "$$state" != "started" ]; then fly machine start "$$mid" -a "$(APP)"; sleep 15; fi; \
	fly ssh console -a "$(APP)" -C "sh -c 'rm -rf /data/* /data/.[!.]* 2>/dev/null; ls -la /data'"; \
	fly machine restart "$$mid" -a "$(APP)"
