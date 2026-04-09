# Job Architecture Documentation

**Purpose**: Comprehensive guide to Kubernetes Job patterns used for GitOps automation in this project.

## Overview

This project uses **Kubernetes Jobs** extensively to automate Day 2 operations that cannot be accomplished with static manifests alone. Jobs handle dynamic configuration, secret management, resource patching, and cleanup tasks.

**Total Jobs**: 14 across 10 components

**Why Jobs?**
- Dynamic value discovery (e.g., extracting auto-generated secrets)
- Shared resource patching (e.g., Console CR)
- Runtime configuration (e.g., Alertmanager silences via API)
- Cleanup operations (e.g., deleting failed pods)
- Cross-component dependencies (e.g., waiting for operator readiness)

**Execution context**: All Jobs run in `openshift-gitops` namespace (except monitoring Jobs)

**Security**: ✅ **All Jobs use dedicated ServiceAccounts with least-privilege RBAC** (AUDIT.md ISSUE-009 resolved)
- 13 dedicated ServiceAccounts created
- 0 cluster-admin usage (production-ready security)
- Namespace-scoped Roles preferred over ClusterRoles
- See [security.md](security.md) "Job RBAC Security" section for details

---

## ArgoCD Sync Hooks

Jobs integrate with ArgoCD's sync lifecycle using resource hooks to control execution timing.

### Hook Types

| Hook | When Executes | Use Cases |
|------|---------------|-----------|
| `PreSync` | Before sync starts | Prerequisites, validation |
| `Sync` | During normal sync | Standard resource creation |
| `Skip` | Never (excluded from sync) | Manual execution only |
| `PostSync` | After successful sync | Configuration, patching shared resources |
| `SyncFail` | After failed sync | Cleanup, notifications |
| `PreDelete` | Before app deletion (ArgoCD 3.3+) | Cleanup before resource deletion |
| `PostDelete` | After app deletion | Resource cleanup |

**Most common**: `PostSync` (used by 90% of Jobs in this project)

**PreDelete vs PostDelete**:
- **PreDelete**: Executes BEFORE ArgoCD deletes any resources (cleanup runs while resources still exist)
- **PostDelete**: Executes AFTER ArgoCD deletes resources (cleanup runs after resources are gone)
- **Recommendation**: Use PreDelete for cleanup that needs to interact with existing resources

### Hook Annotations

```yaml
metadata:
  annotations:
    argocd.argoproj.io/hook: PostSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
    argocd.argoproj.io/sync-wave: "3"
```

**Hook annotation**: `argocd.argoproj.io/hook: PostSync`
- Runs after all non-hook resources are synced and healthy

**Delete policy**: `argocd.argoproj.io/hook-delete-policy: BeforeHookCreation`
- Deletes previous Job instance before creating new one
- Prevents Job name conflicts
- **Alternative**: `HookSucceeded` (delete only after success, useful for debugging)

**Sync wave**: `argocd.argoproj.io/sync-wave: "3"`
- Controls execution order within same hook type
- Lower numbers execute first (can be negative)
- Default wave: `0`
- Waves in this project: `-1`, `0`, `1`, `2`, `3`, `10`

**⚠️ CRITICAL: Hooks and Sync-Waves are Mutually Exclusive**

When BOTH `hook` and `sync-wave` annotations are present:
- ✅ ArgoCD treats the resource as a **HOOK**
- ❌ The `sync-wave` annotation is **COMPLETELY IGNORED**
- ⚠️ Misleading configuration - suggests wave execution, but actually hook behavior

**Incorrect pattern** (sync-wave is ignored):
```yaml
metadata:
  annotations:
    argocd.argoproj.io/hook: PostSync      # Takes precedence
    argocd.argoproj.io/sync-wave: "3"     # IGNORED - misleading!
```

**Correct patterns**:
1. **Use sync-wave for regular resources** (no hook annotation):
   ```yaml
   metadata:
     annotations:
       argocd.argoproj.io/sync-wave: "1"   # Executes in wave 1
   ```

2. **Use hook for hook resources** (omit sync-wave unless ordering hooks):
   ```yaml
   metadata:
     annotations:
       argocd.argoproj.io/hook: PostSync   # Executes after all waves
   ```

3. **Use BOTH only to order hooks relative to other hooks**:
   ```yaml
   metadata:
     annotations:
       argocd.argoproj.io/hook: Sync       # Sync hook
       argocd.argoproj.io/sync-wave: "1"   # Among Sync hooks, execute in wave 1
   ```

**Execution order**:
- Regular resources execute in sync-wave order: `-1`, `0`, `1`, `2`, ...
- PostSync hooks execute AFTER all regular resources (regardless of sync-wave)
- Sync hooks execute during normal sync (can use sync-wave for ordering among Sync hooks)

### Force Execution

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-options: Force=true
```

**Force=true**: Job runs on **every sync**, even if manifest unchanged
- **Critical for idempotent Jobs** that must check current state
- Example: Console plugin Jobs check if plugin already enabled before patching
- Example: Secret rotation Jobs that need to run periodically

**Without Force=true**: ArgoCD skips Job if manifest unchanged since last sync (Job never re-runs)

### PreDelete Hooks and ApplicationSet Configuration

**CRITICAL REQUIREMENT**: PreDelete hooks only execute during **explicit Application deletion**, NOT during ApplicationSet pruning.

#### When PreDelete Hooks Execute

✅ **DOES execute**:
```bash
oc delete application <name>  # Explicit deletion command
```

❌ **DOES NOT execute**:
- ApplicationSet auto-pruning (removing component from generator list)
- Sync-based resource deletion (removing resource from git)

#### Required ApplicationSet Configuration

For PreDelete hooks to work with ApplicationSet-managed Applications, the ApplicationSet MUST be configured with:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  finalizers:
  - resources-finalizer.argocd.argoproj.io  # Protects Applications from ownerReference deletion
spec:
  syncPolicy:
    applicationsSync: create-update  # Prevents auto-deletion when removed from generator
  template:
    metadata:
      finalizers:
      - resources-finalizer.argocd.argoproj.io/background  # Cascade delete managed resources
```

**What each setting does**:

1. **ApplicationSet finalizer** (`metadata.finalizers`):
   - Prevents Applications from being deleted when ApplicationSet is deleted (ownerReferences)
   - Uses background cascading deletion
   - **Required** for `create-update` policy to work

2. **applicationsSync: create-update** (`spec.syncPolicy`):
   - Allows ApplicationSet to **create** and **update** Applications
   - **Prevents** ApplicationSet from **deleting** Applications when removed from generator list
   - Applications become "orphaned" when removed (still exist but not managed)

3. **Application finalizer** (`template.metadata.finalizers`):
   - Controls cascade deletion of Application's managed resources (Deployments, Services, etc.)
   - **background**: Async deletion, Application deleted immediately, resources cleaned in background

#### Workflow for Component Removal with PreDelete Hooks

**Step 1**: Remove component from profile/generator list
```yaml
# gitops-bases/core/applicationset.yaml
generators:
- list:
    elements:
    - item: cert-manager
    # - item: openshift-builds  # REMOVED
    - item: grafana
```
Commit and push → ApplicationSet reconciles → Application becomes orphaned (NOT deleted)

