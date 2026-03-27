#!/bin/bash

# Validation script for Batch 2: Secret Management Jobs RBAC
# Tests least-privilege permissions for loki-s3-secret-creator and grafana-datasource-configurator ServiceAccounts

set -e

PASS_COUNT=0
FAIL_COUNT=0

echo "========================================="
echo "Batch 2: Secret Management RBAC Validation"
echo "========================================="
echo ""

# Function to test permission (should have)
test_permission_allowed() {
    local sa=$1
    local verb=$2
    local resource=$3
    local namespace=$4
    local description=$5

    if oc auth can-i "$verb" "$resource" -n "$namespace" --as="system:serviceaccount:openshift-gitops:$sa" &>/dev/null; then
        echo "✅ PASS: $description"
        ((PASS_COUNT++))
        return 0
    else
        echo "❌ FAIL: $description (should be ALLOWED)"
        ((FAIL_COUNT++))
        return 1
    fi
}

# Function to test permission (should not have)
test_permission_denied() {
    local sa=$1
    local verb=$2
    local resource=$3
    local namespace=$4
    local description=$5

    if ! oc auth can-i "$verb" "$resource" -n "$namespace" --as="system:serviceaccount:openshift-gitops:$sa" &>/dev/null; then
        echo "✅ PASS: $description (correctly blocked)"
        ((PASS_COUNT++))
        return 0
    else
        echo "❌ FAIL: $description (should be BLOCKED)"
        ((FAIL_COUNT++))
        return 1
    fi
}

echo "================================================"
echo "Testing loki-s3-secret-creator ServiceAccount"
echo "================================================"
echo ""
echo "✅ Should HAVE permission:"
test_permission_allowed "loki-s3-secret-creator" "get" "secrets" "openshift-logging" "get secrets in openshift-logging"
test_permission_allowed "loki-s3-secret-creator" "create" "secrets" "openshift-logging" "create secrets in openshift-logging"
test_permission_allowed "loki-s3-secret-creator" "delete" "secrets" "openshift-logging" "delete secrets in openshift-logging"
test_permission_allowed "loki-s3-secret-creator" "get" "secrets" "netobserv" "get secrets in netobserv"
test_permission_allowed "loki-s3-secret-creator" "create" "secrets" "netobserv" "create secrets in netobserv"
test_permission_allowed "loki-s3-secret-creator" "delete" "secrets" "netobserv" "delete secrets in netobserv"

echo ""
echo "❌ Should NOT have permission:"
test_permission_denied "loki-s3-secret-creator" "delete" "pods" "openshift-logging" "delete pods"
test_permission_denied "loki-s3-secret-creator" "create" "namespaces" "" "create namespaces"
test_permission_denied "loki-s3-secret-creator" "get" "secrets" "kube-system" "get secrets in other namespaces"
test_permission_denied "loki-s3-secret-creator" "patch" "consoles" "" "patch consoles"
test_permission_denied "loki-s3-secret-creator" "get" "secrets" "default" "get secrets in default namespace"

echo ""
echo "================================================"
echo "Testing grafana-datasource-configurator ServiceAccount"
echo "================================================"
echo ""
echo "✅ Should HAVE permission:"
test_permission_allowed "grafana-datasource-configurator" "get" "secrets" "monitoring" "get secrets in monitoring"
test_permission_allowed "grafana-datasource-configurator" "list" "secrets" "monitoring" "list secrets in monitoring"
test_permission_allowed "grafana-datasource-configurator" "get" "serviceaccounts" "monitoring" "get serviceaccounts in monitoring"
test_permission_allowed "grafana-datasource-configurator" "get" "grafanadatasources" "monitoring" "get grafanadatasources in monitoring"
test_permission_allowed "grafana-datasource-configurator" "patch" "grafanadatasources" "monitoring" "patch grafanadatasources in monitoring"

echo ""
echo "❌ Should NOT have permission:"
test_permission_denied "grafana-datasource-configurator" "delete" "secrets" "monitoring" "delete secrets"
test_permission_denied "grafana-datasource-configurator" "create" "secrets" "monitoring" "create secrets"
test_permission_denied "grafana-datasource-configurator" "delete" "pods" "monitoring" "delete pods"
test_permission_denied "grafana-datasource-configurator" "create" "namespaces" "" "create namespaces"
test_permission_denied "grafana-datasource-configurator" "get" "secrets" "kube-system" "get secrets in other namespaces"
test_permission_denied "grafana-datasource-configurator" "patch" "consoles" "" "patch consoles"

echo ""
echo "========================================="
echo "Validation Summary"
echo "========================================="
echo "Total tests: $((PASS_COUNT + FAIL_COUNT))"
echo "Passed: $PASS_COUNT"
echo "Failed: $FAIL_COUNT"
echo ""

if [ $FAIL_COUNT -eq 0 ]; then
    echo "✅ All RBAC validations passed!"
    exit 0
else
    echo "❌ Some RBAC validations failed!"
    exit 1
fi
