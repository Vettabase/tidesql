#!/usr/bin/env bash
# entrypoint.sh - Initialise the MariaDB data directory on first run and start the server.
#
# If MARIADB_PREFIX/data/mysql does not exist the data directory is initialised
# with mariadb-install-db.
# The server is started in background, then once TidesDB creates its data
# directory a symlink /usr/local/mariadb/log -> .../tidesdb_data/LOG is
# established, and finally the script waits for the server to exit.
set -eo pipefail

MARIADB_PREFIX="${MARIADB_PREFIX:-/usr/local/mariadb}"
DATADIR="${MARIADB_PREFIX}/data/default"
TIDESDB_DATA="${MARIADB_PREFIX}/data/tidesdb_data"
LOG_LINK="${MARIADB_PREFIX}/log"

# ── Initialise data directory if it has not been set up yet ────────────────
if [ ! -d "${DATADIR}/mysql" ]; then
    echo "[entrypoint] Initialising MariaDB data directory..."

    # Locate mariadb-install-db
    INSTALL_DB=""
    for candidate in \
        "${MARIADB_PREFIX}/scripts/mariadb-install-db" \
        "${MARIADB_PREFIX}/scripts/mysql_install_db" \
        "${MARIADB_PREFIX}/bin/mariadb-install-db" \
        "${MARIADB_PREFIX}/bin/mysql_install_db"; do
        if [ -f "$candidate" ]; then
            INSTALL_DB="$candidate"
            break
        fi
    done

    if [ -z "$INSTALL_DB" ]; then
        echo "[entrypoint] ERROR: mariadb-install-db not found under ${MARIADB_PREFIX}" >&2
        exit 1
    fi

    "${INSTALL_DB}" \
        --defaults-file="/etc/mysql/my.cnf" \
        --user=mysql \
        --basedir="${MARIADB_PREFIX}" \
        --datadir="${DATADIR}"

    chown -R mysql:mysql "${DATADIR}"
    echo "[entrypoint] Data directory initialised."
fi

# ── Prepare runtime directories ─────────────────────────────────────────────
chown -R mysql:mysql /etc/mysql
mkdir -p "${DATADIR}"
chown -R mysql:mysql "${MARIADB_PREFIX}/data"

# ── Launch MariaDB in background ─────────────────────────────────────────────
"${MARIADB_PREFIX}/bin/mariadbd" \
    --defaults-file="/etc/mysql/my.cnf" "$@" &
MARIADBD_PID=$!

# Forward TERM/INT signals so the container shuts down cleanly.
# Single quotes prevent premature expansion; MARIADBD_PID is read at signal time.
trap 'kill -TERM ${MARIADBD_PID}' TERM INT

# ── Wait for TidesDB data directory ─────────────────────────────────────────
# TIDESDB_DATA_TIMEOUT: seconds to wait before giving up (0 = no timeout).
TIDESDB_DATA_TIMEOUT="${TIDESDB_DATA_TIMEOUT:-300}"
elapsed=0
echo "[entrypoint] Waiting for ${TIDESDB_DATA} (timeout: ${TIDESDB_DATA_TIMEOUT}s) ..."
while [ ! -d "${TIDESDB_DATA}" ]; do
    # Exit early if the server died before creating the directory.
    if ! kill -0 "${MARIADBD_PID}" 2>/dev/null; then
        echo "[entrypoint] ERROR: mariadbd exited before ${TIDESDB_DATA} was created." >&2
        exit 1
    fi
    if [ "${TIDESDB_DATA_TIMEOUT}" -gt 0 ] && [ "${elapsed}" -ge "${TIDESDB_DATA_TIMEOUT}" ]; then
        echo "[entrypoint] ERROR: timed out after ${TIDESDB_DATA_TIMEOUT}s waiting for ${TIDESDB_DATA}." >&2
        kill -TERM "${MARIADBD_PID}"
        exit 1
    fi
    sleep 1
    elapsed=$((elapsed + 1))
done
echo "[entrypoint] ${TIDESDB_DATA} found."

# ── Create symbolic link ─────────────────────────────────────────────────────
# Replace any existing log directory/link with a symlink into tidesdb_data.
rm -rf "${LOG_LINK}"
ln -s "${TIDESDB_DATA}/LOG" "${LOG_LINK}"
echo "[entrypoint] Created symlink ${LOG_LINK} -> ${TIDESDB_DATA}/LOG"

# ── Bring MariaDB to foreground ──────────────────────────────────────────────
# wait is interrupted by trapped signals; wait a second time to collect the
# final exit status after the trap handler has sent TERM to mariadbd.
wait "${MARIADBD_PID}"
trap - TERM INT
wait "${MARIADBD_PID}"
