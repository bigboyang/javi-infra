#!/usr/bin/env bash
# Generates SealedSecrets for the apm namespace using kubeseal.
#
# Prerequisites:
#   brew install kubeseal
#   kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/latest/download/controller.yaml
#
# Usage:
#   1. Edit the plain-text secret blocks below with real values.
#   2. Run: ./scripts/seal-secrets.sh
#   3. Commit the resulting files in k8s/overlays/prod/sealed-secrets/
set -euo pipefail

NAMESPACE="apm"
OUT_DIR="$(dirname "$0")/../k8s/overlays/prod/sealed-secrets"

seal() {
  local name="$1"
  local src="$2"
  echo "  sealing ${name}..."
  kubeseal --namespace "${NAMESPACE}" --format yaml < "${src}" > "${OUT_DIR}/${name}.yaml"
}

# ---------------------------------------------------------------------------
# Step 1: write plaintext files to /tmp  (never committed to git)
# ---------------------------------------------------------------------------

cat > /tmp/clickhouse-secret.plain.yaml <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: clickhouse-secret
  namespace: apm
type: Opaque
stringData:
  username: "default"
  password: "REPLACE_WITH_REAL_PASSWORD"
EOF

cat > /tmp/collector-secret.plain.yaml <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: collector-secret
  namespace: apm
type: Opaque
stringData:
  CLICKHOUSE_PASSWORD: "REPLACE_WITH_REAL_PASSWORD"
  API_KEY: "REPLACE_WITH_REAL_API_KEY"
  ALERT_WEBHOOK_URL: ""
  ALERT_SLACK_WEBHOOK_URL: ""
  EMBED_ENDPOINT: "http://ollama:11434"
  QDRANT_ENDPOINT: "http://qdrant:6333"
EOF

cat > /tmp/forecast-secret.plain.yaml <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: forecast-secret
  namespace: apm
type: Opaque
stringData:
  slack_webhook_url: ""
  anthropic_api_key: "REPLACE_WITH_REAL_API_KEY"
  redis_url: "redis://redis-svc:6379"
EOF

echo "Plaintext secrets written to /tmp/*.plain.yaml"
echo "Edit those files with real values, then press ENTER to seal."
read -r

# ---------------------------------------------------------------------------
# Step 2: seal each secret
# ---------------------------------------------------------------------------
seal "clickhouse-sealed-secret"  /tmp/clickhouse-secret.plain.yaml
seal "collector-sealed-secret"   /tmp/collector-secret.plain.yaml
seal "forecast-sealed-secret"    /tmp/forecast-secret.plain.yaml

# Remove plaintext files from /tmp
rm -f /tmp/clickhouse-secret.plain.yaml /tmp/collector-secret.plain.yaml /tmp/forecast-secret.plain.yaml

echo ""
echo "Done. Commit the sealed secrets:"
echo "  git add ${OUT_DIR}/"
echo "  git commit -m 'chore: rotate sealed secrets'"
