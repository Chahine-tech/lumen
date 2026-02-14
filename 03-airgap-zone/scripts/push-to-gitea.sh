#!/bin/bash
set -e

echo "====================================="
echo "Pushing lumen repository to Gitea"
echo "====================================="

# Port-forward to Gitea
echo "Creating port-forward to Gitea..."
kubectl port-forward -n gitea svc/gitea 3001:3000 &
PF_PID=$!
sleep 5

# Navigate to repo root
cd /Users/chahinebenlahcen/Documents/lumen

# Add Gitea as remote
echo "Adding Gitea remote..."
git remote remove gitea 2>/dev/null || true
git remote add gitea http://localhost:3001/lumen/lumen.git

# Push to Gitea
echo "Pushing to Gitea..."
echo ""
echo "Enter Gitea credentials:"
echo "  Username: gitea-admin"
echo "  Password: gitea-admin"
echo ""
git push gitea main --force

# Stop port-forward
kill $PF_PID 2>/dev/null || true

echo ""
echo "✅ Repository pushed to Gitea!"
echo ""
echo "Verify at: http://localhost:3001/lumen/lumen"
