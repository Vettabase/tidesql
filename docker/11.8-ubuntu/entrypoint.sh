#!/usr/bin/env bash
# entrypoint.sh - Initialise the MariaDB data directory on first run and start the server.
#
# If MARIADB_PREFIX/data/mysql does not exist the data directory is initialised
# with mariadb-install-db.
# The server is then started via mariadbd-safe.
set -eo pipefail

MARIADB_PREFIX="${MARIADB_PREFIX:-/usr/local/mariadb}"
DATADIR="${MARIADB_PREFIX}/data"

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

# ── Start MariaDB ───────────────────────────────────────────────────────────
# Ensure the mysql user owns the configuration directory (handles volume mounts).
chown -R mysql:mysql /etc/mysql

exec "${MARIADB_PREFIX}/bin/mariadbd-safe" \
    --defaults-file="/etc/mysql/my.cnf" "$@"
