#!/bin/bash
# Admission tests for the lumen-* Kyverno ValidatingPolicies
# (03-airgap-zone/manifests/kyverno-policies/02 to 05).
#
# Each case is sent with `kubectl apply --dry-run=server`: the admission
# webhooks run, nothing is created. A case passes when the verdict (allow or
# deny) matches the expected one. Runs against the current kubectl context;
# override with KUBECTL="kubectl --context ...".
#
# Usage: make test-policies
K="${KUBECTL:-kubectl}"
# Pod Security "restricted" is enforced on lumen: every test container is
# compliant, so that a denial can only come from Kyverno
SC='{runAsNonRoot: true, allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}, seccompProfile: {type: RuntimeDefault}}'
RES=$(mktemp)
trap 'rm -f "$RES"' EXIT
pod() { # name ns image [initImage]
  local init=""
  [ -n "$4" ] && init="  initContainers:
    - name: init
      image: $4
      securityContext: $SC"
  cat <<Y
apiVersion: v1
kind: Pod
metadata: {name: $1, namespace: $2}
spec:
  containers:
    - name: main
      image: $3
      securityContext: $SC
$init
Y
}
workload() { # kind name ns labels(yaml flow) image resources(yaml flow or none)
  local res=""
  [ "$6" != "none" ] && res="          resources: $6"
  cat <<Y
apiVersion: apps/v1
kind: $1
metadata: {name: $2, namespace: $3, labels: $4}
spec:
  selector: {matchLabels: {k: v}}
$( [ "$1" = StatefulSet ] && echo "  serviceName: s" )
  template:
    metadata: {labels: {k: v}}
    spec:
      containers:
        - name: main
          image: $5
          securityContext: $SC
$res
Y
}
check() { # expect description <<manifest
  local expect=$1 desc=$2 out rc got
  out=$($K apply --dry-run=server -f - 2>&1); rc=$?
  if [ $rc -eq 0 ]; then got=allow; elif echo "$out" | grep -q 'denied the request'; then got=deny; else got="error"; fi
  if [ "$got" = "$expect" ]; then echo pass >> $RES; echo "PASS  [$expect] $desc"; else echo fail >> $RES; echo "FAIL  [expected $expect, got $got] $desc"; echo "      $out" | head -3; fi
}
R="192.168.2.2:5000"; FULL='{requests: {cpu: 10m, memory: 16Mi}, limits: {cpu: 50m, memory: 32Mi}}'
echo "== registry"
pod p1 lumen docker.io/library/nginx:1.27 | check deny  "lumen pod, external image"
pod p2 default nginx:1.27                 | check deny  "default pod, external image"
pod p3 kube-public nginx:1.27                   | check allow "kube-public, external image (out of scope)"
pod p4 lumen $R/redis:7.4.1               | check allow "lumen pod, internal image"
pod p5 lumen $R/redis:7.4.1 busybox:1.37  | check deny  "lumen pod, external init container"
workload Deployment d1 lumen '{app: a, tier: t}' nginx:1.27 "$FULL" | check deny "lumen Deployment, external image (autogen)"
echo "== latest tag"
pod l1 lumen $R/redis:latest              | check deny  "explicit :latest"
pod l2 lumen $R/redis                     | check deny  "no tag behind a registry port (Gatekeeper accepted this)"
pod l3 lumen $R/redis:7.4.1 $R/busybox:latest | check deny "init container :latest"
pod l4 lumen $R/redis@sha256:0000000000000000000000000000000000000000000000000000000000000000 | check allow "digest only"
pod l5 lumen $R/redis:latest-ish          | check allow "tag that only starts with latest"
pod l6 kube-public redis:latest                 | check allow "kube-public (out of scope)"
workload StatefulSet s1 lumen '{app: a, tier: t}' $R/redis:latest "$FULL" | check deny "lumen StatefulSet :latest (autogen)"
echo "== labels"
workload Deployment w1 lumen '{app: a}' $R/redis:7.4.1 "$FULL"          | check deny  "Deployment missing tier"
workload StatefulSet w2 lumen '{tier: t}' $R/redis:7.4.1 "$FULL"        | check deny  "StatefulSet missing app"
workload Deployment w3 lumen '{app: a, tier: t}' $R/redis:7.4.1 "$FULL" | check allow "Deployment with app and tier"
workload Deployment w4 kube-public '{}' nginx:1.27 none                       | check allow "kube-public (out of scope)"
echo "== resources"
workload Deployment r1 lumen '{app: a, tier: t}' $R/redis:7.4.1 none | check deny "no resources at all"
workload Deployment r2 lumen '{app: a, tier: t}' $R/redis:7.4.1 '{requests: {cpu: 10m, memory: 16Mi}, limits: {memory: 32Mi}}' | check deny "missing CPU limit"
workload DaemonSet r3 lumen '{app: a, tier: t}' $R/redis:7.4.1 "$FULL" | check allow "DaemonSet with full resources"
echo "== scope after the selector fix"
pod d1 default $R/redis:latest           | check allow "default pod, internal :latest (latest rule is lumen-only)"
workload Deployment d2 default '{}' $R/redis:7.4.1 none | check allow "default Deployment without labels or resources (lumen-only rules)"
workload Deployment d3 default '{}' nginx:1.27 none     | check deny  "default Deployment, external image (registry covers default)"
echo; p=$(grep -c pass $RES); f=$(grep -c fail $RES); echo "passed=$p failed=$f"; [ "$f" -eq 0 ] && [ "$p" -gt 0 ]
