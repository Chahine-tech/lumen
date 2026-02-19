#!/bin/bash
# Start socat tunnels for Multipass K3s access
# Forwards macOS ports 80/443 → node-1 NodePorts 30101/30958

NODE1_HTTP=30101
NODE1_HTTPS=30958
NODE1_IP=192.168.2.2

pkill -f "socat.*${NODE1_IP}" 2>/dev/null || true
sleep 1

socat TCP-LISTEN:443,fork,reuseaddr TCP:${NODE1_IP}:${NODE1_HTTPS} &
echo $! > /tmp/socat-443.pid

socat TCP-LISTEN:80,fork,reuseaddr TCP:${NODE1_IP}:${NODE1_HTTP} &
echo $! > /tmp/socat-80.pid

echo "Tunnels started: 443→${NODE1_IP}:${NODE1_HTTPS} and 80→${NODE1_IP}:${NODE1_HTTP}"
