.PHONY: help tf-plan tf-apply schema-deploy dbt-run gen-start app-build app-deploy connector-status connector-restart connectors-register fallback-start fallback-stop fallback-status demo-reset

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  %-16s %s\n", $$1, $$2}'

tf-plan: ## Run terraform plan
	cd terraform && terraform plan

tf-apply: ## Run terraform apply (run 'make connector-restart' if pipe definition changed)
	cd terraform && terraform apply

schema-deploy: ## Deploy schemachange migrations
	schemachange deploy -f schemachange/migrations --config-file-path schemachange/schemachange-config.yml

dbt-run: ## Run dbt models
	cd dbt && dbt run

gen-start: ## Start the event generator
	cd generator && python main.py

app-build: ## Build the dashboard application
	cd app/frontend && npm install && npm run build

app-deploy: ## Deploy the application to SPCS
	snow streamlit deploy --project spcs/

connector-status: ## Show V4 HP Kafka connector and task state
	xh GET http://localhost:8083/connectors/auth-events-sink-v4/status

connector-restart: ## Restart V4 HP connector task — required after any pipe change
	xh POST http://localhost:8083/connectors/auth-events-sink-v4/tasks/0/restart
	@sleep 5
	xh GET http://localhost:8083/connectors/auth-events-sink-v4/status

connectors-register: ## Register V4 HP connector (use after demo-reset)
	@echo "Registering V4 HP connector..."
	xh POST http://localhost:8083/connectors Content-Type:application/json < kafka-connect/shared.json
	@sleep 5
	xh GET http://localhost:8083/connectors/auth-events-sink-v4/status

demo-reset: ## Full reset: wipe Kafka + Snowflake tables, restart all services, re-register connectors
	@echo "Stopping all services..."
	docker-compose down
	@echo "Wiping Kafka data directory (clears disk-fill)..."
	rm -rf ./kafka-data
	@echo "Dropping Snowflake target tables (clears stale Snowpipe Streaming channel state)..."
	snow sql -q "DROP TABLE IF EXISTS PAYMENTS_DB.RAW.AUTH_EVENTS_RAW" --connection business_critical || true
	@echo "Starting fresh stack (kafka-init will create 48-partition topics)..."
	docker-compose up -d
	@echo "Waiting for Kafka Connect workers to be ready (~60s)..."
	@sleep 60
	@echo "Registering connectors..."
	$(MAKE) connectors-register

fallback-start: ## Start fallback relay (resilience demo — activate when V4 connector is down)
	docker-compose --profile fallback up -d fallback-relay

fallback-stop: ## Stop and remove the fallback relay container
	docker-compose stop fallback-relay && docker-compose rm -f fallback-relay

fallback-status: ## Show fallback relay container state and recent log tail
	docker ps --filter name=payments-fallback-relay --format "table {{.Names}}\t{{.Status}}"
	@docker logs payments-fallback-relay --tail 20 2>/dev/null || echo "(relay not running)"
