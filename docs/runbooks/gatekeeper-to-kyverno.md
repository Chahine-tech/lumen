# Replacing OPA Gatekeeper with Kyverno policies

The four Gatekeeper constraints (internal registry, latest tag, app labels,
resources) became Kyverno `ValidatingPolicy` resources in
`03-airgap-zone/manifests/kyverno-policies/02` to `05`. The Gatekeeper
manifests, Ansible role and scripts were removed from the repository; commit
`390ee9d` is the last one that has them, and the commands below read them from
there.

Why: Gatekeeper 3.18 is end of life, and no Gatekeeper release is tested on
Kubernetes 1.34, the version the PostgreSQL backups need
([k3s-upgrade-path.md](k3s-upgrade-path.md)). Kyverno already runs for the
Cosign signature policy and is tested on 1.33 to 1.35. Details of the policies
and their design: [security.md, Layer 1](../security.md#layer-1-kyverno-admission-policies).

Kyverno 1.18 is tested on Kubernetes 1.33 to 1.35. If the cluster still runs
an older K3s, Kyverno is outside its tested range there, as it already is for
the signature policy; the k3d test ran on 1.34.

Removing the files from git does not remove Gatekeeper from a running cluster:
it was installed by `start.yml` / `install-opa.sh`, not by ArgoCD. Follow the
steps below in order, so that the cluster is never without admission policies.

Tested on a k3d cluster (K3s 1.34.12, Kyverno 1.18.1, Gatekeeper 3.18.0) on
2026-11-12: both engines active, then Gatekeeper removed, `make test-policies`
23/23 at each stage, nothing left behind. Not run on the lumen cluster yet.

## 1. Kyverno policies active (both engines run side by side)

Push the commit: ArgoCD syncs the Application `kyverno-policies` (wave 11).

```bash
kubectl get validatingpolicies.policies.kyverno.io \
  -o custom-columns='NAME:.metadata.name,READY:.status.conditionStatus.ready'
# expect 4 policies, READY true
make test-policies
# expect: passed=23 failed=0
```

Do not go further until both pass. While both engines run, a request is
rejected if either rejects it; on the k3d test nothing legitimate was rejected
by one and not the other.

## 2. Remove the Gatekeeper constraints and templates

Templates first: deleting a template removes its constraint CRD, and
Gatekeeper must still be running to process it.

```bash
for t in 05-constraint-template-no-latest 04-constraint-template-resources \
         03-constraint-template-labels 02-constraint-template-registry; do
  git show 390ee9d:03-airgap-zone/manifests/opa/$t.yaml | kubectl delete -f - --ignore-not-found
done
# wait until no constraint CRD is left
kubectl get crd | grep constraints.gatekeeper.sh
```

## 3. Uninstall Gatekeeper

```bash
git show 390ee9d:03-airgap-zone/manifests/opa/01-gatekeeper-install.yaml \
  | kubectl delete -f - --ignore-not-found --wait=true
```

## 4. Check

```bash
kubectl get ns gatekeeper-system                       # NotFound
kubectl get crd -o name | grep gatekeeper              # nothing
kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name | grep gatekeeper  # nothing
kubectl get clusterrole,clusterrolebinding -o name | grep gatekeeper                                 # nothing
make test-policies                                     # passed=23 failed=0
```

Optional: delete the `openpolicyagent/gatekeeper` image from the registry on
node-1 and from the transit zone.

## Rollback

Reinstall from the same commit, templates after the install (Gatekeeper takes
a few seconds to generate the constraint CRDs: apply the templates twice if
the constraints report "ensure CRDs are installed first"):

```bash
git show 390ee9d:03-airgap-zone/manifests/opa/01-gatekeeper-install.yaml | kubectl apply -f -
for t in 02-constraint-template-registry 03-constraint-template-labels \
         04-constraint-template-resources 05-constraint-template-no-latest; do
  git show 390ee9d:03-airgap-zone/manifests/opa/$t.yaml | kubectl apply -f -
done
```
