# Security Considerations

**Purpose**: Security patterns and best practices for demo/lab cluster deployments.

## AWS Secrets Manager Integration

**✅ IMPLEMENTED**: AWS credentials are stored in **AWS Secrets Manager** instead of being passed as plaintext to the bastion.

**How It Works:**

1. **Config Files**: You still edit AWS credentials in `config/*.config` files (simple workflow)
2. **Secret Storage**: `init_openshift_installation_lab_cluster.sh` stores credentials in AWS Secrets Manager
3. **IAM Role**: Bastion EC2 instance gets an IAM instance profile with permission to read the secret
4. **Bastion Retrieval**: `bastion_script.sh` retrieves credentials from Secrets Manager (not from uploaded config)
5. **Automatic Cleanup**: `clean_aws_tenant.sh` deletes ALL secrets when cleaning the environment

**Security Benefits:**

✅ **No plaintext upload**: AWS credentials are NOT uploaded to bastion in config files
✅ **No process environment exposure**: Credentials not visible in `/proc/$PID/environ` from config
✅ **Encrypted at rest**: Secrets Manager encrypts data with AWS KMS
✅ **Encrypted in transit**: Retrieved via TLS (AWS API calls)
✅ **Audit trail**: CloudTrail logs all secret access
✅ **IAM-based access**: Only bastion instance profile can read the secret
✅ **Automatic deletion**: Secrets purged during environment cleanup (idempotent)

**What's Still in Plaintext:**

⚠️ **Cluster passwords** (`OCP_ADMIN_PASSWORD`, `OCP_NON_ADMIN_PASSWORD`) remain in `config/common.config`:
- These are NOT AWS credentials (no AWS resource access)
- Only used to configure OCP cluster authentication
- Acceptable risk for demo/lab environments (30h lifespan, dedicated clusters)

⚠️ **Local config files** still contain AWS credentials for initial setup:
- Required for local AWS CLI access (Secrets Manager API calls, bastion provisioning)
- Protected by local workstation security (file permissions, disk encryption)
- Should be deleted after cluster destruction

**Resources Created:**

For each cluster deployment, the following resources are created and cleaned up:

1. **Secrets Manager Secret**: `ocp-installer/${CLUSTER_NAME}/aws-credentials`
   - Contains: `aws_access_key_id`, `aws_secret_access_key` (JSON)
   - Region: Same as `AWS_DEFAULT_REGION`
   - Deletion: Force delete without recovery period during cleanup

2. **IAM Role**: `ocp-bastion-secrets-reader-${CLUSTER_NAME}`
   - Trust policy: Allows EC2 service to assume role
   - Inline policy: Read-only access to the specific secret
   - Deletion: Inline policies removed, then role deleted during cleanup

3. **IAM Instance Profile**: `ocp-bastion-profile-${CLUSTER_NAME}`
   - Attached to bastion EC2 instance
   - Links to IAM role above
   - Deletion: Role detached, then profile deleted during cleanup

**Idempotent Behavior:**

- **Re-running installation**: Secrets/IAM resources are deleted first, then recreated
- **Failed installations**: Next run cleans up orphaned secrets/roles before starting fresh
- **Multiple clusters**: Each cluster gets its own secret/role (isolated by CLUSTER_NAME)

**Best Practices (Even with Secrets Manager):**

1. **Use temporary credentials**: Generate short-lived IAM credentials from RHDP (auto-expire with environment)
2. **Delete local config files**: Remove `config/*.config` after cluster destruction
3. **Verify cleanup**: Ensure `clean_aws_tenant.sh` completes successfully
4. **Clean output directory**: Delete `output/` directory after teardown

**For Production Adaptation:**

If using this tool as a base for production systems:
- ✅ Secrets Manager integration is already implemented (production-ready for AWS credentials)
- ⚠️ Consider adding OCP passwords to Secrets Manager as well
- ✅ Implement credential rotation policies in Secrets Manager
- ✅ Enable AWS CloudTrail for audit logging
- ✅ Use dedicated IAM users with minimal permissions (not RHDP admin credentials)

## Job Resource Management (BestEffort QoS)

**Pattern**: All GitOps configuration Jobs run without resource limits (BestEffort QoS class).

**Why No Resource Limits:**

This is an **intentional design decision** for Day 2 configuration Jobs:

1. **Short-lived execution**: Jobs complete within minutes during cluster initialization
2. **Non-critical timing**: Day 2 setup is not latency-sensitive
3. **Resource availability**: Demo/lab clusters have adequate capacity during bootstrap
4. **Maximum performance**: Jobs can consume available resources for faster completion
5. **Simplicity**: Avoids complexity of testing and tuning limits for 17+ different Jobs

**Job Lifecycle:**

- ✅ Execute during initial ArgoCD sync (Day 2 configuration phase)
- ✅ Complete and terminate (pods cleaned up automatically)
- ✅ Do not run continuously (unlike Deployments/DaemonSets)
- ✅ Idempotent design allows re-execution if needed

**BestEffort Behavior:**

Without resource requests/limits, Jobs get:
- **QoS Class**: BestEffort (lowest priority for eviction)
- **CPU**: Can use all available CPU if cluster is idle
- **Memory**: Can use all available memory if cluster is idle
- **Eviction**: First to be evicted if cluster resources are exhausted (acceptable for setup jobs)

**When This Pattern is Acceptable:**

- ✅ Demo/lab environments with adequate cluster resources
- ✅ Short-lived bootstrap/setup operations
- ✅ Jobs that complete during initial cluster provisioning
- ✅ Non-production workloads where QoS guarantees are not required

**When to Add Resource Limits:**

- ❌ Production environments with strict resource governance
- ❌ Long-running or recurring Jobs
- ❌ Multi-tenant clusters with resource contention
- ❌ Jobs that must complete within SLA time windows

**Decision**: Keep Jobs at BestEffort QoS for demo/lab use case. Jobs need maximum available resources during Day 2 initialization for fastest completion.

## AWS Tenant Isolation

**CRITICAL**: This tool assumes a **dedicated AWS tenant** for OCP clusters only.

**Why This Matters:**

The cleanup script (`clean_aws_tenant.sh`) intentionally deletes **ALL S3 buckets** in the tenant without filtering, as the tenant should contain no production resources beyond the demo cluster.

**⚠️ DO NOT USE IN SHARED AWS ACCOUNTS**

The tool is designed for Red Hat Demo Platform Blank Open Environment, which provides isolated AWS accounts with 30-hour lifespans.

## Alertmanager Security

**CRITICAL**: The Alertmanager configuration is stored in Git and must NOT contain sensitive data.

See [`monitoring.md`](monitoring.md) for details on security requirements for Alertmanager configuration.

**Audit script**: `scripts/audit_alertmanager_secrets.sh` - Use before committing changes to verify no credentials leaked.
