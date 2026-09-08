#!/bin/bash
# Stop this project's containers and remove unused Docker resources.
# Usage: ./cleanup.sh [--full]
#   default  — stop stack, remove project volumes, prune dangling resources
#   --full   — also prune all unused images, containers, networks, and volumes

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

COMPOSE_PROJECT="distributed-log-processor"
export COMPOSE_PROJECT_NAME="$COMPOSE_PROJECT"
FULL_PRUNE=false
[[ "${1:-}" == "--full" ]] && FULL_PRUNE=true

echo "============================================================"
echo " Day 1 — Cleanup"
echo " Project: $SCRIPT_DIR"
echo "============================================================"

command -v docker >/dev/null || { echo "[error] Docker not found"; exit 1; }

echo "[1/5] Stopping host-mode Spring Boot / Maven processes (if any)..."
pkill -f "log-producer/.*spring-boot:run" 2>/dev/null || true
pkill -f "log-consumer/.*spring-boot:run" 2>/dev/null || true
pkill -f "api-gateway/.*spring-boot:run" 2>/dev/null || true
pkill -f "com.example.logprocessor.producer.LogProducerApplication" 2>/dev/null || true
pkill -f "com.example.logprocessor.consumer.LogConsumerApplication" 2>/dev/null || true
pkill -f "com.example.logprocessor.gateway.ApiGatewayApplication" 2>/dev/null || true
rm -rf "$SCRIPT_DIR/.pids"

echo "[2/5] Stopping compose stack and removing project volumes..."
if [ -f docker-compose.yml ]; then
  docker compose down --remove-orphans -v 2>/dev/null || true
fi

echo "[3/5] Removing leftover project containers and images..."
LEFTOVERS=$(docker ps -aq --filter "name=${COMPOSE_PROJECT}" 2>/dev/null || true)
if [ -n "${LEFTOVERS}" ]; then
  docker rm -f $LEFTOVERS 2>/dev/null || true
fi
for img in \
  "${COMPOSE_PROJECT}-api-gateway" \
  "${COMPOSE_PROJECT}-log-producer" \
  "${COMPOSE_PROJECT}-log-consumer"; do
  docker rmi -f "${img}:latest" 2>/dev/null || true
done

echo "[4/5] Removing local Maven build artifacts and runtime logs..."
find "$SCRIPT_DIR" -type d -name target -prune -exec rm -rf {} + 2>/dev/null || true
find "$SCRIPT_DIR" -name '*.class' -delete 2>/dev/null || true
rm -rf "$SCRIPT_DIR/docker-volumes" "$SCRIPT_DIR/logs" "$SCRIPT_DIR/.pids" 2>/dev/null || true
find "$SCRIPT_DIR" -name '*.log' -type f -delete 2>/dev/null || true

echo "[5/5] Pruning unused Docker resources..."
if $FULL_PRUNE; then
  docker system prune -a --volumes -f
else
  docker container prune -f
  docker image prune -f
  docker network prune -f
  docker volume prune -f
fi

echo ""
echo "Cleanup complete."
echo "  Start infra again:  docker compose up -d"
echo "  Full Docker wipe:   ./cleanup.sh --full"
