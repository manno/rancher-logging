# Rancher Logging Fork POC — Current State

> **Last updated**: 2026-06-03
> **Purpose**: Self-contained snapshot of the rancher-logging fork POC, intended for a fresh agent to continue the work without reading the conversation history.

## Mission

Build a system to replace upstream rancher-logging stack images with **Rancher-built SUSE images** that:

1. Keep application code **frozen at v4.10.0** (no breaking changes for Rancher users)
2. Get security fixes by **rebuilding** with fresh:
   - Go compiler (fixes Go stdlib CVEs)
   - SUSE BCI base image (fixes OS-level CVEs)
   - Go module dependencies (fixes dependency CVEs)
3. **Do NOT cherry-pick** code changes from upstream
4. Eventually replace `charts/rancher-logging` and `charts/rancher-logging-crd` with these images while preserving all `values.yaml` field names (no breaking changes for users)

**Components to fork** (4 total):
| Component | Language | Base Image | Status |
|---|---|---|---|
| logging-operator | Go | bci-micro | ✅ Pushed; builds green; multi-arch `:dev-<sha>` manifest published |
| config-reloader | Go | bci-micro | ✅ Pushed; builds green; multi-arch `:dev-<sha>` manifest published |
| fluent-bit | C | bci-base (all stages) | ✅ Pushed; builds green; multi-arch `:dev-<sha>` manifest published. Debug variant removed |
| fluentd | Ruby | Alpine + Sumo (BCI migration deferred) | ⚠️ Automation workflows only — no `build.yaml`. Image still upstream `mirrored-kube-logging-fluentd:v1.16-4.10-full` |

---

## Current State

### What's Done

**All 4 forks created in `manno/`** based on:
- `manno/logging-operator` (rancher-main from upstream `4.10.0`) — **public**
- `manno/config-reloader` (rancher-main from upstream `v0.0.7`) — private
- `manno/fluent-bit` (rancher-main from upstream `v3.1.8`) — private
- `manno/fluentd` (rancher-main from upstream `main` of `kube-logging/fluentd-images`) — private

**All three Go/C build pipelines now publish multi-arch images.** Each push to `rancher-main` produces a `:dev-<sha>` manifest list (amd64 + arm64) at `ghcr.io/manno/<repo>`. Verified tags as of last build:
- `ghcr.io/manno/logging-operator:dev-1ac7739f`
- `ghcr.io/manno/config-reloader:dev-e7126dbf`
- `ghcr.io/manno/fluent-bit:dev-1647f32fb`

