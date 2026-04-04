#!/bin/bash
# k8s-test-dynamic-discovery.sh
# Full end-to-end test of TideSQL dynamic replica discovery on EKS
# Run from AWS CloudShell after cluster and EBS CSI driver are set up
set -euo pipefail

ECR_IMAGE=""
S3_BUCKET=""
NS=""

S3_ACCESS_KEY=""
S3_SECRET_KEY=""

log() { echo ""; echo "========== $1 =========="; }

log "STEP 0 -- Clean slate"
aws s3 rm "s3://${S3_BUCKET}/" --recursive 2>/dev/null || true
kubectl delete statefulset -n $NS tidesql-primary 2>/dev/null || true
kubectl delete deployment -n $NS tidesql-replica 2>/dev/null || true
kubectl delete deployment -n $NS tidesql-failover-controller 2>/dev/null || true
kubectl delete pvc -n $NS data-tidesql-primary-0 2>/dev/null || true
echo "Waiting for pods to terminate..."
sleep 15
kubectl get pods -n $NS 2>/dev/null || true

log "STEP 1: Deploy primary"
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: tidesdb-primary-config
  namespace: $NS
data:
  tidesdb.cnf: |
    [mariadb]
    plugin-load-add=ha_tidesdb.so
    tidesdb_object_store_backend=S3
    tidesdb_s3_endpoint=s3.amazonaws.com
    tidesdb_s3_bucket=${S3_BUCKET}
    tidesdb_s3_region=us-east-1
    tidesdb_s3_access_key=${S3_ACCESS_KEY}
    tidesdb_s3_secret_key=${S3_SECRET_KEY}
    tidesdb_s3_use_ssl=ON
    tidesdb_s3_path_style=OFF
    tidesdb_objstore_local_cache_max=512M
    tidesdb_objstore_wal_sync_threshold=1M
    tidesdb_unified_memtable=ON
    tidesdb_unified_memtable_write_buffer_size=128M
    tidesdb_block_cache_size=256M
    tidesdb_flush_threads=4
    tidesdb_compaction_threads=4
    tidesdb_log_level=INFO
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: tidesql-primary
  namespace: $NS
spec:
  serviceName: tidesql-primary
  replicas: 1
  selector:
    matchLabels:
      app: tidesql
      role: primary
  template:
    metadata:
      labels:
        app: tidesql
        role: primary
    spec:
      containers:
        - name: mariadb
          image: ${ECR_IMAGE}
          imagePullPolicy: Always
          command: ["/bin/bash", "-c"]
          args:
            - |
              mkdir -p /etc/mysql/custom && cp /opt/tidesdb-config/tidesdb.cnf /etc/mysql/custom/tidesdb-k8s.cnf
              exec /usr/local/bin/tidesql-entrypoint.sh
          ports:
            - containerPort: 3306
              name: mysql
          volumeMounts:
            - name: config
              mountPath: /opt/tidesdb-config/tidesdb.cnf
              subPath: tidesdb.cnf
            - name: data
              mountPath: /var/lib/mysql
          livenessProbe:
            exec:
              command: ["mariadb-admin", "ping", "-h", "localhost"]
            initialDelaySeconds: 60
            periodSeconds: 10
          readinessProbe:
            exec:
              command: ["mariadb", "-h", "localhost", "-e", "SELECT 1"]
            initialDelaySeconds: 15
            periodSeconds: 5
      volumes:
        - name: config
          configMap:
            name: tidesdb-primary-config
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: gp3
        resources:
          requests:
            storage: 100Gi
---
apiVersion: v1
kind: Service
metadata:
  name: tidesql-primary
  namespace: $NS
spec:
  type: ClusterIP
  selector:
    app: tidesql
    role: primary
  ports:
    - port: 3306
      targetPort: 3306
      name: mysql
EOF

echo "Waiting for primary..."
kubectl wait -n $NS --for=condition=Ready pod -l app=tidesql,role=primary --timeout=300s
echo "Primary is ready."

log "STEP 2: Verify TidesDB plugin loaded"
kubectl exec -n $NS tidesql-primary-0 -- mariadb -e "SHOW PLUGINS" | grep -i tides
kubectl exec -n $NS tidesql-primary-0 -- mariadb -e "SHOW ENGINE TIDESDB STATUS\G" | grep -E "Connector|Replica mode|Column families"

