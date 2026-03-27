#!/bin/bash

# Batch 7: Validate ODF Subscription Configurator RBAC
# Tests least-privilege permissions for odf-subscription-configurator ServiceAccount

set -e

echo "=== Batch 7.2: ODF Subscription Configurator RBAC Validation ==="
echo ""

SA_NAME="odf-subscription-configurator"
SA_NAMESPACE="openshift-gitops"

echo "Testing ServiceAccount: $SA_NAME in namespace $SA_NAMESPACE"
echo ""

# Test 1: openshift-gitops namespace permissions (configmaps)
echo "1. Testing openshift-gitops namespace permissions:"
oc auth can-i get configmaps --as=system:serviceaccount:$SA_NAMESPACE:$SA_NAME -n openshift-gitops && echo "  ✓ Can get configmaps in openshift-gitops" || echo "  ✗ FAIL: Cannot get configmaps in openshift-gitops"
echo ""

# Test 2: openshift-storage namespace permissions (subscriptions)
echo "2. Testing openshift-storage namespace permissions:"
oc auth can-i get subscriptions.operators.coreos.com --as=system:serviceaccount:$SA_NAMESPACE:$SA_NAME -n openshift-storage && echo "  ✓ Can get subscriptions in openshift-storage" || echo "  ✗ FAIL: Cannot get subscriptions in openshift-storage"
oc auth can-i patch subscriptions.operators.coreos.com --as=system:serviceaccount:$SA_NAMESPACE:$SA_NAME -n openshift-storage && echo "  ✓ Can patch subscriptions in openshift-storage" || echo "  ✗ FAIL: Cannot patch subscriptions in openshift-storage"
echo ""

# Test 3: Verify no cluster-admin (negative test)
echo "3. Verifying NO excessive permissions (should all FAIL):"
oc auth can-i create namespaces --as=system:serviceaccount:$SA_NAMESPACE:$SA_NAME && echo "  ✗ SECURITY ISSUE: Can create namespaces (should not be allowed)" || echo "  ✓ Correctly denied: Cannot create namespaces"
oc auth can-i delete nodes --as=system:serviceaccount:$SA_NAMESPACE:$SA_NAME && echo "  ✗ SECURITY ISSUE: Can delete nodes (should not be allowed)" || echo "  ✓ Correctly denied: Cannot delete nodes"
oc auth can-i '*' '*' --as=system:serviceaccount:$SA_NAMESPACE:$SA_NAME && echo "  ✗ SECURITY ISSUE: Has wildcard permissions (should not be allowed)" || echo "  ✓ Correctly denied: No wildcard permissions"
echo ""

# Test 4: Verify ServiceAccount exists and has correct RBAC bindings
echo "4. Verifying RBAC resources exist:"
oc get serviceaccount $SA_NAME -n $SA_NAMESPACE &>/dev/null && echo "  ✓ ServiceAccount exists" || echo "  ✗ FAIL: ServiceAccount not found"
oc get role odf-subscription-configurator -n openshift-gitops &>/dev/null && echo "  ✓ Role exists in openshift-gitops" || echo "  ✗ FAIL: Role not found in openshift-gitops"
oc get rolebinding odf-subscription-configurator -n openshift-gitops &>/dev/null && echo "  ✓ RoleBinding exists in openshift-gitops" || echo "  ✗ FAIL: RoleBinding not found in openshift-gitops"
oc get role odf-subscription-configurator -n openshift-storage &>/dev/null && echo "  ✓ Role exists in openshift-storage" || echo "  ✗ FAIL: Role not found in openshift-storage"
oc get rolebinding odf-subscription-configurator -n openshift-storage &>/dev/null && echo "  ✓ RoleBinding exists in openshift-storage" || echo "  ✗ FAIL: RoleBinding not found in openshift-storage"
echo ""

echo "=== Validation Complete ==="
