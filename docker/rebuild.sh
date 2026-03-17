#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "${SKIP_CLEANUP}" ] || [ "${SKIP_CLEANUP}" = "0" ]; then
    bash "${SCRIPT_DIR}/cleanup.sh"
fi
bash "${SCRIPT_DIR}/setup.sh"
