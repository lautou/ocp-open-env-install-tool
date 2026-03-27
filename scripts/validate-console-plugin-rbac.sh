#!/bin/bash
# validate-console-plugin-rbac.sh
#
# Validates that the console-plugin-manager ServiceAccount has the correct permissions:
# - CAN patch/get/update consoles
# - CANNOT do anything else (pods, secrets, namespaces, RBAC, etc.)

set -e

SA="system:serviceaccount:openshift-gitops:console-plugin-manager"

echo "============================================================"
echo "Testing console-plugin-manager ServiceAccount Permissions"
echo "============================================================"
echo

# Track pass/fail counts
PASS=0
FAIL=0

echo "✅ REQUIRED PERMISSIONS (should PASS):"
echo "--------------------------------------"

# Test console permissions
echo -n "  1. patch consoles.operator.openshift.io/cluster: "
if oc auth can-i patch consoles.operator.openshift.io/cluster --as=$SA 2>/dev/null | grep -q "yes"; then
  echo "✅ PASS"
  ((PASS++))
else
  echo "❌ FAIL"
  ((FAIL++))
fi

echo -n "  2. get consoles.operator.openshift.io/cluster: "
if oc auth can-i get consoles.operator.openshift.io/cluster --as=$SA 2>/dev/null | grep -q "yes"; then
  echo "✅ PASS"
  ((PASS++))
else
  echo "❌ FAIL"
  ((FAIL++))
fi

echo -n "  3. update consoles.operator.openshift.io/cluster: "
if oc auth can-i update consoles.operator.openshift.io/cluster --as=$SA 2>/dev/null | grep -q "yes"; then
  echo "✅ PASS"
  ((PASS++))
else
  echo "❌ FAIL"
  ((FAIL++))
fi

echo
echo "❌ FORBIDDEN PERMISSIONS (should FAIL):"
echo "---------------------------------------"

# Test that SA CANNOT do these things
echo -n "  4. delete pods: "
if oc auth can-i delete pods --as=$SA 2>/dev/null | grep -q "yes"; then
  echo "❌ FAIL (has permission - security risk!)"
  ((FAIL++))
else
  echo "✅ PASS (correctly blocked)"
  ((PASS++))
fi

echo -n "  5. create namespaces: "
if oc auth can-i create namespaces --as=$SA 2>/dev/null | grep -q "yes"; then
  echo "❌ FAIL (has permission - security risk!)"
  ((FAIL++))
else
  echo "✅ PASS (correctly blocked)"
  ((PASS++))
fi

echo -n "  6. get secrets (all namespaces): "
if oc auth can-i get secrets --all-namespaces --as=$SA 2>/dev/null | grep -q "yes"; then
  echo "❌ FAIL (has permission - security risk!)"
  ((FAIL++))
else
  echo "✅ PASS (correctly blocked)"
  ((PASS++))
fi

echo -n "  7. create clusterrolebindings: "
if oc auth can-i create clusterrolebindings --as=$SA 2>/dev/null | grep -q "yes"; then
  echo "❌ FAIL (has permission - security risk!)"
  ((FAIL++))
else
  echo "✅ PASS (correctly blocked)"
  ((PASS++))
fi

echo -n "  8. impersonate serviceaccounts: "
if oc auth can-i impersonate serviceaccounts --as=$SA 2>/dev/null | grep -q "yes"; then
  echo "❌ FAIL (has permission - security risk!)"
  ((FAIL++))
else
  echo "✅ PASS (correctly blocked)"
  ((PASS++))
fi

echo -n "  9. wildcard permissions (*/*): "
if oc auth can-i '*' '*' --as=$SA 2>/dev/null | grep -q "yes"; then
  echo "❌ FAIL (has admin - security risk!)"
  ((FAIL++))
else
  echo "✅ PASS (correctly blocked)"
  ((PASS++))
fi

echo -n " 10. delete consoles: "
if oc auth can-i delete consoles.operator.openshift.io/cluster --as=$SA 2>/dev/null | grep -q "yes"; then
  echo "❌ FAIL (has permission - not needed!)"
  ((FAIL++))
else
  echo "✅ PASS (correctly blocked)"
  ((PASS++))
fi

echo
echo "============================================================"
echo "VALIDATION RESULTS"
echo "============================================================"
echo "Total Tests: $((PASS + FAIL))"
echo "✅ Passed: $PASS"
echo "❌ Failed: $FAIL"
echo

if [ $FAIL -eq 0 ]; then
  echo "🎉 SUCCESS: All permissions correctly configured!"
  echo "   - ServiceAccount CAN manage console plugins"
  echo "   - ServiceAccount CANNOT perform destructive operations"
  echo "   - Least-privilege RBAC validated ✅"
  exit 0
else
  echo "⚠️  WARNING: Some tests failed!"
  echo "   Review the output above and fix RBAC configuration."
  exit 1
fi
