#!/usr/bin/env bash
# Smoke test for rancher-logging with SUSE-rebuilt images.
#
# Assumes a Kubernetes cluster is reachable via $KUBECONFIG / current context.
# Does NOT create or destroy the cluster.
#
# What it verifies:
#   1. logging-operator chart installs and operator Deployment becomes Ready
#   2. A Logging CR rolls out a fluentbit DaemonSet that becomes Ready
#   3. A Logging CR rolls out a fluentd StatefulSet that becomes Ready
#   4. (default) Logs from a test pod flow through fluentbit -> fluentd and
#      a unique sentinel string appears in fluentd's stdout. Skipped with
#      SKIP_LOG_FLOW_TEST=1.
#
# Exit code 0 = all checks pass. Non-zero = a check failed; the script prints
# the failed pod / resource state and (unless KEEP=1) cleans up.
#
# Parameterized for use in a release pipeline. Override any of:
#   NAMESPACE              (default: cattle-logging-system)
#   RELEASE_NAME           (default: rancher-logging-smoke)
#   CHART_REF              (default: oci://ghcr.io/kube-logging/helm-charts/logging-operator)
#   CHART_VERSION          (default: 4.10.0)
#   IMAGE_LOGGING_OPERATOR (default: ghcr.io/manno/logging-operator:dev-1ac7739f)
#   IMAGE_CONFIG_RELOADER  (default: ghcr.io/manno/config-reloader:dev-e7126dbf)
#   IMAGE_FLUENT_BIT       (default: ghcr.io/manno/fluent-bit:dev-1647f32fb)
#   IMAGE_FLUENTD          (default: rancher/mirrored-kube-logging-fluentd:v1.16-4.10-full)
#   TIMEOUT_OPERATOR       (default: 180s)
#   TIMEOUT_FLUENT_BIT     (default: 180s)
#   TIMEOUT_FLUENTD        (default: 300s)
#   TIMEOUT_LOG_FLOW       (default: 180s)
#
#   GHCR_USER / GHCR_TOKEN optional. If both set, creates an imagePullSecret
#                          in $NAMESPACE so private ghcr.io/manno/* images can
#                          be pulled.
#   KEEP=1                 don't tear down on exit (for debugging)
#   SKIP_LOG_FLOW_TEST=1   skip the end-to-end log-flow check (faster)

set -euo pipefail

# ---- defaults ---------------------------------------------------------------

: "${NAMESPACE:=cattle-logging-system}"
: "${RELEASE_NAME:=rancher-logging-smoke}"
: "${CHART_REF:=oci://ghcr.io/kube-logging/helm-charts/logging-operator}"
: "${CHART_VERSION:=4.10.0}"
: "${IMAGE_LOGGING_OPERATOR:=ghcr.io/manno/logging-operator:dev-1ac7739f}"
: "${IMAGE_CONFIG_RELOADER:=ghcr.io/manno/config-reloader:dev-e7126dbf}"
: "${IMAGE_FLUENT_BIT:=ghcr.io/manno/fluent-bit:dev-1647f32fb}"
: "${IMAGE_FLUENTD:=rancher/mirrored-kube-logging-fluentd:v1.16-4.10-full}"
: "${TIMEOUT_OPERATOR:=180s}"
: "${TIMEOUT_FLUENT_BIT:=180s}"
: "${TIMEOUT_FLUENTD:=300s}"
: "${TIMEOUT_LOG_FLOW:=180s}"
: "${KEEP:=}"
: "${SKIP_LOG_FLOW_TEST:=}"

LOGGING_CR_NAME="smoke-test-logging"
TEST_POD_NAME="smoke-test-log-generator"
SENTINEL="smoke-test-sentinel-$RANDOM-$$"

# ---- helpers ----------------------------------------------------------------

log()  { printf "\033[34m[smoke]\033[0m %s\n" "$*"; }
ok()   { printf "\033[32m[ ok ]\033[0m %s\n" "$*"; }
fail() { printf "\033[31m[fail]\033[0m %s\n" "$*" >&2; }

split_image() {
  # "repo/path:tag" -> "repo/path" "tag"
  local img="$1"
  printf "%s %s\n" "${img%:*}" "${img##*:}"
}

