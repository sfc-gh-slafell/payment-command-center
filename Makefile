.PHONY: help tf-plan tf-apply schema-deploy dbt-run gen-start app-build app-deploy connector-status connector-restart

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

connector-status: ## Show Kafka connector and task state
	xh GET http://localhost:8083/connectors/auth-events-sink-payments/status

connector-restart: ## Restart Kafka connector task — required after any pipe change
	xh POST http://localhost:8083/connectors/auth-events-sink-payments/tasks/0/restart
	@sleep 5
	xh GET http://localhost:8083/connectors/auth-events-sink-payments/status