**Step 2**: Verify Application orphaned
```bash
oc get application openshift-builds -n openshift-gitops
# Status: Still exists (Synced/Healthy or Degraded)
```

**Step 3**: Delete Application explicitly
```bash
oc delete application openshift-builds -n openshift-gitops
# PreDelete hook Job created and executed
# Cleanup runs following custom procedure (e.g., Red Hat official uninstall)
# Application deleted after hook succeeds
```

**Step 4** (Optional): Re-add to profile
```yaml
# Restore to generator list → ApplicationSet recreates Application → Component redeploys
```

#### Example: OpenShift Builds PreDelete Hook

**File**: `components/openshift-builds/base/openshift-gitops-job-delete-openshift-builds-resources.yaml`

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  annotations:
    argocd.argoproj.io/hook: PreDelete
    argocd.argoproj.io/hook-delete-policy: HookSucceeded
    argocd.argoproj.io/sync-options: Force=true
  name: delete-openshift-builds-resources
  namespace: openshift-gitops
spec:
  template:
    spec:
      containers:
      - command: ["/bin/bash", "-c"]
        args:
        - |
          # Step 1: Delete Shipwright CRDs (operator still running, handles cleanup)
          # Step 2: Wait 30s for operator cleanup
          # Step 3: Delete OpenShiftBuild CR
          # Step 4: Delete Subscription and CSV
          # Step 5: Delete OperatorGroup
          # Step 6: Delete namespace
          # Step 7: Verify cleanup succeeded
```

**Execution verified** (2026-04-01):
- PreDelete Job created within 4 seconds of deletion
- Followed Red Hat official uninstall procedure
- Operator cleanly removed (Subscription, CSV, pods deleted)
- Application deleted after hook completion
- Job self-deleted (HookSucceeded policy)

#### When to Use PreDelete vs PostDelete

| Scenario | Hook Type | Reason |
|----------|-----------|--------|
| Cleanup needs existing resources | **PreDelete** | Resources still exist during hook execution |
| Backup before deletion | **PreDelete** | Data accessible during hook |
| Operator requires specific order | **PreDelete** | Control deletion sequence before ArgoCD |
| Notification after deletion | **PostDelete** | Confirm deletion completed |
| Simple cleanup | **PostDelete** | Simpler, no ApplicationSet config needed |

**Recommendation**: Use **PreDelete** when cleanup procedure requires resources to exist (e.g., operator uninstall procedures, data backup).

#### ArgoCD Version Requirements

- **PreDelete hooks**: ArgoCD 3.3+ (OpenShift GitOps 1.20+)
- **PostDelete hooks**: ArgoCD 2.10+ (OpenShift GitOps 1.10+)
- **applicationsSync policy**: ArgoCD 2.5+

#### ApplicationSets Using create-update Policy

All ApplicationSets in this project are configured with `applicationsSync: create-update`:

- `cluster-core-components` (core gitops-base) - **Configured 2026-04-01**
- Additional ApplicationSets inherit this pattern for consistency

**Benefits**:
- Prevents accidental deletion via ApplicationSet pruning
- Enables PreDelete hook execution for controlled cleanup
- Supports component lifecycle management (remove → cleanup → restore)

---

## Job Categories

### 1. Console Plugin Management (6 Jobs)

**Pattern**: Pure Patch Jobs for shared Console CR

**Why Jobs?**
- Console is a **cluster-scoped shared resource** modified by 4 components
- Static manifests would overwrite each other (last one wins)
- Jobs use `oc patch` with JSON Patch to ADD plugins incrementally
- Each Job is idempotent (checks if plugin exists before adding)

**Jobs:**
- `openshift-gitops-job-enable-gitops-console-plugin.yaml` → `gitops-plugin`
- `openshift-gitops-job-enable-pipelines-console-plugin.yaml` → `pipelines-console-plugin`
- `openshift-gitops-job-disable-pipelines-console-plugin.yaml` → Removes `pipelines-console-plugin`
- `openshift-gitops-job-enable-odf-console-plugins.yaml` → `odf-console`, `odf-client-console`
- `openshift-gitops-job-disable-odf-console-plugins.yaml` → Removes `odf-console`, `odf-client-console`
- `openshift-gitops-job-enable-kuadrant-console-plugin.yaml` → `kuadrant-console-plugin`

**Template:**
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  annotations:
    argocd.argoproj.io/hook: PostSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
    argocd.argoproj.io/sync-options: Force=true
  name: enable-gitops-console-plugin
  namespace: openshift-gitops
spec:
  template:
    spec:
      containers:
      - command:
        - /bin/bash
        - -c
        - |
          set -e
          echo "Checking if gitops-plugin is already enabled..."
          if ! oc get console.operator.openshift.io cluster -o jsonpath='{.spec.plugins[*]}' | grep -qw "gitops-plugin"; then
            echo "Enabling gitops-plugin..."
            oc patch console.operator.openshift.io cluster --type=json -p='[{"op": "add", "path": "/spec/plugins/-", "value": "gitops-plugin"}]'
            echo "Plugin gitops-plugin added successfully."
          else
            echo "Plugin gitops-plugin already exists. Nothing changed."
          fi
        image: registry.redhat.io/openshift4/ose-cli:latest
        name: enable-console-plugin
      nodeSelector:
        node-role.kubernetes.io/infra: ''
      restartPolicy: Never
      serviceAccountName: console-plugin-manager
      tolerations:
      - key: node-role.kubernetes.io/infra
        operator: Exists
```

**Key patterns:**
- `hook: PostSync` → Executes after all sync waves complete
- `hook-delete-policy: BeforeHookCreation` → Deletes old Job before creating new one
- `Force=true` → Runs every sync
- Idempotency check with `grep -qw`
- JSON Patch with `op: add` to append to array
- Uses `ose-cli` image for `oc` command
- Dedicated ServiceAccount: `console-plugin-manager` (least-privilege RBAC)

### 2. Secret Management (2 Jobs)

**Pattern**: Dynamic value discovery from operator-generated secrets

**Why Jobs?**
- Operators auto-generate secrets (e.g., S3 credentials from ObjectBucketClaim)
- Secret names/values unknown at manifest creation time
- Jobs extract values and create application-specific secrets

**Jobs:**
- `openshift-gitops-job-create-secret-logging-loki-s3.yaml` → Extracts S3 creds for Loki logging
- `openshift-gitops-job-create-secret-netobserv-loki-s3.yaml` → Extracts S3 creds for NetObserv

**Template (S3 secret extraction):**
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  annotations:
    argocd.argoproj.io/sync-options: Force=true
  name: create-secret-logging-loki-s3
  namespace: openshift-gitops
