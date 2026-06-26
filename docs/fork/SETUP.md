# Trying Out (or Forking) the Rancher Logging SUSE POC

This doc is for colleagues who want to either:
- **Try the POC as-is** — spin up a cluster and run the smoke test
- **Start fresh, informed** — understand the choices made so you can replicate or improve them

For full context on what was built and why, read [STATE.md](STATE.md) first.

---

## The Forks

| Component | Repo | Branch | Image | Status |
|---|---|---|---|---|
| logging-operator | [manno/logging-operator](https://github.com/manno/logging-operator) | `rancher-main` | `ghcr.io/manno/logging-operator:dev-1ac7739f` | ✅ public |
| config-reloader | [manno/config-reloader](https://github.com/manno/config-reloader) | `rancher-main` | `ghcr.io/manno/config-reloader:dev-e7126dbf` | ⚠️ private |
| fluent-bit | [manno/fluent-bit](https://github.com/manno/fluent-bit) | `rancher-main` | `ghcr.io/manno/fluent-bit:dev-1647f32fb` | ⚠️ private |
| fluentd | [manno/fluentd](https://github.com/manno/fluentd) | `rancher-main` | upstream mirrored image | ⚠️ BCI migration deferred |

The chart fork is at [manno/ob-team-charts#1](https://github.com/manno/ob-team-charts/pull/1)
(branch `rancher-logging-4.10-suse1`), bumping the chart to `4.10.0-rancher.24-suse1` with the
three SUSE image refs above.

---

## Running the Smoke Test

The smoke test is at [`smoke-test-rancher-logging.sh`](../../smoke-test-rancher-logging.sh)
in the root of this repo.

It verifies: chart installs → operator Ready → Logging CR rolls out fluentbit DaemonSet +
fluentd StatefulSet → sentinel log line flows through fluentd stdout.

**Blocker**: `config-reloader` and `fluent-bit` GHCR packages are currently private. Before
running the test you need to either:
- Flip those repos public on GitHub (easiest for a POC cluster), or
- Create a `GHCR_USER/GHCR_TOKEN` secret and supply an `imagePullSecret` to the chart

---

## Key Choices (and Tradeoffs)

Each fork's `RANCHER.md` documents its specifics. The cross-cutting decisions:

**Goreleaser, not multi-stage Docker** — compile outside Docker with goreleaser, then `COPY`
into a minimal BCI image. Matches Rancher's existing build patterns; faster CI iteration.
The legacy multi-stage Dockerfile is kept as `Dockerfile.suse.multistage` for reference.

**`.go-version` + `go.mod toolchain`** — Go version stored in `.go-version` (read by
`actions/setup-go`) and mirrored into `go.mod`'s `toolchain` directive (auto-downloaded
locally). Necessary because `GITHUB_TOKEN` can't modify `.github/workflows/` files, so a
`GO_VERSION` env var in the workflow is not auto-updatable.

**Code frozen at upstream 4.10.0** — security comes from rebuilding with fresh
Go/BCI/gems, not from cherry-picking upstream changes. No breaking changes for users.

**Fluentd BCI migration done** — `Dockerfile.suse` on `rancher-main` builds via `artifacts-suse.yaml`, pushing `-suse` suffixed tags in parallel to the Alpine track. Once validated end-to-end, the Alpine Dockerfile can be retired.

---

## What's Still Missing

- Smoke test not yet run on a real cluster (pending making repos public / imagePullSecret)
- No versioned release tags yet (images are `dev-<sha>` pins)
- Chart asset not rendered (don't render on macOS; use the Docker-based charts-build-scripts)
- Build pipelines not yet wired to auto-open chart PRs on new image tags
- Production registry not decided (currently `ghcr.io/manno/`)
