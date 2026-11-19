#!/bin/bash
# Real failures of GitOps deployments, and the alerts they must raise
# (issue #25, docs/runbooks/alerting.md):
#
#   1. nothing fires while the application and the rollout are healthy;
#   2. a broken image applied by hand: ArgoCDAppOutOfSync, then
#      ArgoCDAppUnhealthy once the Deployment misses its progress deadline;
#   3. an application whose sync fails: ArgoCDSyncFailed;
#   4. a canary whose analysis fails: RolloutFailed;
#   5. every alert clears once git and the rollout are back.
#
# For a test cluster with ArgoCD and Argo Rollouts. It needs the Application
# APP (default guestbook, automated sync without selfHeal, its Deployment
# DEPLOYMENT in namespace NS) and the Rollout ROLLOUT in NS, whose canary runs
# an analysis that fails. KUBECTL overrides the kubectl command.
set -euo pipefail

K=${KUBECTL:-kubectl}
NS=${NS:-lumen}
APP=${APP:-guestbook}
DEPLOYMENT=${DEPLOYMENT:-guestbook-ui}
ROLLOUT=${ROLLOUT:-alert-test}
PROM=pod/prometheus-kube-prometheus-stack-prometheus-0
ALERTS="ArgoCDAppOutOfSync ArgoCDAppUnhealthy ArgoCDSyncFailed ArgoCDMetricsAbsent RolloutFailed RolloutMetricsAbsent"

kc() {
  # shellcheck disable=SC2086
  $K "$@"
}
fail() { echo "FAIL: $*"; exit 1; }
ok() { echo "  ok: $*"; }

kc -n monitoring port-forward "$PROM" 19090:9090 >/dev/null 2>&1 &
PF=$!
cleanup() {
  kc -n argocd delete application alert-test-broken --ignore-not-found >/dev/null 2>&1 || true
  kill "$PF" 2>/dev/null || true
}
trap cleanup EXIT
for _ in $(seq 1 30); do
  curl -fsS --max-time 2 http://127.0.0.1:19090/-/ready >/dev/null 2>&1 && break
  sleep 1
done

firing() {
  curl -fsS --max-time 10 http://127.0.0.1:19090/api/v1/alerts \
    | python3 -c 'import json,sys; print(" ".join(sorted({a["labels"]["alertname"] for a in json.load(sys.stdin)["data"]["alerts"] if a["state"]=="firing"})))'
}
# wait_firing SECONDS ALERT...: each alert fires at some point. They need
# not fire together: ArgoCDSyncFailed is over before the 15 minutes of
# ArgoCDAppOutOfSync have passed
wait_firing() {
  local seconds=$1 now missing a seen=" "
  shift
  for _ in $(seq 1 $((seconds / 10))); do
    now=" $(firing) "
    missing=""
    for a in "$@"; do
      [[ "$now" == *" $a "* ]] && seen="$seen$a "
      [[ "$seen" == *" $a "* ]] || missing="$missing $a"
    done
    [ -z "$missing" ] && return 0
    sleep 10
  done
  fail "never fired in ${seconds}s:$missing (firing:$now)"
}
wait_clear() {
  local now a busy
  for _ in $(seq 1 $(($1 / 10))); do
    now=" $(firing) "
    busy=""
    for a in $ALERTS; do [[ "$now" == *" $a "* ]] && busy="$busy $a"; done
    [ -z "$busy" ] && return 0
    sleep 10
  done
  fail "still firing after ${1}s:$busy"
}
container_image() {
  kc -n "$NS" get "$1" "$2" -o jsonpath='{.spec.template.spec.containers[0].image}'
}

echo "== 1. Healthy"
wait_clear 600
ok "none of the alerts fires"
good_image=$(container_image deployment "$DEPLOYMENT")
stable_image=$(container_image rollout "$ROLLOUT")
container=$(kc -n "$NS" get deployment "$DEPLOYMENT" -o jsonpath='{.spec.template.spec.containers[0].name}')

echo "== 2, 3, 4. Failures"
kc -n "$NS" patch deployment "$DEPLOYMENT" --type merge -p '{"spec":{"progressDeadlineSeconds":120}}' >/dev/null
kc -n "$NS" set image "deployment/$DEPLOYMENT" "$container=docker.io/library/busybox:does-not-exist" >/dev/null
source=$(kc -n argocd get application "$APP" -o jsonpath='{.spec.source}')
kc apply -f - >/dev/null <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: alert-test-broken
  namespace: argocd
spec:
  project: default
  source: $source
  destination: {server: "https://kubernetes.default.svc", namespace: alert-test-does-not-exist}
  syncPolicy:
    automated: {prune: true}
    retry: {limit: 1}
EOF
kc -n "$NS" patch rollout "$ROLLOUT" --type json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/image\",\"value\":\"${stable_image%:*}:1.29.7-alpine\"}]" >/dev/null
wait_firing 1800 ArgoCDAppOutOfSync ArgoCDAppUnhealthy ArgoCDSyncFailed RolloutFailed
ok "ArgoCDAppOutOfSync, ArgoCDAppUnhealthy, ArgoCDSyncFailed and RolloutFailed fired"

echo "== 5. Back to git"
kc -n argocd delete application alert-test-broken >/dev/null
kc -n "$NS" set image "deployment/$DEPLOYMENT" "$container=$good_image" >/dev/null
kc -n argocd patch application "$APP" --type merge \
  -p '{"operation":{"initiatedBy":{"username":"alerting-test"},"sync":{"syncStrategy":{"hook":{}}}}}' >/dev/null
kc -n "$NS" patch rollout "$ROLLOUT" --type json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/image\",\"value\":\"$stable_image\"}]" >/dev/null
wait_clear 1500
ok "the alerts have cleared"

echo "PASS"