spec:
  template:
    spec:
      containers:
      - command:
        - /bin/bash
        - -c
        - |
          echo "Read the secret generated by loki OBC"
          while ! oc get secret logging-loki -n openshift-logging 2>/dev/null 1>&2; do
            echo "Waiting for secret logging-loki in namespace openshift-logging."
          done

          ACCESS_KEY=$(oc get secret logging-loki -n openshift-logging --template={{.data.AWS_ACCESS_KEY_ID}} | base64 -d)
          SECRET_KEY=$(oc get secret logging-loki -n openshift-logging --template={{.data.AWS_SECRET_ACCESS_KEY}} | base64 -d)
          BUCKET_NAME=logging-loki
          ENDPOINT=https://s3.openshift-storage.svc
          REGION=eu

          echo "Create the loki-logging-s3 secret"
          oc delete secret generic logging-loki-s3 -n openshift-logging --ignore-not-found
          oc create secret generic logging-loki-s3 -n openshift-logging \
            --from-literal access_key_id=$ACCESS_KEY \
            --from-literal access_key_secret=$SECRET_KEY \
            --from-literal bucketnames=$BUCKET_NAME \
            --from-literal endpoint=$ENDPOINT \
            --from-literal region=$REGION \
            --from-literal insecure=true
        image: registry.redhat.io/openshift4/ose-cli:latest
        name: create-secret-logging-loki-s3
      restartPolicy: Never
      serviceAccountName: openshift-gitops-argocd-application-controller
```

**Key patterns:**
- Wait loop with `while ! oc get` until resource exists
- Extract secret values with `--template={{.data.KEY}} | base64 -d`
- Delete existing secret with `--ignore-not-found`
- Create new secret with `--from-literal`
- Hardcoded endpoint values (NooBaa S3 service)

### 3. Shared Resource Patching (1 Job)

**Pattern**: Runtime patching of cluster-scoped resources requiring dynamic logic

**Why Jobs?**
- Resources require runtime logic (token generation, dependency waiting)
- Cannot be represented as static manifests

**Job:**
- `openshift-gitops-job-configure-grafana-datasource-token.yaml` → Patch GrafanaDatasource CR with ServiceAccount token

**Deprecated Jobs (replaced by static manifests + CMP):**
- ~~`openshift-gitops-job-update-openshift-ingress-operator-ingresscontroller-default.yaml`~~ → Now static manifest in cluster-ingress
- ~~`openshift-gitops-job-update-cluster-apiserver-cluster.yaml`~~ → Now static manifest in openshift-config
- ~~`openshift-gitops-job-create-cluster-cert-manager-resources.yaml`~~ → Now static Certificates with CMP placeholders

**Migration to Static Manifests:**

The "Static + ignoreDifferences doesn't work" assumption was **incorrect for shared resources**.

Static manifests **DO WORK** when:
- Resource is **shared** (created by OpenShift)
- GitOps manages **subset of fields**
- ignoreDifferences ignores **OpenShift-managed fields NOT in Git**

```yaml
# cluster-ingress/base/openshift-ingress-operator-ingresscontroller-default.yaml
spec:
  defaultCertificate:
    name: ingress-certificates  # GitOps manages this

# ApplicationSet ignores OpenShift fields:
ignoreDifferences:
- kind: IngressController
  jsonPointers:
  - /spec/nodePlacement  # OpenShift-managed, not in Git
```

**Why this works:**
- Shared resource pattern (created by installer)
- GitOps declares only specific fields
- Delete=false prevents ArgoCD from deleting resource
- OpenShift continues managing other fields

**Lesson learned:**
- ❌ Static + ignoreDifferences FAILS when ignoring fields **IN Git** (logical contradiction - "here's config, ignore it")
- ✅ Static + ignoreDifferences WORKS when ignoring fields **NOT in Git** (shared resource - "manage subset only")

### 4. Alert Management (1 Job)

**Pattern**: API-based silence creation via Alertmanager REST API

**Why Jobs?**
- Alert silences require Alertmanager API calls (not declarative resources)
- Silences must be created after Alertmanager pods are running and stable
- Job waits for readiness, uses port-forward, creates silences via curl

**Job:**
- `openshift-monitoring-job-create-alert-silences.yaml` → Creates 6 silences for known bugs

**Template (simplified):**
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  annotations:
    argocd.argoproj.io/hook: PostSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
    argocd.argoproj.io/sync-wave: '10'
  name: create-alert-silences
  namespace: openshift-monitoring
spec:
  template:
    spec:
      containers:
      - command:
        - /bin/bash
        - -c
        - |
          set -e

          # Wait for Alertmanager StatefulSet to be ready
          DESIRED_REPLICAS=$(oc get statefulset alertmanager-main -n openshift-monitoring -o jsonpath='{.spec.replicas}')
          for i in {1..60}; do
            READY_REPLICAS=$(oc get statefulset alertmanager-main -n openshift-monitoring -o jsonpath='{.status.readyReplicas}')
            if [ "$READY_REPLICAS" = "$DESIRED_REPLICAS" ]; then
              echo "Alertmanager ready"
              break
            fi
            sleep 5
          done

          # Wait additional time for API stability
          sleep 30

          # Function to create silence with retry
          create_silence() {
            local name=$1
            local payload=$2

            for attempt in $(seq 1 3); do
              # Port-forward to Alertmanager
              oc port-forward -n openshift-monitoring alertmanager-main-0 9093:9093 >/dev/null 2>&1 &
              PF_PID=$!
              sleep 3

              # Create silence
              HTTP_CODE=$(curl -s -w "%{http_code}" -o /tmp/response.json \
                -X POST -H "Content-Type: application/json" \
                --data "$payload" \
                http://localhost:9093/api/v2/silences)

              if [ "$HTTP_CODE" = "200" ]; then
                echo "Silence created: $name"
                kill $PF_PID
                return 0
              fi

              kill $PF_PID
              sleep 5
            done
            return 1
          }

          # Calculate timestamps (10-year silence)
          START_TIME=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
          END_TIME=$(date -u -d '+10 years' +%Y-%m-%dT%H:%M:%S.000Z)

          # Create silences for each known bug
          PAYLOAD=$(cat <<EOF
          {
            "matchers": [
              {"name": "alertname", "value": "TargetDown", "isRegex": false, "isEqual": true}
            ],
            "startsAt": "$START_TIME",
            "endsAt": "$END_TIME",
            "createdBy": "argocd-automation",
            "comment": "Known bug - See KNOWN_BUGS.md"
          }
          EOF
          )
          create_silence "TargetDown alert" "$PAYLOAD"
        image: registry.redhat.io/openshift4/ose-cli:latest
        name: create-silences
      restartPolicy: Never
      serviceAccountName: create-alert-silences
```

**Key patterns:**
- Wave `10` (highest) → Runs last after all monitoring components ready
- Complex readiness waiting (StatefulSet + pods + API stability)
- Retry logic with attempt counter
- Port-forward for API access from Pod
- HEREDOC for JSON payload construction
- Verification via GET after POST

**Security**: Uses dedicated `create-alert-silences` ServiceAccount (principle of least privilege)

### 5. Dynamic Configuration Injection (1 Job)

**Pattern**: Generate runtime configuration based on cluster state

**Why Jobs?**
- Configuration values discovered from cluster resources
- Inject into operator/application configs

**Jobs:**
- `openshift-gitops-job-ack-config-injector.yaml` → Inject AWS credentials into ACK controller

**Deprecated Jobs (replaced by static manifests):**
- ~~`openshift-gitops-job-create-maas-gateway.yaml`~~ → Now static Gateway manifest with CMP placeholders

**Template (ACK config injection):**
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  annotations:
    argocd.argoproj.io/hook: PostSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
    argocd.argoproj.io/sync-wave: "3"
  name: ack-config-injector
  namespace: openshift-gitops
