#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Fix CoreDNS on local OpenShell gateways running under Colima.
#
# Problem: k3s CoreDNS forwards to /etc/resolv.conf which inside the
# CoreDNS pod resolves to an unreachable upstream (e.g., 8.8.4.4).
# The cluster node CAN resolve via Colima's gateway (192.168.5.1)
# but pods can't reach it by default.
#
# Run this after `openshell gateway start` on Colima setups.
#
# Usage: ./scripts/fix-coredns.sh [gateway-name]

set -euo pipefail

GATEWAY_NAME="${1:-}"
DOCKER_HOST="${DOCKER_HOST:-unix://$HOME/.colima/default/docker.sock}"
export DOCKER_HOST

# Find the cluster container
CLUSTER=$(docker ps --filter "name=openshell-cluster" --format '{{.Names}}' | head -1)
if [ -z "$CLUSTER" ]; then
  echo "ERROR: No openshell cluster container found."
  exit 1
fi

# Get the Colima DNS gateway IP
COLIMA_DNS=$(docker exec "$CLUSTER" cat /etc/resolv.conf | grep nameserver | head -1 | awk '{print $2}')
if [ -z "$COLIMA_DNS" ]; then
  echo "ERROR: Could not determine Colima DNS IP."
  exit 1
fi

echo "Patching CoreDNS to forward to $COLIMA_DNS..."

docker exec "$CLUSTER" kubectl patch configmap coredns -n kube-system --type merge -p "{\"data\":{\"Corefile\":\".:53 {\\n    errors\\n    health\\n    ready\\n    kubernetes cluster.local in-addr.arpa ip6.arpa {\\n      pods insecure\\n      fallthrough in-addr.arpa ip6.arpa\\n    }\\n    hosts /etc/coredns/NodeHosts {\\n      ttl 60\\n      reload 15s\\n      fallthrough\\n    }\\n    prometheus :9153\\n    cache 30\\n    loop\\n    reload\\n    loadbalance\\n    forward . $COLIMA_DNS\\n}\\n\"}}" > /dev/null

docker exec "$CLUSTER" kubectl rollout restart deploy/coredns -n kube-system > /dev/null

echo "CoreDNS patched. Waiting for rollout..."
docker exec "$CLUSTER" kubectl rollout status deploy/coredns -n kube-system --timeout=30s > /dev/null

echo "Done. DNS should resolve in ~10 seconds."
