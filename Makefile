.PHONY: help tf-plan tf-apply schema-deploy dbt-run gen-start app-build app-deploy connector-status connector-restart connector-v3-status connector-v3-restart connectors-register demo-reset

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

connector-v3-status: ## Show V3 Kafka connector and task state
	xh GET http://localhost:8084/connectors/auth-events-sink-v3/status

connector-v3-restart: ## Restart V3 connector — required after buffer config changes
	xh DELETE http://localhost:8084/connectors/auth-events-sink-v3
	@sleep 2
	xh POST http://localhost:8084/connectors Content-Type:application/json < kafka-connect-v3/shared.json
	@sleep 5
	xh GET http://localhost:8084/connectors/auth-events-sink-v3/status

connectors-register: ## Register both V4 and V3 connectors (use after demo-reset)
	@echo "Registering V4 HP connector..."
	xh POST http://localhost:8083/connectors Content-Type:application/json < kafka-connect/shared.json
	@echo "Registering V3 Classic connector..."
	xh POST http://localhost:8084/connectors Content-Type:application/json < kafka-connect-v3/shared.json
	@sleep 5
	@echo "V4 status:"
	xh GET http://localhost:8083/connectors/auth-events-sink-v4/status
	@echo "V3 status:"
	xh GET http://localhost:8084/connectors/auth-events-sink-v3/status

demo-reset: ## Full reset: wipe Kafka + Snowflake tables, restart all services, re-register connectors
	@echo "Stopping all services..."
	docker-compose down
	@echo "Wiping Kafka data directory (clears disk-fill)..."
	rm -rf ./kafka-data
	@echo "Dropping Snowflake target tables (clears stale Snowpipe Streaming channel state)..."
	snow sql -q "DROP TABLE IF EXISTS PAYMENTS_DB.RAW.AUTH_EVENTS_RAW_V4" --connection business_critical || true
	snow sql -q "DROP TABLE IF EXISTS PAYMENTS_DB.RAW.AUTH_EVENTS_RAW_V3" --connection business_critical || true
	@echo "Starting fresh stack (kafka-init will create 48-partition topics)..."
	docker-compose up -d
	@echo "Waiting for Kafka Connect workers to be ready (~60s)..."
	@sleep 60
	@echo "Registering connectors..."
	$(MAKE) connectors-register
