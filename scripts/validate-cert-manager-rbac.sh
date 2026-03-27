#!/bin/bash

# Validation script for Batch 3: cert-manager Jobs RBAC
# Tests least-privilege permissions for cert-manager-operator ServiceAccount
# CRITICAL: Validates permissions for TLS certificate management (cluster API, ingress)

set -e

PASS_COUNT=0
FAIL_COUNT=0
SA="cert-manager-operator"

echo "========================================="
echo "Batch 3: cert-manager RBAC Validation"
echo "========================================="
echo ""
echo "⚠️  CRITICAL: Testing TLS certificate management permissions"
echo ""

# Function to test permission (should have)
test_permission_allowed() {
    local sa=$1
    local verb=$2
    local resource=$3
    local namespace=$4
    local description=$5

    local ns_flag=""
    if [ -n "$namespace" ]; then
        ns_flag="-n $namespace"
    fi

    if oc auth can-i "$verb" "$resource" $ns_flag --as="system:serviceaccount:openshift-gitops:$sa" &>/dev/null; then
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

    local ns_flag=""
    if [ -n "$namespace" ]; then
        ns_flag="-n $namespace"
    fi

    if ! oc auth can-i "$verb" "$resource" $ns_flag --as="system:serviceaccount:openshift-gitops:$sa" &>/dev/null; then
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
echo "Testing Cluster-Scoped Permissions"
echo "================================================"
echo ""
echo "✅ Should HAVE permission:"
test_permission_allowed "$SA" "get" "customresourcedefinitions" "" "get CRDs"
test_permission_allowed "$SA" "get" "certmanagers.operator.openshift.io" "" "get certmanagers"
test_permission_allowed "$SA" "list" "certmanagers.operator.openshift.io" "" "list certmanagers"
test_permission_allowed "$SA" "delete" "certmanagers.operator.openshift.io" "" "delete certmanagers"
test_permission_allowed "$SA" "create" "clusterissuers.cert-manager.io" "" "create clusterissuers"
test_permission_allowed "$SA" "get" "clusterissuers.cert-manager.io" "" "get clusterissuers"
test_permission_allowed "$SA" "patch" "clusterissuers.cert-manager.io" "" "patch clusterissuers"
test_permission_allowed "$SA" "update" "clusterissuers.cert-manager.io" "" "update clusterissuers"
test_permission_allowed "$SA" "get" "infrastructures.config.openshift.io" "" "get infrastructures"
test_permission_allowed "$SA" "get" "dnses.config.openshift.io" "" "get dnses"
test_permission_allowed "$SA" "get" "apiservers.config.openshift.io" "" "get apiservers"
test_permission_allowed "$SA" "patch" "apiservers.config.openshift.io" "" "patch apiservers"

echo ""
echo "❌ Should NOT have permission:"
test_permission_denied "$SA" "delete" "apiservers.config.openshift.io" "" "delete apiservers"
test_permission_denied "$SA" "delete" "clusterissuers.cert-manager.io" "" "delete clusterissuers"
test_permission_denied "$SA" "create" "namespaces" "" "create namespaces"

echo ""
echo "================================================"
echo "Testing cert-manager Namespace Permissions"
echo "================================================"
echo ""
echo "✅ Should HAVE permission:"
test_permission_allowed "$SA" "get" "pods" "cert-manager" "get pods in cert-manager"
test_permission_allowed "$SA" "list" "pods" "cert-manager" "list pods in cert-manager"
test_permission_allowed "$SA" "create" "secrets" "cert-manager" "create secrets in cert-manager"
test_permission_allowed "$SA" "delete" "secrets" "cert-manager" "delete secrets in cert-manager"

echo ""
echo "❌ Should NOT have permission:"
test_permission_denied "$SA" "delete" "pods" "cert-manager" "delete pods in cert-manager"
test_permission_denied "$SA" "patch" "deployments" "cert-manager" "patch deployments in cert-manager"

echo ""
echo "================================================"
echo "Testing kube-system Namespace Permissions (AWS Credentials)"
echo "================================================"
echo ""
echo "✅ Should HAVE permission (READ ONLY):"
test_permission_allowed "$SA" "get" "secrets" "kube-system" "get secrets in kube-system"

echo ""
echo "❌ Should NOT have permission:"
test_permission_denied "$SA" "create" "secrets" "kube-system" "create secrets in kube-system"
test_permission_denied "$SA" "delete" "secrets" "kube-system" "delete secrets in kube-system"
test_permission_denied "$SA" "patch" "secrets" "kube-system" "patch secrets in kube-system"

echo ""
echo "================================================"
echo "Testing openshift-ingress Namespace Permissions"
echo "================================================"
echo ""
echo "✅ Should HAVE permission:"
test_permission_allowed "$SA" "create" "certificates.cert-manager.io" "openshift-ingress" "create certificates in openshift-ingress"
test_permission_allowed "$SA" "get" "certificates.cert-manager.io" "openshift-ingress" "get certificates in openshift-ingress"
test_permission_allowed "$SA" "list" "certificates.cert-manager.io" "openshift-ingress" "list certificates in openshift-ingress"
test_permission_allowed "$SA" "patch" "certificates.cert-manager.io" "openshift-ingress" "patch certificates in openshift-ingress"
test_permission_allowed "$SA" "update" "certificates.cert-manager.io" "openshift-ingress" "update certificates in openshift-ingress"

echo ""
echo "❌ Should NOT have permission:"
test_permission_denied "$SA" "delete" "certificates.cert-manager.io" "openshift-ingress" "delete certificates in openshift-ingress"
test_permission_denied "$SA" "create" "secrets" "openshift-ingress" "create secrets in openshift-ingress"

echo ""
echo "================================================"
echo "Testing openshift-config Namespace Permissions"
echo "================================================"
echo ""
echo "✅ Should HAVE permission:"
test_permission_allowed "$SA" "create" "certificates.cert-manager.io" "openshift-config" "create certificates in openshift-config"
test_permission_allowed "$SA" "get" "certificates.cert-manager.io" "openshift-config" "get certificates in openshift-config"
test_permission_allowed "$SA" "list" "certificates.cert-manager.io" "openshift-config" "list certificates in openshift-config"
test_permission_allowed "$SA" "patch" "certificates.cert-manager.io" "openshift-config" "patch certificates in openshift-config"
test_permission_allowed "$SA" "update" "certificates.cert-manager.io" "openshift-config" "update certificates in openshift-config"

echo ""
echo "❌ Should NOT have permission:"
test_permission_denied "$SA" "delete" "certificates.cert-manager.io" "openshift-config" "delete certificates in openshift-config"
test_permission_denied "$SA" "create" "secrets" "openshift-config" "create secrets in openshift-config"

echo ""
echo "================================================"
echo "Testing openshift-ingress-operator Namespace Permissions"
echo "================================================"
echo ""
echo "✅ Should HAVE permission:"
test_permission_allowed "$SA" "get" "ingresscontrollers.operator.openshift.io" "openshift-ingress-operator" "get ingresscontrollers"
test_permission_allowed "$SA" "patch" "ingresscontrollers.operator.openshift.io" "openshift-ingress-operator" "patch ingresscontrollers"

echo ""
echo "❌ Should NOT have permission:"
test_permission_denied "$SA" "delete" "ingresscontrollers.operator.openshift.io" "openshift-ingress-operator" "delete ingresscontrollers"
test_permission_denied "$SA" "create" "ingresscontrollers.operator.openshift.io" "openshift-ingress-operator" "create ingresscontrollers"

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
    echo ""
    echo "⚠️  Next steps:"
    echo "1. Monitor cert-manager Jobs execution"
    echo "2. Verify certificates remain valid"
    echo "3. Test cluster API accessibility"
    echo "4. Test ingress routing"
    exit 0
else
    echo "❌ Some RBAC validations failed!"
    echo ""
    echo "⚠️  DO NOT PROCEED - Fix RBAC before deployment"
    exit 1
fi
