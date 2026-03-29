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
- Gateway API CRDs are installed by the cluster (not by OLM)
- OLM does not generate aggregate RBAC roles for non-OLM CRDs
- ArgoCD application controller lacks permissions to manage Gateway resources

**Affected Components**:
- RHOAI: MaaS Gateway (`maas-default-gateway`)
- RHCL: Kuadrant Gateways
- Any component deploying Gateway API resources

**Debug**:
```bash
# Check if CRDs exist
oc get crd gateways.gateway.networking.k8s.io

# Check ArgoCD permissions
oc auth can-i create gateways.gateway.networking.k8s.io \
  --as=system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller \
  -n openshift-ingress

# Check if ClusterRole exists
oc get clusterrole gateway-api-manager
```

**Fix**:
Verify Gateway API RBAC ClusterRole and ClusterRoleBinding exist in `openshift-gitops-admin-config` component:

```yaml
# ClusterRole: openshift-gitops-clusterrole-gateway-api.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: gateway-api-manager
rules:
- apiGroups:
  - gateway.networking.k8s.io
  resources:
  - gateways
  - gatewayclasses
  - httproutes
  - grpcroutes
  - referencegrants
  verbs:
  - '*'

# ClusterRoleBinding: openshift-gitops-clusterrolebinding-gateway-api.yaml
# Binds to: openshift-gitops-argocd-application-controller ServiceAccount
```

**Prevention**:
When adding components that deploy Gateway API resources, ensure `openshift-gitops-admin-config` includes Gateway API RBAC grants.

**See Also**: docs/claude/components.md → OpenShift GitOps → RBAC Configuration → Gateway API Resources

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

### Known False-Positive Alerts

See [`known-bugs.md`](known-bugs.md) for comprehensive list of silenced alerts and root causes.

## Monitoring Issues

See [`monitoring.md`](monitoring.md) for Alertmanager configuration and alert silence troubleshooting.
