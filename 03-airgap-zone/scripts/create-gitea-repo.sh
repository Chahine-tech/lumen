#!/bin/bash
set -e

echo "====================================="
echo "Creating Gitea organization and repo"
echo "====================================="

GITEA_URL="http://gitea.gitea.svc.cluster.local:3000"
GITEA_USER="gitea-admin"
GITEA_PASS="gitea-admin"

# Create organization via API
echo "Creating organization 'lumen'..."
kubectl run gitea-create-org --image=curlimages/curl:latest --rm -it --restart=Never -- \
  curl -X POST "${GITEA_URL}/api/v1/orgs" \
  -u "${GITEA_USER}:${GITEA_PASS}" \
  -H "Content-Type: application/json" \
  -d '{"username":"lumen","full_name":"Lumen Organization","description":"Lumen airgap project"}' \
  -w "\nHTTP Status: %{http_code}\n"

echo ""
echo "Creating repository 'lumen' in organization..."
kubectl run gitea-create-repo --image=curlimages/curl:latest --rm -it --restart=Never -- \
  curl -X POST "${GITEA_URL}/api/v1/orgs/lumen/repos" \
  -u "${GITEA_USER}:${GITEA_PASS}" \
  -H "Content-Type: application/json" \
  -d '{"name":"lumen","description":"Lumen airgap Kubernetes project","private":false,"auto_init":false}' \
  -w "\nHTTP Status: %{http_code}\n"

echo ""
echo "✅ Organization and repository created!"
echo "Repository URL: ${GITEA_URL}/lumen/lumen"
