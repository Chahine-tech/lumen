#!/bin/bash
set -e

echo "======================================"
echo "Syncing repository to Gitea"
echo "======================================"

# Check if port-forward is already running
if ! nc -z localhost 3001 2>/dev/null; then
    echo "🔌 Starting port-forward to Gitea..."
    kubectl port-forward -n gitea svc/gitea 3001:3000 > /dev/null 2>&1 &
    PF_PID=$!
    sleep 3

    # Cleanup on exit
    trap "kill $PF_PID 2>/dev/null || true" EXIT
fi

# Ensure gitea remote exists
if ! git remote get-url gitea > /dev/null 2>&1; then
    echo "📍 Adding Gitea remote..."
    git remote add gitea http://localhost:3001/lumen/lumen.git
fi

# Push to Gitea
echo "📤 Pushing to Gitea..."
git push gitea main

echo ""
echo "✅ Successfully synced to Gitea!"
echo "🔄 ArgoCD will detect changes within 3 minutes"
