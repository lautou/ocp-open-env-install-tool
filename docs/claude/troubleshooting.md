# Troubleshooting

**Purpose**: Common issues and debugging techniques for cluster installation and operation.

## Installation Issues

### Bastion Provisioning

- **Check bastion UserData logs**: `/var/log/cloud-init-output.log` on bastion
- **Check installation logs**: `~/bastion_execution.log` on bastion (tails automatically in tmux)
- **Session recovery**: Re-run install script to reattach to existing tmux session

### CloudFormation (UPI Mode)

- **Stack naming**: `<cluster-name>-cfn-<component>`
- **Stack failures**: Check AWS CloudFormation console for detailed error messages
- **Network issues**: Verify VPC, subnet, and security group configurations

### CSR Issues

**Symptom**: Nodes stuck in NotReady state after cluster hibernation/restart

**Solution**: Use helper script to approve pending CSRs:

```bash
./scripts/approve_cluster_csrs.sh <BASTION_HOST> <SSH_KEY>
# Example:
./scripts/approve_cluster_csrs.sh ec2-x-x-x-x.compute.amazonaws.com output/bastion_mycluster.pem
```

### AWS Resource Cleanup

**Symptom**: Old cluster resources not cleaned up

**Solution**: Manually invoke cleanup script:

```bash
./scripts/clean_aws_tenant.sh <AWS_KEY> <AWS_SECRET> <REGION> <CLUSTER_NAME> <DOMAIN>
```

**CRITICAL**: This script deletes **ALL S3 buckets** in the tenant. Only use in dedicated demo/lab AWS accounts.

## ArgoCD / GitOps Issues

### Controller OOMKilled

**Symptom**: argocd-application-controller pod restarts with exit code 137

**Solution**: Memory limit increased to 4Gi in manifests (already applied)

**Verification**:
```bash
oc get pod -n openshift-gitops -l app.kubernetes.io/name=argocd-application-controller
```

### Applications Stuck OutOfSync

**Symptom**: "resource mapping not found: no matches for kind X"

**Root cause**: Operator hasn't created CRDs yet

**Solution**: Retry limit set to 10 in ApplicationSets (already applied). Wait for automatic retry or manually sync.

### Job RBAC Permission Errors

**Symptom**: Job fails with "Forbidden: User 'system:serviceaccount:openshift-gitops:<sa-name>' cannot delete/create/update resource"

**Common Causes**:

1. **Using OpenShift API instead of Kubernetes API**:
   ```bash
   # WRONG: Uses OpenShift Project API (project.openshift.io)
   oc delete project openshift-builds

   # CORRECT: Uses Kubernetes Namespace API (v1)
   oc delete namespace openshift-builds
   ```

   **Why**: ServiceAccounts typically have RBAC for core Kubernetes resources (`namespaces`), not OpenShift-specific wrappers (`projects`). In OpenShift, Project = Namespace, so use the core API.

2. **Missing ClusterRole permissions**:
   ```bash
   # Check ServiceAccount's ClusterRole
   oc get clusterrole <sa-name> -o yaml

   # Check ClusterRoleBinding
   oc get clusterrolebinding -o yaml | grep -A10 "<sa-name>"
   ```

3. **Wrong API group in RBAC**:
   ```yaml
   # Check resource API group
   oc api-resources | grep <resource-name>

   # Ensure ClusterRole matches the API group
   apiGroups: [""]              # Core v1 API (pods, services, namespaces)
   apiGroups: ["apps"]          # apps/v1 (deployments, statefulsets)
   apiGroups: ["project.openshift.io"]  # OpenShift Project API
   ```

**Solution**:

Update Job command to use correct API or add missing RBAC permissions to ClusterRole.

**Example Fix (openshift-builds cleanup)**:
- Changed `oc delete project` → `oc delete namespace`
- ServiceAccount has `namespaces` delete permission (core API)
- No RBAC change needed

### Job Stuck in Infinite Loop - OLM API Group Ambiguity

**Symptom**: Job running for hours/days, stuck in wait loop with repeating dots in logs, KubeJobNotCompleted alert firing

**Root Cause**: On clusters with **BOTH** OLM and RHACM installed, generic `oc get subscription` commands resolve to wrong API group

**The Problem:**

Kubernetes has TWO different "subscription" resource types:
- **OLM (Operator Lifecycle Manager)**: `subscription.operators.coreos.com` - for operator installations
- **RHACM (Red Hat ACM)**: `subscription.apps.open-cluster-management.io` - for application deployments

