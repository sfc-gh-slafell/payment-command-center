---
name: spcs-docker-registry
description: Building and pushing Docker images to Snowflake SPCS image registries. Use this skill when writing Dockerfiles for SPCS deployment, configuring Docker push to Snowflake registry, debugging 401 Unauthorized errors on SPCS image push, or setting up CI/CD Docker build+push steps for Snowflake container services.
---

# SPCS Docker Registry

## Purpose

Encode the critical hostname mismatch gotcha and authentication patterns for pushing Docker images to Snowflake's SPCS image registry. This was the hardest failure to debug — it took 6 commits to resolve.

## Critical Rules

### The Hostname Underscore/Hyphen Gotcha

**This is the #1 cause of 401 Unauthorized errors when pushing to SPCS registries.**

Snowflake account identifiers may contain underscores (e.g., `slafell_aws_2`), but `snow spcs image-registry login` stores Docker credentials under a **hyphenated** key (e.g., `slafell-aws-2`).

When Docker pushes an image, it looks up credentials by the hostname in the image tag. If the tag uses underscores but credentials are stored under hyphens, Docker finds no matching credentials and falls back to anonymous auth → **401 Unauthorized**.

**Fix:** Always use the hyphenated form of the registry hostname:

```bash
# WRONG — underscores in hostname, won't match stored credentials
REGISTRY_HOST="sfpscogs-slafell_aws_2.registry.snowflakecomputing.com"

# CORRECT — hyphens match the credential key from snow CLI login
REGISTRY_HOST="sfpscogs-slafell-aws-2.registry.snowflakecomputing.com"
```

### Docker Login via Snow CLI

Always use `snow spcs image-registry login` instead of manual `docker login`:

```bash
# CORRECT — handles JWT token exchange automatically
snow spcs image-registry login --connection default

# WRONG — requires manual token management, fragile
echo "$TOKEN" | docker login "$REGISTRY" -u "$USER" --password-stdin
```

### Image Naming Convention

```
<registry-host>/<database>/<schema>/<repository>/<image>:<tag>

# Example:
sfpscogs-slafell-aws-2.registry.snowflakecomputing.com/payments_db/app/dashboard_repo/payment-command-center:latest
```

**Note:** Database/schema/repo names in the path keep their original case (typically uppercase in Snowflake). Only the registry hostname needs hyphen normalization.

### CI/CD Docker Push Pattern

```yaml
# DO NOT use docker/setup-buildx-action — it creates an isolated builder
# that can't access host credentials from snow spcs image-registry login
# - uses: docker/setup-buildx-action@v3  # ❌ WRONG

- name: Docker login to Snowflake registry
  run: snow spcs image-registry login --connection default

- name: Build and push
  env:
    REGISTRY_HOST: sfpscogs-slafell-aws-2.registry.snowflakecomputing.com  # HYPHENS
    IMAGE_TAG: ${{ github.sha }}
  run: |
    IMAGE="${REGISTRY_HOST}/payments_db/app/dashboard_repo/payment-command-center"
    docker buildx build \
      --platform linux/amd64 \
      --tag "${IMAGE}:${IMAGE_TAG}" \
      --tag "${IMAGE}:latest" \
      --push \
      -f app/Dockerfile app/
```

**Key points:**
- **Never use `docker/setup-buildx-action@v3`** — its isolated builder can't access host `~/.docker/config.json` credentials
- Use default Docker daemon builder (shares host credential store)
- Always specify `--platform linux/amd64` — SPCS only supports AMD64, not ARM
- Use `docker buildx build --push` (more reliable than separate build+push for SPCS)
- Always tag with both git SHA and `latest`
- Verify `REGISTRY_HOST` is non-empty before docker operations

### Connections Configuration for Snow CLI

```toml
# ~/.snowflake/connections.toml (chmod 0600!)
[default]
account = "ORG-ACCOUNT"
user = "SVC_USER"
authenticator = "SNOWFLAKE_JWT"
private_key_file = "/tmp/snowflake_key.p8"
```

## Common Pitfalls

1. **401 Unauthorized on push** — Registry hostname uses underscores instead of hyphens. The `snow spcs image-registry login` credential key uses hyphens.
2. **"Must provide --username"** — Using manual `docker login` with empty vars. Use `snow spcs image-registry login` instead.
3. **Empty REGISTRY_HOST** — Secret not set or not propagated to job. Always guard: `if: env.REGISTRY_HOST != ''`
4. **Wrong platform** — SPCS runs on `linux/amd64`. Always specify `--platform linux/amd64` in buildx. ARM images (from Apple Silicon) cause service to stuck in `PENDING` with "Readiness probe failing".
5. **Credential not found after login** — Docker config.json may have stale entries. Reset with `echo '{}' > ~/.docker/config.json` before login.
6. **Isolated buildx builder has no credentials** — `docker/setup-buildx-action@v3` creates a container builder that can't see host `~/.docker/config.json`. Don't use it — rely on default Docker daemon builder.

## Quick Reference

```bash
# Normalize hostname (replace underscores with hyphens)
REGISTRY_HOST=$(echo "$RAW_HOST" | tr '_' '-')

# Verify credentials are stored correctly
cat ~/.docker/config.json | jq '.auths | keys'

# Test registry connectivity
docker pull ${REGISTRY_HOST}/payments_db/app/dashboard_repo/payment-command-center:latest
```
