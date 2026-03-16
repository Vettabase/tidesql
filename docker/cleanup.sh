#!/bin/bash
set -e

# Resolve the script directory regardless of where the script is invoked from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
IMAGE_NAME=${IMAGE_NAME:-"tidesql"}
TAG=${TAG:-"11.8-ubuntu"}
CONTAINER_NAME=${CONTAINER_NAME:-"tidesql"}
VOLUME_DATA="tidesql-data"
VOLUME_CONF="tidesql-conf"
VOLUME_LOG="tidesql-log"

echo "### 1. Cleaning up existing resources..."
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
docker volume rm "$VOLUME_DATA" "$VOLUME_CONF" "$VOLUME_LOG" 2>/dev/null || true
docker rmi -f "${IMAGE_NAME}:${TAG}" 2>/dev/null || true
