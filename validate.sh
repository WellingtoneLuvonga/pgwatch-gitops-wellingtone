#!/usr/bin/env bash
set -e

ERRORS=0

echo "🔍 Running GitOps repository pre-commit checks..."

# 1. Verify critical root paths
REQUIRED_PATHS=(
  "base/kustomization.yaml"
  "custom-values.yaml"
  "sealed-sources.yaml"
  "argocd"
)

for path in "${REQUIRED_PATHS[@]}"; do
  if [ ! -e "$path" ]; then
    echo "❌ Missing required path: $path"
    ERRORS=$((ERRORS + 1))
  fi
done

# 2. Validate overlay folder depth and relative Kustomize base path
if [ -d "overlays" ]; then
  for overlay_dir in overlays/*/*; do
    if [ -d "$overlay_dir" ]; then
      echo "📁 Checking overlay: $overlay_dir"
      
      # Ensure kustomization.yaml exists
      if [ ! -f "$overlay_dir/kustomization.yaml" ]; then
        echo "  ❌ Missing kustomization.yaml in $overlay_dir"
        ERRORS=$((ERRORS + 1))
        continue
      fi

      # Verify correct relative path depth '../../../base'
      if ! grep -q '\.\./\.\./\.\./base' "$overlay_dir/kustomization.yaml"; then
        echo "  ❌ Invalid base path in $overlay_dir/kustomization.yaml (Must be '../../../base')"
        ERRORS=$((ERRORS + 1))
      fi

      # Dry-run Kustomize build to ensure YAML syntax and patches compile
      if command -v kubectl &> /dev/null; then
        if ! kubectl kustomize "$overlay_dir" > /dev/null 2>&1; then
          echo "  ❌ Kustomize compilation failed for $overlay_dir"
          ERRORS=$((ERRORS + 1))
        fi
      fi
    fi
  done
fi

# 3. Fail commit if errors are detected
if [ $ERRORS -gt 0 ]; then
  echo -e "\n🛑 Pre-commit check failed with $ERRORS error(s). Fix issues before committing."
  exit 1
else
  echo -e "\n✅ All structure checks and Kustomize builds passed!"
  exit 0
fi
