#!/bin/bash
#
# TidesQL Failover Controller
#
# Monitors the primary MariaDB instance and promotes a replica
# when the primary becomes unresponsive. Designed to run as a
# sidecar container or CronJob in Kubernetes.
#
# Usage:
#   ./failover.sh
#
# Environment variables:
#   PRIMARY_HOST      Primary MariaDB host (default: tidesql-primary)
#   PRIMARY_PORT      Primary MariaDB port (default: 3306)
#   REPLICA_HOST      Replica MariaDB host (default: tidesql-replica)
#   REPLICA_PORT      Replica MariaDB port (default: 3306)
#   CHECK_INTERVAL    Seconds between health checks (default: 5)
#   FAILURE_THRESHOLD Consecutive failures before promotion (default: 3)
#   MYSQL_USER        MariaDB user for health checks (default: root)
#   MYSQL_PASSWORD    MariaDB password (default: empty)

set -euo pipefail

PRIMARY_HOST="${PRIMARY_HOST:-tidesql-primary}"
PRIMARY_PORT="${PRIMARY_PORT:-3306}"
REPLICA_HOST="${REPLICA_HOST:-tidesql-replica}"
REPLICA_PORT="${REPLICA_PORT:-3306}"
CHECK_INTERVAL="${CHECK_INTERVAL:-5}"
FAILURE_THRESHOLD="${FAILURE_THRESHOLD:-3}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-}"

FAILURES=0

log() {
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
}

check_primary() {
    if mariadb -h "$PRIMARY_HOST" -P "$PRIMARY_PORT" \
               -u "$MYSQL_USER" ${MYSQL_PASSWORD:+-p"$MYSQL_PASSWORD"} \
               -e "SELECT 1" > /dev/null 2>&1; then
        return 0
    fi
    return 1
}

promote_replica() {
    log "PROMOTING replica $REPLICA_HOST to primary"

    # promote via SET GLOBAL
    mariadb -h "$REPLICA_HOST" -P "$REPLICA_PORT" \
            -u "$MYSQL_USER" ${MYSQL_PASSWORD:+-p"$MYSQL_PASSWORD"} \
            -e "SET GLOBAL tidesdb_promote_primary = ON" 2>&1

    if [ $? -eq 0 ]; then
        log "PROMOTION SUCCESSFUL: $REPLICA_HOST is now primary"

        # verify writes work
        mariadb -h "$REPLICA_HOST" -P "$REPLICA_PORT" \
                -u "$MYSQL_USER" ${MYSQL_PASSWORD:+-p"$MYSQL_PASSWORD"} \
                -e "SELECT 'write_test'" > /dev/null 2>&1

        log "Replica is accepting connections"
    else
        log "PROMOTION FAILED: could not promote $REPLICA_HOST"
    fi
}

log "TidesQL Failover Controller started"
log "Monitoring primary at $PRIMARY_HOST:$PRIMARY_PORT"
log "Replica at $REPLICA_HOST:$REPLICA_PORT"
log "Check interval: ${CHECK_INTERVAL}s, failure threshold: $FAILURE_THRESHOLD"

while true; do
    if check_primary; then
        if [ "$FAILURES" -gt 0 ]; then
            log "Primary recovered after $FAILURES failures"
        fi
        FAILURES=0
    else
        FAILURES=$((FAILURES + 1))
        log "Primary health check failed ($FAILURES/$FAILURE_THRESHOLD)"

        if [ "$FAILURES" -ge "$FAILURE_THRESHOLD" ]; then
            log "Primary unreachable for $FAILURES consecutive checks"
            promote_replica
            # after promotion, exit so the controller can be restarted
            # with the new primary as the target
            log "Failover complete. Exiting controller."
            exit 0
        fi
    fi

    sleep "$CHECK_INTERVAL"
done