spec:
  template:
    spec:
      containers:
      - command:
        - /bin/bash
        - -c
        - |
          set -e

          echo "Retrieving AWS credentials from Secrets Manager..."
          AWS_ACCESS_KEY=$(aws secretsmanager get-secret-value --secret-id ack-route53-user --query SecretString --output text | jq -r '.AccessKeyId')
          AWS_SECRET_KEY=$(aws secretsmanager get-secret-value --secret-id ack-route53-user --query SecretString --output text | jq -r '.SecretAccessKey')

          echo "Creating ACK system namespace configuration..."
          oc create secret generic ack-route53-user-secrets -n ack-system \
            --from-literal=AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY \
            --from-literal=AWS_SECRET_ACCESS_KEY=$AWS_SECRET_KEY \
            --dry-run=client -o yaml | oc apply -f -

          echo "Configuration injected successfully."
        image: registry.redhat.io/openshift4/ose-cli:latest
        name: inject-config
      restartPolicy: Never
      serviceAccountName: openshift-gitops-argocd-application-controller
```

**Key patterns:**
- AWS Secrets Manager integration
- `jq` for JSON parsing
- `--dry-run=client -o yaml | oc apply` for idempotent create/update
- Wave `3` to run after operator deployment

### 6. Cleanup Operations (2 Jobs)

**Pattern**: Remove failed/unwanted resources

**Why Jobs?**
- Automated cleanup of error states
- Remove resources incompatible with configuration

**Jobs:**
- `openshift-gitops-job-cleanup-installer-pods.yaml` → Delete failed installer pods
- `openshift-gitops-job-delete-openshift-builds-resources.yaml` → Remove OpenShift Builds operator (superseded by Pipelines)
  - Uses proper operator cleanup sequence (Subscription → CSV → CR finalizer removal → Namespace)
  - See "Pattern: Operator Cleanup with Finalizer Handling" below

**Template (cleanup failed pods):**
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  annotations:
    argocd.argoproj.io/sync-options: Force=true
  name: cleanup-installer-pods
  namespace: openshift-gitops
spec:
  template:
    spec:
      containers:
      - command:
        - /bin/bash
        - -c
        - |
          echo "Starting cleanup of error installer pods..."
          TARGET_NS="openshift-kube-controller-manager"

          # Find pods with Error/Failed status and label app=installer
          PODS_TO_DELETE=$(oc get pods -n "$TARGET_NS" -l app=installer --no-headers | awk '$3 ~ /Error|Failed/ {print $1}')

          if [[ -z "$PODS_TO_DELETE" ]]; then
            echo "No pods found in Error/Failed state. Nothing to clean up."
          else
            echo "Found failed pods:"
            echo "$PODS_TO_DELETE"

            for pod in $PODS_TO_DELETE; do
              echo "Deleting pod: $pod"
              oc delete pod "$pod" -n "$TARGET_NS"
            done

            echo "Cleanup complete."
          fi
        image: registry.redhat.io/openshift4/ose-cli:latest
        name: cleanup
      restartPolicy: Never
      serviceAccountName: openshift-gitops-argocd-application-controller
```

**Key patterns:**
- `awk` filtering for specific status
- Loop through results
- Idempotent (safe if no pods found)
- `Force=true` to run every sync

### 7. Dependency Waiting (0 Jobs) - PATTERN REMOVED

**Pattern**: ~~Wait for cross-component dependencies before proceeding~~

**Status**: **REMOVED** (2026-03-31) - No longer needed

**Historical context:**
Previously, `openshift-builds` included a PreSync Job (`check-and-wait-openshift-pipelines`) that waited for OpenShift Pipelines to be ready before deploying OpenShift Builds.

**Why removed:**
- Both operators are deployed together in devops profiles via their respective ApplicationSets
- Operators handle their own dependency reconciliation internally
- OpenShift Builds operator waits for Tekton components during its reconciliation loop
- Unnecessary complexity when both are installed simultaneously

**Alternative approach:**
Deploy both operators via ApplicationSets and let operator reconciliation handle timing:
- `openshift-builds` → core ApplicationSet
- `openshift-pipelines` → devops ApplicationSet

Operators retry internally until dependencies are met.

### 8. Operator Node Selector Updates (1 Job)

**Pattern**: Modify OLM-managed Subscription node placement post-deployment

**Why Jobs?**
- OLM Subscriptions with `config.nodeSelector` don't apply immediately to deployed operators
- Direct Deployment patching required after operator installation

**Job:**
- `openshift-storage-job-update-subscriptions-node-selector.yaml` → Apply infra node selector to ODF operators

**Template:**
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  annotations:
    argocd.argoproj.io/hook: PostSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
    argocd.argoproj.io/sync-wave: "3"
  name: update-subscriptions-node-selector
  namespace: openshift-storage
spec:
  template:
    spec:
      containers:
      - command:
        - /bin/bash
        - -c
        - |
          set -e

          echo "Waiting for ODF operator deployments..."
          oc wait deployment odf-operator-controller-manager -n openshift-storage --for=condition=Available --timeout=300s

          echo "Patching operator deployments with infra node selector..."
          for deployment in $(oc get deployments -n openshift-storage -o name | grep -E "odf-|ocs-|noobaa-"); do
            echo "Patching $deployment"
            oc patch $deployment -n openshift-storage --type=merge -p '{
              "spec": {
                "template": {
                  "spec": {
                    "nodeSelector": {"node-role.kubernetes.io/infra": ""},
                    "tolerations": [{"key": "node-role.kubernetes.io/infra", "operator": "Exists"}]
                  }
                }
              }
            }'
          done

          echo "All deployments patched."
        image: registry.redhat.io/openshift4/ose-cli:latest
        name: update-node-selector
      restartPolicy: Never
      serviceAccountName: openshift-gitops-argocd-application-controller
```

**Key patterns:**
- Wait for initial deployment
- Loop through multiple deployments with `grep -E` filter
- Patch deployment spec (triggers pod recreation)
- Strategic merge patch with full JSON structure

### 9. GPU MachineSet Creation (1 Job)

**Pattern**: Infrastructure-as-Code for compute resources

**Why Jobs?**
- MachineSet manifests require dynamic cluster-specific values (AMI ID, subnets, security groups)
- Values must be discovered from existing MachineSets

**Job:**
- `openshift-gitops-job-create-gpu-machineset.yaml` → Create GPU-enabled MachineSet

**Key patterns:**
- Clone existing MachineSet as template
- Modify instance type, AMI, userdata for GPU
- `oc get machineset -o json` for value extraction

---

## Development Guide

### Job Development Template

Use this template as starting point for new Jobs:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  annotations:
    # Choose hook type based on when Job should run
    argocd.argoproj.io/hook: PostSync  # Options: PreSync, Sync, PostSync, PostDelete

    # Delete policy: BeforeHookCreation (always) or HookSucceeded (debugging)
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation

    # Sync wave: -1 (early), 0 (default), 3 (late), 10 (very late)
    argocd.argoproj.io/sync-wave: "3"

    # Force execution every sync? (true for idempotent checks, false for one-time operations)
    # argocd.argoproj.io/sync-options: Force=true

  name: my-job-name
  namespace: openshift-gitops  # Jobs run in GitOps namespace (except monitoring)
spec:
  # Optional: retry failed jobs
  # backoffLimit: 3

  template:
    metadata:
      name: my-job-name
    spec:
      containers:
      - name: my-job
        image: registry.redhat.io/openshift4/ose-cli:latest  # Standard image with oc/kubectl

        command:
        - /bin/bash
        - -c
        - |
          set -e  # Exit on error

          echo "Starting job..."

          # Your logic here
          # Example: Wait for resource
          # while ! oc get <resource> <name> -n <namespace> 2>/dev/null; do
          #   echo "Waiting for resource..."
          #   sleep 5
          # done

          # Example: Patch resource
          # oc patch <resource> <name> -n <namespace> --type=merge -p '{"spec":{"field":"value"}}'

          # Example: Create secret
          # VALUE=$(oc get secret <name> -n <namespace> --template='{{.data.key}}' | base64 -d)
          # oc create secret generic <new-secret> -n <namespace> --from-literal=key=$VALUE

          echo "Job complete."

      # Infrastructure node placement (standard for all Jobs)
      nodeSelector:
        node-role.kubernetes.io/infra: ''

      tolerations:
      - key: node-role.kubernetes.io/infra
        operator: Exists

      # Never retry Job pod (Job resource handles retries)
      restartPolicy: Never

      # ServiceAccount with cluster-admin (standard)
      serviceAccountName: openshift-gitops-argocd-application-controller
```

