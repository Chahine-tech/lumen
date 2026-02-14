#!/bin/bash
set -e

echo "====================================="
echo "Installing Gitea via API"
echo "====================================="

# Wait for Gitea to be ready
echo "Waiting for Gitea pod..."
kubectl wait --for=condition=ready pod -n gitea -l app=gitea --timeout=120s

# Get Gitea service cluster IP
GITEA_URL="http://gitea.gitea.svc.cluster.local:3000"

echo "Installing Gitea with default configuration..."

# Run installation via API from inside cluster
kubectl run gitea-installer --image=curlimages/curl:latest --rm -it --restart=Never -- \
  curl -X POST "$GITEA_URL/" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "db_type=sqlite3" \
  --data-urlencode "db_path=/data/gitea/gitea.db" \
  --data-urlencode "app_name=Gitea: Git with a cup of tea" \
  --data-urlencode "repo_root_path=/data/git/repositories" \
  --data-urlencode "lfs_root_path=/data/git/lfs" \
  --data-urlencode "run_user=git" \
  --data-urlencode "domain=gitea.gitea.svc.cluster.local" \
  --data-urlencode "ssh_port=22" \
  --data-urlencode "http_port=3000" \
  --data-urlencode "app_url=http://gitea.gitea.svc.cluster.local:3000/" \
  --data-urlencode "log_root_path=/data/gitea/log" \
  --data-urlencode "admin_name=gitea-admin" \
  --data-urlencode "admin_passwd=gitea-admin" \
  --data-urlencode "admin_confirm_passwd=gitea-admin" \
  --data-urlencode "admin_email=admin@gitea.local"

echo ""
echo "✅ Gitea installation complete!"
echo "Waiting for Gitea to restart..."
sleep 10

# Wait for pod to be ready again
kubectl wait --for=condition=ready pod -n gitea -l app=gitea --timeout=120s

echo "✅ Gitea is ready!"
