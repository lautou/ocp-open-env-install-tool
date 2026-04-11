# KFP v2 Secret Injection Patterns

**Last Updated:** 2026-04-11  
**KFP Version:** 2.14.6  
**RHOAI Version:** 2.18  
**Platform:** OpenShift Data Science Pipelines (DSPA)

## Overview

This document describes the correct patterns for injecting Kubernetes secrets into Kubeflow Pipelines (KFP) v2 components. Understanding these patterns is critical because **KFP has specific requirements** about where and how secrets can be configured.

## Critical Discovery: Platform Specs Go at TASK Level

**WRONG** ❌ - Adding `kubernetes` to executor definition in `deploymentSpec.executors`:
```yaml
deploymentSpec:
  executors:
    exec-my-task:
      container:
        image: my-image
      kubernetes:  # ❌ IGNORED BY KFP
        secretAsVolume:
        - secretName: my-secret
          mountPath: /mnt/secrets
```

**CORRECT** ✅ - Adding `platforms` to task definition in `root.dag.tasks`:
```yaml
root:
  dag:
    tasks:
      my-task:
        componentRef:
          name: comp-my-task
        platforms:  # ✅ CORRECT LOCATION
          kubernetes:
            deploymentSpec:
              executors:
                exec-my-task:
                  secretAsVolume:
                  - secretName: my-secret
                    mountPath: /mnt/secrets
```

## Why This Matters

**Platform-specific configurations** (Kubernetes secrets, volumes, node selectors, etc.) are **task-level concerns** in KFP v2, not executor-level concerns. The executor defines the container spec, but platform features are applied per task invocation.

## Secret Injection Methods

### Method 1: Automatic Injection (For Artifact I/O)

**When it works:** Tasks with artifact **inputs** that need S3/storage access.

**How it works:** KFP automatically injects credentials when downloading artifact inputs. The `kfp-launcher` sidecar reads from the secret specified in the DSPA configuration and makes credentials available to the executor.

**Evidence in logs:**
```json
"store_session_info": {
  "Provider":"s3",
  "Params":{
    "accessKeyKey":"AWS_ACCESS_KEY_ID",
    "secretKeyKey":"AWS_SECRET_ACCESS_KEY",
    "secretName":"pipeline-artifacts"
  }
}
```

**When it DOESN'T work:**
- ❌ Tasks with only **outputs** (no input artifacts)
- ❌ Custom S3 operations in Python code beyond KFP artifact I/O
- ❌ Manual boto3 usage to download non-artifact files

**Example:** `docling-chunk` has artifact input → credentials auto-injected ✓

**Counter-example:** `collect-chunks` has only outputs → NO auto-injection ✗

### Method 2: Explicit Secret Volume Mount (platformSpec)

**When to use:** Tasks that need credentials for custom operations (not KFP artifact I/O).

**Python SDK Pattern:**
```python
from kfp import dsl
from kfp.kubernetes import use_secret_as_volume

@dsl.pipeline
def my_pipeline():
    task = my_component()
    use_secret_as_volume(
        task=task,
        secret_name='my-secret',
        mount_path='/mnt/secrets'
    )
```

**Compiled YAML Pattern:**
```yaml
root:
  dag:
    tasks:
      my-task:
        componentRef:
          name: comp-my-task
        platforms:
          kubernetes:
            deploymentSpec:
              executors:
                exec-my-task:
                  secretAsVolume:
                  - secretName: my-secret
                    mountPath: /mnt/secrets
                    optional: false  # Set true if secret may not exist
```

**Python Component Code:**
```python
def my_component(output: dsl.Output[dsl.Artifact]) -> int:
    import os
    from pathlib import Path
    
    # Read credentials from mounted secret
    secret_path = '/mnt/secrets'
    with open(f'{secret_path}/AWS_ACCESS_KEY_ID') as f:
        access_key = f.read().strip()
    with open(f'{secret_path}/AWS_SECRET_ACCESS_KEY') as f:
        secret_key = f.read().strip()
    
    # Use credentials
    import boto3
    s3_client = boto3.client(
        's3',
        endpoint_url=os.environ['AWS_S3_ENDPOINT'],
        aws_access_key_id=access_key,
        aws_secret_access_key=secret_key
    )
    # ...
```

### Method 3: Secret Environment Variables (platformSpec)

**When to use:** Tasks that expect credentials in environment variables.

**Python SDK Pattern:**
```python
from kfp.kubernetes import use_secret_as_env

@dsl.pipeline
def my_pipeline():
    task = my_component()
    use_secret_as_env(
        task=task,
        secret_name='my-secret',
        secret_key_to_env={
            'AWS_ACCESS_KEY_ID': 'AWS_ACCESS_KEY_ID',
            'AWS_SECRET_ACCESS_KEY': 'AWS_SECRET_ACCESS_KEY'
        }
    )
```