When you run `oc get subscription` without explicit API group:
- **Default resolution**: RHACM API (`apps.open-cluster-management.io`)
- **RBAC configured for**: OLM API (`operators.coreos.com`)
- **Result**: `Forbidden` error (ServiceAccount has no RHACM permissions)

**Job fails but loop continues:**
```bash
# Job script wait loop
while ! oc get subscription "$NAME" -n "$NS" >/dev/null 2>&1; do
  echo -n "."
  sleep 5
done

# What happens:
# 1. oc get subscription → Uses apps.open-cluster-management.io (RHACM API)
# 2. Error: Forbidden (ServiceAccount has operators.coreos.com RBAC, not RHACM RBAC)
# 3. Command fails (exit code 1)
# 4. ! command = true (negation)
# 5. Loop continues waiting forever
# 6. OLM subscription actually exists but cannot be found
```

**How to Diagnose:**

1. Check Job pod logs:
   ```bash
   oc logs <job-pod-name> -n openshift-gitops
   
   # Look for:
   # - Infinite dots: "Waiting for subscription..........."
   # - No progress after startup messages
   ```

2. Test command manually in Job pod:
   ```bash
   # Wrong API (fails on RHACM clusters)
   oc exec <pod> -- oc get subscription <name> -n <namespace>
   # Error: Forbidden: User "..." cannot get resource "subscriptions" in API group "apps.open-cluster-management.io"
   
   # Correct API (works)
   oc exec <pod> -- oc get subscription.operators.coreos.com <name> -n <namespace>
   # Shows the subscription successfully
   ```

3. Verify RHACM is installed:
   ```bash
   oc get subscription.apps.open-cluster-management.io --all-namespaces
   # If results found → RHACM installed → API conflict exists
   ```

**Solution:**

Add explicit API group to ALL OLM resource commands:

```bash
# ❌ WRONG - Ambiguous
oc get subscription my-operator -n my-namespace
oc patch subscription my-operator -n my-namespace --type=merge -p "$PATCH"
oc delete subscription my-operator -n my-namespace
oc wait subscription my-operator -n my-namespace --for=...

# ✅ CORRECT - Explicit API group
oc get subscription.operators.coreos.com my-operator -n my-namespace
oc patch subscription.operators.coreos.com my-operator -n my-namespace --type=merge -p "$PATCH"
oc delete subscription.operators.coreos.com my-operator -n my-namespace
oc wait subscription.operators.coreos.com my-operator -n my-namespace --for=...
```

**OLM resources requiring explicit API groups:**
- `subscription.operators.coreos.com` - **CRITICAL** (conflicts with RHACM)
- `csv.operators.coreos.com` (ClusterServiceVersion)
- `installplan.operators.coreos.com`
- `operatorgroup.operators.coreos.com`
- `catalogsource.operators.coreos.com`

**Example Failure (fixed in 8ab206e):**

**Job**: `update-odf-subscriptions-node-selector`
- **Runtime**: 24+ hours stuck in loop
- **Symptoms**: 
  - KubeJobNotCompleted alert firing
  - Logs showing infinite dots: "Waiting for subscription.................."
  - Pod restarts: 2 (backoff retries)
- **Root cause**: 
  - Lines 65, 72, 82, 89: `oc get subscription` / `oc patch subscription`
  - Resolved to `apps.open-cluster-management.io` (RHACM)
  - RBAC configured for `operators.coreos.com` (OLM)
  - Forbidden error → infinite wait loop
- **Fix**: Added `.operators.coreos.com` to all subscription references
- **Result**: Job completes in ~30 seconds

**Immediate Fix for Stuck Jobs:**

1. Delete the stuck Job:
   ```bash
   oc delete job <job-name> -n openshift-gitops
   ```

2. Fix the Job manifest (add `.operators.coreos.com`)

3. Commit and push changes

4. ArgoCD recreates Job with fixed script via PostSync hook

5. Job completes successfully

**Prevention:**
- ✅ Always use explicit API groups for OLM resources (defensive coding)
- ✅ Especially critical on `ocp-reference` profile (includes RHACM)
- ✅ Test Jobs on RHACM-enabled clusters before production

**Related Issues:**
- All Jobs working with OLM operators (subscriptions, CSVs, InstallPlans)
- Bastion installation script (GitOps operator installation)
- Cleanup Jobs (operator uninstallation)