**Chart-side draft PR exists** at [manno/ob-team-charts#1](https://github.com/manno/ob-team-charts/pull/1) on branch `rancher-logging-4.10-suse1`. Swaps the chart's default image refs to the three SUSE tags above and bumps the version to `4.10.0-rancher.24-suse1`. Not rendered yet.

**Smoke test script** at [`smoke-test-rancher-logging.sh`](https://github.com/manno/rancher-logging/blob/main/smoke-test-rancher-logging.sh) in this repo. Parameterized for release-pipeline reuse. Verifies: chart installs → operator Ready → Logging CR rolls out fluentbit DaemonSet + fluentd StatefulSet → sentinel log line flows through fluentd stdout.

### What's Pending

1. **Per-fork repo setup** still pending for `config-reloader`, `fluent-bit`, `fluentd` — labels, COPILOT_GITHUB_TOKEN, PR-creation permission (see "Repo Setup Requirements" below). logging-operator was set up early.
2. **Run the smoke test on a real cluster.** Mario plans to do this on a separate machine. Awaiting result before pushing the chart-side PR upstream.
3. **Render the chart asset** for the suse1 version. Don't render on macOS — see Known Issues. Either run charts-build-scripts in `ghcr.io/rancher/ci-image/charts` via Docker, or push to upstream and let CI render.
4. **Bind the build pipelines to the chart via dispatch events.** Each fork's `build.yaml` needs a `repository_dispatch` step that pings `ob-team-charts`. A receiver workflow in `ob-team-charts` updates the patch + version, runs `make charts`, opens a PR.
5. **Migrate fluentd to bci-ruby:3.3** — still deferred (Alpine + Sumo base kept). Largest remaining supply-chain risk: depends on Sumo's public ECR refresh cadence.
6. **Cut versioned release tags** (`v4.10.0-suse1` etc.) and replace `dev-<sha>` pins in the chart with versioned ones.
7. **Decide on production registry** (currently `ghcr.io/manno/`).
8. **Add an agentic workflow that reacts to open weekly-health-check issues.** The existing `weekly-health-check.md` workflow posts its report as an issue; a follow-up workflow should triage/respond to those (e.g., open PRs for actionable items, comment with diagnosis, close stale ones). Same `gh-aw` pattern as `cve-response.md` — slash-command or `workflow_dispatch` trigger, scoped permissions, safe-outputs for issue comments.

---

## Architecture Decisions (and Why)

### 1. Goreleaser pattern, NOT multi-stage Docker build

**Decision**: Compile binary outside Docker with goreleaser, then `COPY` into image.

**Why**: Matches Rancher's existing build patterns; faster CI iteration; better caching; reusable binaries across image variants.

**Files**: `.goreleaser.yaml`, `Dockerfile.suse` (just COPY), `scripts/build.sh` (uses goreleaser).

The legacy multi-stage Dockerfile is preserved as `Dockerfile.suse.multistage` for reference.

### 2. `.go-version` file + `go.mod` toolchain directive

**Decision**: Store Go compiler version in `.go-version` (read by `actions/setup-go`) AND bump `go.mod`'s `toolchain` directive (auto-downloaded by local Go 1.21+).

**Why**: GITHUB_TOKEN cannot modify files under `.github/workflows/` (security restriction). So `GO_VERSION` env var in workflow files is a non-starter for auto-update workflows. The two-file approach gives:
- CI gets the version via `actions/setup-go` reading `.go-version`
- Local devs get auto-download via Go's toolchain mechanism in go.mod
- Devs without Go 1.21+ also get help if they use `mise`/`asdf`/`gimme` (all read `.go-version`)

### 3. `gh cli` directly for PR creation, NOT `peter-evans/create-pull-request`

**Decision**: Use `gh pr create` / `gh pr edit` in workflow scripts.

**Why**: One less third-party dependency; idempotent (re-runs update existing PR via `gh pr edit`); standard tooling; visible in workflow logs.

**Pattern** (used in `auto-update-go.yaml`, `auto-update-bci.yaml`):
```bash
git checkout -B "${BRANCH}"
git add <files>
git commit -m "${TITLE}"
git push -f origin "${BRANCH}"

EXISTING=$(gh pr list --head "${BRANCH}" --json number --jq '.[0].number // empty')
if [ -n "${EXISTING}" ]; then
  gh pr edit "${EXISTING}" --title "${TITLE}" --body-file pr-body.md
else
  gh pr create --title "${TITLE}" --body-file pr-body.md \
    --base rancher-main --head "${BRANCH}" --label "..."
fi
```

### 4. Renovate for Go modules (auto-merge security/patches)

**Decision**: Use Renovate (`renovate.json5`) for Go module dependency updates. Auto-merge enabled for vulnerability alerts (any time) and patch updates. Minors grouped weekly. Majors require manual review.

**Why**: Renovate has better grouping, more flexible auto-merge, vulnerability alerts work with auto-merge. SUSE BCI excluded from Renovate (handled by `auto-update-bci.yaml` to avoid conflicts).

### 5. CVE response — Pattern A integration with image-scanning

**Decision**: Image-scanning team's repo triggers our `cve-response.md` workflow via `workflow_dispatch` with `issue_url` input. CVE issue stays in image-scanning repo (no mirror in our fork). Our workflow comments back on the source issue with the PR link.

**Trigger**:
```bash
gh workflow run cve-response \
  --repo manno/logging-operator \
  -f issue_url=https://github.com/<scanning-org>/<scanning-repo>/issues/<n>
```

**Why**: Cleaner debugging (visible in Actions UI), no issue duplication, single source of truth for CVE tracking lives with the security team.

### 6. Removed: `upstream-security-patch.md` workflow

**Decision**: Deleted. We do NOT cherry-pick from upstream.

**Why**: Upstream doesn't actively backport to 4.10.x. We maintain the frozen code version. Security comes from rebuilds, not code changes.

### 7. Forks are PRIVATE (except `manno/logging-operator`)

**Why**: Workflows reference internal Rancher infrastructure (image-scanning repo, eventual Vault secrets, prime registries). Public forks would leak this.

**Drift**: `manno/logging-operator` was flipped to public during the POC for easier ghcr testing. The other three (`config-reloader`, `fluent-bit`, `fluentd`) remain private. For the smoke test on a real cluster, either flip the other two public OR supply `GHCR_USER/GHCR_TOKEN` so the test creates an imagePullSecret.

### 8. Multi-arch manifest list via `imagetools create` (not single-buildx)

**Decision**: For `logging-operator` and `config-reloader` (which use goreleaser), build per-arch images in a loop (`:dev-<sha>-amd64`, `:dev-<sha>-arm64`), then compose a manifest list at the unsuffixed `:dev-<sha>` tag with `docker buildx imagetools create`.

**Why**: A single `docker buildx build --platform linux/amd64,linux/arm64` invocation would need the Dockerfile to be platform-aware (`ARG TARGETARCH`, COPY from per-platform binary paths) AND require corresponding changes to `.goreleaser.yaml` (which shares the Dockerfile). The `imagetools create` approach is purely a workflow change — Dockerfile and goreleaser untouched. The per-arch tags published as side effects are harmless.

**Files**: `.github/workflows/build.yaml` in `logging-operator` + `config-reloader`. `fluent-bit` uses `docker/build-push-action` with `platforms: linux/amd64,linux/arm64` directly — different code path because no goreleaser involved.

**Gotcha**: goreleaser v2 writes arm64 binaries to `dist/<name>_linux_arm64_v8.0/<name>` (note the `_v8.0` suffix — ARMv8 base version). The workflow's `[ -f $binary_path ]` guard previously silently skipped arm64 because the path lacked the suffix. The `imagetools create` step exposed the bug.

### 9. fluent-bit production stage uses `bci-base`, not `bci-minimal`

**Decision**: All three fluent-bit stages (`builder`, `production` — `debug` since removed) use `bci-base`.

**Why**: First build run failed with `zypper: command not found` in the production stage. `bci-minimal` ships rpm but NOT zypper (a comment in the original Dockerfile claiming otherwise was wrong). The fix is either:
- (a) Install runtime libs in the builder using `zypper --installroot /pkgroot` and COPY the rootfs into bci-minimal — proper SUSE pattern, keeps ~30 MB runtime
- (b) Switch production to bci-base — 1-line change, ~110 MB runtime (comparable to upstream `mirrored-fluent-fluent-bit`)

Chose (b) for POC velocity. Revisit (a) if image size becomes a concern.

### 10. Debug variant removed from fluent-bit

**Decision**: Deleted the `debug` stage from `Dockerfile.suse` and the matrix from `build.yaml`. The chart's `images.fluentbit_debug` field points at the same production image as `images.fluentbit`.

**Why**: The historical reason for a separate debug image was that upstream `fluent/fluent-bit:3.1.8` is distroless and can't be `kubectl exec`'d into usefully. Our production stage now runs on bci-base, which already provides bash, zypper, and a usable shell — debug variant is redundant. Don't reintroduce unless the production base ever goes back to something distroless.

Bonus side effect: the original debug stage's package list (`htop`, `tmux`, `mtr`, `vim`, `valgrind`, `ltrace`, `tcpdump`, `sysstat`) wouldn't resolve from bci-base's default repos — those packages live in SLE_BCI_extra. Removing the variant sidestepped that problem.

### 11. Chart-side work happens on a fork branch, not `rancher/ob-team-charts` main

**Decision**: Image-ref updates + version bumps land first on a branch of `manno/ob-team-charts`, opened as a draft PR for review. CI in the fork (which uses the same `ghcr.io/rancher/ci-image/charts` container as upstream) renders the chart asset.

**Why**: `charts-build-scripts` requires GNU `patch`, which macOS lacks (errors with "detected Apple/FreeBSD version of /usr/bin/patch"). Rather than install brew packages, render via the ci-image — either Docker locally or via PR CI. Once verified, the change can be PR'd to upstream `rancher/ob-team-charts`.

---

## File Inventory: `manno/logging-operator`

### Created files (POC)

```
.go-version                              # Go compiler version (1.26)
.goreleaser.yaml                         # Multi-arch builds + Docker
.gitattributes                           # Marks *.lock.yml as generated
.gitignore                               # Ignores .envrc, dist/, etc.
Dockerfile.suse                          # Simple COPY of pre-built binary
Dockerfile.suse.multistage               # Legacy reference
RANCHER.md                               # Documentation for the fork
renovate.json5                           # Renovate config (auto-merge security)
scripts/build.sh                         # Local build using goreleaser

.github/agents/agentic-workflows.agent.md   # gh-aw agent config
.github/aw/actions-lock.json                # gh-aw pinned action SHAs
.github/workflows/
├── README.md                            # Workflow documentation
├── build.yaml                           # Build + push (push/PR/tag)
├── auto-update-go.yaml                  # Daily Go compiler check + PR
├── auto-update-bci.yaml                 # Daily SUSE BCI digest check + PR
├── cve-response.md                      # Agentic: CVE response (slash + workflow_dispatch)
├── cve-response.lock.yml                # Generated by `gh aw compile`
├── weekly-health-check.md               # Agentic: weekly status report
└── weekly-health-check.lock.yml         # Generated by `gh aw compile`
```

### Modified
- `go.mod` — `toolchain` directive bumped alongside `.go-version` updates

### Pre-existing (untouched from upstream)
- `main.go` (in repo root, NOT `cmd/manager/main.go` as docs suggest!)
- `config/crd/` — CRDs
- All other application code (frozen)

---

## Repo Setup Requirements (Per Fork)

A fresh agent setting up a new fork must do ALL of these or workflows will fail.
Apply per fork (config-reloader, fluent-bit, fluentd; logging-operator already done).

### 1. Allow Actions to create PRs
```bash
gh api -X PUT repos/manno/<fork>/actions/permissions/workflow \
  -f default_workflow_permissions=write \
  -F can_approve_pull_requests=true
```

### 2. Enable issues on the repo (required for safe-outputs.create-issue)
```bash
gh api -X PATCH repos/manno/<fork> -F has_issues=true
```
**Why**: `weekly-health-check.md` posts its report as an issue. Without this,
the workflow run succeeds but the safe-output handler hits 410 (Issues disabled).

### 3. Create labels (workflows use `--label` and fail if missing)

Full label set used by the agentic + cron workflows across all forks:

```bash
LABELS=(
  # Cron + Renovate bots
  dependencies automated
  go-update suse-bci-update gem-update
  # Agentic CVE response
  security cve-fix cve-tracking agentic needs-review
  needs-api-migration verification-failed
  temporary-replace temporary-fork breaking-change
  bot-fallback zypper-pin needs-investigation
  ruby-abi-risk sumo-base-bump bundle-install-failed
  # Renovate vuln auto-merge
  vulnerability
  # Weekly health check
  weekly-health-check
  # GitHub Actions updates (Renovate)
  ci github-actions
  # Ruby-specific (fluentd)
  ruby
)
for label in "${LABELS[@]}"; do
  gh label create "$label" --repo manno/<fork> 2>/dev/null || true
done
```

Most forks won't need every label — but creating the superset is harmless,
and the workflows will fail noisily if any expected label is missing.

### 4. Set Copilot token (for agentic workflows)
- Create a fine-grained PAT at https://github.com/settings/personal-access-tokens/new
- Required scope: **Copilot Requests: Read and write**
- Set it: `gh aw secrets set COPILOT_GITHUB_TOKEN --owner manno --repo <fork>`

### 5. Verify all required secrets
```bash
gh aw secrets bootstrap --engine copilot --non-interactive --repo manno/<fork>
```

---

## Known Issues / Things to Fix

### High priority
1. **`weekly-health-check.md` checks irrelevant metrics** — issue counts, stale issues. We don't use issues here. Should focus on: build status, open auto-update PRs (Renovate, Go, BCI), dependency freshness, vulnerable Go modules. The whole "Issue Health" section should be removed/replaced.
2. **fluent-bit build takes ~90 min** — QEMU emulation for arm64 cross-compile is slow. cmake builds the bundled jemalloc + backtrace subprojects, plus fluent-bit itself. No easy fix without native arm64 runners (GitHub offers them on paid plans). Caches help on rebuilds but the first build of each cache-invalidating commit is painful.

### Medium priority
3. **fluentd fork has no `build.yaml`** — still automation only. Migration to bci-ruby blocked on Sumo base decision (see Decision #4).
4. **Image registry decision** — currently `ghcr.io/manno/`. Production probably wants `rancher/` (DockerHub) or multi-registry per `docs/logging/fork/agentic-workflows.md`.
5. **`config-reloader` + `fluent-bit` are still private on ghcr** — blocks real-cluster testing without imagePullSecret. Easiest: flip public for the POC.
6. **`:latest` manifest in fluent-bit's `.goreleaser.yaml`** is amd64-only (lines around `name_template: ".../:latest"`). `:Tag-suse1` works correctly. Only matters for the goreleaser release path; the dev-<sha> workflow path is unaffected.

### Low priority
7. **Tag scheme** — `dev-<sha>` for branch builds is now verified working. Versioned `<tag>-suse1` for releases still untested (no release tag cut yet).

---

## Chart Integration (In Progress)

Image-ref updates land on `manno/ob-team-charts` branch `rancher-logging-4.10-suse1` (draft PR #1). State as of 2026-06-03:

| field | new value | status |
|---|---|---|
| `image` (logging-operator) | `ghcr.io/manno/logging-operator:dev-1ac7739f` | ✅ in patch |
| `images.config_reloader` | `ghcr.io/manno/config-reloader:dev-e7126dbf` | ✅ in patch |
| `images.fluentbit` | `ghcr.io/manno/fluent-bit:dev-1647f32fb` | ✅ in patch |
| `images.fluentbit_debug` | `ghcr.io/manno/fluent-bit:dev-1647f32fb` | ✅ in patch (same as fluentbit; debug variant dropped) |
| `images.fluentd` | unchanged (upstream mirror) | ⏭️ fluentd SUSE rebuild deferred |
| `images.nodeagent_fluentbit` | unchanged | ⏭️ Windows; no SUSE alternative |
| chart version | `4.10.0-rancher.23` → `4.10.0-rancher.24-suse1` | ✅ in package.yaml |

**Not done yet**:
- Chart asset not rendered. Render via `ghcr.io/rancher/ci-image/charts` in Docker, OR push branch upstream and let CI render. Don't render on macOS — see Known Issues / Decision #11.
- Smoke test on a real cluster (`ob-team-charts/dev-scripts/smoke-test-rancher-logging.sh`).
- After verification, PR the branch to upstream `rancher/ob-team-charts`.

**Backward compatibility**: Field NAMES stay identical (`image.repository`, `images.fluentbit.repository`, etc.). Only default VALUES change. User overrides continue to work.

**Windows `nodeagent_fluentbit`**: SUSE BCI is Linux-only. Kept on the existing Windows image; no SUSE variant planned.

**Tag-bumping later**: Once we cut versioned releases on the forks (`v4.10.0-suse1` etc.), the `dev-<sha>` pins above get replaced with the versioned tags. Same shape, different values.

---

## Map of Existing Docs (Stale-ness Check)

| File | Status | Notes |
|---|---|---|
| `STATE.md` (this file) | ✅ Current | Source of truth |
| `README.md` | ⚠️ Mostly stale | Points to `poc.md` which is stale; component table is fine |
| `poc.md` | ❌ STALE | Multi-stage Dockerfile (we use goreleaser); peter-evans (we use gh cli); env-var GO_VERSION (we use .go-version); old gh-aw schema |
| `proposal.md` | ⚠️ Partial | Strategy correct; tactics wrong |
| `implementation-guide.md` | ⚠️ Partial | Same issue — high-level OK, low-level details wrong |
| `agentic-workflows.md` | ⚠️ Partial | Concepts correct; schema is old (max-operations not max, pull-requests not pull_requests, etc.) |
| `agentic-real-examples.md` | ✅ Reference | External examples, not our code |
| `../../../docs/AGENTIC-WORKFLOWS-GUIDE.md` | ❌ STALE | Schema mismatch — see "gh-aw Schema Changes" below |

---

## gh-aw Schema Changes (v0.72.1)

The `AGENTIC-WORKFLOWS-GUIDE.md` docs predate the current schema. Differences a fresh agent will hit:

| Old | New |
|---|---|
| `max-operations: 1` | `max: 1` |
| `pull-requests` (in `tools.github.toolsets`) | `pull_requests` (underscores) |
| `bash: true` | `bash: ["git:*", "gh:*", ...]` (allowlist) |
| `web-fetch: true` | `web-fetch:` (just declare, no value) |
| `permissions: read-all` | Granular: `permissions:\n  contents: read\n  ...` |
| `tools.github.lockdown:` | Removed |
| `${{ github.event.comment.body }}` in prompt | NOT in allowed expression list (security). Fetch via tools instead. |
| Fixed cron `'57 6 * * 1'` | Prefer `schedule: weekly on monday` (fuzzy, distributes load) |

**Always use latest action versions** (verify with `gh api repos/<owner>/<repo>/releases/latest`):
- `actions/checkout@v6` (was v4/v5)
- `actions/setup-go@v6`
- `docker/setup-qemu-action@v4`
- `docker/setup-buildx-action@v4`
- `docker/login-action@v4`
- `goreleaser/goreleaser-action@v7`

---

## Useful Commands (Cheat Sheet)

```bash
# Compile agentic workflows (run after .md changes)
gh aw compile .github/workflows/

# Verify secrets are set
gh aw secrets bootstrap --engine copilot --non-interactive --repo manno/<fork>

# Trigger workflow manually
gh workflow run <name> --repo manno/<fork> --ref rancher-main

# Watch a run
gh run watch <run-id> --repo manno/<fork>

# Get failure logs
gh run view <run-id> --repo manno/<fork> --log-failed

# Check repo settings (PR creation)
gh api repos/manno/<fork>/actions/permissions/workflow

# Trigger CVE response from image-scanning context
gh workflow run cve-response \
  --repo manno/logging-operator \
  -f issue_url=https://github.com/<owner>/<repo>/issues/<n>
```

---

## Key Files in `ob-team-charts` (this repo)

- `packages/rancher-logging/4.10/package.yaml` — Source chart URL + version
- `packages/rancher-logging/4.10/generated-changes/patch/values.yaml.patch` — Image overrides (this is what gets updated for SUSE migration)
- `charts/rancher-logging/<version>/` — Generated chart output
- `charts/rancher-logging-crd/<version>/` — Generated CRD chart
- `.github/workflows/push/` — Scripts that push from ob-team-charts → rancher/charts

---

## What a Fresh Agent Should Do First

1. **Read this file.** Skip the other docs in `docs/logging/fork/` for now (they're stale).
2. **Check current state of forks**: `gh repo list manno --fork` and `gh run list --repo manno/logging-operator`
3. **Verify the logging-operator workflows still work** before replicating to other forks
4. **Pick the next task** from "What's Pending" above
5. **Don't trust the old docs** — verify schema/syntax with `gh aw new` and `gh aw compile`

If working on the other 3 forks, the logging-operator workflows are the reference. Adapt:
- **config-reloader**: identical pattern (Go + bci-micro)
- **fluent-bit**: replace goreleaser with Make/CMake build, use bci-minimal, add debug variant
- **fluentd**: replace goreleaser with bundler/Ruby build, use bci-ruby:3.3
