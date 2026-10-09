#!/usr/bin/env bash
set -e

CUR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${CUR_DIR}/.." && pwd)"

if [ -z "$1" ] || [ -z "$2" ]; then
  echo "Usage: ./promote-cluster.sh <path-to-cluster.env> <target-env (staging|prod)>"
  exit 1
fi

source "$1"
NEW_ENV="$2"
OLD_ENV="${TARGET_ENV:-staging}"

if [ "$OLD_ENV" == "$NEW_ENV" ]; then
  echo "Cluster ${CLUSTER_NAME} is already in environment '${NEW_ENV}'."
  exit 0
fi

echo "=================================================="
echo " Promoting Cluster: ${CLUSTER_NAME} (${OLD_ENV} -> ${NEW_ENV})"
echo "=================================================="

SRC_DIR="${REPO_ROOT}/base/scrape-configs/${OLD_ENV}"
DEST_DIR="${REPO_ROOT}/base/scrape-configs/${NEW_ENV}"
SRC_FILE="${SRC_DIR}/prometheus-${CLUSTER_NAME}-scrape.yaml"
DEST_FILE="${DEST_DIR}/prometheus-${CLUSTER_NAME}-scrape.yaml"

if [ ! -f "$SRC_FILE" ]; then
  echo "Error: Source scrape manifest not found at ${SRC_FILE}!"
  exit 1
fi

# 1. Move file and update environment labels
mkdir -p "$DEST_DIR"
mv "$SRC_FILE" "$DEST_FILE"
sed -i "s/environment: ${OLD_ENV}/environment: ${NEW_ENV}/g" "$DEST_FILE"

# 2. Update source environment kustomization.yaml
REMAINING_SRC=$(find "${SRC_DIR}" -maxdepth 1 -name "prometheus-*.yaml" -exec basename {} \; 2>/dev/null | sort || true)
cat <<EOF > "${SRC_DIR}/kustomization.yaml"
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
EOF
if [ -z "$REMAINING_SRC" ]; then
  echo "resources: []" > "${SRC_DIR}/kustomization.yaml"
else
  for file in $REMAINING_SRC; do
    echo "  - $file" >> "${SRC_DIR}/kustomization.yaml"
  done
fi

# 3. Update destination environment kustomization.yaml
ALL_DEST=$(find "${DEST_DIR}" -maxdepth 1 -name "prometheus-*.yaml" -exec basename {} \; 2>/dev/null | sort || true)
cat <<EOF > "${DEST_DIR}/kustomization.yaml"
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
EOF
for file in $ALL_DEST; do
  echo "  - $file" >> "${DEST_DIR}/kustomization.yaml"
done

# 4. Update TARGET_ENV in the cluster .env file
sed -i "s/TARGET_ENV=.*/TARGET_ENV=\"${NEW_ENV}\"/" "$1"

# 5. Commit and push promotion to Git
git -C "${REPO_ROOT}" add base/scrape-configs/ clusters/
git -C "${REPO_ROOT}" commit -m "promote: move cluster ${CLUSTER_NAME} from ${OLD_ENV} to ${NEW_ENV}" || true
git -C "${REPO_ROOT}" push origin main

echo "=================================================="
echo " SUCCESS: Cluster ${CLUSTER_NAME} promoted to ${NEW_ENV}!"
echo " ArgoCD will prune from ${OLD_ENV} and deploy to ${NEW_ENV}."
echo "=================================================="