### Partial Sync Cycles

**Symptom**: Application repeatedly shows "Partial sync operation succeeded" every 5-6 minutes, health cycles between Healthy → Missing

**Root Causes**:

**1. Job with TTL but no ArgoCD hook annotation**

When a Job has `ttlSecondsAfterFinished` but is NOT marked as an ArgoCD hook:
- Job completes → TTL controller deletes Job after timeout
- ArgoCD detects deletion → re-syncs to recreate Job
- Result: Continuous sync cycle every TTL period

**Solution**: Mark Job as ArgoCD hook to exclude from drift detection

```yaml
metadata:
  annotations:
    argocd.argoproj.io/hook: Sync  # or PreSync/PostSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
    argocd.argoproj.io/sync-wave: "1"
```

**Example**: OpenShift Pipelines cleanup-auto-tektonconfig Job (fixed in 0813d6e)

**2. API version mismatch (operator converts resources)**

When manifests use deprecated API version but operator converts to newer version:
- Operator converts resource at runtime (e.g., v1alpha1 → v1beta1)
- Operator may rename fields during conversion
- ArgoCD compares desired (old API) vs actual (new API) → detects drift
- Result: "Partial sync operation succeeded" continuously

**Solution**: Update manifests to match operator's current API version

```yaml
# Before (causes drift)
apiVersion: addon.open-cluster-management.io/v1alpha1
kind: ClusterManagementAddon
spec:
  supportedConfigs:  # Old field name
    - defaultConfig: {...}

# After (matches operator)
apiVersion: addon.open-cluster-management.io/v1beta1
kind: ClusterManagementAddon
spec:
  defaultConfigs:  # New field name (no nested defaultConfig)
    - group: addon.open-cluster-management.io
      name: deploy-config
```

**Example**: RHACM ClusterManagementAddon resources (fixed in d931ec8)

**3. Operator-managed fields causing auto-heal cycles**

When operator dynamically manages fields that are not in manifests:
- Operator adds/modifies fields at runtime based on addon configuration
- ArgoCD compares static manifest vs dynamic operator state → detects drift
- Auto-heal triggers sync to restore manifest state
- Operator immediately re-adds its managed fields
- Result: Continuous auto-heal cycle every 4-8 minutes

**Solution**: Add ignoreDifferences for operator-managed fields

```yaml
# In ApplicationSet
spec:
  template:
    spec:
      ignoreDifferences:
      - group: addon.open-cluster-management.io
        kind: ClusterManagementAddOn
        jsonPointers:
        - /spec/defaultConfigs      # Operator adds/updates addon configs
        - /spec/installStrategy     # Operator manages deployment strategy
```

**Why both fields are needed**:
- `/spec/installStrategy`: Operator determines Manual vs Placements deployment
- `/spec/defaultConfigs`: Operator adds addon-specific entries and updates versions

**Common mistakes**:
- ❌ Ignoring only `/spec/installStrategy` (insufficient - defaultConfigs also drift)
- ❌ Trying to declare these fields in manifests (operator overrides them anyway)
- ✅ Ignore both fields, let operator manage them completely

**Example**: RHACM ClusterManagementAddon auto-heal cycles (fixed in dd38d0e)
- cluster-proxy: Operator adds extra defaultConfigs entry for proxy configuration
- managed-serviceaccount: Operator updates version (2.10 → 2.11) in defaultConfigs
- Both resources had installStrategy added by operator

**How to debug**:

1. Check Application status:
   ```bash
   oc get application <app-name> -n openshift-gitops \
     -o jsonpath='{.status.operationState.message}'
   ```

2. Compare desired vs actual:
   ```bash
   # Get ArgoCD's desired state
   oc get application <app-name> -n openshift-gitops -o yaml

   # Get actual cluster state
   oc get <resource> <name> -n <namespace> -o yaml
   ```

3. Look for API version or field name differences
4. Check operator logs for conversion messages:
   ```bash
   oc logs -n <operator-namespace> deployment/<operator-name>
   ```

**Prevention**: Always use latest stable API versions for operator CRDs, mark Jobs with TTL as ArgoCD hooks

### ApplicationSet Ownership Conflicts

**Symptom**: "Object X is already owned by another ApplicationSet controller Y"

**Solution**: Delete conflicting Application, let correct ApplicationSet recreate it

