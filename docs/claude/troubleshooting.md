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

### ApplicationSet Ownership Conflicts

**Symptom**: "Object X is already owned by another ApplicationSet controller Y"

**Solution**: Delete conflicting Application, let correct ApplicationSet recreate it

```bash
oc delete application <app-name> -n openshift-gitops
```

## Component-Specific Issues

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

### Known False-Positive Alerts

See [`known-bugs.md`](known-bugs.md) for comprehensive list of silenced alerts and root causes.

## Monitoring Issues

See [`monitoring.md`](monitoring.md) for Alertmanager configuration and alert silence troubleshooting.
