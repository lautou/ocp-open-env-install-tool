#!/bin/bash

# Batch 7: Validate MaaS Gateway Operator RBAC
# Tests least-privilege permissions for maas-gateway-operator ServiceAccount

set -e

echo "=== Batch 7.3: MaaS Gateway Operator RBAC Validation ==="
echo ""

SA_NAME="maas-gateway-operator"
SA_NAMESPACE="openshift-gitops"

echo "Testing ServiceAccount: $SA_NAME in namespace $SA_NAMESPACE"
echo ""

# Test 1: ClusterRole permissions (dnses.config.openshift.io)
echo "1. Testing cluster-scoped permissions:"
oc auth can-i get dnses.config.openshift.io --as=system:serviceaccount:$SA_NAMESPACE:$SA_NAME && echo "  ✓ Can get dnses" || echo "  ✗ FAIL: Cannot get dnses"
echo ""

# Test 2: openshift-ingress namespace permissions (gateways)
echo "2. Testing openshift-ingress namespace permissions:"
oc auth can-i get gateways.gateway.networking.k8s.io --as=system:serviceaccount:$SA_NAMESPACE:$SA_NAME -n openshift-ingress && echo "  ✓ Can get gateways in openshift-ingress" || echo "  ✗ FAIL: Cannot get gateways in openshift-ingress"
oc auth can-i create gateways.gateway.networking.k8s.io --as=system:serviceaccount:$SA_NAMESPACE:$SA_NAME -n openshift-ingress && echo "  ✓ Can create gateways in openshift-ingress" || echo "  ✗ FAIL: Cannot create gateways in openshift-ingress"
oc auth can-i patch gateways.gateway.networking.k8s.io --as=system:serviceaccount:$SA_NAMESPACE:$SA_NAME -n openshift-ingress && echo "  ✓ Can patch gateways in openshift-ingress" || echo "  ✗ FAIL: Cannot patch gateways in openshift-ingress"
oc auth can-i update gateways.gateway.networking.k8s.io --as=system:serviceaccount:$SA_NAMESPACE:$SA_NAME -n openshift-ingress && echo "  ✓ Can update gateways in openshift-ingress" || echo "  ✗ FAIL: Cannot update gateways in openshift-ingress"
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
oc get clusterrole maas-gateway-operator &>/dev/null && echo "  ✓ ClusterRole exists" || echo "  ✗ FAIL: ClusterRole not found"
oc get clusterrolebinding maas-gateway-operator &>/dev/null && echo "  ✓ ClusterRoleBinding exists" || echo "  ✗ FAIL: ClusterRoleBinding not found"
oc get role maas-gateway-operator -n openshift-ingress &>/dev/null && echo "  ✓ Role exists in openshift-ingress" || echo "  ✗ FAIL: Role not found in openshift-ingress"
oc get rolebinding maas-gateway-operator -n openshift-ingress &>/dev/null && echo "  ✓ RoleBinding exists in openshift-ingress" || echo "  ✗ FAIL: RoleBinding not found in openshift-ingress"
echo ""

echo "=== Validation Complete ==="