### Choosing Hook Type and Wave

**Decision tree:**

1. **When should Job run relative to manifests?**
   - Before manifests applied → `PreSync`
   - After manifests applied and healthy → `PostSync`
   - Only when app deleted → `PostDelete`

2. **What wave number?**
   - Needs to run first (dependencies) → `-1`
   - Standard timing → `0` or `3`
   - Needs everything else ready → `10`

3. **Should it run every sync?**
   - Job is idempotent (checks state before acting) → `Force=true`
   - Job should run once only → No `Force` annotation

**Examples:**
- Wait for operator CRD: `PreSync`, wave `-1`
- Patch shared resource: `PostSync`, wave `3`, `Force=true`
- Create silences after monitoring ready: `PostSync`, wave `10`
- Delete app resources: `PostDelete`, wave `0`

### Common Patterns

#### Pattern: Wait for Resource

```bash
echo "Waiting for <resource> to exist..."
while ! oc get <resource> <name> -n <namespace> 2>/dev/null; do
  echo "Still waiting..."
  sleep 5
done

# Wait for ready condition
oc wait <resource> <name> -n <namespace> --for=condition=Ready --timeout=300s
```

#### Pattern: Extract Secret Value

```bash
# Wait for secret to exist
while ! oc get secret <secret-name> -n <namespace> 2>/dev/null; do
  sleep 5
done

# Extract and decode
VALUE=$(oc get secret <secret-name> -n <namespace> --template='{{.data.key}}' | base64 -d)

# Use value
oc create secret generic <new-secret> -n <namespace> --from-literal=key=$VALUE
```

#### Pattern: Idempotent Resource Patch

```bash
# Check if already configured
if ! oc get <resource> <name> -n <namespace> -o jsonpath='{.spec.field}' | grep -q "value"; then
  echo "Applying configuration..."
  oc patch <resource> <name> -n <namespace> --type=merge -p '{"spec":{"field":"value"}}'
else
  echo "Already configured."
fi
```

#### Pattern: Idempotent Secret Creation

```bash
# Delete if exists, create new
oc delete secret <secret-name> -n <namespace> --ignore-not-found
oc create secret generic <secret-name> -n <namespace> \
  --from-literal=key1=value1 \
  --from-literal=key2=value2
```

Alternative (better for GitOps):
```bash
# Apply from YAML (idempotent)
oc create secret generic <secret-name> -n <namespace> \
  --from-literal=key1=value1 \
  --dry-run=client -o yaml | oc apply -f -
```

#### Pattern: Loop Through Resources

```bash
for resource in $(oc get <resource-type> -n <namespace> -o name | grep <pattern>); do
  echo "Processing $resource"
  oc patch $resource -n <namespace> --type=merge -p '{"spec":{"field":"value"}}'
done
```

#### Pattern: Retry with Backoff

```bash
for attempt in {1..5}; do
  if <command>; then
    echo "Success on attempt $attempt"
    exit 0
  fi

  echo "Attempt $attempt failed, retrying in $((attempt * 5)) seconds..."
  sleep $((attempt * 5))
done

echo "Failed after 5 attempts"
exit 1
```

#### Pattern: Operator Cleanup with Finalizer Handling (PostDelete)

**Problem**: Deleting operator Custom Resources with finalizers can cause deadlock when using `--cascade=foreground`. The operator continues running while the Job waits indefinitely for the CR to be deleted, causing timeout and BackoffLimitExceeded failure.

**Solution**: Delete resources in proper order (Subscription → CSV → CR with finalizer removal → Namespace):

```bash
set -e

# Step 1: Delete Subscription (stops operator updates)
echo "Step 1: Deleting Subscription..."
if oc get subscription <operator-name> -n <namespace> &>/dev/null; then
  oc delete subscription <operator-name> -n <namespace> --ignore-not-found
  echo "✅ Subscription deleted"
else
  echo "ℹ️  Subscription not found"
fi

# Step 2: Delete CSV (stops operator)
echo "Step 2: Deleting ClusterServiceVersion..."
CSV_NAME=$(oc get csv -n <namespace> -o name 2>/dev/null | grep <operator-name> || echo "")
if [ -n "$CSV_NAME" ]; then
  oc delete $CSV_NAME -n <namespace> --ignore-not-found
  echo "✅ CSV deleted: $CSV_NAME"
else
  echo "ℹ️  CSV not found"
fi

# Step 3: Wait for operator pods to terminate
echo "Step 3: Waiting for operator pods to terminate..."
if oc get pods -l app=<operator-label> -n <namespace> &>/dev/null; then
  oc wait --for=delete pod -l app=<operator-label> -n <namespace> --timeout=120s 2>/dev/null || \
    echo "⚠️  Timeout waiting for pods (continuing anyway)"
  echo "✅ Operator pods terminated"
else
  echo "ℹ️  No operator pods found"
fi

# Step 4: Remove finalizer from CR (if operator didn't clean up)
echo "Step 4: Removing finalizer from CR..."
if oc get <cr-kind> <cr-name> &>/dev/null; then
  FINALIZER_COUNT=$(oc get <cr-kind> <cr-name> -o jsonpath='{.metadata.finalizers}' 2>/dev/null | \
    grep -c "<finalizer-name>" || echo "0")
  if [ "$FINALIZER_COUNT" -gt 0 ]; then
    oc patch <cr-kind> <cr-name> --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' \
      2>/dev/null || echo "⚠️  Failed to remove finalizer (may already be removed)"
    echo "✅ Finalizer removed"
  else
    echo "ℹ️  No finalizer found (operator already cleaned up)"
  fi
else
  echo "ℹ️  CR not found"
fi

# Step 5: Delete CR
echo "Step 5: Deleting CR..."
if oc get <cr-kind> <cr-name> &>/dev/null; then
  oc delete <cr-kind> <cr-name> --ignore-not-found --timeout=60s
  echo "✅ CR deleted"
else
  echo "ℹ️  CR already deleted"
fi

# Step 6: Delete namespace
echo "Step 6: Deleting namespace..."
if oc get namespace <namespace> &>/dev/null; then
  oc delete namespace <namespace> --ignore-not-found --timeout=120s
  echo "✅ Namespace deleted"
else
  echo "ℹ️  Namespace already deleted"
fi

echo "✅ Cleanup completed successfully"
```