```bash
oc delete application <app-name> -n openshift-gitops
```

### Orphaned ApplicationSets After Profile Switch

**Symptom**: Unwanted Applications deployed (rhacm, rhacs, openshift-service-mesh, etc.) that are not in your active profile

**Root Cause**:
- ApplicationSets from previous profiles remain when switching to a different profile
- The cluster-profile Application only creates ApplicationSets for the new profile
- Old ApplicationSets are NOT automatically deleted
- These orphaned ApplicationSets continue creating Applications

**Example Scenario**:
1. Cluster initially deployed with profile A (includes ACM, ACS, Service Mesh)
2. Profile switched to ocp-ai (does not include ACM, ACS, Service Mesh)
3. Old ApplicationSets remain and continue deploying rhacm, rhacs, openshift-service-mesh

**Diagnosis**:

```bash
# Check active profile
oc get application -n openshift-gitops cluster-profile -o jsonpath='{.spec.source.path}{"\n"}'
# Example output: gitops-profiles/ocp-ai

# List ApplicationSets that SHOULD exist for this profile
oc kustomize gitops-profiles/ocp-ai | grep "kind: ApplicationSet" -A2 | grep "name:" | awk '{print $2}' | sort

# List ApplicationSets that ACTUALLY exist
oc get applicationset -n openshift-gitops -o name | sed 's|applicationset.argoproj.io/||' | sort

# Compare the two lists - differences are orphaned ApplicationSets
```

**Solution**:

Delete orphaned ApplicationSets (they will automatically delete their managed Applications):

```bash
# Example: Delete ACM ApplicationSets not in ocp-ai profile
oc delete applicationset -n openshift-gitops cluster-acm-hub cluster-acm-managed

# Example: Delete ACS ApplicationSets
oc delete applicationset -n openshift-gitops cluster-acs-central cluster-acs-secured

# Example: Delete Service Mesh ApplicationSet
oc delete applicationset -n openshift-gitops cluster-openshift-servicemesh
```

**Prevention**:

When changing profiles, explicitly delete ApplicationSets from the previous profile:

```bash
# List all ApplicationSets before profile change
oc get applicationset -n openshift-gitops -o name > /tmp/before.txt

# Change profile (update cluster-profile Application or reinstall)

# List ApplicationSets after profile change
oc get applicationset -n openshift-gitops -o name > /tmp/after.txt

# Identify ApplicationSets that should be deleted
comm -13 <(oc kustomize gitops-profiles/<new-profile> | grep "kind: ApplicationSet" -A2 | grep "name:" | awk '{print "applicationset.argoproj.io/"$2}' | sort) <(sort /tmp/after.txt)

# Delete orphaned ApplicationSets
# (manually review and delete each one)
```

**Architectural Note**: This is expected ArgoCD behavior. ApplicationSets are cluster-scoped resources not owned by the profile Application, so they don't get pruned when the profile changes. Future improvements could use a parent ApplicationSet to manage child ApplicationSets with pruning enabled.

## Component-Specific Issues

### ArgoCD Application Stuck OutOfSync/Missing (Operator CRs)

**Symptom**: Application fails to sync on fresh cluster, stuck in OutOfSync/Missing state with "CRD not found" errors even after retry limit exhausted

**Example Error Messages**:
```
certificates.cert-manager.io is forbidden: User "system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller" cannot create resource "certificates" in API group "cert-manager.io" in the namespace "openshift-ingress": RBAC: clusterrole.rbac.authorization.k8s.io "certificates.cert-manager.io-v1-edit" not found
```

**Root Cause**:
- ArgoCD validates ALL resources before applying ANY resources
- Operator Custom Resources (e.g., Certificate, ClusterIssuer) fail validation when CRDs don't exist
- ArgoCD aborts entire sync without creating the operator Subscription
- Subscription would install CRDs, but never gets applied
- Creates a deadlock: CR validation fails → Subscription not created → CRDs never installed

**Debug**:
```bash
# Check Application status
oc get application <app-name> -n openshift-gitops -o yaml | grep -A 20 "operationState:"

# Check if CRDs exist
oc explain certificates.cert-manager.io
# Error = CRDs missing

# Check if Subscription was created
oc get subscription -n cert-manager-operator
# NotFound = Subscription never applied due to validation failure

# Check Application sync history
oc get application <app-name> -n openshift-gitops -o jsonpath='{.status.operationState.message}'
```

