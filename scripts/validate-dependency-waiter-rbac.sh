#!/bin/bash

# Validation script for Batch 5: Dependency Waiter Job RBAC
# Tests least-privilege permissions for dependency-waiter ServiceAccount

set -e

PASS_COUNT=0
FAIL_COUNT=0
SA="dependency-waiter"

echo "========================================="
echo "Batch 5: Dependency Waiter RBAC Validation"
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
echo "Testing openshift-operators Namespace Permissions"
echo "================================================"
echo ""
echo "✅ Should HAVE permission (READ ONLY):"
test_permission_allowed "$SA" "get" "subscriptions.operators.coreos.com" "openshift-operators" "get subscriptions in openshift-operators"
test_permission_allowed "$SA" "list" "subscriptions.operators.coreos.com" "openshift-operators" "list subscriptions in openshift-operators"
test_permission_allowed "$SA" "get" "installplans.operators.coreos.com" "openshift-operators" "get installplans in openshift-operators"

echo ""
echo "❌ Should NOT have permission:"
test_permission_denied "$SA" "create" "subscriptions.operators.coreos.com" "openshift-operators" "create subscriptions"
test_permission_denied "$SA" "delete" "subscriptions.operators.coreos.com" "openshift-operators" "delete subscriptions"
test_permission_denied "$SA" "patch" "subscriptions.operators.coreos.com" "openshift-operators" "patch subscriptions"
test_permission_denied "$SA" "update" "subscriptions.operators.coreos.com" "openshift-operators" "update subscriptions"
test_permission_denied "$SA" "create" "installplans.operators.coreos.com" "openshift-operators" "create installplans"
test_permission_denied "$SA" "delete" "installplans.operators.coreos.com" "openshift-operators" "delete installplans"
test_permission_denied "$SA" "list" "installplans.operators.coreos.com" "openshift-operators" "list installplans"
test_permission_denied "$SA" "get" "subscriptions.operators.coreos.com" "default" "get subscriptions in other namespaces"
test_permission_denied "$SA" "get" "pods" "openshift-operators" "get pods"
test_permission_denied "$SA" "delete" "namespaces" "" "delete namespaces"

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
    echo "Security: Read-only access to Subscriptions and InstallPlans"
    exit 0
else
    echo "❌ Some RBAC validations failed!"
    exit 1
fi