**Compiled YAML Pattern:**
```yaml
root:
  dag:
    tasks:
      my-task:
        platforms:
          kubernetes:
            deploymentSpec:
              executors:
                exec-my-task:
                  secretAsEnv:
                  - secretName: my-secret
                    data:
                    - secretKey: AWS_ACCESS_KEY_ID
                      envVar: AWS_ACCESS_KEY_ID
                    - secretKey: AWS_SECRET_ACCESS_KEY
                      envVar: AWS_SECRET_ACCESS_KEY
```

## What DOESN'T Work

### ❌ valueFrom.secretKeyRef in Executor Env Vars

**Attempted Pattern (FAILS):**
```yaml
deploymentSpec:
  executors:
    exec-my-task:
      container:
        env:
        - name: AWS_ACCESS_KEY_ID
          valueFrom:  # ❌ NOT SUPPORTED IN KFP
            secretKeyRef:
              name: my-secret
              key: AWS_ACCESS_KEY_ID
```

**Result:** Environment variable shows as `null` in pod at runtime.

**Why it fails:** This is Kubernetes pod spec syntax, but KFP uses its own platform-specific config system. The executor container spec is templated and doesn't support `valueFrom` directly.

### ❌ kubernetes Config in Executor Definition

**Attempted Pattern (FAILS):**
```yaml
deploymentSpec:
  executors:
    exec-my-task:
      container:
        image: my-image
      kubernetes:  # ❌ WRONG LOCATION
        secretAsVolume: [...]
```

**Result:** Configuration ignored, secret not mounted.

**Why it fails:** Platform configs must be at TASK level in `platforms` field, not at executor level.

## Real-World Example: collect-chunks Component

### Problem

The `collect-chunks` component needs to:
1. Download chunk files from S3 (artifacts created by parallel for-loop iterations)
2. Merge them into a single JSONL file
3. Output the merged file as a KFP artifact

**Challenge:** collect-chunks has only **outputs**, no inputs → KFP doesn't auto-inject S3 credentials.

### Solution

**1. Add platformSpec to task definition** (lines 747-762):
```yaml
root:
  dag:
    tasks:
      collect-chunks:
        componentRef:
          name: comp-collect-chunks
        dependentTasks:
        - for-loop-1
        platforms:
          kubernetes:
            deploymentSpec:
              executors:
                exec-collect-chunks:
                  secretAsVolume:
                  - secretName: pipeline-artifacts
                    mountPath: /mnt/secrets
```

**2. Component reads from mounted files** (Python code):
```python
def collect_chunks(output_path: dsl.Output[dsl.Artifact]) -> int:
    import os
    import boto3
    
    # Read AWS credentials from mounted secret
    secret_path = '/mnt/secrets'
    with open(f'{secret_path}/AWS_ACCESS_KEY_ID') as f:
        aws_access_key = f.read().strip()
    with open(f'{secret_path}/AWS_SECRET_ACCESS_KEY') as f:
        aws_secret_key = f.read().strip()
    
    # S3 config from environment variables (static values work fine)
    s3_endpoint = os.environ.get('AWS_S3_ENDPOINT')
    s3_bucket = os.environ.get('AWS_S3_BUCKET')
    
    # Connect to S3
    s3_client = boto3.client(
        's3',
        endpoint_url=s3_endpoint,
        aws_access_key_id=aws_access_key,
        aws_secret_access_key=aws_secret_key,
        verify=False
    )
    
    # Download and merge chunk files...
```

**3. Static env vars in executor** (for non-sensitive config):
```yaml
deploymentSpec:
  executors:
    exec-collect-chunks:
      container:
        env:
        - name: AWS_S3_ENDPOINT
          value: https://s3.openshift-storage.svc:443
        - name: AWS_S3_BUCKET
          value: ai-generation-llm-rag-pipelines
```

## DSPA Configuration

The DSPA (Data Science Pipelines Application) specifies which secret contains S3 credentials:

```yaml
apiVersion: datasciencepipelinesapplications.opendatahub.io/v1alpha1
kind: DataSciencePipelinesApplication
spec:
  objectStorage:
    externalStorage:
      s3CredentialsSecret:
        secretName: pipeline-artifacts
        accessKey: AWS_ACCESS_KEY_ID
        secretKey: AWS_SECRET_ACCESS_KEY
```

**This configures:**
- Secret name for automatic injection (artifact I/O)
- Secret keys for access key and secret key
- Endpoint, bucket, region for S3 connection

