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
  echo "Usage: ./offboard-cluster.sh <path-to-cluster.env>"
  exit 1
fi

source "$1"

API_HOST=$(echo "${API_URL}" | sed -E 's|https://([^:]+):.*|\1|')

echo "=================================================="
echo " Offboarding Cluster: ${CLUSTER_NAME}"
echo "=================================================="

# 1. Remove Remote OpenShift Exporter Stack
echo "[1/5] Cleaning up remote OpenShift resources on ${CLUSTER_NAME}..."
kubectl --server="${API_URL}" --token="${OPENSHIFT_TOKEN}" --insecure-skip-tls-verify \
  delete deployment/pgwatch-exporter-agent service/pgwatch-exporter-agent route/pgwatch-metrics-dev configmap/pgwatch-sources-cm \
  -n "${REMOTE_NAMESPACE}" --ignore-not-found

# 2. Remove Minikube Watcher & Secret
echo "[2/5] Cleaning up Minikube discovery watcher and token secret..."
kubectl delete deployment "pgwatch-crunchy-watcher-${CLUSTER_NAME}" -n pgwatch --ignore-not-found
kubectl delete secret "${CLUSTER_NAME}-dev-token" -n pgwatch --ignore-not-found

# 3. Remove ScrapeConfig Manifests & Local Git File
echo "[3/5] Cleaning up Prometheus ScrapeConfig..."
kubectl delete scrapeconfig "pgwatch-crunchy-${CLUSTER_NAME}-dev" -n monitoring --ignore-not-found

SCRAPE_FILE="${REPO_ROOT}/base/scrape-configs/prometheus-${CLUSTER_NAME}-scrape.yaml"
KUSTOMIZE_FILE="${REPO_ROOT}/base/scrape-configs/kustomization.yaml"

if [ -f "$SCRAPE_FILE" ]; then
  rm -f "$SCRAPE_FILE"
fi

if [ -f "$KUSTOMIZE_FILE" ]; then
  sed -i "/prometheus-${CLUSTER_NAME}-scrape.yaml/d" "$KUSTOMIZE_FILE"
  kubectl apply -k "${REPO_ROOT}/base/scrape-configs/" || true
fi

# 4. Clean up Prometheus Host Aliases & Restart Pod
echo "[4/5] Removing DNS hostAliases from Prometheus..."
CURRENT_ALIASES=$(kubectl get prometheus prometheus-stack-kube-prom-prometheus -n monitoring -o jsonpath='{.spec.hostAliases}')

if [ -n "$CURRENT_ALIASES" ] && [ "$CURRENT_ALIASES" != "null" ]; then
  UPDATED_ALIASES=$(echo "$CURRENT_ALIASES" | jq --arg api "$API_HOST" --arg metrics "$METRICS_HOST" \
    'map(select(.hostnames[] | contains($api) or contains($metrics) | not))')
  
  kubectl patch prometheus prometheus-stack-kube-prom-prometheus -n monitoring --type='merge' \
    -p "{\"spec\":{\"hostAliases\": $UPDATED_ALIASES}}"
fi

# Force rollout restart so Prometheus instantly purges removed /etc/hosts entries
kubectl rollout restart statefulset/prometheus-prometheus-stack-kube-prom-prometheus -n monitoring

# 5. Final Verification
echo "[5/5] Verifying offboarding status..."
sleep 3
HTTP_CODE=$(curl -k -o /dev/null -s -w "%{http_code}" "https://${METRICS_HOST}/metrics" || echo "000")

echo "=================================================="
echo " OFFBOARDING COMPLETE: Cluster ${CLUSTER_NAME} removed."
echo " Endpoint status post-cleanup: HTTP ${HTTP_CODE} (Expected: 503 or 000/timeout)"
echo "=================================================="