**Fix**:
Add `argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true` annotation to ALL operator Custom Resources:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  annotations:
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
  name: ingress
  namespace: openshift-ingress
spec:
  # ... certificate spec
```

**Affected Resources**:
- cert-manager: Certificate, ClusterIssuer
- ArgoCD: ArgoCD CR
- Network Policy: AdminNetworkPolicy, BaselineAdminNetworkPolicy
- Cluster Autoscaler: ClusterAutoscaler
- Any operator CR where CRD is installed by the operator

**Prevention**:
Always add `SkipDryRunOnMissingResource=true` to operator CRs when CRDs are installed by the operator itself.

**See Also**: CLAUDE.md → GitOps Patterns → SkipDryRunOnMissingResource for detailed explanation

---

### ArgoCD Cannot Create Gateway Resources (RBAC)

**Symptom**: Application fails with "gateways.gateway.networking.k8s.io is forbidden" RBAC errors

**Example Error Message**:
```
gateways.gateway.networking.k8s.io is forbidden: User "system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller" cannot create resource "gateways" in API group "gateway.networking.k8s.io" in the namespace "openshift-ingress"
```

**Root Cause**:
Gateway API resources are namespace-scoped. ArgoCD can manage them in namespaces with the `argocd.argoproj.io/managed-by: openshift-gitops` label.

**Affected Components**:
- RHOAI: MaaS Gateway (`maas-default-gateway` in `openshift-ingress`)
- RHCL: Kuadrant Gateways (in `kuadrant-system`)

**Debug**:
```bash
# Check if CRDs exist
oc get crd gateways.gateway.networking.k8s.io

# Check namespace label
oc get namespace openshift-ingress -o jsonpath='{.metadata.labels.argocd\.argoproj\.io/managed-by}'

# Check ArgoCD permissions
oc auth can-i create gateways.gateway.networking.k8s.io \
  --as=system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller \
  -n openshift-ingress
```

**Fix**:
Ensure the target namespace has the managed-by label:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  labels:
    argocd.argoproj.io/managed-by: openshift-gitops
  name: openshift-ingress
```

The `argocd.argoproj.io/managed-by` label grants namespace-level RBAC to the ArgoCD application controller ServiceAccount, allowing it to manage all resources in that namespace.

**Note**: Cluster-scoped Gateway API RBAC is NOT required. Namespace-level permissions via the managed-by label are sufficient.

---

### cert-manager Certificate Failures

**Symptom**: Let's Encrypt certificates not issuing

**Debug**:
```bash
# Check Certificate status
oc get certificate -n openshift-ingress

# Check cert-manager logs
oc logs -n cert-manager -l app.kubernetes.io/component=controller

# Check ACME challenge
oc get challenge -A
```

**Common causes**:
- DNS propagation delay (wait 5-10 minutes)
- Route53 credentials missing or invalid
- cert-manager controller not ready (pod readiness check fixed in Job)

### ODF Subscriptions Not on Infra Nodes

**Symptom**: ODF operator pods running on worker nodes

**Debug**:
```bash
# Check subscription nodeSelector
oc get subscription -n openshift-storage <subscription-name> -o yaml | grep -A5 nodeSelector
```

**Solution**: Job patches subscriptions with infra node selector. Check Job logs:

```bash
oc logs -n openshift-storage job/update-subscriptions-node-selector
```

### Loki Ingester Flush Failures - Invalid S3 Credentials

**Symptom**: LokiIngesterFlushFailureRateCritical alert firing, Loki ingester pods logging S3 flush errors

**Example Error**:
```
level=error caller=flush.go:261 component=ingester msg="failed to flush" 
err="store put chunk: InvalidAccessKeyId: The AWS access key Id you provided does not exist in our records. status code: 403"
```

**Root Cause**: 
Invalid AWS credentials in `logging-loki-s3` secret after NooBaa instance recreation/deletion.

**Common Triggers**:
- Accidental deletion of `openshift-storage` Application during troubleshooting
- Manual deletion of NooBaa resources
- ODF upgrade/reinstall that recreates NooBaa instance

**Why this happens**:
1. Loki uses S3 bucket provided by NooBaa (via ObjectBucketClaim)
2. NooBaa generates unique AWS-compatible credentials for each bucket
3. When NooBaa instance is deleted/recreated, old credentials become invalid
4. `logging-loki-s3` secret still contains old credentials
5. Loki cannot flush log chunks to S3 → flush failures → alert fires