dump_state() {
  log "Dumping namespace state for debugging:"
  kubectl -n "$NAMESPACE" get all,logging,clusterflow,clusteroutput 2>/dev/null || true
  log "Recent events:"
  kubectl -n "$NAMESPACE" get events --sort-by=.lastTimestamp 2>/dev/null \
    | tail -25 || true
  log "Non-ready pods (describe):"
  kubectl -n "$NAMESPACE" get pods -o json 2>/dev/null \
    | jq -r '.items[] | select(.status.phase != "Running" or
        ([.status.containerStatuses // [] | .[] | .ready] | all | not))
        | .metadata.name' \
    | while read -r pod; do
        [ -z "$pod" ] && continue
        kubectl -n "$NAMESPACE" describe pod "$pod" 2>/dev/null | tail -40
      done || true
}

cleanup() {
  local exit_code=$?
  if [ "$exit_code" -ne 0 ]; then
    fail "Smoke test FAILED (exit $exit_code)"
    dump_state
  fi
  if [ -n "$KEEP" ]; then
    log "KEEP=1, leaving $NAMESPACE / $RELEASE_NAME in place."
    log "Cleanup manually with:"
    log "  helm uninstall $RELEASE_NAME -n $NAMESPACE"
    log "  kubectl delete ns $NAMESPACE"
    exit "$exit_code"
  fi
  log "Cleaning up..."
  kubectl -n "$NAMESPACE" delete pod "$TEST_POD_NAME" --ignore-not-found --wait=false 2>/dev/null || true
  kubectl -n "$NAMESPACE" delete clusterflow,clusteroutput --all --ignore-not-found 2>/dev/null || true
  kubectl -n "$NAMESPACE" delete logging "$LOGGING_CR_NAME" --ignore-not-found 2>/dev/null || true
  helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" 2>/dev/null || true
  kubectl delete ns "$NAMESPACE" --ignore-not-found --wait=false 2>/dev/null || true
  exit "$exit_code"
}
trap cleanup EXIT

# ---- pre-flight -------------------------------------------------------------

log "Pre-flight checks"
for tool in kubectl helm jq; do
  command -v "$tool" >/dev/null || { fail "$tool not found in PATH"; exit 1; }
done
kubectl cluster-info >/dev/null 2>&1 || { fail "cannot reach cluster (check KUBECONFIG)"; exit 1; }
ok "kubectl, helm, jq present; cluster reachable: $(kubectl config current-context)"

# ---- namespace + optional pull secret ---------------------------------------

log "Creating namespace $NAMESPACE"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

PULL_SECRET_NAME=""
if [ -n "${GHCR_USER:-}" ] && [ -n "${GHCR_TOKEN:-}" ]; then
  PULL_SECRET_NAME="ghcr-cred"
  log "Creating imagePullSecret '$PULL_SECRET_NAME' for ghcr.io"
  kubectl -n "$NAMESPACE" create secret docker-registry "$PULL_SECRET_NAME" \
    --docker-server=ghcr.io \
    --docker-username="$GHCR_USER" \
    --docker-password="$GHCR_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  ok "imagePullSecret created"
fi

# ---- install logging-operator chart -----------------------------------------

read -r OP_REPO OP_TAG <<<"$(split_image "$IMAGE_LOGGING_OPERATOR")"

log "Installing $CHART_REF (version $CHART_VERSION) as release $RELEASE_NAME"
log "  operator image: $OP_REPO:$OP_TAG"

HELM_ARGS=(
  upgrade --install "$RELEASE_NAME" "$CHART_REF"
  --version "$CHART_VERSION"
  --namespace "$NAMESPACE"
  --set "image.repository=$OP_REPO"
  --set "image.tag=$OP_TAG"
  --set "createCustomResource=true"
  --wait --timeout="$TIMEOUT_OPERATOR"
)
if [ -n "$PULL_SECRET_NAME" ]; then
  HELM_ARGS+=(--set "imagePullSecrets[0].name=$PULL_SECRET_NAME")
fi
helm "${HELM_ARGS[@]}" >/dev/null

log "Waiting for operator Deployment Ready (timeout $TIMEOUT_OPERATOR)"
# Deployment name follows the chart's fullname template; usually "<release>-logging-operator"
OPERATOR_DEPLOY=$(kubectl -n "$NAMESPACE" get deploy -l app.kubernetes.io/name=logging-operator -o name | head -1)
[ -n "$OPERATOR_DEPLOY" ] || { fail "logging-operator Deployment not found"; exit 1; }
kubectl -n "$NAMESPACE" wait "$OPERATOR_DEPLOY" \
  --for=condition=Available --timeout="$TIMEOUT_OPERATOR" >/dev/null
ok "logging-operator Ready ($OPERATOR_DEPLOY)"

# ---- Logging CR with per-component image overrides --------------------------

read -r CR_REPO CR_TAG <<<"$(split_image "$IMAGE_CONFIG_RELOADER")"
read -r FB_REPO FB_TAG <<<"$(split_image "$IMAGE_FLUENT_BIT")"
read -r FD_REPO FD_TAG <<<"$(split_image "$IMAGE_FLUENTD")"

log "Applying Logging CR with per-component image overrides:"
log "  fluentbit:       $FB_REPO:$FB_TAG"
log "  fluentd:         $FD_REPO:$FD_TAG"
log "  config-reloader: $CR_REPO:$CR_TAG"

# Note: bufferStorageVolume.emptyDir avoids needing a PVC provisioner on
# bare k3d/kind clusters. For production you'd want a real PVC.
kubectl apply -f - <<EOF >/dev/null
apiVersion: logging.banzaicloud.io/v1beta1
kind: Logging
metadata:
  name: $LOGGING_CR_NAME
spec:
  controlNamespace: $NAMESPACE
  fluentbit:
    image:
      repository: $FB_REPO
      tag: $FB_TAG
      pullPolicy: IfNotPresent
  fluentd:
    image:
      repository: $FD_REPO
      tag: $FD_TAG
      pullPolicy: IfNotPresent
    configReloaderImage:
      repository: $CR_REPO
      tag: $CR_TAG
      pullPolicy: IfNotPresent
    bufferStorageVolume:
      emptyDir: {}
EOF

log "Waiting for fluentbit DaemonSet to appear..."
for _ in $(seq 1 30); do
  FB_DS=$(kubectl -n "$NAMESPACE" get ds -o name 2>/dev/null | grep fluentbit | head -1 || true)
  [ -n "$FB_DS" ] && break
  sleep 2
done
[ -n "$FB_DS" ] || { fail "fluentbit DaemonSet never appeared"; exit 1; }
log "  $FB_DS"

log "Waiting for fluentbit pods Ready (timeout $TIMEOUT_FLUENT_BIT)"
kubectl -n "$NAMESPACE" rollout status "$FB_DS" --timeout="$TIMEOUT_FLUENT_BIT" >/dev/null
ok "fluentbit DaemonSet Ready"

log "Waiting for fluentd StatefulSet to appear..."
for _ in $(seq 1 30); do
  FD_STS=$(kubectl -n "$NAMESPACE" get sts -o name 2>/dev/null | grep fluentd | head -1 || true)
  [ -n "$FD_STS" ] && break
  sleep 2
done
[ -n "$FD_STS" ] || { fail "fluentd StatefulSet never appeared"; exit 1; }
log "  $FD_STS"

log "Waiting for fluentd Ready (timeout $TIMEOUT_FLUENTD)"
kubectl -n "$NAMESPACE" rollout status "$FD_STS" --timeout="$TIMEOUT_FLUENTD" >/dev/null
ok "fluentd StatefulSet Ready"

# ---- (optional) log-flow check ---------------------------------------------

if [ -n "$SKIP_LOG_FLOW_TEST" ]; then
  ok "Smoke test PASSED (log-flow check skipped via SKIP_LOG_FLOW_TEST)"
  exit 0
fi

log "Applying ClusterOutput + ClusterFlow that pipes test pod logs to fluentd stdout"
kubectl apply -f - <<EOF >/dev/null
apiVersion: logging.banzaicloud.io/v1beta1
kind: ClusterOutput
metadata:
  name: smoke-test-stdout
  namespace: $NAMESPACE
spec:
  stdout:
    output_type: json
---
apiVersion: logging.banzaicloud.io/v1beta1
kind: ClusterFlow
metadata:
  name: smoke-test-flow
  namespace: $NAMESPACE
spec:
  match:
    - select:
        labels:
          smoke-test: "true"
  globalOutputRefs:
    - smoke-test-stdout
EOF

# Give the operator a few seconds to regenerate fluentd config + config-reloader to reload
log "Letting operator regenerate fluentd config..."
sleep 15

log "Launching log generator pod with sentinel: $SENTINEL"
kubectl -n "$NAMESPACE" run "$TEST_POD_NAME" \
  --image=busybox:1.36 \
  --labels="smoke-test=true" \
  --restart=Never \
  --command -- sh -c "for i in 1 2 3 4 5 6 7 8 9 10; do echo \"$SENTINEL iter \$i\"; sleep 1; done; sleep 60" \
  >/dev/null
kubectl -n "$NAMESPACE" wait pod "$TEST_POD_NAME" \
  --for=condition=Ready --timeout=60s >/dev/null
ok "Log generator pod Running"

log "Searching fluentd logs for sentinel (timeout $TIMEOUT_LOG_FLOW)"
FD_POD=$(kubectl -n "$NAMESPACE" get pods -l app.kubernetes.io/name=fluentd -o name | head -1)
[ -n "$FD_POD" ] || { fail "fluentd pod not found"; exit 1; }

deadline=$(( $(date +%s) + ${TIMEOUT_LOG_FLOW%s} ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if kubectl -n "$NAMESPACE" logs "$FD_POD" --tail=500 2>/dev/null | grep -q "$SENTINEL"; then
    ok "Sentinel '$SENTINEL' found in fluentd logs -- end-to-end flow works"
    ok "Smoke test PASSED"
    exit 0
  fi
  sleep 3
done

fail "Sentinel '$SENTINEL' did NOT appear in fluentd logs within $TIMEOUT_LOG_FLOW"
log "Last 50 lines of fluentd:"
kubectl -n "$NAMESPACE" logs "$FD_POD" --tail=50 || true
exit 1
