#!/bin/bash

# Validation script for Batch 4: Cleanup Jobs RBAC
# Tests least-privilege permissions for cleanup-operator ServiceAccount

set -e

PASS_COUNT=0
FAIL_COUNT=0
SA="cleanup-operator"

echo "========================================="
echo "Batch 4: Cleanup Jobs RBAC Validation"
echo "========================================="
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
test_permission_allowed "$SA" "delete" "namespaces" "" "delete namespaces"
test_permission_allowed "$SA" "delete" "openshiftbuilds.operator.openshift.io" "" "delete openshiftbuilds"

echo ""
echo "❌ Should NOT have permission:"
test_permission_denied "$SA" "create" "namespaces" "" "create namespaces"
test_permission_denied "$SA" "delete" "clusterroles" "" "delete clusterroles"
test_permission_denied "$SA" "create" "openshiftbuilds.operator.openshift.io" "" "create openshiftbuilds"
test_permission_denied "$SA" "get" "openshiftbuilds.operator.openshift.io" "" "get openshiftbuilds"

echo ""
echo "================================================"
echo "Testing openshift-kube-controller-manager Namespace Permissions"
echo "================================================"
echo ""
echo "✅ Should HAVE permission:"
test_permission_allowed "$SA" "list" "pods" "openshift-kube-controller-manager" "list pods in openshift-kube-controller-manager"
test_permission_allowed "$SA" "delete" "pods" "openshift-kube-controller-manager" "delete pods in openshift-kube-controller-manager"

echo ""
echo "❌ Should NOT have permission:"
test_permission_denied "$SA" "create" "pods" "openshift-kube-controller-manager" "create pods in openshift-kube-controller-manager"
test_permission_denied "$SA" "patch" "pods" "openshift-kube-controller-manager" "patch pods in openshift-kube-controller-manager"
test_permission_denied "$SA" "delete" "pods" "kube-system" "delete pods in other namespaces"
test_permission_denied "$SA" "list" "pods" "default" "list pods in other namespaces"
test_permission_denied "$SA" "delete" "deployments" "openshift-kube-controller-manager" "delete deployments"

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
