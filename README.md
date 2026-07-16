# rancher-logging fork workspace

Local checkout grouping the four upstream repos that together produce the
images consumed by the Rancher `rancher-logging` 4.10 chart, plus the chart
repo that ships them.

## Layout

| Directory | Upstream | Fork | Role |
|---|---|---|---|
| [`logging-operator/`](https://github.com/manno/logging-operator) | `kube-logging/logging-operator` | `manno/logging-operator` (branch `rancher-main`) | Operator binary + SUSE image |
| [`config-reloader/`](https://github.com/manno/config-reloader/blob/rancher-main/RANCHER.md) | `kube-logging/config-reloader` | `manno/config-reloader` | Config-reloader sidecar SUSE image |
| [`fluent-bit/`](https://github.com/manno/fluent-bit/blob/rancher-main/RANCHER.md) | `fluent/fluent-bit` | `manno/fluent-bit` | Fluent-bit SUSE image |
| [`fluentd/`](https://github.com/manno/fluentd/blob/rancher-main/RANCHER.md) | `kube-logging/fluentd-images` | `manno/fluentd` (branch `rancher-main`, scope `v1.16-4.10/`) | Fluentd image — **SUSE pipeline green**, parallel to Alpine on branch `bci-ruby-migration` ([PR #6](https://github.com/manno/fluentd/pull/6)); awaiting smoke test |
| [`ob-team-charts/`](https://github.com/manno/ob-team-charts) | `rancher/ob-team-charts` | `manno/ob-team-charts` (branch `rancher-logging-4.10-suse1`) | Chart repo — consumes the four images above at `packages/rancher-logging/4.10/` |

The chart that consumes these images lives in a sibling checkout:
`../ob-team-charts/packages/rancher-logging/4.10/`.

## Design docs (`docs/fork/`)

Design and current-state docs for the fork POC live in
[`docs/fork/`](docs/fork/):

| Doc | What it is |
|---|---|
| [`docs/fork/SETUP.md`](docs/fork/SETUP.md) | **Try it out or fork it** — forks, smoke test, key choices, what's missing |
| [`docs/fork/STATE.md`](docs/fork/STATE.md) | **Current-state snapshot** — full detail for picking up the work cold |

## Status snapshot

- Code is **frozen at upstream 4.10.0**. Security comes from rebuilding with
  fresh Go / BCI / gems, not from cherry-picking upstream code.
- All 4 images now build on SUSE BCI. **Fluentd SUSE pipeline is green**
  on `bci-ruby-migration` ([PR #6](https://github.com/manno/fluentd/pull/6))
  in parallel with the Alpine track; next step is the smoke test
  against `ob-team-charts` — see [`fluentd/RANCHER.md`](https://github.com/manno/fluentd/blob/rancher-main/RANCHER.md).
  Alpine + Sumologic pipeline stays live (`v1.16-4.10-{base,filters,full}`)
  while the parallel SUSE pipeline iterates on
  `v1.16-4.10-{base,filters,full}-suse` tags.
- Image visibility on GHCR (as of latest smoke test): `logging-operator`
  public; `config-reloader` and `fluent-bit` still private.
- Chart bump landed in `ob-team-charts` as commit
  `656f38d bump rancher-logging to 4.10.0-rancher.24-suse1 with SUSE images`.

## Automation (shared shape across forks)

| Layer | Mechanism |
|---|---|
| Continuous | Renovate (`renovate.json5`) — Go modules / gems, vuln + patch auto-merge |
| Daily | `auto-update-go.yaml`, `auto-update-bci.yaml` (Go forks only) |
| Triggered | `.github/workflows/cve-response.md` — agentic CVE response, called by `image-scanning` repo via `gh workflow run` |
| Weekly | `.github/workflows/weekly-health-check.md` — agentic meta-monitor |
| Push to `rancher-main` | `build.yaml` (Go forks, goreleaser) / `artifacts.yaml` (fluentd) — multi-arch build + push to `ghcr.io/manno/*` |

Per-fork deviations are documented in each `RANCHER.md`. The largest deviation
is fluentd (no Go, no BCI auto-update, no goreleaser — see its RANCHER.md).

## Testing

Smoke test for the full image set against a live cluster:

- Script: `../ob-team-charts/dev-scripts/smoke-test-rancher-logging.sh`
  (branch `add-rancher-logging-smoke-test` of `manno/ob-team-charts`)
- Usage notes: `../ob-team-charts/dev/smoke-test-instructions.md`
  (local-only — `dev/` is gitignored)

The script installs the upstream operator chart, overrides each image via a
`Logging` CR, waits for fluent-bit + fluentd Ready, then verifies a sentinel
log line flows end-to-end. Parameterized for reuse in a release pipeline
(see the Actions snippet at the bottom of the instructions file).

Open gaps the smoke test does NOT cover:

- Rendering the rancher-modified chart from `packages/rancher-logging/4.10/`
  (uses the upstream chart + value overrides instead).
- The Windows nodeagent fluent-bit image (no SUSE Windows variant exists).
- The `fluentbit_debug` codepath (debug collapsed into the production image).

## References

- Per-fork details: [`logging-operator`](https://github.com/manno/logging-operator),
  [`config-reloader/RANCHER.md`](https://github.com/manno/config-reloader/blob/rancher-main/RANCHER.md),
  [`fluent-bit/RANCHER.md`](https://github.com/manno/fluent-bit/blob/rancher-main/RANCHER.md),
  [`fluentd/RANCHER.md`](https://github.com/manno/fluentd/blob/rancher-main/RANCHER.md)
- Design docs: [`docs/fork/`](docs/fork/) — start with
  [`STATE.md`](docs/fork/STATE.md) for the current snapshot,
  [`proposal.md`](docs/fork/proposal.md) for background
- Agentic workflow guide: `../ob-team-charts/docs/AGENTIC-WORKFLOWS-GUIDE.md`
- Upstream operator docs: <https://kube-logging.dev/>
