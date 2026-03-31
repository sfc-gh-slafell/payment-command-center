---
name: python-ruff-lint
description: Python linting with ruff for Snowflake-related projects (FastAPI backends, Kafka producers, data pipelines). Use this skill when writing Python code that will be checked by ruff in CI, debugging E402 (import not at top) or F401 (unused import) errors, configuring ruff for a project, or setting up pre-commit hooks for Python lint.
---

# Python Ruff Linting

## Purpose

Prevent ruff lint failures in CI by encoding the import patterns, common violations, and configuration needed for Python projects with FastAPI backends and data pipeline code.

## Critical Rules

### E402: Module-Level Import Not at Top of File

This fires when imports appear after non-import code (e.g., app initialization).

**The FastAPI Pattern Problem:**

```python
# TRIGGERS E402 — routes imported after app creation
from fastapi import FastAPI

app = FastAPI()

from routes.filters import router as filters_router    # E402
from routes.summary import router as summary_router    # E402
app.include_router(filters_router)
```

**Fix Option A: Move all imports to top (preferred)**

```python
from fastapi import FastAPI
from routes.filters import router as filters_router
from routes.summary import router as summary_router
from routes.timeseries import router as timeseries_router
from routes.breakdown import router as breakdown_router
from routes.events import router as events_router
from routes.latency import router as latency_router

app = FastAPI(lifespan=lifespan)

app.include_router(filters_router)
app.include_router(summary_router)
```

This works when route modules don't import `app` at module level (they shouldn't — they should define routers independently).

**Fix Option B: noqa annotation (when circular imports exist)**

```python
app = FastAPI(lifespan=lifespan)

# Routes must be imported after app creation to avoid circular imports
from routes.filters import router as filters_router  # noqa: E402
from routes.summary import router as summary_router  # noqa: E402
```

Only use this when there's a genuine circular dependency reason.

**Fix Option C: Per-file suppression in ruff config**

```toml
[tool.ruff.lint.per-file-ignores]
"app/backend/main.py" = ["E402"]
```

Use sparingly — only for entrypoint files with legitimate deferred imports.

### F401: Imported But Unused

**Never commit unused imports.** These are auto-fixable:

```bash
ruff check --fix  # Automatically removes unused imports
```

**Common violations in this project:**

| File | Unused Import | Action |
|---|---|---|
| `routes/filters.py` | `from fastapi import Depends` | Remove `Depends` — not using dependency injection |
| `snowflake_client.py` | `import json` | Remove — no JSON serialization in this module |
| `generator/main.py` | `from config import BOOTSTRAP_SERVERS` | Remove — only used in `producer.py` |

**Rule:** Only import what you use in THAT file. Don't import "just in case."

### Recommended ruff Configuration

```toml
# pyproject.toml
[tool.ruff]
target-version = "py311"
line-length = 120

[tool.ruff.lint]
select = [
    "E",   # pycodestyle errors
    "F",   # pyflakes
    "I",   # isort
    "UP",  # pyupgrade
]
ignore = []

[tool.ruff.lint.per-file-ignores]
# Only if entrypoint genuinely needs deferred imports
# "app/backend/main.py" = ["E402"]

[tool.ruff.lint.isort]
known-first-party = ["routes", "config", "producer", "scenarios"]
```

### CI Integration

```yaml
# .github/workflows/ci.yml
- name: Python Lint (ruff)
  run: ruff check generator/ fallback_ingest/ app/backend/
```

**Pre-commit hook (recommended):**

```yaml
# .pre-commit-config.yaml
repos:
  - repo: https://github.com/astral-sh/ruff-pre-commit
    rev: v0.8.0
    hooks:
      - id: ruff
        args: [--fix]
      - id: ruff-format
```

### Import Organization Pattern

Follow this order (enforced by `ruff lint --select I`):

```python
# 1. Standard library
import logging
import os
from contextlib import asynccontextmanager

# 2. Third-party
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles

# 3. Local/first-party
from routes.filters import router as filters_router
from routes.summary import router as summary_router
from snowflake_client import SnowflakeClient
```

Blank line between each group. No mixing.

## Common Pitfalls

1. **E402 in FastAPI main.py** — Move route imports to top of file. Routes should define `router = APIRouter()` independently, not import `app`.
2. **F401 unused imports** — Run `ruff check --fix` before committing. Set up pre-commit hook.
3. **Missing ruff config** — Without explicit config, ruff uses defaults which include E402 and F401. Either fix violations or configure ignores.
4. **CI fails but local passes** — Ensure local ruff version matches CI. Pin version in `requirements-dev.txt` or `pyproject.toml`.
5. **Redundant nested imports** — Don't `import json` inside a function if it's already imported at module level.

## Quick Reference

```bash
# Check for violations
ruff check generator/ fallback_ingest/ app/backend/

# Auto-fix what's fixable (F401, I001, etc.)
ruff check --fix generator/ fallback_ingest/ app/backend/

# Show specific rule explanation
ruff rule E402
ruff rule F401

# Format code
ruff format generator/ fallback_ingest/ app/backend/
```