log "STEP 3: Create users and initial data"
kubectl exec -n $NS tidesql-primary-0 -- mariadb -e "
  CREATE USER IF NOT EXISTS 'monitor'@'%' IDENTIFIED BY 'M0nitor!Pass9';
  GRANT ALL PRIVILEGES ON *.* TO 'monitor'@'%' WITH GRANT OPTION;
  CREATE DATABASE IF NOT EXISTS app_prod;
  CREATE TABLE app_prod.items (id INT PRIMARY KEY, name VARCHAR(100)) ENGINE=TIDESDB;
  INSERT INTO app_prod.items VALUES (1,'alpha'),(2,'beta'),(3,'gamma');
  OPTIMIZE TABLE app_prod.items;
  FLUSH PRIVILEGES;
"

log "STEP 4: Verify data in S3"
aws s3 ls "s3://${S3_BUCKET}/" --recursive

log "STEP 5: Deploy replicas"
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: tidesdb-replica-config
  namespace: $NS
data:
  tidesdb.cnf: |
    [mariadb]
    plugin-load-add=ha_tidesdb.so
    tidesdb_object_store_backend=S3
    tidesdb_s3_endpoint=s3.amazonaws.com
    tidesdb_s3_bucket=${S3_BUCKET}
    tidesdb_s3_region=us-east-1
    tidesdb_s3_access_key=${S3_ACCESS_KEY}
    tidesdb_s3_secret_key=${S3_SECRET_KEY}
    tidesdb_s3_use_ssl=ON
    tidesdb_s3_path_style=OFF
    tidesdb_objstore_local_cache_max=512M
    tidesdb_replica_mode=ON
    tidesdb_replica_sync_interval=1000000
    tidesdb_unified_memtable=ON
    tidesdb_unified_memtable_write_buffer_size=128M
    tidesdb_block_cache_size=256M
    tidesdb_flush_threads=2
    tidesdb_compaction_threads=2
    tidesdb_log_level=INFO
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tidesql-replica
  namespace: $NS
spec:
  replicas: 2
  selector:
    matchLabels:
      app: tidesql
      role: replica
  template:
    metadata:
      labels:
        app: tidesql
        role: replica
    spec:
      containers:
        - name: mariadb
          image: ${ECR_IMAGE}
          imagePullPolicy: Always
          command: ["/bin/bash", "-c"]
          args:
            - |
              mkdir -p /etc/mysql/custom && cp /opt/tidesdb-config/tidesdb.cnf /etc/mysql/custom/tidesdb-k8s.cnf
              exec /usr/local/bin/tidesql-entrypoint.sh
          ports:
            - containerPort: 3306
              name: mysql
          volumeMounts:
            - name: config
              mountPath: /opt/tidesdb-config/tidesdb.cnf
              subPath: tidesdb.cnf
            - name: cache
              mountPath: /var/lib/mysql
          readinessProbe:
            exec:
              command: ["mariadb", "-h", "localhost", "-e", "SELECT 1"]
            initialDelaySeconds: 15
            periodSeconds: 5
      volumes:
        - name: config
          configMap:
            name: tidesdb-replica-config
        - name: cache
          emptyDir:
            sizeLimit: 50Gi
---
apiVersion: v1
kind: Service
metadata:
  name: tidesql-replica
  namespace: $NS
spec:
  type: ClusterIP
  selector:
    app: tidesql
    role: replica
  ports:
    - port: 3306
      targetPort: 3306
      name: mysql
EOF

echo "Waiting for replicas..."
kubectl wait -n $NS --for=condition=Ready pod -l app=tidesql,role=replica --timeout=300s
echo "Replicas are ready."

log "STEP 6: Create monitor user on replicas"
for pod in $(kubectl get pods -n $NS -l role=replica -o name); do
  kubectl exec -n $NS "$pod" -- mariadb -e "
    CREATE USER IF NOT EXISTS 'monitor'@'%' IDENTIFIED BY 'M0nitor!Pass9';
    GRANT ALL PRIVILEGES ON *.* TO 'monitor'@'%' WITH GRANT OPTION;
    FLUSH PRIVILEGES;
  " 2>/dev/null || echo "  (skipped $pod - not ready yet)"
done

