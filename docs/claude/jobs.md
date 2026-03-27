# Job Architecture Documentation

**Purpose**: Comprehensive guide to Kubernetes Job patterns used for GitOps automation in this project.

## Overview

This project uses **Kubernetes Jobs** extensively to automate Day 2 operations that cannot be accomplished with static manifests alone. Jobs handle dynamic configuration, secret management, resource patching, and cleanup tasks.

**Total Jobs**: 20 across 12 components

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
| `PostDelete` | After app deletion | Resource cleanup |

**Most common**: `PostSync` (used by 90% of Jobs in this project)

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
- Waves in this project: `-1`, `0`, `3`, `10`

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

---

## Job Categories

### 1. Console Plugin Management (5 Jobs)

**Pattern**: Pure Patch Jobs for shared Console CR

**Why Jobs?**
- Console is a **cluster-scoped shared resource** modified by 4 components
- Static manifests would overwrite each other (last one wins)
- Jobs use `oc patch` with JSON Patch to ADD plugins incrementally
- Each Job is idempotent (checks if plugin exists before adding)

**Jobs:**
- `openshift-gitops-job-enable-gitops-console-plugin.yaml` → `gitops-plugin`
- `openshift-gitops-job-enable-pipelines-console-plugin.yaml` → `pipelines-console-plugin`
- `openshift-gitops-job-disable-pipelines-console-plugin.yaml` → Removes plugin
- `openshift-gitops-job-enable-odf-console-plugins.yaml` → `odf-console`, `odf-client-console`
- `openshift-gitops-job-enable-kuadrant-console-plugin.yaml` → `kuadrant-console-plugin`

**Template:**
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  annotations:
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
      serviceAccountName: openshift-gitops-argocd-application-controller
      tolerations:
      - key: node-role.kubernetes.io/infra
        operator: Exists
```

**Key patterns:**
- `Force=true` → Runs every sync
- Idempotency check with `grep -qw`
- JSON Patch with `op: add` to append to array
- Uses `ose-cli` image for `oc` command

### 2. Secret Management (3 Jobs)

**Pattern**: Dynamic value discovery from operator-generated secrets

**Why Jobs?**
- Operators auto-generate secrets (e.g., S3 credentials from ObjectBucketClaim)
- Secret names/values unknown at manifest creation time
- Jobs extract values and create application-specific secrets

**Jobs:**
- `openshift-gitops-job-create-secret-logging-loki-s3.yaml` → Extracts S3 creds for Loki logging
- `openshift-gitops-job-create-secret-netobserv-loki-s3.yaml` → Extracts S3 creds for NetObserv
- `openshift-gitops-job-configure-grafana-datasource-token.yaml` → Creates token for Grafana datasource

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

### 3. Shared Resource Patching (4 Jobs)

**Pattern**: Modify cluster-scoped resources that cannot be fully managed by GitOps

**Why Jobs?**
- Resources exist at cluster scope (created by installer/operators)
- GitOps manages subset of fields, operators manage others
- Static manifests with `ignoreDifferences` **DO NOT WORK** (field never applied)
- Jobs runtime-patch specific fields

**Jobs:**
- `openshift-gitops-job-update-openshift-ingress-operator-ingresscontroller-default.yaml` → Set default certificate
- `openshift-gitops-job-update-cluster-apiserver-cluster.yaml` → Configure API server
- `openshift-gitops-job-create-cluster-cert-manager-resources.yaml` → Create Certificate CRs
- `openshift-gitops-job-configure-grafana-datasource-token.yaml` → Patch GrafanaDatasource CR

**Template (IngressController patching):**
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  annotations:
    argocd.argoproj.io/hook: PostSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
    argocd.argoproj.io/sync-wave: "3"
  name: update-ingresscontroller-default-certificate
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
          echo "Waiting for Certificate default-ingress-certificate to be ready..."
          oc wait certificate default-ingress-certificate -n openshift-ingress --for=condition=Ready --timeout=300s

          echo "Patching IngressController to use custom certificate..."
          oc patch ingresscontroller default -n openshift-ingress-operator --type=merge \
            -p '{"spec":{"defaultCertificate":{"name":"default-ingress-certificate"}}}'

          echo "IngressController patched successfully."
        image: registry.redhat.io/openshift4/ose-cli:latest
        name: patch-ingresscontroller
      restartPolicy: Never
      serviceAccountName: openshift-gitops-argocd-application-controller
```

**Key patterns:**
- `oc wait` for dependency readiness (Certificate CR)
- `oc patch --type=merge` for strategic merge patch
- Wave `3` to run after cert-manager resources created
- PostSync hook (runs after manifests synced)

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

### 5. Dynamic Configuration Injection (2 Jobs)

**Pattern**: Generate runtime configuration based on cluster state

**Why Jobs?**
- Configuration values discovered from cluster resources
- Inject into operator/application configs

**Jobs:**
- `openshift-gitops-job-ack-config-injector.yaml` → Inject AWS credentials into ACK controller
- `openshift-gitops-job-create-maas-gateway.yaml` → Create MaaS Gateway with discovered endpoints

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
- `openshift-gitops-job-delete-openshift-builds-resources.yaml` → Remove OpenShift Builds (superseded by Pipelines)

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

### 7. Dependency Waiting (1 Job)

**Pattern**: Wait for cross-component dependencies before proceeding

**Why Jobs?**
- Component A depends on Component B being fully operational
- ArgoCD sync doesn't guarantee cross-component ordering

**Job:**
- `openshift-gitops-job-check-and-wait-openshift-pipelines.yaml` → Wait for Pipelines operator before deploying Builds

**Template:**
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
    argocd.argoproj.io/sync-wave: "-1"
  name: check-and-wait-openshift-pipelines
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
          echo "Waiting for OpenShift Pipelines operator to be ready..."

          # Wait for TektonConfig CRD to exist
          until oc get crd tektonconfigs.operator.tekton.dev 2>/dev/null; do
            echo "Waiting for TektonConfig CRD..."
            sleep 10
          done

          # Wait for TektonConfig to be ready
          oc wait tektonconfig config --for=condition=Ready --timeout=600s

          echo "OpenShift Pipelines is ready."
        image: registry.redhat.io/openshift4/ose-cli:latest
        name: wait-pipelines
      restartPolicy: Never
      serviceAccountName: openshift-gitops-argocd-application-controller
```

**Key patterns:**
- `PreSync` hook (runs before manifests)
- Wave `-1` (runs first)
- `until oc get crd` for CRD availability
- `oc wait --for=condition=Ready` for resource readiness

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

---

## Best Practices

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
     - `console-plugin-manager` - 6 console plugin Jobs (~99% permission reduction)
     - `cert-manager-operator` - 3 cert-manager Jobs (~95% reduction)
     - `loki-s3-secret-creator` - 2 S3 secret Jobs (~95% reduction)
   - See [security.md](security.md) "Job RBAC Security" section for full details

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

**Jobs are essential** for GitOps automation beyond static manifests. This project uses 21 Jobs across 6 categories:

1. **Console Plugin Management** (5) - Patch shared Console CR
2. **Secret Management** (3) - Extract operator-generated credentials
3. **Shared Resource Patching** (4) - Runtime configuration of cluster resources
4. **Alert Management** (1) - Alertmanager API automation
5. **Dynamic Configuration** (2) - Inject discovered values
6. **Cleanup** (2) - Remove unwanted resources
7. **Dependency Waiting** (1) - Cross-component synchronization
8. **Node Selector Updates** (1) - Post-deployment operator placement
9. **Infrastructure Creation** (1) - GPU MachineSet generation

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