**Debug**:
```bash
# Check Loki ingester logs for S3 errors
oc logs -n openshift-logging logging-loki-ingester-0 --tail=100 | grep -i "flush.*error"

# Check OBC status
oc get obc logging-loki -n openshift-logging

# Check when secret was last updated
oc get secret logging-loki-s3 -n openshift-logging -o jsonpath='{.metadata.creationTimestamp}'

# Check when NooBaa was created (should match OBC age)
oc get noobaa -n openshift-storage -o jsonpath='{.items[0].metadata.creationTimestamp}'
```

**Fix**:

**Step 1: Recreate ObjectBucketClaim** (if needed)

If OBC is older than NooBaa instance, delete and recreate it:

```bash
# Delete OBC (ArgoCD will recreate)
oc delete obc logging-loki -n openshift-logging

# If OBC stuck with finalizer
oc patch obc logging-loki -n openshift-logging --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]'

# Delete associated ObjectBucket if it exists
oc get objectbucket | grep logging-loki
oc delete objectbucket obc-openshift-logging-logging-loki

# If ObjectBucket stuck with finalizer
oc patch objectbucket obc-openshift-logging-logging-loki --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]'

# Restart NooBaa operator to process new OBC
oc delete pod -n openshift-storage -l app=noobaa,noobaa-operator=deployment

# Wait for OBC to become Bound
oc get obc logging-loki -n openshift-logging -w
```

**Step 2: Update Loki S3 secret with new credentials**

Extract new credentials from OBC and update Loki secret:

```bash
# Get new credentials from OBC secret
ACCESS_KEY=$(oc get secret logging-loki -n openshift-logging -o jsonpath='{.data.AWS_ACCESS_KEY_ID}')
SECRET_KEY=$(oc get secret logging-loki -n openshift-logging -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}')
BUCKET=$(oc get secret logging-loki -n openshift-logging -o jsonpath='{.data.BUCKET_NAME}')
ENDPOINT=$(oc get secret logging-loki -n openshift-logging -o jsonpath='{.data.BUCKET_HOST}')
REGION=$(oc get secret logging-loki -n openshift-logging -o jsonpath='{.data.BUCKET_REGION}')

# Update logging-loki-s3 secret
oc patch secret logging-loki-s3 -n openshift-logging --type=json -p="[
  {\"op\": \"replace\", \"path\": \"/data/access_key_id\", \"value\": \"$ACCESS_KEY\"},
  {\"op\": \"replace\", \"path\": \"/data/access_key_secret\", \"value\": \"$SECRET_KEY\"},
  {\"op\": \"replace\", \"path\": \"/data/bucketnames\", \"value\": \"$BUCKET\"},
  {\"op\": \"replace\", \"path\": \"/data/endpoint\", \"value\": \"$ENDPOINT\"},
  {\"op\": \"replace\", \"path\": \"/data/region\", \"value\": \"$REGION\"}
]"
```

**Step 3: Restart Loki ingester pods**

```bash
# Restart all ingester pods to pick up new credentials
oc delete pod -n openshift-logging -l app.kubernetes.io/component=ingester

# Wait for pods to be ready (StatefulSet restarts sequentially)
oc get pods -n openshift-logging -l app.kubernetes.io/component=ingester -w

# Verify no flush errors in logs
oc logs -n openshift-logging logging-loki-ingester-0 --tail=50 | grep -i "flush.*error"
```

**Verification**:
```bash
# Check ingester pods are healthy
oc get pods -n openshift-logging -l app.kubernetes.io/component=ingester

# Monitor logs for successful flushes (no errors)
oc logs -n openshift-logging logging-loki-ingester-0 --tail=20 --follow

# Check alert clears (may take 5-10 minutes)
# Alert threshold: flush failure rate > threshold for sustained period
```

**Prevention**:
- Avoid deleting `openshift-storage` Application unless absolutely necessary
- If ODF must be reinstalled, update Loki credentials immediately after
- The `create-secret-logging-loki-s3` Job (PostSync hook) should run automatically on `openshift-logging` Application sync to regenerate credentials

**Alternative (automated)**: Trigger Job to regenerate secret

