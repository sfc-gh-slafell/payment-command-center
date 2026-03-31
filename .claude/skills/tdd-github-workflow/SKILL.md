---
name: tdd-github-workflow
description: >
  Standard development workflow for this project using TDD red/green pattern
  with GitHub issue tracking. Use for every GitHub issue implementation: creating
  feature branches, writing failing tests first (red), implementing to pass (green),
  committing, opening PRs, tagging issues, commenting, running CI, merging, and
  closing issues. Triggers: implement issue, work on issue, start issue, TDD,
  red/green, feature branch workflow, PR workflow.
---

# TDD GitHub Workflow

Standard development lifecycle for every GitHub issue in this project.

## Workflow Steps

For each GitHub issue:

### 1. Feature Branch

```
git checkout -b issue-<N>/<short-kebab-description> main
```

Branch naming: `issue-<number>/<2-4 word kebab-case summary>`.

### 2. RED Phase — Write Failing Tests First

Before writing any implementation code:

1. Read the issue body and linked spec sections to understand acceptance criteria.
2. Write test assertions that validate the acceptance criteria. Place tests in `tests/`.
3. Run tests — confirm they **fail**. This is the RED state.

Test types by component:
- **Terraform**: `tests/validate_terraform.sh` — resource declarations, file assertions, `terraform validate`
- **Python**: `pytest` tests in `tests/`
- **Frontend**: Jest/Vitest tests in `app/frontend/src/__tests__/`
- **SQL/schemachange**: Compile-only validation via `snowflake_sql_execute` with `only_compile=true`
- **dbt**: `dbt compile` + `dbt test` against expected models

### 3. GREEN Phase — Implement to Pass

Write the minimum code to make all tests pass:

1. Implement deliverables listed in the issue.
2. Run tests after each file — confirm incremental progress.
3. Run full test suite — confirm **all pass**. This is the GREEN state.

### 4. Verify Acceptance Criteria

Before committing, verify every acceptance criterion checkbox from the issue:

```bash
gh issue view <N> --json body | jq -r '.body' | grep '\- \[' 
```

Manually confirm each criterion is satisfied by the implementation.

### 5. Commit

Stage and commit on the feature branch. Follow conventional commit style:

```bash
git add <relevant files>
git commit -m "$(cat <<'EOF'
feat(terraform): add database, schemas, and roles (#<N>)

<1-2 sentence description of what and why>

Closes #<N>

.... Generated with [Cortex Code](https://docs.snowflake.com/en/user-guide/cortex-code/cortex-code)

Co-Authored-By: Cortex Code <noreply@snowflake.com>
EOF
)"
```

Commit message conventions:
- `feat(scope)`: new feature or deliverable
- `fix(scope)`: bug fix
- `docs(scope)`: documentation only
- `ci(scope)`: CI/CD changes
- `refactor(scope)`: code restructuring without behavior change

### 6. Push and Create PR

```bash
git push -u origin issue-<N>/<branch-name>
gh pr create --title "<PR title>" --body "$(cat <<'EOF'
## Summary
<bullet points of what this PR delivers>

Closes #<N>

## Test plan
- [ ] Tests pass locally (red/green verified)
- [ ] terraform validate / pytest / dbt test succeeds
- [ ] Acceptance criteria from issue verified

.... Generated with [Cortex Code](https://docs.snowflake.com/en/user-guide/cortex-code/cortex-code)
EOF
)"
```

### 7. Comment on the Issue

Leave a comment on the GitHub issue summarizing work done:

```bash
gh issue comment <N> --body "$(cat <<'EOF'
## Implementation Complete

**Branch:** `issue-<N>/<name>`
**PR:** #<PR-number>

### What was done
<bullet list of deliverables>

### Tests
- All acceptance criteria verified
- TDD red/green cycle completed
- `terraform validate` / `pytest` / relevant test commands pass
EOF
)"
```

### 8. Comment on the PR

Add a review-ready comment on the PR with any context reviewers need.

### 9. CI/CD Checks

If GitHub Actions CI is configured (issues #26/#27), wait for checks to pass.
If no CI yet, local test passage is sufficient.

### 10. Merge and Close

```bash
gh pr merge <PR-number> --squash --delete-branch
```

If the PR body contains `Closes #<N>`, GitHub auto-closes the issue on merge.
Verify the issue is closed:

```bash
gh issue view <N> --json state
```

## Parallel Work

When issues have no dependencies, multiple feature branches can be worked simultaneously.
Always rebase on `main` before creating the PR if `main` has advanced.

## Key Rules

- Never commit directly to `main`.
- Every issue gets its own feature branch.
- Tests come before implementation (red before green).
- Every PR links to its issue with `Closes #<N>`.
- Every issue gets a completion comment before merge.