**Required RBAC** (example for `cleanup-operator` ClusterRole):

```yaml
rules:
- apiGroups: [""]
  resources: [namespaces, pods]
  verbs: [delete, list, get]
- apiGroups: [<operator-api-group>]
  resources: [<cr-plural>]
  verbs: [delete, get, patch]  # patch required for finalizer removal
- apiGroups: [operators.coreos.com]
  resources: [subscriptions, clusterserviceversions]
  verbs: [delete, list, get]
```

**Key points**:
- ✅ Stops operator before deleting CR (prevents finalizer deadlock)
- ✅ Fallback finalizer removal if operator doesn't clean up
- ✅ Idempotent (safe to retry on failure)
- ✅ Comprehensive logging for troubleshooting
- ✅ Timeouts prevent infinite waiting
- ❌ Never use `--cascade=foreground` for operator CRs with finalizers

**Example**: `components/openshift-builds/base/openshift-gitops-job-delete-openshift-builds-resources.yaml`

---

## Best Practices

### Prefer Static Configuration Over Jobs

**Principle**: Use static manifests whenever possible. Jobs should be last resort.

**Anti-pattern example** (removed in commit d6cd56f):
```yaml
# ❌ BAD: Using PostSync Job to patch dynamic bucket name
# DSPA with empty bucket field (fails validation)
spec:
  objectStorage:
    externalStorage:
      bucket: ""  # Empty - will be patched by Job

# PostSync Job patches DSPA after OBC creates bucket
# Problems: 
# - Chicken-and-egg problem (DSPA needs bucket to deploy)
# - Unnecessary complexity
# - Race conditions
# - Fragile for redeployment
```

**Correct pattern**:
```yaml
# ✅ GOOD: Static bucket name, no Job needed
# OBC with static bucket name
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
spec:
  bucketName: ai-generation-llm-rag-pipelines  # Static, predictable

# DSPA with hardcoded bucket name
spec:
  objectStorage:
    externalStorage:
      bucket: "ai-generation-llm-rag-pipelines"  # Same static name
```

**Result**: Simple, declarative, robust. No PostSync Job needed.

**When Jobs ARE required:**
- ✅ Shared resources (Console CR modified by multiple components)
- ✅ Runtime API calls (Alertmanager silence API)
- ✅ Dynamic discovery when static values impossible (cluster domain, AWS region)
- ✅ Cleanup operations (PreDelete hooks)

**When Jobs are NOT required:**
- ❌ Values that can be static (bucket names, passwords)
- ❌ One-time patching that static config could handle
- ❌ Workarounds for poor manifest design

**Rule**: If you're writing a PostSync Job, first ask: "Can this be static configuration instead?"

### Shell Scripting

1. **Extract complex scripts to ConfigMaps**
   - For scripts >100 lines, use ConfigMap instead of embedded bash
   - Mount ConfigMap at `/scripts` with executable permissions (0755)
   - Benefits: Better maintainability, no YAML escaping, easier testing

   **Example:**
   ```yaml
   # Job manifest (35 lines)
   spec:
     containers:
     - command: ["/scripts/my-script.sh"]
       volumeMounts:
       - mountPath: /scripts
         name: scripts
     volumes:
     - configMap:
         name: my-scripts
         defaultMode: 0755

   # ConfigMap (separate file, 200+ lines of clean bash)
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: my-scripts
   data:
     my-script.sh: |
       #!/bin/bash
       set -e
       # Clean, readable script without \n escapes
   ```

   **Pattern applied:** See `cert-manager-configmap-scripts.yaml` (resolves AUDIT.md ISSUE-003)

2. **Always use `set -e`**
   - Exit immediately on any error
   - Prevents cascading failures

3. **Quote variables**
   - Use `"$VAR"` not `$VAR`
   - Prevents word splitting on spaces

4. **Use HEREDOC for multi-line JSON/YAML**
   ```bash
   PAYLOAD=$(cat <<'EOF'
   {
     "field": "value"
   }
   EOF
   )
   ```
   - Single quotes `<<'EOF'` prevent variable expansion
   - Double quotes `<<EOF` allow variable expansion

5. **Provide clear logging**
   - Echo before each major operation
   - Show what values were discovered
   - Distinguish success ✅ vs error ❌ messages

6. **Use `--ignore-not-found` for cleanup**
   - `oc delete <resource> --ignore-not-found`
   - Makes cleanup idempotent

### Variable Naming Convention

**CRITICAL**: Use prefixed variable names in Job scripts to avoid conflicts with CMP plugin placeholders.

**Why this matters:**
- CMP plugin performs `sed` replacement on ALL manifests: `s|CLUSTER_REGION|eu-central-1|g`
- If Job script uses `CLUSTER_REGION=` variable, it gets replaced: `eu-central-1=$(oc get...)`
- Result: Invalid bash syntax, Job fails

**Standard naming convention:**

```bash
# ✅ Infrastructure-discovered values (from OpenShift APIs)
OCP_BASE_DOMAIN=     # From dns.config.openshift.io/cluster
OCP_CLUSTER_NAME=    # From infrastructure.status.infrastructureName
OCP_PLATFORM=        # From infrastructure.status.platform

# ✅ AWS-discovered values (from Infrastructure or MachineSet APIs)
AWS_REGION=          # From infrastructure.status.platformStatus.aws.region
AWS_ACCESS_KEY=      # From secrets
AWS_SECRET_KEY=      # From secrets

# ✅ Computed/derived values
BASE_DOMAIN=         # Only when transforming OCP_BASE_DOMAIN
API_URL=             # Only when building URLs
INFRA_ID=            # Only when cloning MachineSets

# ✅ Constants (hardcoded values, not discovered)
REGION=eu            # OK when hardcoded (not discovered from APIs)
TIMESTAMP=$(date +%s) # OK for unique identifiers

# ❌ NEVER use these in Job bash scripts (reserved for CMP placeholders)
CLUSTER_DOMAIN       # CMP replaces with apps.${BASE_DOMAIN}
ROOT_DOMAIN          # CMP replaces with parent domain
CLUSTER_REGION       # CMP replaces with discovered region
```

**Examples:**

```bash
# ❌ BAD - Conflicts with CMP placeholder
CLUSTER_REGION=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.aws.region}')
region: ${CLUSTER_REGION}  # CMP will corrupt this before Job runs

# ✅ GOOD - Prefixed variable name
AWS_REGION=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.aws.region}')
region: ${AWS_REGION}  # Safe from CMP replacement

# ❌ BAD - Conflicts with CMP placeholder
CLUSTER_DOMAIN=$(oc get dns.config.openshift.io/cluster -o jsonpath='{.spec.baseDomain}')
hostname: maas-api.apps.${CLUSTER_DOMAIN}

# ✅ GOOD - Prefixed variable name
OCP_BASE_DOMAIN=$(oc get dns.config.openshift.io/cluster -o jsonpath='{.spec.baseDomain}')
hostname: maas-api.apps.${OCP_BASE_DOMAIN}
```

