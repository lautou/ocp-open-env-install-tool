# ArgoCD Hook Robustness Guide

**Last Updated:** 2026-04-11  
**Problem Solved:** PostSync hook Jobs deadlocking and requiring manual intervention

## The Problem

ArgoCD PostSync hooks for pipeline upload Jobs were deadlocking frequently, requiring manual cleanup:

```bash
# Symptoms
oc get application uc-ai-generation-llm-rag -n openshift-gitops
# Status: "waiting for completion of hook batch/Job/upload-pipeline-rag-data-ingestion"

oc get job upload-pipeline-rag-data-ingestion -n openshift-gitops
# STATUS: Running (but actually failed, stuck retrying)

oc get pods -l job-name=upload-pipeline-rag-data-ingestion
# 6 pods in Error state (backoffLimit=6 retries)
```

**Manual intervention required:**
1. Delete failed job
2. Delete error pods  
3. Clear ArgoCD operation state
4. Trigger new sync

**Frequency:** 4+ deadlocks in a single debugging session

## Root Causes

### 1. Hook Delete Policy: HookSucceeded Only

```yaml
annotations:
  argocd.argoproj.io/hook-delete-policy: HookSucceeded
```

**Problem:**
- Deletes job ONLY on success
- Failed jobs remain forever
- ArgoCD waits indefinitely for completion
- **Result:** Deadlock requiring manual cleanup

### 2. High Retry Limit: backoffLimit=6 (default)

**Problem:**
- Job retries 6 times before marking Failed
- Each retry creates a new pod
- 6 pods pile up in Error state
- Takes 15-20 minutes to exhaust retries
- **Result:** Slow failure, resource waste

### 3. No Timeout: activeDeadlineSeconds unset

**Problem:**
- Job can hang indefinitely
- No forcing timeout
- Network issues, API hangs cause infinite waits
- **Result:** Stuck jobs never fail

### 4. No Validation: Upload invalid specs

**Problem:**
- KFP SDK install + API call before validation
- Invalid pipeline specs retry 6 times
- Each retry wastes 2-3 minutes
- **Result:** 12-18 minutes wasted on fixable errors

## Solutions Applied

### 1. Combined Delete Policy ✅

```yaml
metadata:
  annotations:
    argocd.argoproj.io/hook: PostSync
    argocd.argoproj.io/hook-delete-policy: HookSucceeded,HookFailed
```

**What it does:**
- Deletes job on SUCCESS
- Deletes job on FAILURE
- **Result:** No deadlocks, auto-cleanup

**ArgoCD retains logs:**
- Job logs saved in ArgoCD UI
- Pod logs retrievable for ~5 minutes
- Failed job logs visible in Application status

### 2. Fast Failure: backoffLimit=1 ✅

```yaml
spec:
  backoffLimit: 1
```

**What it does:**
- Only 1 retry attempt
- Fail fast (2-3 minutes instead of 15-20)
- Max 2 pods (original + 1 retry)
- **Result:** Quick feedback, less resource waste

**Rationale:**
- Upload failures are usually fixable errors (invalid spec)
- No benefit to retrying 6 times
- Next sync will trigger new job anyway

### 3. Timeout Enforcement: 5 minutes ✅

```yaml
spec:
  activeDeadlineSeconds: 300
```

**What it does:**
- Forces job termination after 5 minutes
- Prevents infinite hangs
- Fails job if exceeds deadline
- **Result:** No stuck jobs

**Breakdown:**
- DSPA API wait: ~30 seconds
- pip install kfp: ~60 seconds
- Validation: ~5 seconds
- Upload to API: ~30-60 seconds
- Buffer: 2-3 minutes

### 4. Early Validation: Catch errors fast ✅

```yaml
# Added to rag-data-ingestion upload job
echo "Validating pipeline YAML structure..."
python3 -c "
import sys, yaml
try:
    with open('/pipeline/pipeline.yaml') as f:
        data = yaml.safe_load(f)

    # Check required keys
    required_keys = ['components', 'deploymentSpec', 'root', 'schemaVersion']
    missing = [k for k in required_keys if k not in data]
    if missing:
        print(f'ERROR: Missing required keys: {missing}')
        sys.exit(1)

    # Check schema version
    if data.get('schemaVersion') != '2.1.0':
        print(f'WARNING: Unexpected schemaVersion: {data.get(\"schemaVersion\")}')

    print('✓ Pipeline YAML structure valid')
except yaml.YAMLError as e:
    print(f'ERROR: Invalid YAML: {e}')
    sys.exit(1)
"
```

