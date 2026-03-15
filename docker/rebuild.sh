#!/bin/bash
set -e

# Resolve the repository root regardless of where the script is invoked from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Configuration
TAG=${TAG:-"tidesql:11.8-ubuntu"}
CONTAINER_NAME=${CONTAINER_NAME:-"tidesql"}
VOLUME_DATA="tidesql-data"
VOLUME_CONF="tidesql-conf"

echo "### 1. Cleaning up existing resources..."
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
docker volume rm "$VOLUME_DATA" "$VOLUME_CONF" 2>/dev/null || true
docker rmi -f "$TAG" 2>/dev/null || true

echo "### 2. Building the new image..."
docker build \
    -f "${REPO_ROOT}/docker/11.8-ubuntu/Dockerfile" \
    -t "$TAG" \
    --no-cache \
    "${REPO_ROOT}"

echo "### 3. Starting the container..."
docker run -d \
    --name "$CONTAINER_NAME" \
    -p 3306:3306 \
    -v "$VOLUME_CONF":/etc/mysql \
    -v "$VOLUME_DATA":/usr/local/mariadb/data \
    "$TAG"
r=$?

echo
echo '-----'
echo
echo "### Done!"
echo "Exit code: $r"
echo "Logs:"
docker logs -f "$CONTAINER_NAME"
