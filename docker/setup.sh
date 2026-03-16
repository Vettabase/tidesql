#!/bin/bash
set -e

# Resolve the repository root regardless of where the script is invoked from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Configuration
IMAGE_NAME=${IMAGE_NAME:-"tidesql"}
TAG=${TAG:-"11.8-ubuntu"}
CONTAINER_NAME=${CONTAINER_NAME:-"tidesql"}
VOLUME_DATA="tidesql-data"
VOLUME_CONF="tidesql-conf"
VOLUME_LOG="tidesql-log"

# ── Storage engine selection ──────────────────────────────────────────────────
# Optional engines that can be excluded or selectively included.
KNOWN_OPTIONAL_ENGINES="ARCHIVE BLACKHOLE CONNECT EXAMPLE FEDERATED FEDERATEDX MROONGA ROCKSDB S3 SPHINX SPIDER"
# Engines that are always present in the build (cannot be excluded).
ALWAYS_INCLUDED_ENGINES="TIDESDB INNODB ARIA MYISAM CSV MEMORY HEAP MERGE MRG_MyISAM SEQUENCE"

_upper_space() {
    echo "$1" | tr '[:lower:]' '[:upper:]' | tr ',' ' '
}

_is_optional_engine() {
    local e="$1"
    for k in $KNOWN_OPTIONAL_ENGINES; do [ "$k" = "$e" ] && return 0; done
    return 1
}

_is_always_included() {
    local e="$1"
    for k in $ALWAYS_INCLUDED_ENGINES; do [ "$k" = "$e" ] && return 0; done
    return 1
}

_is_known_engine() {
    _is_optional_engine "$1" || _is_always_included "$1"
}

DISABLED_ENGINES=""

if [ -n "${EXCLUDE_ENGINES:-}" ] && [ -n "${INCLUDE_ENGINES:-}" ]; then
    echo "Error: EXCLUDE_ENGINES and INCLUDE_ENGINES cannot both be set." >&2
    exit 1
fi

if [ -n "${EXCLUDE_ENGINES:-}" ]; then
    EXCL_NORM="$(_upper_space "$EXCLUDE_ENGINES")"
    if [ "$EXCL_NORM" != "ALL" ]; then
        for engine in $EXCL_NORM; do
            if _is_always_included "$engine"; then
                echo "Error: '${engine}' is always included and cannot be excluded." >&2
                exit 1
            fi
            if ! _is_optional_engine "$engine"; then
                echo "Error: Unknown engine '${engine}'. Excludable engines: $(echo "$KNOWN_OPTIONAL_ENGINES" | tr ' ' ',')" >&2
                exit 1
            fi
        done
        DISABLED_ENGINES="$(echo "$EXCL_NORM" | tr ' ' ',')"
    fi
    # EXCLUDE_ENGINES=ALL → include all optional engines → DISABLED_ENGINES=""

elif [ -n "${INCLUDE_ENGINES:-}" ]; then
    INCL_NORM="$(_upper_space "$INCLUDE_ENGINES")"
    for engine in $INCL_NORM; do
        if ! _is_known_engine "$engine"; then
            echo "Error: Unknown engine '${engine}'. Optional engines: $(echo "$KNOWN_OPTIONAL_ENGINES" | tr ' ' ',')" >&2
            exit 1
        fi
    done
    # DISABLED = KNOWN_OPTIONAL minus what was requested to be included.
    _disabled=""
    for engine in $KNOWN_OPTIONAL_ENGINES; do
        _found=0
        for incl in $INCL_NORM; do
            if [ "$incl" = "$engine" ]; then _found=1; break; fi
        done
        if [ "$_found" = "0" ]; then
            _disabled="${_disabled:+${_disabled},}${engine}"
        fi
    done
    DISABLED_ENGINES="$_disabled"
fi

echo "### 2. Building the new image..."
BUILD_ARGS=()
[ -n "$DISABLED_ENGINES" ] && BUILD_ARGS+=(--build-arg "DISABLED_ENGINES=${DISABLED_ENGINES}")
docker build \
    -f "${REPO_ROOT}/docker/ubuntu/Dockerfile" \
    -t "${IMAGE_NAME}:${TAG}" \
    --no-cache \
    "${BUILD_ARGS[@]}" \
    "${REPO_ROOT}"

echo "### 3. Starting the container..."
docker run -d \
    --name "$CONTAINER_NAME" \
    -p 3306:3306 \
    -v "$VOLUME_CONF":/etc/mysql \
    -v "$VOLUME_DATA":/usr/local/mariadb/data \
    -v "$VOLUME_LOG":/usr/local/mariadb/log \
    "${IMAGE_NAME}:${TAG}"
r=$?

echo
echo '-----'
echo
echo "### Done!"
echo "Exit code: $r"
echo "Logs:"
docker logs -f "$CONTAINER_NAME"
