#!/usr/bin/env bash
set -e

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

# 3. Clean ScrapeConfig Manifests & Push Deletion to Git (ArgoCD Auto-Prunes)
echo "[3/5] Cleaning up Git manifests for ArgoCD auto-pruning..."

SCRAPE_DIR="${REPO_ROOT}/base/scrape-configs"
KUSTOMIZE_FILE="${SCRAPE_DIR}/kustomization.yaml"

# Delete cluster scrape file
rm -f "${SCRAPE_DIR}/"*"${CLUSTER_NAME}"*.yaml

# Rebuild kustomization.yaml cleanly based on remaining files
REMAINING_FILES=$(find "${SCRAPE_DIR}" -maxdepth 1 -name "prometheus-*.yaml" -exec basename {} \; 2>/dev/null || true)

if [ -z "$REMAINING_FILES" ]; then
  cat <<EOF > "$KUSTOMIZE_FILE"
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []
EOF
else
  cat <<EOF > "$KUSTOMIZE_FILE"
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
EOF
  for file in $REMAINING_FILES; do
    echo "  - $file" >> "$KUSTOMIZE_FILE"
  done
fi

git -C "${REPO_ROOT}" add base/scrape-configs/
git -C "${REPO_ROOT}" commit -m "offboard: remove scrape configs for ${CLUSTER_NAME}" || true
git -C "${REPO_ROOT}" push origin main

# 4. Clean up Prometheus Host Aliases & Restart Pod
echo "[4/5] Removing DNS hostAliases from Prometheus..."
CURRENT_ALIASES=$(kubectl get prometheus prometheus-stack-kube-prom-prometheus -n monitoring -o json 2>/dev/null | jq '.spec.hostAliases // []')

if [ -n "$CURRENT_ALIASES" ] && [ "$CURRENT_ALIASES" != "[]" ]; then
  UPDATED_ALIASES=$(echo "$CURRENT_ALIASES" | jq \
    --arg api "$API_HOST" \
    --arg metrics "$METRICS_HOST" \
    --arg pgo "${PGO_FEDERATE_HOST:-}" \
    '([.[]? | .ip as $ip | .hostnames[]? | {ip: $ip, host: .}]
      | map(select(.host | (contains($api) or contains($metrics) or ($pgo != "" and contains($pgo))) | not))
     )
     | group_by(.ip)
     | map({ip: .[0].ip, hostnames: [.[].host] | unique})')
  
  kubectl patch prometheus prometheus-stack-kube-prom-prometheus -n monitoring --type='merge' \
    -p "{\"spec\":{\"hostAliases\": $UPDATED_ALIASES}}"
fi

kubectl rollout restart statefulset/prometheus-prometheus-stack-kube-prom-prometheus -n monitoring

# 5. Final Verification
echo "[5/5] Verifying offboarding status..."
sleep 3
HTTP_CODE=$(curl -k -o /dev/null -s -w "%{http_code}" "https://${METRICS_HOST}/metrics" || echo "000")

echo "=================================================="
echo " OFFBOARDING COMPLETE: Cluster ${CLUSTER_NAME} offboarded."
echo " Endpoint status post-cleanup: HTTP ${HTTP_CODE} (Expected: 503 or 000/timeout)"
echo " ArgoCD will auto-prune ScrapeConfig resources upon syncing with Git."
echo "=================================================="
