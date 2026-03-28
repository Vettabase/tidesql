#!/usr/bin/env bash
# entrypoint.sh - Initialise the MariaDB data directory on first run and start the server.
#
# If MARIADB_PREFIX/data/mysql does not exist the data directory is initialised
# with mariadb-install-db.
#################################################################################################
# The server is then started via mariadbd, and any .sql / .sh files found in
# /docker-entrypoint-initdb.d are executed in alphabetical order once the
# server is ready.
set -euo pipefail

MARIADB_PREFIX="${MARIADB_PREFIX:-/usr/local/mariadb}"
DATADIR="${MARIADB_PREFIX}/data/default"
INITDB_DIR="/docker-entrypoint-initdb.d"
SOCKET="/tmp/mariadb.sock"

# Initialise data directory if it has not been set up yet 
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

# Start MariaDB
# Ensure runtime directories exist with correct ownership (handles volume mounts).
chown -R mysql:mysql /etc/mysql
mkdir -p "${DATADIR}" "${MARIADB_PREFIX}/log"
chown -R mysql:mysql "${MARIADB_PREFIX}/data" "${MARIADB_PREFIX}/log"

"${MARIADB_PREFIX}/bin/mariadbd" \
    --defaults-file="/etc/mysql/my.cnf" "$@" &
MARIADBD_PID=$!

# Run init scripts from /docker-entrypoint-initdb.d if any exist
shopt -s nullglob
INIT_FILES=()
for f in "${INITDB_DIR}"/*.sql "${INITDB_DIR}"/*.sh; do
    INIT_FILES+=("$f")
done

if [ ${#INIT_FILES[@]} -gt 0 ]; then
    # Sort init files alphabetically across both extensions
    IFS=$'\n' INIT_FILES=($(printf '%s\n' "${INIT_FILES[@]}" | sort))
    unset IFS

    echo "[entrypoint] Waiting for MariaDB to be ready..."
    for _ in $(seq 1 30); do
        if "${MARIADB_PREFIX}/bin/mariadb" \
                --socket="${SOCKET}" \
                --user=root \
                -e "SELECT 1" > /dev/null 2>&1; then
            break
        fi
        if ! kill -0 "${MARIADBD_PID}" 2>/dev/null; then
            echo "[entrypoint] ERROR: MariaDB exited unexpectedly." >&2
            exit 1
        fi
        sleep 1
    done

    if ! "${MARIADB_PREFIX}/bin/mariadb" \
            --socket="${SOCKET}" \
            --user=root \
            -e "SELECT 1" > /dev/null 2>&1; then
        echo "[entrypoint] ERROR: MariaDB did not become ready in time." >&2
        exit 1
    fi

    echo "[entrypoint] Running init scripts..."
    for f in "${INIT_FILES[@]}"; do
        case "$f" in
            *.sql)
                echo "[entrypoint] Executing SQL: $f"
                "${MARIADB_PREFIX}/bin/mariadb" \
                    --socket="${SOCKET}" \
                    --user=root < "$f"
                ;;
            *.sh)
                echo "[entrypoint] Executing shell script: $f"
                # shellcheck disable=SC1090
                bash "$f"
                ;;
        esac
    done
    echo "[entrypoint] Init scripts complete."
fi

wait "${MARIADBD_PID}"
