#!/bin/bash
set -e

# Resolve the script directory regardless of where the script is invoked from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
IMAGE_NAME=${IMAGE_NAME:-"tidesql"}
TAG=${TAG:-"latest"}
VOLUME_DATA="tidesql-data"
VOLUME_CONF="tidesql-conf"
VOLUME_LOG="tidesql-log"

echo "### 1. Cleaning up existing resources..."

docker ps -a -q --filter "ancestor=${IMAGE_NAME}:${TAG}" 2>/dev/null \
    | xargs -r docker rm -f

if [ -z "${KEEP_VOLUMES}" ] || [ "${KEEP_VOLUMES}" = "0" ]; then
    docker volume rm "$VOLUME_DATA" "$VOLUME_CONF" "$VOLUME_LOG" 2>/dev/null || true
fi

docker rmi -f "${IMAGE_NAME}:${TAG}" 2>/dev/null || true
