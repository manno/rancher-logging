# rancher-logging — SUSE BCI image rebuild experiment

This repo documents and supports a proof-of-concept for rebuilding the four
container images consumed by the Rancher `rancher-logging` 4.10 chart on a
[SUSE BCI](https://registry.suse.com/bci/bci-base) base, replacing the
upstream Alpine / Sumologic bundles.

The goal is a clean supply chain: no third-party pre-built gem/binary bundles,
images rooted in a SUSE-maintained base that receives continuous CVE fixes,
and an automated update pipeline so security patches land without human
intervention.

## Images

All images are published to [ghcr.io/manno](https://github.com/manno?tab=packages):

| Image | Fork | Tags |
|---|---|---|
| `ghcr.io/manno/logging-operator` | [manno/logging-operator](https://github.com/manno/logging-operator) | `dev-<sha>`, `latest` |
| `ghcr.io/manno/config-reloader` | [manno/config-reloader](https://github.com/manno/config-reloader) | `dev-<sha>`, `latest` |
| `ghcr.io/manno/fluent-bit` | [manno/fluent-bit](https://github.com/manno/fluent-bit) | `dev-<sha>`, `latest` (Alpine), `latest-suse` (SUSE BCI) |
| `ghcr.io/manno/fluentd` | [manno/fluentd](https://github.com/manno/fluentd) | `v1.16-4.10-{base,filters,full}` (Alpine), `v1.16-4.10-{base,filters,full}-suse` (SUSE BCI) |

All four GHCR namespaces are public — no auth needed to pull.

## Fork overview

Each fork tracks a single upstream at a pinned version. Security comes from
rebuilding with fresh base images and updated dependencies, not from
cherry-picking upstream code changes.

### [manno/logging-operator](https://github.com/manno/logging-operator) · [manno/config-reloader](https://github.com/manno/config-reloader)

Go binaries. Built with the latest Go toolchain on `bci/golang`, shipped
in `bci/bci-base`. Renovate handles Go module updates; a daily
`auto-update-bci.yaml` workflow rebuilds when a new BCI base image is
published.

### [manno/fluent-bit](https://github.com/manno/fluent-bit)

C/C++ binary. Built from source via the upstream CMake pipeline, on
`bci/bci-base` with SUSE packages for OpenSSL, SASL, libsystemd, etc.

### [manno/fluentd](https://github.com/manno/fluentd)

Ruby gem bundle — the most complex migration. The upstream image used a
Sumologic pre-built gem archive on Alpine. This fork builds all ~80 gems
(including native extensions) from source on `bci/bci-base`. The build
requires several libraries vendored from source that are not in the SLE_BCI
repo:

- **Legacy libGeoIP** (retired by MaxMind in 2018) — built from
  [`GeoIP-1.6.12`](https://github.com/maxmind/geoip-api-c/releases/tag/v1.6.12)
  for the `geoip-c` gem
- **libmaxminddb** — vendored by the `geoip2_c` gem itself via autotools;
  no system package needed

The SUSE pipeline runs in parallel with the existing Alpine pipeline on branch
[`bci-ruby-migration`](https://github.com/manno/fluentd/tree/bci-ruby-migration)
([PR #6](https://github.com/manno/fluentd/pull/6)).

## Automation

Each fork has the same automation stack:

| Layer | Mechanism | Purpose |
|---|---|---|
| Continuous | Renovate (`renovate.json5`) | Dependency bumps — vuln/patch auto-merge |
| Daily | `auto-update-go.yaml` / `auto-update-bci.yaml` | Rebuild when upstream Go or BCI base image is updated |
| CVE response | `cve-response.md` (agentic) | Called by an image-scanning repo via `gh workflow run` for long-tail CVEs |
| Weekly | `weekly-health-check.md` (agentic) | Audit Renovate flow, base freshness, bundler-audit |
| Push to `rancher-main` | `build.yaml` / `artifacts.yaml` | Multi-arch build + push to `ghcr.io/manno/*` |

## Testing

### Quick start with k3d

[`k3d-import.sh`](k3d-import.sh) pulls all four SUSE images from GHCR and
loads them into a running k3d cluster via `k3d image import`:

```bash
# prerequisites: docker, k3d, an existing cluster
k3d cluster create rancher-logging-test

./k3d-import.sh          # loads SUSE images into cluster 'k3s-default'
CLUSTER=rancher-logging-test ./k3d-import.sh   # specific cluster name
```

The script prints a ready-to-paste env-var block for the smoke test at the end.

**Other modes:**

```bash
VARIANT=alpine ./k3d-import.sh               # Alpine images instead
VARIANT=both   ./k3d-import.sh               # load both, for A/B comparison
TAG=dev-1ac7739f ./k3d-import.sh             # specific commit-sha tag

# Push to a k3d-managed registry instead of direct import:
K3D_REGISTRY=k3d-registry.localhost:5000 ./k3d-import.sh
```

### Smoke test

[`smoke-test-rancher-logging.sh`](smoke-test-rancher-logging.sh) installs the
upstream logging-operator Helm chart, deploys a `Logging` CR with the custom
images, and verifies that a sentinel log line flows end-to-end from a test pod
through fluent-bit → fluentd.

```bash
# After k3d-import.sh, use the printed env vars:
IMAGE_LOGGING_OPERATOR=ghcr.io/manno/logging-operator:latest \
  IMAGE_CONFIG_RELOADER=ghcr.io/manno/config-reloader:latest \
  IMAGE_FLUENT_BIT=ghcr.io/manno/fluent-bit:latest-suse \
  IMAGE_FLUENTD=ghcr.io/manno/fluentd:v1.16-4.10-full-suse \
  ./smoke-test-rancher-logging.sh
```

Parameterization:

| Variable | Default | Description |
|---|---|---|
| `IMAGE_LOGGING_OPERATOR` | `ghcr.io/manno/logging-operator:dev-1ac7739f` | Operator image |
| `IMAGE_CONFIG_RELOADER` | `ghcr.io/manno/config-reloader:dev-e7126dbf` | Config-reloader image |
| `IMAGE_FLUENT_BIT` | `ghcr.io/manno/fluent-bit:dev-1647f32fb` | Fluent-bit image |
| `IMAGE_FLUENTD` | `rancher/mirrored-kube-logging-fluentd:v1.16-4.10-full` | Fluentd image |
| `CHART_REF` | `oci://ghcr.io/kube-logging/helm-charts/logging-operator` | Helm chart OCI ref |
| `CHART_VERSION` | `4.10.0` | Chart version |
| `NAMESPACE` | `cattle-logging-system` | Target namespace |
| `SKIP_LOG_FLOW_TEST` | _(unset)_ | Set to `1` to skip end-to-end log-flow check |
| `KEEP` | _(unset)_ | Set to `1` to leave cluster state for debugging |

**Full SUSE example** — load images and run smoke test against k3d:

```bash
k3d cluster create rancher-logging-test
CLUSTER=rancher-logging-test ./k3d-import.sh
# copy the printed IMAGE_* vars, then:
IMAGE_LOGGING_OPERATOR=ghcr.io/manno/logging-operator:latest \
  IMAGE_CONFIG_RELOADER=ghcr.io/manno/config-reloader:latest \
  IMAGE_FLUENT_BIT=ghcr.io/manno/fluent-bit:latest-suse \
  IMAGE_FLUENTD=ghcr.io/manno/fluentd:v1.16-4.10-full-suse \
  ./smoke-test-rancher-logging.sh
```

## Status

| Image | SUSE build | Notes |
|---|---|---|
| logging-operator | ✅ | `rancher-main` branch, goreleaser + BCI |
| config-reloader | ✅ | `rancher-main` branch |
| fluent-bit | ✅ | `rancher-main` branch |
| fluentd | ✅ pipeline green | Alpine track still running in parallel; smoke test pending |