## Debugging Secret Issues

### 1. Check if secret exists
```bash
oc get secret pipeline-artifacts -n ai-generation-llm-rag
```

### 2. Verify secret has required keys
```bash
oc get secret pipeline-artifacts -n ai-generation-llm-rag -o yaml | grep -E "AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY"
```

### 3. Check pod spec for volume mount
```bash
POD=$(oc get pods -n ai-generation-llm-rag -l pipelines.kubeflow.org/pipelinename=rag-data-ingestion --sort-by=.metadata.creationTimestamp | tail -1 | awk '{print $1}')
oc get pod $POD -n ai-generation-llm-rag -o json | jq '.spec.volumes[] | select(.secret)'
```

### 4. Verify environment variables in pod
```bash
oc get pod $POD -n ai-generation-llm-rag -o json | jq '.spec.containers[].env[] | select(.name | contains("AWS"))'
```

### 5. Check executor logs for credential errors
```bash
oc logs $POD -c main -n ai-generation-llm-rag | grep -i "credential\|aws\|secret"
```

## References

- **KFP v2 Documentation:** https://www.kubeflow.org/docs/components/pipelines/v2/
- **kfp-kubernetes SDK:** https://github.com/kubeflow/pipelines/tree/master/kubernetes_platform/python/kfp/kubernetes
- **Kubernetes Executor Config Proto:** https://github.com/kubeflow/pipelines/blob/master/kubernetes_platform/proto/kubernetes_executor_config.proto
- **RHOAI Pipelines Docs:** https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/

## Troubleshooting History

### Issue: "AWS credentials not found in environment"

**Attempted Solutions:**
1. ❌ Added `valueFrom.secretKeyRef` to executor env vars → showed as `null` in pod
2. ❌ Added `kubernetes.secretAsVolume` to executor definition → config ignored
3. ✅ Added `platforms.kubernetes.deploymentSpec.executors.secretAsVolume` to task definition → **WORKS**

**Root Cause:** Platform-specific configurations must be at task level, not executor level.

**Commits:**
- `ea7a9f9` - Failed attempt with valueFrom.secretKeyRef
- `3cba396` - Failed attempt with kubernetes in executor
- `[PENDING]` - Correct solution with platformSpec at task level

## Best Practices

1. **Use automatic injection when possible** - If your task has artifact inputs, KFP handles credentials automatically
2. **Add platformSpec only when needed** - Don't add secret mounts to tasks that don't need them
3. **Read from files, not env vars** - `secretAsVolume` is more reliable than `secretAsEnv`
4. **Set optional: false** - Fail fast if secret doesn't exist
5. **Document why secrets are needed** - Add comments explaining custom S3 operations
6. **Test with missing secrets** - Verify error messages are clear
7. **Static values in env vars are fine** - Use env vars for non-sensitive config (endpoints, buckets)

## Common Patterns

### Pattern: Parallel Task Output Aggregation

**Problem:** For-loop creates N parallel outputs, need to merge into single artifact.

**Solution:** Aggregator task with secret mount to download all iteration artifacts.

**See:** `collect-chunks` component in `rag-data-ingestion` pipeline.

### Pattern: External S3 Download

**Problem:** Import data from external S3 bucket not managed by KFP.

**Solution:** Task with `from_s3` parameter and secret mount for external credentials.

**See:** `import-pdfs` component with `from_s3: true` mode (not used in current pipeline).

### Pattern: Cross-Pipeline Artifact Sharing

**Problem:** Access artifacts created by different pipeline runs.

**Solution:** Secret mount + boto3 to download by S3 URI, bypassing KFP artifact system.

## Migration Guide

### From Executor-Level to Task-Level Secrets

**Before (doesn't work):**
```yaml
deploymentSpec:
  executors:
    exec-my-task:
      kubernetes:
        secretAsVolume: [...]
```

**After (works):**
```yaml
root:
  dag:
    tasks:
      my-task:
        platforms:
          kubernetes:
            deploymentSpec:
              executors:
                exec-my-task:
                  secretAsVolume: [...]
```

**Steps:**
1. Remove `kubernetes` section from executor in `deploymentSpec`
2. Add `platforms` section to task in `root.dag.tasks`
3. Nest same `secretAsVolume` config under `platforms.kubernetes.deploymentSpec.executors.{executor-name}`
4. Test that secret is mounted in pod
5. Verify component can read secret files

## Future Improvements

- [ ] Create reusable KFP Python components with secret mounting patterns
- [ ] Add validation script to check platformSpec configurations
- [ ] Document secretAsEnv pattern with examples
- [ ] Create troubleshooting playbook for common secret issues
- [ ] Add integration tests for secret mounting