```bash
# Delete Job to force ArgoCD to recreate it
oc delete job create-secret-logging-loki-s3 -n openshift-gitops

# Trigger sync on openshift-logging Application
oc patch application openshift-logging -n openshift-gitops --type merge \
  -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{}}}'

# Job will extract credentials from OBC and update logging-loki-s3 secret
oc logs -n openshift-gitops job/create-secret-logging-loki-s3 --follow

# Still need to restart ingester pods (Step 3 above)
```

**Related Issues**:
- NooBaa bucket access denied
- Loki compactor S3 errors (same credentials used)
- OpenShift Logging retention issues (logs not persisted to S3)

### LokiStackComponentsNotReadyWarning - Invalid Secret Structure

**Symptom**: LokiStackComponentsNotReadyWarning alert firing, LokiStack in degraded state

**Error in LokiStack status**:
```
Invalid object storage secret contents: missing secret field: bucketnames
```

**Root Cause**: 
The `logging-loki-s3` secret has empty values for required fields (`bucketnames`, `endpoint`, `region`).

**Common Triggers**:
- Manual patching of `logging-loki-s3` secret without setting all required fields
- Incomplete secret recreation after troubleshooting S3 credential issues
- Script errors that only partially populate the secret

**Required Secret Fields**:
The `logging-loki-s3` secret must contain all of these fields with non-empty values:
- `access_key_id` - AWS access key from NooBaa OBC
- `access_key_secret` - AWS secret key from NooBaa OBC
- `bucketnames` - Bucket name (typically "logging-loki")
- `endpoint` - S3 endpoint URL (e.g., "https://s3.openshift-storage.svc")
- `region` - AWS region (e.g., "eu")
- `insecure` - TLS verification flag ("true" for NooBaa internal S3)

**Debug**:
```bash
# Check LokiStack status
oc get lokistack logging-loki -n openshift-logging -o jsonpath='{.status.conditions}' | jq .

# Check secret contents (decode base64)
oc get secret logging-loki-s3 -n openshift-logging -o jsonpath='{.data}' | \
  jq -r 'to_entries[] | "\(.key): \(.value | @base64d)"'

# Look for empty values - these are the problem
# Expected output should show all fields with actual values
```

**Fix**:

**Option 1: Delete Secret and Resync (Recommended)**

Use the automated PostSync Job to recreate the secret properly:

```bash
# Delete invalid secret
oc delete secret logging-loki-s3 -n openshift-logging

# Trigger ArgoCD sync to run PostSync Job
argocd app sync openshift-logging

# Wait for Job to complete (reads OBC credentials and creates secret)
oc logs -n openshift-gitops job/create-secret-logging-loki-s3 --follow

# Verify secret has all required fields
oc get secret logging-loki-s3 -n openshift-logging -o jsonpath='{.data}' | \
  jq -r 'to_entries[] | "\(.key): \(.value | @base64d)"'

# Wait for LokiStack to become Ready (pods will roll out automatically)
oc get lokistack logging-loki -n openshift-logging -w
```

**Option 2: Manual Secret Patch (Quick Fix)**

If you need immediate fix without waiting for sync:

```bash
# Patch secret with missing fields
oc patch secret logging-loki-s3 -n openshift-logging --type=json -p='[
  {"op": "replace", "path": "/data/bucketnames", "value": "'"$(echo -n "logging-loki" | base64)"'"},
  {"op": "replace", "path": "/data/endpoint", "value": "'"$(echo -n "https://s3.openshift-storage.svc" | base64)"'"},
  {"op": "replace", "path": "/data/region", "value": "'"$(echo -n "eu" | base64)"'"}
]'

# LokiStack should detect valid secret and roll out pods automatically
```

**Verification**:
```bash
# Check LokiStack is Ready
oc get lokistack logging-loki -n openshift-logging

# Check all component types are Ready (7 types)
oc get lokistack logging-loki -n openshift-logging -o jsonpath='{.status.components}' | jq .

# Verify pods are running
oc get pods -n openshift-logging | grep loki

# Check alert clears (typically 1-5 minutes after components Ready)
```

**Prevention**:
- Use the `create-secret-logging-loki-s3` PostSync Job instead of manual patching
- If manual intervention needed, ensure all 6 required fields are populated
- Trigger `argocd app sync openshift-logging` to recreate secret properly
- Avoid partial secret updates that leave fields empty

**Related Issues**:
- Loki ingester flush failures (caused by invalid credentials - see previous section)
- LokiStack components not starting (waiting for valid storage secret)

### RHOAI Models as a Service Dashboard Not Showing Models

