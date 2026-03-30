.PHONY: help tf-plan tf-apply schema-deploy dbt-run gen-start app-build app-deploy

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  %-16s %s\n", $$1, $$2}'

tf-plan: ## Run terraform plan
	cd terraform && terraform plan

tf-apply: ## Run terraform apply
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