**When to use Jobs vs CMP placeholders:**

| Scenario | Approach | Example |
|----------|----------|---------|
| Static YAML field needing cluster-specific value | CMP placeholder | `region: CLUSTER_REGION` in ClusterIssuer |
| Runtime logic/conditions | Job with prefixed variables | `if [ "$AWS_REGION" = "us-east-1" ]; then ...` |
| Secret extraction | Job with prefixed variables | `AWS_ACCESS_KEY=$(oc extract...)` |
| API patching | Job with prefixed variables | `oc patch ... --patch "{\"hostname\": \"api.${OCP_BASE_DOMAIN}\"}"` |
| Dynamic TIMESTAMP generation | Job | `dnsNames: ["api.${TIMESTAMP}.${OCP_BASE_DOMAIN}"]` |

**Rule of thumb:** If the value can be determined at ArgoCD sync time (static), use CMP placeholder. If it requires runtime discovery or logic, use Job with prefixed variables.

### Resource Management

1. **Always specify namespace**
   - Don't rely on default namespace
   - `-n <namespace>` on every `oc` command

2. **Use `oc wait` instead of sleep loops**
   ```bash
   # ❌ Bad
   sleep 60

   # ✅ Good
   oc wait deployment <name> -n <namespace> --for=condition=Available --timeout=60s
   ```

3. **Infrastructure node placement**
   - All Jobs should run on infra nodes
   - Use standard `nodeSelector` + `tolerations`

4. **Use dedicated ServiceAccounts with least-privilege RBAC**
   - ✅ **IMPLEMENTED**: All 20 Jobs use dedicated ServiceAccounts (AUDIT.md ISSUE-009 resolved)
   - Principle of least privilege (0 cluster-admin usage)
   - Pattern: 1 ServiceAccount per Job type or shared for similar operations
   - Examples:
     - `console-plugin-manager` - 5 console plugin Jobs (~99% permission reduction)
     - `cert-manager-operator` - watchdog Deployment (~95% reduction from cluster-admin)
     - `loki-s3-secret-creator` - 2 S3 secret Jobs (~95% reduction)
   - See [security.md](security.md) "Job RBAC Security" section for full details

5. **Always use explicit API groups for OLM resources**
   - **CRITICAL on clusters with RHACM installed**
   - OLM and RHACM share resource names (subscription, channel, etc.)
   - Generic commands resolve to wrong API group → Forbidden errors → infinite loops

   **Problem:**
   ```bash
   # ❌ WRONG - Ambiguous on RHACM clusters
   oc get subscription my-operator -n my-namespace
   
   # Result: Uses apps.open-cluster-management.io (RHACM)
   # Expected: operators.coreos.com (OLM)
   # Error: Forbidden (ServiceAccount has OLM RBAC, not RHACM RBAC)
   ```

   **Solution - Always specify full resource type:**
   ```bash
   # ✅ CORRECT - Explicit API group
   oc get subscription.operators.coreos.com my-operator -n my-namespace
   oc patch subscription.operators.coreos.com my-operator -n my-namespace --type=merge -p "$PATCH"
   oc delete subscription.operators.coreos.com my-operator -n my-namespace
   oc wait subscription.operators.coreos.com my-operator --for=...
   ```

   **OLM resources requiring explicit API groups:**
   - `subscription.operators.coreos.com` - **CRITICAL** (conflicts with RHACM)
   - `csv.operators.coreos.com` (ClusterServiceVersion)
   - `installplan.operators.coreos.com`
   - `operatorgroup.operators.coreos.com`
   - `catalogsource.operators.coreos.com`

   **RHACM conflicting resources:**
   - `subscription` → `apps.open-cluster-management.io/v1` (RHACM app deployments)
   - `channel` → `apps.open-cluster-management.io/v1`
   - `helmrelease` → `apps.open-cluster-management.io/v1`
   - `placementrule` → `apps.open-cluster-management.io/v1`

   **Real-world failure (fixed in 8ab206e):**
   - **Job**: `update-odf-subscriptions-node-selector`
   - **Symptom**: Running 24+ hours, stuck in infinite wait loop
   - **Root cause**: `oc get subscription` resolved to RHACM API
   - **Error**: `Forbidden: User "..." cannot get resource "subscriptions" in API group "apps.open-cluster-management.io"`
   - **Loop logic**: Command failed → `! command` = true → wait loop continues forever
   - **Fix**: Added `.operators.coreos.com` to all subscription references
   - **Result**: Job completes in 30 seconds instead of running forever

   **When this matters:**
   - ✅ Always use explicit API groups (defensive coding)
   - ✅ Especially critical on `ocp-reference` profile (includes RHACM)
   - ✅ Prevents failures when RHACM added to existing clusters
   - ✅ Makes RBAC errors clearer (correct API group, actual permission issue)

### RBAC Security Patterns

**All Jobs in this project follow production-ready RBAC patterns:**

1. **Dedicated ServiceAccounts** - Never reuse generic ServiceAccounts
2. **Namespace-scoped Roles preferred** - Only use ClusterRoles when cluster-scoped resources required
3. **Minimal permissions** - Grant only exact verbs and resources needed
4. **Validation scripts** - Test permissions with `oc auth can-i` before deployment

**Example RBAC implementation:**
```yaml
# ServiceAccount
apiVersion: v1
kind: ServiceAccount
metadata:
  name: my-job-operator
  namespace: openshift-gitops

# Namespace-scoped Role (preferred)
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: my-job-operator
  namespace: target-namespace
rules:
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["create", "update"]  # Only what's needed

# ClusterRole (only if cluster-scoped resources)
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: my-job-operator
rules:
- apiGroups: ["config.openshift.io"]
  resources: ["infrastructures"]
  verbs: ["get", "list"]  # Read-only when possible

# Job uses dedicated SA
spec:
  template:
    spec:
      serviceAccountName: my-job-operator
```

### ArgoCD Integration

1. **Use `Force=true` for idempotent Jobs**
   - Jobs that check state before acting should run every sync
   - Console plugins, secret rotation, etc.

2. **Choose delete policy carefully**
   - `BeforeHookCreation` for production (clean slate)
   - `HookSucceeded` for debugging (pod logs persist)

3. **Wave ordering is critical**
   - Lower waves must complete before higher waves start
   - Use waves to enforce dependencies

4. **Test hook deletion behavior**
   - Verify Job is deleted and recreated on next sync
   - Check pod logs after failure

---

## Anti-Patterns

### ❌ Static Manifest + ignoreDifferences

**Pattern:**
```yaml
# In manifest
spec:
  field: value

# In ApplicationSet
ignoreDifferences:
- jsonPointers:
  - /spec/field
```

**Why it fails:** Field is **NEVER APPLIED**. ArgoCD ignores the field, so it's never sent to Kubernetes.

**Solution:** Use PostSync Job with `oc patch` to apply the field.

### ❌ Hardcoding Dynamic Values

**Pattern:**
```bash
TOKEN="hardcoded-value"
```

**Why it fails:** Values change per cluster, per deployment.

**Solution:** Discover values at runtime:
```bash
TOKEN=$(oc get secret <name> -n <namespace> --template='{{.data.token}}' | base64 -d)
```

