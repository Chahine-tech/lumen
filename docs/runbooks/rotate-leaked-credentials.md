# Rotating the credentials leaked in the public repository (issue #1)

The repository is public on GitHub. Until the commit that adds this page,
several credentials were written in tracked files. Removing them from the tree
does not un-leak them: they stay in the git history, which anyone may already
have cloned. Each one is handled by **rotation**, not by rewriting history.

## What leaked

| Credential | Where (history) | Since | Still valid? |
|---|---|---|---|
| Gitea Actions runner registration token | `gitea-runner/01-runner.yaml` | 2365b9e, 2026-02-20 | yes until reset (step 2) |
| Gitea admin password (two values) | `group_vars/all.yml`, README, `AIRGAP-MULTIPASS.md`, `operational-improvements.md`, Gitea scripts | February 2026 | yes until changed (step 1) |
| ArgoCD admin password | `DEPLOYMENT.md` (services table) | February 2026 (k3d era) | unknown: rotate anyway (step 3) |
| Grafana and Traefik dashboard `admin:admin` | `DEPLOYMENT.md`, old `08-middlewares.yaml` | February 2026 | should not be: moved to Vault in 6402f59 and 6eb0299 (step 4 checks) |

gitleaks finds only the runner token and the `admin:admin` examples. The
passwords above are too simple for its rules; they were found by reading the
files. The known historical findings are listed in `.gitleaksignore`.

Exposure: the values are public, but Gitea, ArgoCD and the dashboards are
reachable only from the lab network (`192.168.2.0/24`, MetalLB VIP
`192.168.2.100`). Using them needs access to that network.

## 1. Gitea admin password

1. Change it in the Gitea UI (Site Administration > User Accounts >
   `gitea-admin` > Edit). The CLI `gitea admin user change-password` takes the
   password as a command-line flag, visible in the process list of the pod.
2. Store it in your password manager. Ansible reads it from the environment
   only:
   ```bash
   read -rs GITEA_ADMIN_PASSWORD && export GITEA_ADMIN_PASSWORD
   ```
3. Remove the password from your local remote URL (it is in `.git/config`):
   ```bash
   git remote set-url gitea https://gitea-admin@gitea.airgap.local/lumen/lumen.git
   ```
   git prompts once and the macOS keychain (`credential.helper osxkeychain`)
   keeps it.
4. Changing the password does not revoke access tokens. In Gitea, Settings >
   Applications: delete every token you do not recognise, then create a new
   token for CI and replace the `CI_TOKEN` Actions secret (used by the release
   job to push the manifest bump).

## 2. Runner registration token

1. Create the Vault policy and role (a new cluster gets them from the
   `vault-init` Job; on a running cluster, with an admin token):
   ```bash
   kubectl exec -it -n vault vault-0 -- sh
   export VAULT_TOKEN=<admin token>
   vault policy write gitea-runner-policy - <<'EOF'
   path "lumen/data/gitea-runner" {
     capabilities = ["read"]
   }
   EOF
   vault write auth/kubernetes/role/gitea-runner \
     bound_service_account_names=gitea-runner-vso \
     bound_service_account_namespaces=gitea \
     policies=gitea-runner-policy \
     ttl=1h
   ```
2. Push: ArgoCD (Application `vso-config`) creates
   `manifests/vso/06-gitea-runner-secret.yaml`. It takes over the existing
   Secret `gitea-runner-token` (`overwrite: true`) once Vault holds a value.
3. Reset the token in the Gitea UI: Site Administration > Actions > Runners >
   Create new runner > Reset registration token. Without this step the next
   command stores the leaked token again: `gitea actions generate-runner-token`
   returns the current token, it does not create one.
4. Copy it to Vault and restart the runner:
   ```bash
   ./03-airgap-zone/scripts/seed-gitea-runner-token.sh
   ```
5. Check the runner list (Site Administration > Actions > Runners). The runner
   registers again at every pod restart (its state is in an `emptyDir`), so
   several `k8s-runner` entries are expected; delete the offline duplicates.
   **A runner with any other name was registered by someone else**: delete it,
   and treat every Actions secret as leaked (`CI_COSIGN_KEY`: new Cosign key
   pair and new public key in the Kyverno policy; `CI_TOKEN`: step 1.4).

Steps 2 to 4 were tested on a k3d cluster (Gitea 1.21.5, Vault 1.19.0, VSO
1.3.0) on 2026-11-12, both with an existing unmanaged Secret and with a
Secret already managed by VSO: the runner registered with the token from
Vault. Step 3 (the UI reset) was not tested.

## 3. ArgoCD admin password

Change it in the ArgoCD UI (User Info > Update Password), then delete the
initial Secret if it still exists:
```bash
kubectl delete secret argocd-initial-admin-secret -n argocd --ignore-not-found
```
Disabling the local admin in favour of SSO is issue #27.

## 4. Check the values already moved to Vault

The old default (`admin` / `admin`) must be refused (HTTP 401):
```bash
OLD=admin
curl -sk -o /dev/null -w '%{http_code}\n' -u "admin:$OLD" https://traefik.airgap.local/dashboard/
curl -sk -o /dev/null -w '%{http_code}\n' -u "admin:$OLD" https://grafana.airgap.local/api/org
```

## 5. On your workstation

`cosign.key` and `vault-keys.json` are at the repository root. They are
ignored by git, so they did not leak, but they are the most sensitive files of
the project: issues #3 (unseal keys) and #13 (Cosign key in Vault Transit)
remove them.

## Preventing the next leak

- `make scan-secrets`: gitleaks over the full history, as in CI.
- CI: `.gitea/workflows/secret-scan.yaml` (Gitea; mirror the image first with
  `01-connected-zone/scripts/22-pull-gitleaks.sh` and
  `02-transit-zone/push-gitleaks.sh`) and `.github/workflows/secret-scan.yml`
  (public mirror).
- Before each commit: `brew install pre-commit && pre-commit install`
  (gitleaks is already installed locally).
- Ansible reads `GITEA_ADMIN_PASSWORD` from the environment and pushes to Gitea
  without putting the password in a URL, `.git/config` or the keychain.
