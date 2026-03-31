# Tests

This directory contains the test suites for the Payment Authorization Command Center.

## Test Types

| File | Type | Requires live services |
|------|------|------------------------|
| `test_scenario_indicator_backend.py` | Unit | No |
| `e2e_pipeline_test.py` | End-to-end integration | Yes |
| `validate_*.sh` | Shell validation | Varies |

---

## Running Unit Tests

Unit tests mock all external dependencies and run without live services:

```bash
# From project root
pytest tests/test_scenario_indicator_backend.py -v
```

---

## Running End-to-End Integration Tests

The e2e tests validate the full pipeline: Generator → Kafka → Snowpipe → Interactive Tables → Dashboard API.

### Prerequisites

All services must be running before executing e2e tests:

1. Event generator (`http://localhost:8000`)
2. Dashboard API backend (`http://localhost:3001` or your configured URL)
3. Snowflake connection with credentials configured
4. Kafka connector running and consuming from `payments.auth` topic

### Environment Variables

```bash
# Required for Snowflake checks
export SNOWFLAKE_ACCOUNT=sfpscogs-slafell-aws-2
export SNOWFLAKE_USER=SLAFELL
export SNOWFLAKE_PRIVATE_KEY_PATH=/path/to/rsa_key.p8
# OR: export SNOWFLAKE_PASSWORD=<password>

# Optional (shown with defaults)
export DASHBOARD_URL=http://localhost:3001
export GENERATOR_URL=http://localhost:8000
export SNOWFLAKE_DATABASE=PAYMENTS_DB
export SNOWFLAKE_WAREHOUSE=PAYMENTS_ADMIN_WH
```

### Running

```bash
# Run all e2e tests (marks services unavailable as skipped)
pytest tests/e2e_pipeline_test.py -v

# Run only the fast smoke tests (no Snowflake, no scenario injection)
pytest tests/e2e_pipeline_test.py::TestE2EPipeline::test_generator_produces_events -v
pytest tests/e2e_pipeline_test.py::TestE2EPipeline::test_dashboard_api_all_endpoints -v

# Run the full scenario injection test (~3-4 minutes due to IT refresh wait)
pytest tests/e2e_pipeline_test.py::TestE2EPipeline::test_scenario_injection_end_to_end -v -s
```

### Expected Output (all services running)

```
tests/e2e_pipeline_test.py::TestE2EPipeline::test_generator_produces_events PASSED
tests/e2e_pipeline_test.py::TestE2EPipeline::test_snowflake_ingest_active PASSED
tests/e2e_pipeline_test.py::TestE2EPipeline::test_interactive_table_refresh PASSED
tests/e2e_pipeline_test.py::TestE2EPipeline::test_scenario_injection_end_to_end PASSED
tests/e2e_pipeline_test.py::TestE2EPipeline::test_dashboard_api_all_endpoints PASSED

========== 5 passed in ~180s ==========
```

### Expected Output (services not running)

```
tests/e2e_pipeline_test.py::TestE2EPipeline::test_generator_produces_events SKIPPED
tests/e2e_pipeline_test.py::TestE2EPipeline::test_snowflake_ingest_active SKIPPED
...

========== 5 skipped ==========
```

---

## CI/CD Integration

E2e tests are tagged `@pytest.mark.e2e` and excluded from the standard PR CI run.

They run on:
- **Manual trigger** (`workflow_dispatch`) for pre-demo validation
- **Nightly schedule** against the pre-production environment

To run only non-e2e tests in CI:
```bash
pytest tests/ -v -m "not e2e"
```

To run e2e tests in CI (requires secrets):
```bash
pytest tests/ -v -m e2e
```

---

## Test Timing Reference

| Test | Approximate duration |
|------|---------------------|
| `test_generator_produces_events` | <1s |
| `test_dashboard_api_all_endpoints` | <5s |
| `test_snowflake_ingest_active` | 5-15s |
| `test_interactive_table_refresh` | 5-15s |
| `test_scenario_injection_end_to_end` | ~3-4 min |
