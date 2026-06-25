#!/usr/bin/env bash
# k3d-import.sh — pull the four custom rancher-logging fork images from
# ghcr.io/manno/* and make them available inside a local k3d cluster, so
# the chart's smoke test can reference our builds without pulling over
# the internet on every pod start.
#
# Two modes:
#   1. Default: `k3d image import` — loads tarballs directly into every
#      node's containerd. No k3d-registry container required.
#   2. K3D_REGISTRY=k3d-registry.localhost:5000 (or similar): retag the
#      images for the local registry and push them. Use this if your
#      cluster already trusts a k3d-managed registry.
#
# Tag scheme (matches what each fork's CI publishes):
#   logging-operator   tag = $TAG                 (default: latest)
#   config-reloader    tag = $TAG                 (default: latest)
#   fluent-bit         tag = $TAG (alpine) or $TAG_FLUENT_BIT_SUSE (suse)
#   fluentd            tag = $FLUENTD_VERSION-{base,filters,full}[-suse]
#
# Usage examples:
#   ./k3d-import.sh                              # latest suse-variant set
#   VARIANT=alpine ./k3d-import.sh               # keep alpine for comparison
#   VARIANT=both ./k3d-import.sh                 # mirror both image sets
#   TAG=dev-1ac7739f ./k3d-import.sh             # specific commit-sha tag
#   K3D_REGISTRY=k3d-registry.localhost:5000 ./k3d-import.sh
#
# After import, paste the final block into your smoke-test invocation.

set -euo pipefail

CLUSTER=${CLUSTER:-k3s-default}
OWNER=${OWNER:-manno}
VARIANT=${VARIANT:-suse}                              # suse | alpine | both
TAG=${TAG:-latest}                                    # operator / config-reloader / fluent-bit (alpine)
TAG_FLUENT_BIT_SUSE=${TAG_FLUENT_BIT_SUSE:-latest-suse}
FLUENTD_VERSION=${FLUENTD_VERSION:-v1.16-4.10}
K3D_REGISTRY=${K3D_REGISTRY:-}                        # if set, push instead of import

if [[ ${1:-} == -h || ${1:-} == --help ]]; then
  sed -n '2,/^set -euo/p' "$0" | sed -e '/^set -euo/d' -e 's/^# \{0,1\}//'
  exit 0
fi

# --- Build the image list --------------------------------------------------
IMAGES=(
  "ghcr.io/${OWNER}/logging-operator:${TAG}"
  "ghcr.io/${OWNER}/config-reloader:${TAG}"
)

case $VARIANT in
  alpine) IMAGES+=("ghcr.io/${OWNER}/fluent-bit:${TAG}") ;;
  suse)   IMAGES+=("ghcr.io/${OWNER}/fluent-bit:${TAG_FLUENT_BIT_SUSE}") ;;
  both)   IMAGES+=("ghcr.io/${OWNER}/fluent-bit:${TAG}"
                   "ghcr.io/${OWNER}/fluent-bit:${TAG_FLUENT_BIT_SUSE}") ;;
  *) echo "VARIANT must be one of: suse alpine both (got: $VARIANT)" >&2; exit 1 ;;
esac

for stage in base filters full; do
  case $VARIANT in
    alpine) IMAGES+=("ghcr.io/${OWNER}/fluentd:${FLUENTD_VERSION}-${stage}") ;;
    suse)   IMAGES+=("ghcr.io/${OWNER}/fluentd:${FLUENTD_VERSION}-${stage}-suse") ;;
    both)   IMAGES+=("ghcr.io/${OWNER}/fluentd:${FLUENTD_VERSION}-${stage}"
                     "ghcr.io/${OWNER}/fluentd:${FLUENTD_VERSION}-${stage}-suse") ;;
  esac
done

# Helpers — pick the "primary" image of each role for the smoke-test hint
# at the end. With VARIANT=both we prefer the suse variant.
pick() {
  local needle=$1
  local result=""
  for img in "${IMAGES[@]}"; do
    [[ $img == *"/${needle}:"* ]] || continue
    result=$img
    [[ $img == *-suse* || $img == *-suse-* ]] && { echo "$img"; return; }
  done
  echo "$result"
}
# For fluentd we always want the `full` image in the smoke-test hint
# (it's the one the chart actually deploys).
pick_fluentd_full() {
  local result=""
  for img in "${IMAGES[@]}"; do
    [[ $img == *"/fluentd:${FLUENTD_VERSION}-full"* ]] || continue
    result=$img
    [[ $img == *-suse ]] && { echo "$img"; return; }
  done
  echo "$result"
}

# --- Sanity checks ---------------------------------------------------------
command -v docker >/dev/null || { echo "ERROR: docker not on PATH" >&2; exit 1; }
command -v k3d    >/dev/null || { echo "ERROR: k3d not on PATH"    >&2; exit 1; }

if [[ -z $K3D_REGISTRY ]]; then
  # `k3d image import` mode — cluster must exist.
  if ! k3d cluster list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$CLUSTER"; then
    echo "ERROR: k3d cluster '$CLUSTER' not found. Available clusters:" >&2
    k3d cluster list >&2
    exit 1
  fi
fi

# --- Pull --------------------------------------------------------------------
echo "==> Pulling ${#IMAGES[@]} image(s) from ghcr.io"
for img in "${IMAGES[@]}"; do
  printf '    %s\n' "$img"
  docker pull -q "$img" >/dev/null
done

# --- Import or push ----------------------------------------------------------
if [[ -n $K3D_REGISTRY ]]; then
  echo
  echo "==> Retagging and pushing to ${K3D_REGISTRY}"
  REWRITTEN=()
  for img in "${IMAGES[@]}"; do
    # ghcr.io/manno/fluentd:tag → k3d-registry.localhost:5000/manno/fluentd:tag
    new="${K3D_REGISTRY}/${img#ghcr.io/}"
    docker tag "$img" "$new"
    docker push -q "$new" >/dev/null
    printf '    %s\n' "$new"
    REWRITTEN+=("$new")
  done
  IMAGES=("${REWRITTEN[@]}")
else
  echo
  echo "==> Importing into k3d cluster '${CLUSTER}'"
  # --mode direct: load via `ctr image import` on each node. Faster than
  # the default tools-image path when you only have a handful of images.
  k3d image import "${IMAGES[@]}" --cluster "$CLUSTER" --mode direct
fi

# --- Smoke-test hint ---------------------------------------------------------
HINT_OP=$(pick logging-operator)
HINT_CR=$(pick config-reloader)
HINT_FB=$(pick fluent-bit)
HINT_FD=$(pick_fluentd_full)

cat <<EOF

==> Done. Run the rancher-logging smoke test against the imported images:

  IMAGE_LOGGING_OPERATOR=${HINT_OP} \\
    IMAGE_CONFIG_RELOADER=${HINT_CR} \\
    IMAGE_FLUENT_BIT=${HINT_FB} \\
    IMAGE_FLUENTD=${HINT_FD} \\
    ./dev-scripts/smoke-test-rancher-logging.sh

(Run that from your ob-team-charts checkout.)
EOF