**Symptom**: LLMInferenceServices with MaaS configuration do not appear in the RHOAI dashboard "AI asset endpoints → Models as a service" tab

**Example Error**: Browser console shows API error when accessing the MaaS tab:
```json
{
  "error": {
    "code": "service_unavailable",
    "message": "MaaS service is not available"
  }
}
```

**Affected Version**: RHOAI 3.3.0

**Root Cause**:
The gen-ai-ui backend component cannot discover the maas-api service URL. Gen-ai-ui container logs show empty URL during initialization:
```
time=2026-03-31T21:12:46.108Z level=INFO msg="Using real MaaS client factory" url=""
```

This prevents the dashboard from fetching the list of MaaS-enabled models, even though:
- All CRs show Ready status (DataScienceCluster, ModelsAsService, Dashboard)
- OdhDashboardConfig has `modelAsService: true`
- maas-api service exists and is healthy
- Network connectivity works (gen-ai-ui can reach maas-api)
- Models are correctly configured and accessible via external URLs

**Debug**:
```bash
# Check gen-ai-ui logs for MaaS client initialization
oc logs -n redhat-ods-applications deployment/rhods-dashboard -c gen-ai-ui | grep -i maas

# Should show "url=\"\"" instead of actual service URL

# Verify maas-api service exists and is healthy
oc get svc maas-api -n redhat-ods-applications
oc exec -n redhat-ods-applications deployment/maas-api -- curl -k -s https://localhost:8443/health
# Should return: {"status":"healthy"}

# Check if models are correctly configured
oc get llminferenceservice -n <namespace> -o yaml | grep -A 5 "alpha.maas.opendatahub.io/tiers"

# Verify models are accessible via external URL
curl -k https://maas-api.apps.<cluster-domain>/<namespace>/<model-name>/health
```

**Verification of Correct Configuration**:
```bash
# LLMInferenceService should have:
# 1. MaaS tiers annotation
oc get llminferenceservice <name> -n <namespace> -o jsonpath='{.metadata.annotations.alpha\.maas\.opendatahub\.io/tiers}'
# Expected: ["test","free"] or similar

# 2. Dashboard label
oc get llminferenceservice <name> -n <namespace> -o jsonpath='{.metadata.labels.opendatahub\.io/dashboard}'
# Expected: "true"

# 3. Stop annotation set to false
oc get llminferenceservice <name> -n <namespace> -o jsonpath='{.metadata.annotations.serving\.kserve\.io/stop}'
# Expected: "false"

# 4. NO genai-asset label (mutually exclusive with MaaS)
oc get llminferenceservice <name> -n <namespace> -o jsonpath='{.metadata.labels.opendatahub\.io/genai-asset}'
# Expected: (empty/no output)

# 5. Check CR status
oc get modelsasservice default-modelsasservice -o jsonpath='{.status.phase}'
# Expected: Ready

oc get dashboard default-dashboard -o jsonpath='{.status.phase}'
# Expected: Ready
```

**Workaround**:
Models ARE accessible via their external URLs through the Gateway:
```bash
# Get model URL from LLMInferenceService status
oc get llminferenceservice <name> -n <namespace> -o jsonpath='{.status.url}'

# Example: https://maas-api.apps.myocp.sandbox3491.opentlc.com/laurent/mybeautifulmodel

# Use this URL directly for inference requests
curl -k https://maas-api.apps.<cluster-domain>/<namespace>/<model-name>/v1/models
```

**Impact**:
- **Severity**: High - Dashboard MaaS listing completely non-functional
- **Scope**: All RHOAI 3.3.0 deployments with MaaS enabled
- **Business Impact**: Users cannot discover or manage MaaS models via dashboard UI
- **Workaround Quality**: Partial - models work but require manual URL construction

**Status**:
- **JIRA**: [Create ticket using template above]
- **Platform Bug**: Service discovery failure in gen-ai-ui component
- **Fix ETA**: Pending Red Hat investigation
- **Recommendation**: Open Red Hat support case for RHOAI 3.3.0 MaaS feature

**Reference**: Full investigation details in conversation transcript `c5f3e798-75bf-4c72-8f67-2d9602cd1bef.jsonl`

---

### Known False-Positive Alerts

See [`known-bugs.md`](known-bugs.md) for comprehensive list of silenced alerts and root causes.

## Monitoring Issues

See [`monitoring.md`](monitoring.md) for Alertmanager configuration and alert silence troubleshooting.
