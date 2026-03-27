#!/bin/bash

# Batch 7: Validate GPU MachineSet Operator RBAC
# Tests least-privilege permissions for gpu-machineset-operator ServiceAccount

set -e

echo "=== Batch 7.1: GPU MachineSet Operator RBAC Validation ==="
echo ""

SA_NAME="gpu-machineset-operator"
SA_NAMESPACE="openshift-gitops"

echo "Testing ServiceAccount: $SA_NAME in namespace $SA_NAMESPACE"
echo ""

# Test 1: ClusterRole permissions (infrastructure.config.openshift.io)
echo "1. Testing cluster-scoped permissions:"
oc auth can-i get infrastructures.config.openshift.io --as=system:serviceaccount:$SA_NAMESPACE:$SA_NAME && echo "  ✓ Can get infrastructures" || echo "  ✗ FAIL: Cannot get infrastructures"
echo ""

# Test 2: openshift-machine-api namespace permissions (machinesets and machineautoscalers)
echo "2. Testing openshift-machine-api namespace permissions:"
oc auth can-i get machinesets.machine.openshift.io --as=system:serviceaccount:$SA_NAMESPACE:$SA_NAME -n openshift-machine-api && echo "  ✓ Can get machinesets" || echo "  ✗ FAIL: Cannot get machinesets"
oc auth can-i list machinesets.machine.openshift.io --as=system:serviceaccount:$SA_NAMESPACE:$SA_NAME -n openshift-machine-api && echo "  ✓ Can list machinesets" || echo "  ✗ FAIL: Cannot list machinesets"
oc auth can-i create machinesets.machine.openshift.io --as=system:serviceaccount:$SA_NAMESPACE:$SA_NAME -n openshift-machine-api && echo "  ✓ Can create machinesets" || echo "  ✗ FAIL: Cannot create machinesets"
oc auth can-i patch machinesets.machine.openshift.io --as=system:serviceaccount:$SA_NAMESPACE:$SA_NAME -n openshift-machine-api && echo "  ✓ Can patch machinesets" || echo "  ✗ FAIL: Cannot patch machinesets"
oc auth can-i update machinesets.machine.openshift.io --as=system:serviceaccount:$SA_NAMESPACE:$SA_NAME -n openshift-machine-api && echo "  ✓ Can update machinesets" || echo "  ✗ FAIL: Cannot update machinesets"
oc auth can-i get machineautoscalers.autoscaling.openshift.io --as=system:serviceaccount:$SA_NAMESPACE:$SA_NAME -n openshift-machine-api && echo "  ✓ Can get machineautoscalers" || echo "  ✗ FAIL: Cannot get machineautoscalers"
oc auth can-i create machineautoscalers.autoscaling.openshift.io --as=system:serviceaccount:$SA_NAMESPACE:$SA_NAME -n openshift-machine-api && echo "  ✓ Can create machineautoscalers" || echo "  ✗ FAIL: Cannot create machineautoscalers"
oc auth can-i patch machineautoscalers.autoscaling.openshift.io --as=system:serviceaccount:$SA_NAMESPACE:$SA_NAME -n openshift-machine-api && echo "  ✓ Can patch machineautoscalers" || echo "  ✗ FAIL: Cannot patch machineautoscalers"
oc auth can-i update machineautoscalers.autoscaling.openshift.io --as=system:serviceaccount:$SA_NAMESPACE:$SA_NAME -n openshift-machine-api && echo "  ✓ Can update machineautoscalers" || echo "  ✗ FAIL: Cannot update machineautoscalers"
echo ""

# Test 3: openshift-gitops namespace permissions (configmaps)
echo "3. Testing openshift-gitops namespace permissions:"
oc auth can-i get configmaps --as=system:serviceaccount:$SA_NAMESPACE:$SA_NAME -n openshift-gitops && echo "  ✓ Can get configmaps in openshift-gitops" || echo "  ✗ FAIL: Cannot get configmaps in openshift-gitops"
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
oc get clusterrole gpu-machineset-operator &>/dev/null && echo "  ✓ ClusterRole exists" || echo "  ✗ FAIL: ClusterRole not found"
oc get clusterrolebinding gpu-machineset-operator &>/dev/null && echo "  ✓ ClusterRoleBinding exists" || echo "  ✗ FAIL: ClusterRoleBinding not found"
oc get role gpu-machineset-operator -n openshift-machine-api &>/dev/null && echo "  ✓ Role exists in openshift-machine-api" || echo "  ✗ FAIL: Role not found in openshift-machine-api"
oc get rolebinding gpu-machineset-operator -n openshift-machine-api &>/dev/null && echo "  ✓ RoleBinding exists in openshift-machine-api" || echo "  ✗ FAIL: RoleBinding not found in openshift-machine-api"
oc get role gpu-machineset-operator -n openshift-gitops &>/dev/null && echo "  ✓ Role exists in openshift-gitops" || echo "  ✗ FAIL: Role not found in openshift-gitops"
oc get rolebinding gpu-machineset-operator -n openshift-gitops &>/dev/null && echo "  ✓ RoleBinding exists in openshift-gitops" || echo "  ✗ FAIL: RoleBinding not found in openshift-gitops"
echo ""

echo "=== Validation Complete ==="
