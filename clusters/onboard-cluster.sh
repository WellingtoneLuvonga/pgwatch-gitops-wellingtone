#!/usr/bin/env bash
set -e

# Dynamically locate repository root (looks in current dir or parent dir for base/scrape-configs)
CUR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -d "${CUR_DIR}/base/scrape-configs" ]; then
  REPO_ROOT="${CUR_DIR}"
elif [ -d "${CUR_DIR}/../base/scrape-configs" ]; then
  REPO_ROOT="$(cd "${CUR_DIR}/.." && pwd)"
else
  echo "Error: Could not locate base/scrape-configs directory!"
  exit 1
fi

if [ -z "$1" ]; then
  echo "Usage: ./onboard-cluster.sh <path-to-cluster.env>"
  exit 1
fi

source "$1"

echo "=================================================="
echo " Onboarding Cluster: ${CLUSTER_NAME}"
echo "=================================================="

# 1. Create Secret in Minikube
echo "[1/6] Storing OpenShift API Token in Minikube..."
kubectl create secret generic "${CLUSTER_NAME}-dev-token" \
  --namespace pgwatch \
  --from-literal=token="${OPENSHIFT_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -

# 2. Deploy Remote Exporter Agent on Target OpenShift Cluster
echo "[2/6] Deploying Exporter Agent stack on remote cluster (${CLUSTER_NAME})..."
cat <<EOF | kubectl --server="${API_URL}" --token="${OPENSHIFT_TOKEN}" --insecure-skip-tls-verify apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pgwatch-exporter-agent
  namespace: ${REMOTE_NAMESPACE}
  labels:
    app: pgwatch-exporter-agent
spec:
  replicas: 1
  selector:
    matchLabels:
      app: pgwatch-exporter-agent
  template:
    metadata:
      labels:
        app: pgwatch-exporter-agent
    spec:
      serviceAccountName: pgo
      containers:
        - name: pgwatch
          image: docker.bin.sbb.ch/cybertecpostgresql/pgwatch:latest
          imagePullPolicy: Always
          workingDir: /tmp
          command:
            - /bin/sh
            - -c
            - |
              exec /pgwatch/pgwatch \
                --web-disable \
                --sources=/etc/pgwatch3/sources.yaml \
                --sink=prometheus://0.0.0.0:9188 > /dev/termination-log 2>&1
          ports:
            - name: metrics
              containerPort: 9188
              protocol: TCP
          volumeMounts:
            - name: sources-volume
              mountPath: /etc/pgwatch3
            - name: tmp-dir
              mountPath: /tmp
      volumes:
        - name: sources-volume
          configMap:
            name: pgwatch-sources-cm
            defaultMode: 420
        - name: tmp-dir
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: pgwatch-exporter-agent
  namespace: ${REMOTE_NAMESPACE}
  labels:
    app: pgwatch-exporter-agent
spec:
  type: ClusterIP
  ports:
    - port: 9188
      targetPort: metrics
      name: metrics
      protocol: TCP
  selector:
    app: pgwatch-exporter-agent
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: pgwatch-metrics-dev
  namespace: ${REMOTE_NAMESPACE}
spec:
  host: ${METRICS_HOST}
  to:
    kind: Service
    name: pgwatch-exporter-agent
    weight: 100
  port:
    targetPort: metrics
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
  wildcardPolicy: None
EOF

# 3. Deploy Local Watcher in Minikube
echo "[3/6] Deploying Discovery Watcher in Minikube..."
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pgwatch-crunchy-watcher-${CLUSTER_NAME}
  namespace: pgwatch
  labels:
    app: pgwatch-crunchy-watcher-${CLUSTER_NAME}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: pgwatch-crunchy-watcher-${CLUSTER_NAME}
  template:
    metadata:
      labels:
        app: pgwatch-crunchy-watcher-${CLUSTER_NAME}
    spec:
      hostAliases:
        - ip: "${API_IP}"
          hostnames:
            - "$(echo ${API_URL} | sed -E 's|https://([^:]+):.*|\1|')"
      containers:
        - name: watcher
          image: bitnami/kubectl:latest
          env:
            - name: CLUSTER_TOKEN
              valueFrom:
                secretKeyRef:
                  name: ${CLUSTER_NAME}-dev-token
                  key: token
                  optional: true
          command:
            - /bin/sh
            - -c
            - |
              API_URL="${API_URL}"
              while true; do
                if [ -n "\$CLUSTER_TOKEN" ]; then
                  kubectl --server="\$API_URL" --token="\$CLUSTER_TOKEN" --insecure-skip-tls-verify \
                    get secrets -n ${REMOTE_NAMESPACE} -l postgres-operator.crunchydata.com/cluster \
                    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.data.user}{"|"}{.data.password}{"|"}{.data.host}{"|"}{.data.port}{"|"}{.data.dbname}{"\n"}{end}' 2>/dev/null > /tmp/raw_secrets.txt

                  cat <<EOC > /tmp/sources.yaml
              # Auto-discovered Crunchy PGO Databases (${CLUSTER_NAME})
              EOC

                  grep '\-pguser-' /tmp/raw_secrets.txt | while IFS='|' read -r SEC U_B64 P_B64 H_B64 PORT_B64 DB_B64; do
                    U=\$(echo "\$U_B64" | base64 -d 2>/dev/null)
                    P=\$(echo "\$P_B64" | base64 -d 2>/dev/null)
                    H=\$(echo "\$H_B64" | base64 -d 2>/dev/null)
                    PORT=\$(echo "\$PORT_B64" | base64 -d 2>/dev/null)
                    DB=\$(echo "\$DB_B64" | base64 -d 2>/dev/null)
                    CLUSTER=\$(echo "\$SEC" | sed 's/-pguser-.*//')
                    USER_TAG=\$(echo "\$SEC" | sed 's/.*-pguser-//')

                    if [ -n "\$U" ] && [ -n "\$P" ] && [ -n "\$H" ]; then
                      cat <<EOC >> /tmp/sources.yaml
              - name: crunchy_${CLUSTER_NAME}_\${CLUSTER}_\${USER_TAG}
                conn_str: "host=\${H} port=\${PORT:-5432} user=\${U} password='\${P}' dbname=\${DB:-postgres} sslmode=disable"
                preset_metrics: minimal
                is_enabled: true
              EOC
                    fi
                  done

                  kubectl --server="\$API_URL" --token="\$CLUSTER_TOKEN" --insecure-skip-tls-verify \
                    create configmap pgwatch-sources-cm -n ${REMOTE_NAMESPACE} \
                    --from-file=sources.yaml=/tmp/sources.yaml \
                    --dry-run=client -o yaml | \
                    kubectl --server="\$API_URL" --token="\$CLUSTER_TOKEN" --insecure-skip-tls-verify \
                    apply -n ${REMOTE_NAMESPACE} -f - 2>/dev/null
                fi
                sleep 30
              done
