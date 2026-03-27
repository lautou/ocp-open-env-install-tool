#!/bin/bash

# Batch 6: Validate ACK Config Injector RBAC
# Tests least-privilege permissions for ack-config-operator ServiceAccount

set -e

echo "=== Batch 6: ACK Config Injector RBAC Validation ==="
echo ""

SA_NAME="ack-config-operator"
SA_NAMESPACE="openshift-gitops"

echo "Testing ServiceAccount: $SA_NAME in namespace $SA_NAMESPACE"
echo ""

# Test 1: ClusterRole permissions (infrastructure.config.openshift.io)
echo "1. Testing cluster-scoped permissions:"
oc auth can-i get infrastructures.config.openshift.io --as=system:serviceaccount:$SA_NAMESPACE:$SA_NAME && echo "  ✓ Can get infrastructures" || echo "  ✗ FAIL: Cannot get infrastructures"
echo ""

# Test 2: kube-system namespace permissions (read AWS credentials)
echo "2. Testing kube-system namespace permissions:"
oc auth can-i get secrets --as=system:serviceaccount:$SA_NAMESPACE:$SA_NAME -n kube-system && echo "  ✓ Can get secrets in kube-system" || echo "  ✗ FAIL: Cannot get secrets in kube-system"
echo ""

# Test 3: ack-system namespace permissions (create/update secrets and configmaps)
echo "3. Testing ack-system namespace permissions:"
oc auth can-i create secrets --as=system:serviceaccount:$SA_NAMESPACE:$SA_NAME -n ack-system && echo "  ✓ Can create secrets in ack-system" || echo "  ✗ FAIL: Cannot create secrets in ack-system"
oc auth can-i patch secrets --as=system:serviceaccount:$SA_NAMESPACE:$SA_NAME -n ack-system && echo "  ✓ Can patch secrets in ack-system" || echo "  ✗ FAIL: Cannot patch secrets in ack-system"
oc auth can-i update secrets --as=system:serviceaccount:$SA_NAMESPACE:$SA_NAME -n ack-system && echo "  ✓ Can update secrets in ack-system" || echo "  ✗ FAIL: Cannot update secrets in ack-system"
oc auth can-i create configmaps --as=system:serviceaccount:$SA_NAMESPACE:$SA_NAME -n ack-system && echo "  ✓ Can create configmaps in ack-system" || echo "  ✗ FAIL: Cannot create configmaps in ack-system"
oc auth can-i patch configmaps --as=system:serviceaccount:$SA_NAMESPACE:$SA_NAME -n ack-system && echo "  ✓ Can patch configmaps in ack-system" || echo "  ✗ FAIL: Cannot patch configmaps in ack-system"
oc auth can-i update configmaps --as=system:serviceaccount:$SA_NAMESPACE:$SA_NAME -n ack-system && echo "  ✓ Can update configmaps in ack-system" || echo "  ✗ FAIL: Cannot update configmaps in ack-system"
echo ""

# Test 4: Verify no cluster-admin (negative test)
echo "4. Verifying NO excessive permissions (should all FAIL):"
oc auth can-i create namespaces --as=system:serviceaccount:$SA_NAMESPACE:$SA_NAME && echo "  ✗ SECURITY ISSUE: Can create namespaces (should not be allowed)" || echo "  ✓ Correctly denied: Cannot create namespaces"
oc auth can-i delete nodes --as=system:serviceaccount:$SA_NAMESPACE:$SA_NAME && echo "  ✗ SECURITY ISSUE: Can delete nodes (should not be allowed)" || echo "  ✓ Correctly denied: Cannot delete nodes"
oc auth can-i '*' '*' --as=system:serviceaccount:$SA_NAMESPACE:$SA_NAME && echo "  ✗ SECURITY ISSUE: Has wildcard permissions (should not be allowed)" || echo "  ✓ Correctly denied: No wildcard permissions"
echo ""

# Test 5: Verify ServiceAccount exists and has correct RBAC bindings
echo "5. Verifying RBAC resources exist:"
oc get serviceaccount $SA_NAME -n $SA_NAMESPACE &>/dev/null && echo "  ✓ ServiceAccount exists" || echo "  ✗ FAIL: ServiceAccount not found"
oc get clusterrole ack-config-operator &>/dev/null && echo "  ✓ ClusterRole exists" || echo "  ✗ FAIL: ClusterRole not found"
oc get clusterrolebinding ack-config-operator &>/dev/null && echo "  ✓ ClusterRoleBinding exists" || echo "  ✗ FAIL: ClusterRoleBinding not found"
oc get role ack-config-operator -n kube-system &>/dev/null && echo "  ✓ Role exists in kube-system" || echo "  ✗ FAIL: Role not found in kube-system"
oc get rolebinding ack-config-operator -n kube-system &>/dev/null && echo "  ✓ RoleBinding exists in kube-system" || echo "  ✗ FAIL: RoleBinding not found in kube-system"
oc get role ack-config-operator -n ack-system &>/dev/null && echo "  ✓ Role exists in ack-system" || echo "  ✗ FAIL: Role not found in ack-system"
oc get rolebinding ack-config-operator -n ack-system &>/dev/null && echo "  ✓ RoleBinding exists in ack-system" || echo "  ✗ FAIL: RoleBinding not found in ack-system"
echo ""

echo "=== Validation Complete ==="
