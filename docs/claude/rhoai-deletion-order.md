# RHOAI Deletion Order

**Critical**: Proper deletion order prevents orphaned user workloads and stuck namespaces.

## Red Hat Official Guidance

From [Red Hat OpenShift AI 3.3 Documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.3/html/installing_and_uninstalling_openshift_ai_self-managed/uninstalling-openshift-ai-self-managed_uninstalling-openshift-ai-self-managed):

> "While these resources might still remain in your OpenShift cluster, they are not functional. After uninstalling, Red Hat recommends that you review the projects and custom resources in your OpenShift cluster and delete anything no longer in use to prevent potential issues, such as pipelines that cannot run, notebooks that cannot be undeployed, or models that cannot be undeployed."

**Key insight**: User workloads become NON-FUNCTIONAL after the RHOAI platform is removed. They must be deleted BEFORE uninstalling the platform.

## Correct Deletion Order

### 1. Delete User Workload Applications FIRST

These Applications deploy workloads that depend on the RHOAI platform:

```bash
# Delete AI use case Application (manages InferenceServices, LlamaStack, Notebooks, Pipelines)
oc delete application uc-ai-generation-llm-rag -n openshift-gitops
```

**Why**: This Application manages:
- InferenceServices (KServe)
- LlamaStack distribution
- Notebooks
- Pipelines

All of these resources become orphaned and non-functional if the RHOAI platform is removed first.

### 2. Delete RHOAI Platform Application LAST

```bash
# Delete RHOAI platform (triggers PreDelete hook)
oc delete application rhoai -n openshift-gitops
```

**What happens**:
1. PreDelete hook executes (`delete-rhoai-resources` Job)
2. Hook checks for remaining user workload namespaces (safety net)
3. Hook deletes DataScienceCluster CR
4. Hook uninstalls RHOAI operator
5. Hook deletes platform namespaces
6. Hook deletes RHOAI CRDs

## What Happens if Order is Wrong

**Scenario**: Delete `rhoai` Application before user workload Applications

**Result**:
1. ✅ DataScienceCluster deleted
2. ✅ RHOAI operator uninstalled
3. ✅ RHOAI CRDs deleted
4. ❌ User workload namespaces stuck in "Terminating" state
5. ❌ InferenceServices can't clean up (CRDs gone)
6. ❌ Notebooks can't undeploy (operator gone)
7. ❌ Pipelines can't stop (platform gone)

**Cleanup required**: Manual force-deletion of all resources in user workload namespaces with finalizer removal.

## PreDelete Hook Safety Net

The RHOAI PreDelete hook (as of 2026-04-16) includes a **Step 0** that attempts to clean up user workload namespaces:

```yaml
# Step 0: Clean up user workload namespaces (if any remain)
USER_WORKLOAD_NAMESPACES=(
  "ai-generation-llm-rag"
  "external-db-ai-generation-llm-rag"
)
```

**Purpose**: Safety net for cases where user workload Applications weren't deleted first.

**Limitation**: This is a **force-cleanup** that may not gracefully undeploy workloads. Proper deletion order is still recommended.

## ApplicationSet Deletion Order

When switching profiles or removing AI components:

### Option 1: Delete Individual Applications (Recommended)

```bash
# 1. User workloads first
oc delete application uc-ai-generation-llm-rag -n openshift-gitops

# Wait for user workload deletions to complete
sleep 30

# 2. Platform last
oc delete application rhoai -n openshift-gitops

# 3. Delete ApplicationSet (after Applications are gone)
oc delete applicationset cluster-ai -n openshift-gitops
```

### Option 2: Delete ApplicationSet (Auto-orphans Applications)

If you delete the `cluster-ai` ApplicationSet:
- ApplicationSet has `applicationsSync: create-update` (not `sync`)
- Applications are NOT auto-deleted
- Applications become orphaned (no longer managed)
- **You must still delete Applications in correct order manually**

## Profile Switch Procedure

When switching from `ocp-ai` to `ocp-standard` profile:

```bash
# 1. Update cluster-profile to new profile
oc patch application cluster-profile -n openshift-gitops --type=json -p='[
  {"op": "replace", "path": "/spec/source/path", "value": "gitops-profiles/ocp-standard"}
]'

# 2. Wait for cluster-profile to sync (creates new ApplicationSets)
oc wait --for=condition=Synced application cluster-profile -n openshift-gitops --timeout=120s

# 3. Delete user workload Applications FIRST
oc delete application uc-ai-generation-llm-rag -n openshift-gitops

# 4. Wait for user workloads to fully delete
sleep 60

# 5. Delete platform Application
oc delete application rhoai -n openshift-gitops

# 6. Delete AI ApplicationSet (cleanup)
oc delete applicationset cluster-ai -n openshift-gitops
```

## Verification

After deletion:

```bash
# Check for remaining user workload namespaces
oc get namespaces | grep -E "ai-generation-llm-rag|external-db-ai-generation-llm-rag"

# Check for remaining RHOAI namespaces
oc get namespaces | grep -E "ods|rhoai"

# Check for remaining RHOAI CRDs
oc get crd | grep -E "opendatahub.io|kubeflow.org"

# Check for orphaned webhooks
oc get validatingwebhookconfiguration,mutatingwebhookconfiguration | grep -E "opendatahub|kserve|rhoai"
```

**Expected result**: All should return no results.

## Manual Cleanup (if stuck)

If namespaces are stuck in "Terminating" after incorrect deletion order:

```bash
# Force-delete all resources in user workload namespaces
for ns in ai-generation-llm-rag external-db-ai-generation-llm-rag; do
  oc delete all --all -n $ns --force --grace-period=0
  oc delete pvc --all -n $ns --force --grace-period=0
  oc patch namespace $ns --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]'
  oc patch namespace $ns --type=json -p='[{"op": "remove", "path": "/spec/finalizers"}]'
done
```

## Summary

✅ **DO**: Delete user workloads → platform → ApplicationSet  
❌ **DON'T**: Delete platform before user workloads

**Rationale**: User workloads depend on RHOAI platform (CRDs, operator, webhooks). Platform removal orphans workloads and prevents graceful cleanup.