EOF

# 4. Patch Prometheus Host Aliases (Idempotent Merge)
echo "[4/6] Patching Prometheus DNS Host Aliases..."
API_HOST=$(echo ${API_URL} | sed -E 's|https://([^:]+):.*|\1|')

CURRENT_ALIASES=$(kubectl get prometheus prometheus-stack-kube-prom-prometheus -n monitoring -o json 2>/dev/null | jq '.spec.hostAliases // []')

# Remove existing entries for API_HOST / METRICS_HOST if present, then append fresh IPs
UPDATED_ALIASES=$(echo "$CURRENT_ALIASES" | jq \
  --arg api_ip "$API_IP" --arg api_host "$API_HOST" \
  --arg ing_ip "$INGRESS_IP" --arg ing_host "$METRICS_HOST" \
  'map(select(.hostnames[] | contains($api_host) or contains($ing_host) | not)) + [{"ip": $api_ip, "hostnames": [$api_host]}, {"ip": $ing_ip, "hostnames": [$ing_host]}]')

kubectl patch prometheus prometheus-stack-kube-prom-prometheus -n monitoring --type='merge' \
  -p "{\"spec\":{\"hostAliases\": $UPDATED_ALIASES}}"

# Force rollout restart so Prometheus pods reload /etc/hosts immediately
kubectl rollout restart statefulset/prometheus-prometheus-stack-kube-prom-prometheus -n monitoring

# 5. Create Prometheus ScrapeConfig
echo "[5/6] Creating Prometheus ScrapeConfig..."
SCRAPE_FILE="${REPO_ROOT}/base/scrape-configs/prometheus-${CLUSTER_NAME}-scrape.yaml"
KUSTOMIZE_FILE="${REPO_ROOT}/base/scrape-configs/kustomization.yaml"

cat <<EOF > "$SCRAPE_FILE"
apiVersion: monitoring.coreos.com/v1alpha1
kind: ScrapeConfig
metadata:
  name: pgwatch-crunchy-${CLUSTER_NAME}-dev
  namespace: monitoring
  labels:
    release: prometheus-stack
spec:
  scheme: HTTPS
  scrapeInterval: 30s
  scrapeTimeout: 15s
  tlsConfig:
    insecureSkipVerify: true
  staticConfigs:
    - targets:
        - "${METRICS_HOST}:443"
      labels:
        environment: ${REMOTE_NAMESPACE}
        cluster: ${CLUSTER_NAME}
        job: pgwatch-crunchy-exporter
EOF

if ! grep -q "prometheus-${CLUSTER_NAME}-scrape.yaml" "$KUSTOMIZE_FILE"; then
  echo "  - prometheus-${CLUSTER_NAME}-scrape.yaml" >> "$KUSTOMIZE_FILE"
fi

kubectl apply -k "${REPO_ROOT}/base/scrape-configs/"

# 6. Verification Test
echo "[6/6] Verifying endpoint availability..."
sleep 5
HTTP_CODE=$(curl -k -o /dev/null -s -w "%{http_code}" "https://${METRICS_HOST}/metrics" || echo "000")

echo "=================================================="
if [ "$HTTP_CODE" -eq 200 ]; then
  echo " SUCCESS: Cluster ${CLUSTER_NAME} onboarded! (Endpoint HTTP 200 OK)"
else
  echo " WARNING: Endpoint returned HTTP $HTTP_CODE. Check pod rollout or DNS."
fi
echo "=================================================="