**What it catches:**
- YAML parse errors
- Missing required top-level keys
- Wrong schema version
- **Result:** Fail in 5 seconds instead of 3 minutes

## Hook Deletion Policies Comparison

| Policy | Deletes On Success | Deletes On Failure | Use Case |
|--------|-------------------|-------------------|----------|
| `HookSucceeded` | ✅ | ❌ | Keep failed jobs for debugging |
| `HookFailed` | ❌ | ✅ | Keep successful jobs as evidence |
| `BeforeHookCreation` | ✅ | ✅ | Always use latest (loses history) |
| **`HookSucceeded,HookFailed`** | **✅** | **✅** | **Most robust (RECOMMENDED)** |

## When Jobs Still Fail

### Stuck in Terminating State

**Symptoms:**
```bash
oc get job upload-pipeline -n openshift-gitops
# STATUS: Terminating (stuck for >5 minutes)
```

**Root Cause:** Finalizer preventing deletion

**Solution:**
```bash
# Remove finalizer
oc patch job upload-pipeline-rag-data-ingestion -n openshift-gitops \
  -p '{"metadata":{"finalizers":null}}' --type=merge
```

### ArgoCD Operation Stuck

**Symptoms:**
```bash
oc get application uc-ai-generation-llm-rag -n openshift-gitops
# operationState.phase: Running (forever)
```

**Root Cause:** ArgoCD operation state not cleared

**Solution:**
```bash
# Clear operation state
kubectl patch application.argoproj.io uc-ai-generation-llm-rag \
  -n openshift-gitops --type json \
  -p='[{"op": "remove", "path": "/status/operationState"}]'

# Trigger new sync
oc patch application.argoproj.io uc-ai-generation-llm-rag \
  -n openshift-gitops --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"normal"}}}'
```

## Alternative Approaches

### 1. Sync Waves Instead of Hooks

**Better for:** Ordering resources without lifecycle coupling

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "10"  # Not a hook, just ordering
```

**Pros:**
- No hook lifecycle issues
- Better visibility in UI
- Can't deadlock

**Cons:**
- Can't block sync on failure
- Less control over execution

### 2. Argo Workflows for Complex Jobs

**Better for:** Multi-step pipelines with retries/conditions

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Workflow
spec:
  entrypoint: upload-pipeline
  templates:
  - name: upload-pipeline
    retryStrategy:
      limit: 2
      retryPolicy: Always
```

**Pros:**
- Advanced retry strategies
- Better observability
- Event-driven

**Cons:**
- Additional controller dependency
- More complexity

### 3. External Controller/Operator

**Better for:** Production-grade pipeline management

```python
# Kubernetes operator watches ConfigMaps
@kopf.on.update('configmap', namespace='ai-generation-llm-rag')
def upload_pipeline(spec, name, **kwargs):
    if name.startswith('pipeline-'):
        # Upload to KFP with exponential backoff
        upload_with_retry(spec)
```

**Pros:**
- Independent lifecycle
- No ArgoCD coupling
- Full control over retry logic

**Cons:**
- Custom code to maintain
- Additional deployment

## Best Practices

### For All ArgoCD Hook Jobs

1. **Always use combined delete policy:**
   ```yaml
   argocd.argoproj.io/hook-delete-policy: HookSucceeded,HookFailed
   ```

2. **Set low backoffLimit:**
   ```yaml
   spec:
     backoffLimit: 1  # or 2 max
   ```

3. **Always set timeout:**
   ```yaml
   spec:
     activeDeadlineSeconds: 300  # adjust per job
   ```

4. **Validate early:**
   - Check inputs before expensive operations
   - Fail fast with clear error messages

5. **Use restartPolicy: Never:**
   ```yaml
   template:
     spec:
       restartPolicy: Never
   ```

### When to Use Hooks vs Alternatives

**Use Hooks when:**
- Simple one-shot jobs
- Blocking sync on success is required
- Lifecycle tied to Application sync

**Use Sync Waves when:**
- Just need ordering
- Don't need to block on failure
- Want cleaner Application status

**Use External Controller when:**
- Complex retry logic needed
- Independent lifecycle preferred
- Production-grade reliability required

## Debugging Failed Hooks

### 1. Check Job Status
```bash
oc get job -n openshift-gitops | grep upload-pipeline
```