### ❌ Non-Idempotent Operations

**Pattern:**
```bash
oc patch console cluster --type=json -p='[{"op": "add", "path": "/spec/plugins/-", "value": "my-plugin"}]'
```

**Why it fails:** Running twice adds plugin twice (array duplicate).

**Solution:** Check first:
```bash
if ! oc get console cluster -o jsonpath='{.spec.plugins[*]}' | grep -qw "my-plugin"; then
  oc patch console cluster --type=json -p='[{"op": "add", "path": "/spec/plugins/-", "value": "my-plugin"}]'
fi
```

### ❌ Missing Error Handling

**Pattern:**
```bash
VALUE=$(oc get secret foo -n bar --template='{{.data.key}}' | base64 -d)
oc create secret generic baz --from-literal=key=$VALUE
```

**Why it fails:** If first command fails, `$VALUE` is empty, creates invalid secret.

**Solution:**
```bash
set -e  # Exit on any error

VALUE=$(oc get secret foo -n bar --template='{{.data.key}}' | base64 -d)

if [ -z "$VALUE" ]; then
  echo "ERROR: Value is empty"
  exit 1
fi

oc create secret generic baz --from-literal=key=$VALUE
```

### ❌ Insufficient Wait Time

**Pattern:**
```bash
sleep 10
oc patch resource ...
```

**Why it fails:** Arbitrary sleep may be too short or too long.

**Solution:**
```bash
oc wait resource <name> --for=condition=Ready --timeout=300s
oc patch resource ...
```

### ❌ Using Wrong Container Image

**Pattern:**
```yaml
image: image-registry.openshift-image-registry.svc:5000/openshift/tools:latest
```

**Why it fails:** Non-standard registry, may not exist in all clusters.

**Solution:** Use Red Hat registries:
```yaml
image: registry.redhat.io/openshift4/ose-cli:latest
```

### ❌ Embedding Complex Scripts in YAML

**Pattern:**
```yaml
apiVersion: batch/v1
kind: Job
spec:
  template:
    spec:
      containers:
      - command:
        - /bin/bash
        - -c
        - |
          #!/bin/bash
          set -e
          # 200+ lines of complex bash script
          # Multiple levels of YAML escaping
          # Hard to read, test, or maintain
          ...
```

**Why it fails:**
- Multiple levels of string interpolation (bash + YAML escaping)
- Hard to unit test (embedded in YAML)
- Difficult to debug failures (no syntax highlighting)
- Poor code reusability (cannot share between Jobs)
- Large YAML files (100+ lines for simple Jobs)

**Solution:** Extract to ConfigMap (see Best Practices #1):
```yaml
# Job (35 lines)
apiVersion: batch/v1
kind: Job
spec:
  template:
    spec:
      containers:
      - command: ["/scripts/my-script.sh"]
        volumeMounts:
        - mountPath: /scripts
          name: scripts
      volumes:
      - configMap:
          name: my-scripts
          defaultMode: 0755

# ConfigMap (separate file, 200+ lines of clean bash)
apiVersion: v1
kind: ConfigMap
metadata:
  name: my-scripts
data:
  my-script.sh: |
    #!/bin/bash
    set -e
    # Clean, readable script
```

**Benefits:**
- ✅ 70% file reduction (Job YAML stays small)
- ✅ Proper bash formatting (no escaping)
- ✅ Easier testing (extract script to test locally)
- ✅ Better maintainability (edit without YAML complexity)

**Example:** `cert-manager-configmap-scripts.yaml` (AUDIT.md ISSUE-003 resolution)

---

## Troubleshooting Jobs

### Job Failed to Start

**Symptoms:** Job resource exists but no Pod created

**Causes:**
- ServiceAccount doesn't exist
- Image pull failure
- Resource quotas exceeded

**Debug:**
```bash
oc describe job <job-name> -n openshift-gitops
oc get events -n openshift-gitops --sort-by='.lastTimestamp'
```

### Job Pod CrashLoopBackOff

**Symptoms:** Pod starts but immediately fails

**Causes:**
- Command syntax error
- Missing dependencies in image
- Script exits with error code

**Debug:**
```bash
oc logs job/<job-name> -n openshift-gitops
oc describe pod -l job-name=<job-name> -n openshift-gitops
```

### Job Timeout

**Symptoms:** Job runs but never completes

**Causes:**
- Waiting for resource that never appears
- Infinite loop
- Resource never reaches Ready condition

**Debug:**
```bash
oc logs job/<job-name> -n openshift-gitops -f  # Follow logs
```

**Add timeout to waits:**
```bash
oc wait resource <name> --for=condition=Ready --timeout=300s  # 5 minutes max
```

### Job Succeeded But Resource Not Configured

**Symptoms:** Job shows Completed but expected change didn't happen

**Causes:**
- Idempotency check prevented action
- Wrong namespace
- Wrong resource name
- Patch syntax error (failed silently)

**Debug:**
```bash
oc logs job/<job-name> -n openshift-gitops  # Check "Already configured" messages
oc get <resource> <name> -n <namespace> -o yaml  # Verify actual state
```

### Job Not Running on Sync

**Symptoms:** ArgoCD sync succeeds but Job never executed

**Causes:**
- Missing `Force=true` annotation (Job manifest unchanged)
- Wrong hook type
- Wave dependencies not met

**Debug:**
```bash
# Check if Job exists
oc get job <job-name> -n openshift-gitops

# Check ArgoCD Application events
oc describe application <app-name> -n openshift-gitops
```

**Force re-execution:**
```bash
# Delete Job, ArgoCD will recreate on next sync
oc delete job <job-name> -n openshift-gitops

# Trigger sync
oc patch application <app-name> -n openshift-gitops --type=merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"normal"}}}'
```

---

## Summary

**Jobs are essential** for GitOps automation beyond static manifests. This project uses 15 Jobs across 9 categories:

1. **Console Plugin Management** (6) - Patch shared Console CR
2. **Secret Management** (2) - Extract operator-generated credentials
3. **Shared Resource Patching** (1) - Runtime configuration requiring dynamic logic
4. **Alert Management** (1) - Alertmanager API automation
5. **Dynamic Configuration** (1) - Inject discovered values
6. **Cleanup** (2) - Remove unwanted resources
7. **Dependency Waiting** (0) - Cross-component synchronization (pattern removed)
8. **Node Selector Updates** (1) - Post-deployment operator placement
9. **Infrastructure Creation** (1) - GPU MachineSet generation

**Deprecated Jobs** (replaced by static manifests + CMP):
- 3 cert-manager Jobs → Now static Certificates with CMP placeholders
- 1 MaaS Gateway Job → Now static Gateway with CMP placeholders

**Key principles:**
- Use Jobs for dynamic operations that can't be expressed in static manifests
- Make Jobs idempotent with state checks
- Use ArgoCD hooks (PostSync most common) and waves for ordering
- Wait for dependencies with `oc wait`, not arbitrary sleeps
- Run on infrastructure nodes
- Provide clear logging
- Use `Force=true` for Jobs that should run every sync

**Next steps:**
- Review existing Jobs for anti-patterns
- Standardize error handling across all Jobs
- Consider extracting common functions to shared scripts
- Document component-specific Job behaviors in components.md
