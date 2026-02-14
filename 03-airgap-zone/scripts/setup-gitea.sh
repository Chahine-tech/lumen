#!/bin/bash
set -e

echo "====================================="
echo "Setting up Gitea"
echo "====================================="

# Wait for Gitea to be ready
echo "Waiting for Gitea pod..."
kubectl wait --for=condition=ready pod -n gitea -l app=gitea --timeout=120s

# Port-forward to Gitea
echo "Creating port-forward to Gitea..."
kubectl port-forward -n gitea svc/gitea 3001:3000 &
PF_PID=$!
sleep 5

echo ""
echo "✅ Gitea is ready!"
echo ""
echo "Access Gitea at: http://localhost:3001"
echo ""
echo "Initial Setup Steps:"
echo "1. Open http://localhost:3000 in browser"
echo "2. Complete the initial configuration (use defaults)"
echo "3. Create admin user:"
echo "   - Username: gitea-admin"
echo "   - Password: gitea-admin"
echo "   - Email: admin@gitea.local"
echo "4. Create organization: 'lumen'"
echo "5. Create repository: 'lumen' (public)"
echo ""
echo "Press Enter when setup is complete..."
read

# Stop port-forward
kill $PF_PID 2>/dev/null || true

echo "✅ Gitea setup complete!"
