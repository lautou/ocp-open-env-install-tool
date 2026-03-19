#!/bin/bash
# Audit Alertmanager configuration for sensitive data
# Ensures no secrets/credentials are stored in GitOps-managed alertmanager config

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$PROJECT_ROOT/components/cluster-monitoring/base/openshift-monitoring-secret-alertmanager-main.yaml"

echo "========================================="
echo "Alertmanager Configuration Security Audit"
echo "========================================="
echo ""
echo "Scanning: $CONFIG_FILE"
echo ""

# Check if file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ ERROR: Alertmanager configuration file not found!"
    echo "Expected: $CONFIG_FILE"
    exit 1
fi

# Patterns that might indicate secrets (case-insensitive)
PATTERNS=(
    "api_key"
    "api_token"
    "auth_token"
    "password"
    "secret"
    "webhook.*http"
    "slack_api_url"
    "pagerduty_url"
    "victorops_api_key"
    "opsgenie_api_key"
    "email.*smtp"
    "smtp_auth_password"
    "bearer_token"
    "authorization"
)

FOUND=0
SUSPICIOUS_LINES=()

echo "Checking for sensitive patterns..."
echo ""

for pattern in "${PATTERNS[@]}"; do
    # Search for pattern, exclude comments and metadata
    matches=$(grep -inE "$pattern" "$CONFIG_FILE" | \
              grep -v "^[[:space:]]*#" | \
              grep -v "kind: Secret" | \
              grep -v "type: Opaque" | \
              grep -v "stringData:" | \
              grep -v "metadata:" | \
              grep -v "name: alertmanager-main" | \
              grep -v "namespace: openshift-monitoring" || true)

    if [ -n "$matches" ]; then
        echo "⚠️  WARNING: Potential secret found matching pattern: $pattern"
        echo "$matches"
        echo ""
        FOUND=1
        SUSPICIOUS_LINES+=("$pattern: $matches")
    fi
done

echo "========================================="
echo "Audit Summary"
echo "========================================="
echo ""

if [ $FOUND -eq 0 ]; then
    echo "✅ PASS: No sensitive patterns detected in Alertmanager configuration"
    echo ""
    echo "The configuration contains only routing logic and alert silences."
    echo "Safe to commit to Git."
    exit 0
else
    echo "❌ FAIL: Potential secrets detected in Alertmanager configuration!"
    echo ""
    echo "Found ${#SUSPICIOUS_LINES[@]} suspicious pattern(s):"
    for line in "${SUSPICIOUS_LINES[@]}"; do
        echo "  - $line"
    done
    echo ""
    echo "RECOMMENDATIONS:"
    echo "1. Review the flagged lines above"
    echo "2. Remove any actual secrets/credentials from alertmanager.yaml"
    echo "3. Use Kubernetes Secret references for notification receivers"
    echo "4. Keep alertmanager.yaml credential-free for GitOps safety"
    echo ""
    echo "See KNOWN_BUGS.md for more information on secure configuration."
    exit 1
fi