log "STEP 7: Test cold start discovery"
echo "Reading from replica (cold start data)..."
kubectl exec -n $NS deploy/tidesql-replica -- mariadb -e "SELECT * FROM app_prod.items ORDER BY id"

log "STEP 8: Verify replica image has signal mask fix"
kubectl exec -n $NS deploy/tidesql-replica -- strings /usr/local/lib/libtidesdb.so | grep -c "pthread_sigmask" || true
kubectl exec -n $NS deploy/tidesql-replica -- strings /usr/local/lib/libtidesdb.so | grep "Replica sync: created new CF" || true

log "STEP 9: Check replica reaper status"
kubectl exec -n $NS deploy/tidesql-replica -- mariadb -e "SHOW ENGINE TIDESDB STATUS\G" | grep -E "Column families|Replica mode|Connector"
echo "Replica LOG (reaper entries):"
kubectl exec -n $NS deploy/tidesql-replica -- grep -i "reaper\|replica sync\|discover" /usr/local/mariadb/data/tidesdb_data/LOG 2>/dev/null | tail -10 || echo "(no entries)"
echo ""
echo "Replica LOG line count:"
kubectl exec -n $NS deploy/tidesql-replica -- wc -l /usr/local/mariadb/data/tidesdb_data/LOG 2>/dev/null || true

log "STEP 10: Dynamic discovery test - create new table on primary"
kubectl exec -n $NS tidesql-primary-0 -- mariadb -e "
  CREATE DATABASE dyntest;
  CREATE TABLE dyntest.t1 (id INT PRIMARY KEY, msg TEXT) ENGINE=TIDESDB;
  INSERT INTO dyntest.t1 VALUES (1,'dynamic discovery works');
  OPTIMIZE TABLE dyntest.t1;
"

echo "Waiting 15 seconds for S3 upload + replica sync..."
sleep 15

log "STEP 11: Check replica state after dynamic table creation"
echo "Column families:"
kubectl exec -n $NS deploy/tidesql-replica -- mariadb -e "SHOW ENGINE TIDESDB STATUS\G" | grep "Column families"
echo ""
echo "TidesDB data directory:"
kubectl exec -n $NS deploy/tidesql-replica -- ls /usr/local/mariadb/data/tidesdb_data/
echo ""
echo "LOG line count:"
kubectl exec -n $NS deploy/tidesql-replica -- wc -l /usr/local/mariadb/data/tidesdb_data/LOG 2>/dev/null || true
echo ""
echo "Discovery entries in LOG:"
kubectl exec -n $NS deploy/tidesql-replica -- grep -i "replica sync\|discover\|dyntest" /usr/local/mariadb/data/tidesdb_data/LOG 2>/dev/null | tail -10 || echo "(none)"

log "STEP 12: Attempt to read dynamic table from replica"
if kubectl exec -n $NS deploy/tidesql-replica -- mariadb -N -e "SELECT * FROM dyntest.t1" 2>/dev/null; then
  echo ""
  echo "*** PASS: Dynamic discovery works! ***"
else
  echo ""
  echo "*** FAIL: Table not found on replica ***"
  echo ""
  echo "Trying after 30 more seconds..."
  sleep 30
  echo "Column families now:"
  kubectl exec -n $NS deploy/tidesql-replica -- mariadb -e "SHOW ENGINE TIDESDB STATUS\G" | grep "Column families"
  echo "LOG growth:"
  kubectl exec -n $NS deploy/tidesql-replica -- wc -l /usr/local/mariadb/data/tidesdb_data/LOG 2>/dev/null || true
  echo "Discovery entries:"
  kubectl exec -n $NS deploy/tidesql-replica -- grep -i "replica sync\|discover\|dyntest" /usr/local/mariadb/data/tidesdb_data/LOG 2>/dev/null | tail -10 || echo "(none)"
  echo ""
  if kubectl exec -n $NS deploy/tidesql-replica -- mariadb -N -e "SELECT * FROM dyntest.t1" 2>/dev/null; then
    echo "*** PASS (delayed): Dynamic discovery works after 45 seconds ***"
  else
    echo "*** FAIL: Dynamic discovery not working ***"
  fi
fi

log "STEP 13: All pods status"
kubectl get pods -n $NS -o wide

echo ""
echo "========== TEST COMPLETE =========="