### 2. Check Pod Logs
```bash
POD=$(oc get pods -n openshift-gitops -l job-name=upload-pipeline-rag-data-ingestion --sort-by=.metadata.creationTimestamp | tail -1 | awk '{print $1}')
oc logs -n openshift-gitops $POD --all-containers=true
```

### 3. Check ArgoCD Application
```bash
oc get application.argoproj.io uc-ai-generation-llm-rag -n openshift-gitops \
  -o jsonpath='{.status.operationState.phase}: {.status.operationState.message}'
```

### 4. Check Hook Configuration
```bash
oc get job upload-pipeline-rag-data-ingestion -n openshift-gitops -o yaml | \
  grep -A 3 "annotations:"
```

## Migration Guide

### From Old Configuration

**Before:**
```yaml
metadata:
  annotations:
    argocd.argoproj.io/hook-delete-policy: HookSucceeded
spec:
  # backoffLimit defaults to 6
  # no activeDeadlineSeconds
  template:
    spec:
      containers:
      - command: [upload-script.sh]  # no validation
```

**After:**
```yaml
metadata:
  annotations:
    argocd.argoproj.io/hook-delete-policy: HookSucceeded,HookFailed
spec:
  activeDeadlineSeconds: 300
  backoffLimit: 1
  template:
    spec:
      containers:
      - command:
        - /bin/bash
        - -c
        - |
          # Validate first
          validate-inputs.py
          # Then execute
          upload-script.sh
```

### Testing the Changes

1. **Trigger a sync:**
   ```bash
   oc patch application.argoproj.io uc-ai-generation-llm-rag \
     -n openshift-gitops --type merge \
     -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"normal"}}}'
   ```

2. **Watch job creation:**
   ```bash
   watch -n 2 'oc get jobs -n openshift-gitops | grep upload-pipeline'
   ```

3. **Simulate failure** (modify ConfigMap to have invalid YAML):
   ```bash
   # Job should fail fast (1-2 minutes)
   # Job should auto-delete
   # ArgoCD should show clear error
   ```

4. **Verify auto-cleanup:**
   ```bash
   # After failure, job should disappear within ~1 minute
   oc get job upload-pipeline-rag-data-ingestion -n openshift-gitops
   # Error: NotFound (expected!)
   ```

## Monitoring

### Metrics to Track

- **Hook execution time:** Should be <5 minutes
- **Retry count:** Should be 0-1 (not 6)
- **Manual interventions:** Should be 0 after this fix
- **Job cleanup time:** Should be <1 minute after completion

### Alerts to Set

```yaml
# Prometheus alert example
- alert: ArgocdHookStuck
  expr: argocd_app_sync_total{phase="Running"} > 600
  annotations:
    summary: "ArgoCD sync stuck for >10 minutes"
    
- alert: ArgocdHookHighRetries
  expr: kube_job_status_failed{namespace="openshift-gitops",job=~"upload-pipeline.*"} > 1
  annotations:
    summary: "Hook job failing repeatedly"
```

## References

- **ArgoCD Resource Hooks:** https://argo-cd.readthedocs.io/en/stable/user-guide/resource_hooks/
- **GitHub Issue #4811:** Sync gets stuck (requires manual termination)
- **GitHub Issue #23226:** ArgoCD fails on hook-finalizer
- **Kubernetes Jobs:** https://kubernetes.io/docs/concepts/workloads/controllers/job/

## Commit History

- **4f970a5** - Make ArgoCD PostSync hooks robust: Prevent deadlocks
  - Added HookSucceeded,HookFailed delete policy
  - Set backoffLimit: 1
  - Set activeDeadlineSeconds: 300
  - Added YAML validation

## Known Limitations

1. **Logs retention:** Failed job logs only in ArgoCD UI for ~5min after deletion
   - **Mitigation:** ArgoCD retains in Application status
   - **Alternative:** External log aggregation (ELK, Loki)

2. **No retry for transient failures:** backoffLimit=1 means one retry only
   - **Mitigation:** Next sync creates new job
   - **Alternative:** Increase to 2 if needed

3. **Timeout may be too short:** 5 minutes might not be enough for slow networks
   - **Mitigation:** Increase activeDeadlineSeconds to 600 (10min)
   - **Monitor:** Track actual execution times

## Future Improvements

- [ ] Add metrics/monitoring for hook execution time
- [ ] Create alert for stuck hooks (>10 minutes)
- [ ] Consider external controller for production
- [ ] Add integration tests for hook lifecycle
- [ ] Document rollback procedure if upload fails
