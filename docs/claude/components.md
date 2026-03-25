# Component-Specific Configuration

**Purpose**: Detailed configuration patterns and special behaviors for GitOps components.

**Note**: Only components with non-standard patterns or special requirements are documented here. Simple operator deployments without special configuration are intentionally omitted (discoverable via filesystem).

## Console Plugins

**Pattern**: Pure Patch Jobs (no static manifests)

**Why Jobs only:**
- Console is a **shared resource** modified by 4 components
- Static manifests would overwrite each other
- Jobs use `oc patch` with JSON Patch to ADD plugins incrementally
- Each Job is idempotent and checks if plugin already exists

**Components with console plugins:**
- `openshift-gitops-admin-config` → `gitops-plugin`
- `openshift-pipelines` → `pipelines-console-plugin`
- `openshift-storage` → `odf-console`, `odf-client-console`
- `rh-connectivity-link` → `kuadrant-console-plugin`

**Implementation:**
Each component includes:
1. Patch Job `openshift-gitops-job-enable-*-console-plugin.yaml` that adds plugin if not present
2. Job runs with `Force=true` to ensure execution on every sync
3. Idempotent check prevents duplicate additions

## OpenShift GitOps (ArgoCD)

**Purpose**: Manages Day 2 cluster configuration through GitOps principles.

**Namespace**: `openshift-gitops`

**Configuration**: `components/openshift-gitops-admin-config/base/openshift-gitops-argocd-openshift-gitops.yaml`

**Key Configurations:**

1. **Controller Memory Limits** (Critical):
   ```yaml
   controller:
     resources:
       limits:
         cpu: '2'
         memory: 4Gi  # Increased from default 3Gi
       requests:
         cpu: 250m
         memory: 2Gi  # Increased from default 1Gi
   ```

   **Why 4Gi memory?**
   - Default 3Gi causes OOMKilled crashes (exit code 137) in production clusters
   - Controller manages 25-30+ applications with complex CRDs
   - Memory usage spikes during reconciliation of large ApplicationSets
   - 4Gi provides stable operation with headroom for growth

2. **ApplicationSet Retry Configuration**:
   All ApplicationSets configured with:
   ```yaml
   syncPolicy:
     automated:
       prune: true
       selfHeal: true
     retry:
       limit: 10  # Increased from default 5-7
   ```

   **Why retry limit 10?**
   - Addresses CRD timing issues during cluster bootstrap
   - Operators may not have created CRDs when ArgoCD first syncs
   - Exponential backoff means later retries have sufficient delay
   - By retry 10, enough time has passed for operator bootstrapping
   - Prevents manual intervention for transient CRD availability issues

3. **RBAC Configuration**:
   ```yaml
   rbac:
     defaultPolicy: ''
     policy: |
       g, system:cluster-admins, role:admin
       g, cluster-admins, role:admin
     scopes: '[groups]'
   ```

4. **Resource Exclusions**:
   ```yaml
   resourceExclusions: |
     - apiGroups:
       - tekton.dev
       clusters:
       - '*'
       kinds:
       - TaskRun
       - PipelineRun
   ```
   Prevents ArgoCD from managing ephemeral Tekton resources.

**Troubleshooting:**

Common issues and solutions:

1. **Controller OOMKilled**:
   - Symptom: Pod restarts with exit code 137
   - Solution: Memory limit increased to 4Gi (already applied)
   - Verification: `oc get pod -n openshift-gitops -l app.kubernetes.io/name=argocd-application-controller`

2. **Applications stuck OutOfSync with CRD errors**:
   - Symptom: "resource mapping not found: no matches for kind X"
   - Solution: Retry limit set to 10 (already applied in all ApplicationSets)
   - Wait for automatic retry or manually sync application

3. **ApplicationSet ownership conflicts**:
   - Symptom: "Object X is already owned by another ApplicationSet controller Y"
   - Solution: Delete conflicting Application, let correct ApplicationSet recreate it
   - Example: When moving applications between ApplicationSets (core → devops)

**Version Management:**

ArgoCD version follows OpenShift GitOps operator channel (managed by OLM).

## cert-manager IngressController

**Pattern**: Pure Patch Job (no static manifests)

**Purpose**: Configure the default OpenShift IngressController to use Let's Encrypt certificates managed by cert-manager.

**Why Job only (no static manifest):**
The Static Manifest + ignoreDifferences pattern was **attempted and FAILED** for IngressController. Here's why:

**Problem with Static + ignoreDifferences:**
```yaml
# Static manifest declares:
spec:
  defaultCertificate:
    name: ingress-certificates

# ignoreDifferences says:
ignoreDifferences:
- kind: IngressController
  jsonPointers:
  - /spec/defaultCertificate  # "Ignore this field"
```

**Result:** ArgoCD **never applies** the field it's told to ignore → Certificate not configured → SSL errors ❌

This is a **logical contradiction**: "Here's the config, but ignore it" = Config never applied.

**Working Implementation (Pure Job):**

Job: `openshift-gitops-job-update-openshift-ingress-operator-ingresscontroller-default.yaml`

1. Waits for cert-manager to create Certificate `ingress` in `openshift-ingress`
2. Waits for Certificate to reach Ready condition (Let's Encrypt issued)
3. Patches IngressController with `defaultCertificate: {name: ingress-certificates}`
4. Triggers rolling update of router pods with new certificate

**Zero-downtime behavior:**
- ✅ IngressController starts with auto-generated wildcard certificate (OpenShift default)
- ✅ Ingress/Routes work immediately with self-signed certificate
- ✅ Job waits for Let's Encrypt certificate to be Ready (2-5 minutes)
- ✅ Patch triggers rolling update of router pods (~30 seconds)
- ✅ High availability maintained during certificate rotation (3 replicas)

**Lesson learned:**
- ❌ Static + ignoreDifferences = Field never applied
- ✅ Pure Job = Reliable, predictable, works correctly

## cert-manager Certificate Provisioning

**Pattern**: Dynamic Job with pod readiness checks

**Purpose**: Create ClusterIssuer and Certificate resources after cert-manager operator is fully initialized.

**Critical Race Condition Fixed:**

The Job (`create-cluster-cert-manager-resources`) previously waited only for CertManager CR deployment conditions, which caused a race condition during cluster bootstrap:

**Problem:**
```bash
# Old approach (BROKEN):
oc wait certmanager cluster \
    --for condition=cert-manager-controller-deploymentAvailable \
    --timeout=120s

# Problem: Deployment conditions check that Deployment resource exists,
# NOT that pods are running or controller is initialized
```

**Timeline of race condition:**
1. CertManager CR shows "deploymentAvailable" (Deployment created)
2. Job creates certificates immediately
3. cert-manager pods haven't started yet (may be 60+ seconds later)
4. cert-manager controller tries to process certificates before ACME client initialized
5. Let's Encrypt order created, but authorization fetch fails with 404
6. cert-manager gives up without retry → 1-hour exponential backoff

**Root Cause:**
- CertManager CR conditions reflect **Deployment readiness** (desired replicas exist)
- **Not pod readiness** (containers running and passing readiness probes)
- **Not controller initialization** (ACME client ready to process certificates)

**Fix Applied:**
```bash
# New approach (FIXED):
oc wait certmanager cluster \
    --for condition=cert-manager-controller-deploymentAvailable \
    --timeout=120s

# ADDED: Wait for pods to be Ready (containers running + readiness probes passing)
oc wait pod -n cert-manager \
    -l app.kubernetes.io/component=controller \
    --for=condition=Ready \
    --timeout=120s

oc wait pod -n cert-manager \
    -l app.kubernetes.io/component=webhook \
    --for=condition=Ready \
    --timeout=120s
```

**Why this works:**
- Pod `Ready` condition ensures containers are running
- cert-manager readiness probe confirms controller is responsive
- ACME client has time to initialize before certificates are created
- Webhook pod must be ready before validating Certificate resources

**Time added:** ~30-60 seconds (pod startup time)

**Lesson learned:**
- CertManager CR conditions ≠ cert-manager controller ready
- Always wait for pod `Ready` condition when controller initialization matters
- Deployment conditions only guarantee Deployment resource exists, not pod state

**Dynamic TIMESTAMP in Certificate DNS Names:**

The Job intentionally includes a dynamic TIMESTAMP in Certificate dnsNames to ensure unique DNS records for Let's Encrypt DNS-01 challenges:

```yaml
dnsNames:
- "apps.${CLUSTER_DOMAIN}"              # Static - main domain
- "*.apps.${CLUSTER_DOMAIN}"            # Static - wildcard
- "apps.${TIMESTAMP}.${CLUSTER_DOMAIN}" # Dynamic - changes on each Job run
```

**Why TIMESTAMP changes on each run:**
- ✅ Ensures unique DNS TXT records for ACME DNS-01 challenges
- ✅ Prevents Let's Encrypt caching issues during Job retriggers
- ✅ Allows idempotent Job execution without DNS record conflicts
- ✅ Static DNS names (primary domain and wildcard) remain consistent for actual cluster usage

**Idempotency:**
- If Certificate exists: `oc apply` updates it with new TIMESTAMP → new Let's Encrypt authorization
- If Certificate deleted: `oc apply` creates it with new TIMESTAMP → fresh certificate issuance
- Job is retriggerable (`Force=true`) without issues

**Impact:**
- Primary certificate purpose (securing `*.apps.${CLUSTER_DOMAIN}`) is unaffected
- TIMESTAMP DNS name is only used during ACME challenge validation, not for routing
- Certificate remains valid for same static domains across Job runs

## OpenShift Data Foundation (ODF)

**Pattern**: Dynamic Job with ConfigMap-driven channel management

**Purpose**: Configure all ODF operator subscriptions to run on infrastructure nodes via nodeSelector.

**Implementation**:

Job: `openshift-storage-job-update-subscriptions-node-selector.yaml`

1. Extracts ODF channel from `cluster-versions` ConfigMap: `data.odf` (e.g., `stable-4.20`)
2. Builds subscription names dynamically: `<package>-<channel>-redhat-operators-openshift-marketplace`
3. Patches 8 ODF subscriptions with nodeSelector: `cluster.ocs.openshift.io/openshift-storage: ""`
4. Handles special case: `odf-dependencies` (no channel suffix in name)

**Subscriptions Patched** (7 standard + 1 special):
- `cephcsi-operator`
- `mcg-operator`
- `ocs-client-operator`
- `ocs-operator`
- `odf-csi-addons-operator`
- `recipe`
- `rook-ceph-operator`
- `odf-dependencies` (special - no channel in name)

**Known Bug - Intentional Exclusions**:

The following 2 subscriptions are **intentionally NOT patched** due to a known ODF bug that prevents proper configuration of tolerations/nodeSelector:
- `odf-external-snapshotter-operator` → runs on worker nodes
- `odf-prometheus-operator` → runs on worker nodes

These operators will continue running on worker nodes until the upstream bug is resolved.

**Upgrade Behavior**:

When upgrading OCP (e.g., 4.20 → 4.21):
1. Update `cluster-versions` ConfigMap: `odf: "stable-4.21"`
2. Job automatically uses new channel
3. No Job modification required → channel-agnostic design

**Why ConfigMap approach**:
- ✅ Consistent with project architecture (centralized version management)
- ✅ Upgrade-proof (no hardcoded channels)
- ✅ Explicit control (list of packages, not wildcard discovery)
- ✅ Documents exceptions clearly (bug workaround)

## OpenShift Pipelines (Tekton)

**TektonConfig Profile Behavior:**

The TektonConfig CR supports three profiles:
- **`lite`**: Installs only Tekton Pipelines
- **`basic`**: Installs Tekton Pipelines, Tekton Triggers, Tekton Chains, and Tekton Results
- **`all`**: Installs all components including TektonAddon (ConsoleCLIDownload, ConsoleQuickStart, etc.)

**Important**: While Red Hat documentation states "all" is the default profile, when managing TektonConfig via GitOps without explicitly specifying the `profile` field, the operator appears to default to `basic` instead. This means:

- ✅ With `profile: basic`: You get core Tekton components but **no** TektonAddon
- ✅ With `profile: all`: You get TektonAddon which includes:
  - ConsoleCLIDownload resources (tkn-cli-serve pod for web console CLI downloads)
  - ConsoleQuickStart resources
  - ConsoleYAMLSample resources

**TektonConfig Configuration:**

The project explicitly configures both `profile` and `targetNamespace`:

```yaml
# components/openshift-pipelines/base/cluster-tektonconfig-config.yaml
spec:
  profile: all                        # Full Tekton components with console integration
  targetNamespace: openshift-pipelines  # Deploy components to standard OpenShift namespace
```

**Why explicit configuration:**
- `profile: all` ensures TektonAddon is installed (console CLI downloads, quick starts, YAML samples)
- `targetNamespace: openshift-pipelines` uses the standard OpenShift namespace (operator default is `tekton-pipelines`)
- Both fields are managed by GitOps (no ignoreDifferences)

**Version Note**: In OpenShift Pipelines 1.20+, the `basic` profile was enhanced to include Tekton Results (previously only in `all` profile).

## AWS Controllers for Kubernetes (ACK) - Route53

**Purpose**: Enables Kubernetes-native management of AWS Route53 resources (HostedZones, RecordSets, HealthChecks) via custom resources.

**Configuration Approach**:

The ACK Route53 operator requires specific ConfigMap and Secret resources to function. Rather than hardcoding AWS credentials and region, we use a **dynamic configuration injection Job** that:

1. **Runs in `openshift-gitops` namespace** with the `openshift-gitops-argocd-application-controller` ServiceAccount
2. **Waits for** the cluster's `aws-creds` Secret in `kube-system` (created during installation)
3. **Extracts** AWS credentials and region from cluster resources:
   - AWS credentials from `kube-system/aws-creds` Secret
   - AWS region from Infrastructure CR (`infrastructure.config.openshift.io/cluster`)
4. **Creates** in `ack-system` namespace:
   - `ack-route53-user-secrets` Secret (AWS credentials)
   - `ack-route53-user-config` ConfigMap (all required environment variables)

**Required ConfigMap Variables**:
The operator deployment expects these environment variables from the ConfigMap:
- `AWS_REGION` - AWS region (from Infrastructure CR)
- `AWS_ENDPOINT_URL` - Custom AWS endpoint (usually empty)
- `ACK_ENABLE_DEVELOPMENT_LOGGING` - Enable debug logging
- `ACK_LOG_LEVEL` - Log verbosity level
- `ACK_RESOURCE_TAGS` - Default tags applied to AWS resources
- `ACK_WATCH_NAMESPACE` - Limit to specific namespace (empty = all)
- `ENABLE_CARM` - Cross Account Resource Management (false by default)
- `ENABLE_LEADER_ELECTION` - High availability mode
- `FEATURE_GATES` - Feature flag configuration (empty = none)
- `LEADER_ELECTION_NAMESPACE` - Namespace for leader election
- `RECONCILE_DEFAULT_MAX_CONCURRENT_SYNCS` - Reconciliation concurrency

**Important**: Missing any of these variables will cause the controller to crash with parsing errors like `invalid argument "$(VARIABLE_NAME)"`.

**Installation**: ACK Route53 is part of the `core` gitops-base and is automatically deployed in all profiles.

## Cluster Observability Operator

**Purpose**: Provides unified observability UI plugins for OpenShift Console, integrating monitoring and logging insights directly in the console.

**Installation**: Deployed in dedicated `openshift-observability-operator` namespace with AllNamespaces OperatorGroup.

**Namespace**: `openshift-observability-operator`

**IMPORTANT - Required Label:**

The namespace **must** have the `openshift.io/cluster-monitoring: "true"` label per Red Hat documentation:

```yaml
metadata:
  labels:
    openshift.io/cluster-monitoring: "true"
  name: openshift-observability-operator
```

**Why this label is required:**
- Routes ServiceMonitor resources to cluster monitoring (not user-workload monitoring)
- Without it, user-workload Prometheus tries to scrape the health-analyzer ServiceMonitor
- The health-analyzer ServiceMonitor uses deprecated TLS file path syntax (operator-generated)
- User-workload Prometheus Operator rejects it, causing PrometheusOperatorRejectedResources alert
- Cluster monitoring handles the ServiceMonitor correctly

**OperatorGroup**: `observability-operator`
- Empty spec (no `spec:` section) → **AllNamespaces mode**
- Operator watches all namespaces cluster-wide
- Allows UIPlugin resources to be created at cluster scope

**UI Plugins**:

The component deploys two UIPlugin custom resources:

1. **Logging UIPlugin** (`cluster-uiplugin-logging.yaml`)
   - Type: Logging
   - Integrates with LokiStack: `logging-loki`
   - Logs limit: 50
   - Timeout: 30s

2. **Monitoring UIPlugin** (`cluster-uiplugin-monitoring.yaml`)
   - Type: Monitoring
   - Cluster Health Analyzer: enabled
   - Provides cluster health insights in console
   - Creates additional `health-analyzer` deployment when enabled

Both UIPlugins:
- Use `SkipDryRunOnMissingResource=true` (CRD installed by operator)
- Deploy on infra nodes (nodeSelector + tolerations)

**Deployments Created:**
- `observability-operator` - Main operator controller
- `monitoring` - Monitoring console plugin frontend
- `logging` - Logging console plugin frontend
- `health-analyzer` - Backend health analysis (created by monitoring UIPlugin)
- `perses-operator` - Perses dashboard operator
- `obo-prometheus-operator` - Prometheus operator for custom MonitoringStack CRs
- `obo-prometheus-operator-admission-webhook` - Webhook for Prometheus resources

**Installation**: Part of the `core` gitops-base, automatically deployed in all profiles.

## Red Hat Connectivity Link (RHCL) - Kuadrant

**Purpose**: Provides API gateway capabilities including rate limiting, authentication, DNS management, and TLS policies through the Kuadrant operator stack.

**Installation**: Deployed in `kuadrant-system` namespace. Available in select profiles via `gitops-bases/rh-connectivity-link/default`.

**Namespace**: `kuadrant-system`

**OperatorGroup**: `rhcl`
- Empty spec (no `spec:` section) → **AllNamespaces mode**
- Allows Kuadrant CRDs to be used cluster-wide

**Operator Stack (4 operators):**

The RHCL component manages 4 operator subscriptions with infrastructure node placement:

1. **RHCL Operator** (`rhcl-operator`)
   - Main Kuadrant operator
   - Creates Kuadrant CR and manages operator lifecycle

2. **Authorino Operator** (`authorino-operator`)
   - API authentication and authorization engine
   - Installed as dependency of Kuadrant

3. **DNS Operator** (`dns-operator`)
   - Multi-cluster DNS management
   - Installed as dependency of Kuadrant

4. **Limitador Operator** (`limitador-operator`)
   - Rate limiting engine
   - Installed as dependency of Kuadrant

**OLM-Generated Subscription Names:**

Dependency operators use OLM-generated subscription names following the pattern:
```
{package}-{channel}-{source}-{sourceNamespace}
```

Examples:
- `authorino-operator-stable-redhat-operators-openshift-marketplace`
- `dns-operator-stable-redhat-operators-openshift-marketplace`
- `limitador-operator-stable-redhat-operators-openshift-marketplace`

**Why these names?** When operators are installed via OLM dependency resolution (rather than direct manifest application), OLM generates subscription names automatically. The manifests use these generated names to match existing cluster state and enable GitOps management of dependencies.

**Infrastructure Node Placement:**

All 4 operator subscriptions are configured with infrastructure node placement:

```yaml
spec:
  config:
    nodeSelector:
      node-role.kubernetes.io/infra: ""
    tolerations:
      - key: node-role.kubernetes.io/infra
        operator: Exists
```

This ensures operator control plane workloads run on infrastructure nodes, separating them from user workloads.

**Kuadrant CR:**

The component creates a `Kuadrant` custom resource that automatically provisions:
- **Authorino** instance (authentication engine)
- **Limitador** instance (rate limiting engine)

**Known Limitations:**

1. **Operator Instance Pods** - Authorino and Limitador instances run on **worker nodes**:
   - No API exists in Kuadrant CR to configure nodeSelector/tolerations for instances
   - Only operator subscriptions support infra node placement
   - Accepted limitation for demo/lab environments

2. **Console Plugin** - `kuadrant-console-plugin` deployment runs on **worker nodes**:
   - No configuration option in operator to set nodeSelector/tolerations
   - Plugin is auto-created by RHCL operator
   - Accepted limitation for demo/lab environments
   - JIRA ticket created for upstream feature request

**Result:**
- ✅ All 4 **operator pods** run on infrastructure nodes
- ⚠️ **Instance pods** (authorino, limitador) run on worker nodes (accepted)
- ⚠️ **Console plugin** runs on worker nodes (accepted)

**Console Plugin:**

The component includes a Job to enable the `kuadrant-console-plugin` in OpenShift Console:
- Job: `openshift-gitops-job-enable-kuadrant-console-plugin.yaml`
- Idempotent patch that adds plugin if not already present
- Uses `Force=true` to run on every ArgoCD sync

**Version Management:**

Operator channels are managed via `cluster-versions` ConfigMap:
- `rhcl-operator: stable`
- `authorino-operator: stable`
- `dns-operator: stable`
- `limitador-operator: stable`

Kustomize replacements automatically inject channel versions during build.

**Observability Configuration:**

The RHCL component includes comprehensive observability for Gateway API and Kuadrant resources, following upstream Kuadrant v1.2.0 configuration with OpenShift adaptations.

1. **Kuadrant Observability Enabled:**
   ```yaml
   # components/rh-connectivity-link/base/kuadrant-system-kuadrant-kuadrant.yaml
   spec:
     observability:
       enable: true
   ```

   **Auto-creates 5 ServiceMonitors in `kuadrant-system` namespace**:
   - `authorino-operator-monitor` - Authorino operator metrics
   - `dns-operator-monitor` - DNS operator metrics
   - `kuadrant-authorino-monitor` - Authorino instance metrics
   - `kuadrant-operator-monitor` - Kuadrant operator metrics
   - `limitador-operator-monitor` - Limitador operator metrics

2. **kube-state-metrics for Gateway API:**

   Deployed in `monitoring` namespace (without cluster-monitoring label - uses user-workload Prometheus):

   - **CustomResourceStateMetrics ConfigMap**: Defines metrics for 14 resource types
     - **Gateway API** (8): Gateway, GatewayClass, HTTPRoute, GRPCRoute, TCPRoute, TLSRoute, UDPRoute, BackendTLSPolicy
     - **Kuadrant Policies** (4): RateLimitPolicy, AuthPolicy, DNSPolicy, TLSPolicy
     - **Kuadrant DNS** (2): DNSRecord, DNSHealthCheckProbe
     - **Source**: `gateway-api-state-metrics` v0.7.0
     - **API Versions**: Uses v1 for all Kuadrant policies (matches deployed CRDs)

   - **Deployment**: `kube-state-metrics-kuadrant`
     - Image: `registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.9.2`
     - Resources: 10m/100m CPU, 190Mi/250Mi memory
     - Ports: 8081 (main metrics), 8082 (self metrics)

   - **RBAC**: ClusterRole with list/watch permissions for Gateway API and Kuadrant CRDs

   - **ServiceMonitor**: Scraped by user-workload Prometheus (30s interval)
     - Label drop: Removes pod/service/endpoint/namespace labels from metrics
     - Two endpoints: main metrics + self metrics

3. **Istio Observability:**

   Enhanced metrics for service mesh traffic in `openshift-ingress` namespace:

   - **Telemetry CR**: Adds custom tags to REQUEST_COUNT and REQUEST_DURATION metrics
     ```yaml
     tagOverrides:
       destination_port: "string(destination.port)"
       request_host: "request.host"
       request_url_path: "request.url_path"
     ```

   - **ServiceMonitor**: Scrapes istiod control plane metrics
     - Port: http-monitoring
     - Namespace: openshift-ingress (OpenShift OSSM location, not upstream's gateway-system)

4. **Grafana Observability Stack:**

   Complete Grafana deployment in `monitoring` namespace:

   - **Grafana Instance**: Minimal CR using Grafana Operator defaults
     - Label: `dashboards: grafana` (for instance selection)
     - Managed by Grafana Operator (already deployed in core ApplicationSet)

   - **GrafanaDatasource**: Thanos Querier connection
     - Type: prometheus (default datasource)
     - URL: Dynamically set to Thanos Querier Route (not Service)
     - Auth: Bearer token from ServiceAccount
     - Job configures URL + token dynamically at deployment

   - **ServiceAccount**: `grafana-datasource` with `cluster-monitoring-view` ClusterRole
     - Allows Grafana to query Prometheus/Thanos
     - **Token Secret**: Explicit Secret with `kubernetes.io/service-account-token` type
       - Required in OpenShift 4.11+ (ServiceAccount tokens no longer auto-created)
       - Secret: `monitoring-secret-grafana-datasource-token.yaml`
       - Annotation: `kubernetes.io/service-account.name: grafana-datasource`

   - **6 GrafanaDashboard CRs**: Complete dashboards from Kuadrant v1.3.0
     - `platform-engineer` - Platform engineer focused metrics (72KB JSON)
     - `business-user` - Business user analytics (23KB JSON)
     - `controller-resources-metrics` - Controller resource utilization (8KB JSON)
     - `controller-runtime-metrics` - Controller runtime performance (20KB JSON)
     - `app-developer` - Application development metrics (46KB JSON)
     - `dns-operator` - DNS operator monitoring (23KB JSON)

   - **ConfigMapGenerator**: Creates ConfigMaps from dashboard JSON files
     - Source: https://github.com/Kuadrant/kuadrant-operator/tree/v1.3.0/examples/dashboards
     - Total: 192KB of dashboard definitions

   - **Configuration Job**: `configure-grafana-datasource-token` (PostSync wave 3)
     - Extracts Thanos Querier Route URL from `openshift-monitoring` namespace
     - Waits for ServiceAccount token Secret to be created
     - Patches GrafanaDatasource with dynamic Route URL and bearer token
     - Uses oc CLI (no jq dependency required)

**Metrics Flow:**
- kube-state-metrics → exports Gateway API/Kuadrant policy state metrics
- User-workload Prometheus → scrapes kube-state-metrics ServiceMonitor
- Istio control plane → exports enhanced request metrics via istiod
- Platform Prometheus → scrapes istiod ServiceMonitor
- Grafana → queries Thanos Querier (aggregates platform + user-workload Prometheus)

**Important Notes:**
- `monitoring` namespace does NOT have `openshift.io/cluster-monitoring: "true"` label
- RHCL is user-installed, so uses user-workload Prometheus (not platform Prometheus)
- Platform Prometheus scrapes namespaces WITH the label; user-workload scrapes WITHOUT
- Operator ServiceMonitors are auto-created by Kuadrant CR (not static manifests)
- GrafanaDatasource uses Thanos Querier Route URL (per RHCL 1.3 docs), not Service URL

**Known Issue - API Version Fix Applied:**

The upstream `gateway-api-state-metrics` v0.7.0 expects Kuadrant v1 APIs, which RHCL 1.3 now deploys. Our implementation correctly uses v1 API versions for all Kuadrant policies (RateLimitPolicy, AuthPolicy, DNSPolicy, TLSPolicy), ensuring kube-state-metrics can collect policy metrics. Earlier versions used incorrect API versions (v1beta2/v1beta3/v1alpha1) which prevented metrics collection.

**Installation**: Part of the `rh-connectivity-link` gitops-base, included in profiles with API gateway capabilities.

## Red Hat build of Keycloak (RHBK)

**Purpose**: Provides enterprise-grade identity and access management (IAM) with SSO, authentication, and authorization capabilities.

**Installation**: Deployed in `keycloak` namespace with dedicated PostgreSQL database in `databases-keycloak` namespace.

**Namespace**: `keycloak`

**OperatorGroup**: `rhbk-operator`
- Target namespaces: `keycloak` only (single-namespace mode)
- Keycloak CRs can only be created in `keycloak` namespace

**Operator Subscription:**

```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhbk-operator
  namespace: keycloak
spec:
  channel: stable-v26.4
  config:
    nodeSelector:
      node-role.kubernetes.io/infra: ""
    tolerations:
      - key: node-role.kubernetes.io/infra
        operator: Exists
  name: rhbk-operator
  source: redhat-operators
```

**Infrastructure Node Placement:**

RHBK operator pods run on infrastructure nodes via subscription nodeSelector and tolerations.

**PostgreSQL Database:**

The component includes a dedicated PostgreSQL 13 database for Keycloak in the `databases-keycloak` namespace:

**Namespace**: `databases-keycloak`
- Separate namespace for database isolation
- Label: `argocd.argoproj.io/managed-by: openshift-gitops`

**Database Resources:**

1. **Secret**: `keycloak-db`
   - Credentials: `keycloak/keycloak` (user/password)
   - Database name: `keycloak`
   - No sync-wave annotations (simple deployment)

2. **PersistentVolumeClaim**: `keycloak-db`
   - Storage: 5Gi
   - Access Mode: ReadWriteOnce

3. **Service**: `keycloak-db`
   - Port: 5432 (postgresql)
   - Type: ClusterIP
   - Selector: `app.kubernetes.io/name: keycloak-db`

4. **Deployment**: `keycloak-db`
   - Image: `registry.redhat.io/rhel8/postgresql-13:1`
   - Replicas: 1
   - Strategy: Recreate (single replica database)
   - Resources: 100m/128Mi request, 250m/256Mi limit
   - Probes: liveness (tcpSocket), readiness (psql exec)
   - Volume: Persistent storage at `/var/lib/pgsql/data`

**Database Connection Details:**

```
Host: keycloak-db.databases-keycloak.svc
Port: 5432
Database: keycloak
Username: keycloak
Password: keycloak

JDBC URL: jdbc:postgresql://keycloak-db.databases-keycloak.svc:5432/keycloak
```

**Version Management:**

Operator channel managed via `cluster-versions` ConfigMap:
- `rhbk-operator: stable-v26.4`

**Design Decisions:**

1. **Separate Database Namespace**: Isolates database from Keycloak application for security and organization
2. **Single Replica Database**: Recreate strategy ensures data consistency (acceptable for demo/lab environments)
3. **Minimal Labels/Annotations**: Clean manifests without unnecessary metadata
4. **Infrastructure Node Placement**: Operator pods on infra nodes (database on worker nodes - acceptable for demo/lab)
5. **Plain Secret**: Database credentials in unencrypted secret (acceptable for demo/lab with 30h lifespan)

**Keycloak Instance Configuration:**

The component deploys a Keycloak CR with the following configuration:

```yaml
spec:
  instances: 1
  db:
    vendor: postgres
    host: keycloak-db.databases-keycloak.svc
    database: keycloak
    usernameSecret: {name: keycloak-db-secret, key: database-user}
    passwordSecret: {name: keycloak-db-secret, key: database-password}
  http:
    httpEnabled: true  # Backend uses HTTP (route does TLS termination)
  ingress:
    enabled: false     # Using OpenShift Route instead
  hostname:
    strict: false      # Auto-detect hostname from incoming requests
```

**Route Configuration:**

```yaml
spec:
  port:
    targetPort: http   # Service exposes HTTP on port 8080
  tls:
    termination: edge  # TLS termination at route level
    insecureEdgeTerminationPolicy: Redirect
  to:
    kind: Service
    name: keycloak-service
```

**Hostname Management:**

Keycloak uses `hostname.strict: false` to **auto-detect the hostname from incoming HTTP requests**. This eliminates the need for:
- ❌ Hardcoded placeholder hostnames in manifests
- ❌ Dynamic hostname update Jobs
- ❌ ArgoCD ignoreDifferences configuration

The Keycloak operator automatically creates the `keycloak-service` with ports:
- `8080` (http) - Main Keycloak endpoint
- `9000` (management) - Management interface

**Why this works:**
- Route terminates TLS and forwards HTTP to backend service port 8080
- Keycloak receives requests with the actual route hostname in HTTP headers
- With `strict: false`, Keycloak uses that hostname for redirects
- No static configuration or patching needed

**Installation**: Part of the `core` gitops-base, automatically deployed in all profiles.

## Red Hat OpenShift AI (RHOAI)

**Purpose**: Enterprise AI/ML platform providing model development, training, serving, and monitoring capabilities.

**Installation**: Deployed in `redhat-ods-operator` and `redhat-ods-applications` namespaces. Included in AI-focused profiles.

**Namespace**: `redhat-ods-operator` (operator), `redhat-ods-applications` (applications)

**Key Components:**

### DataScienceCluster Configuration

The DataScienceCluster CR controls which RHOAI components are enabled:

```yaml
# components/rhoai/base/cluster-datasciencecluster-default-dsc.yaml
spec:
  components:
    kserve:
      managementState: Managed
      modelsAsService:
        managementState: Managed  # Enables MaaS API for model serving
    kueue:
      managementState: Unmanaged  # Cluster-wide Kueue managed separately
    # ... other components
```

**Models as a Service (MaaS):**
- Enabled via `kserve.modelsAsService.managementState: Managed`
- Deploys `maas-api` pod in `redhat-ods-applications`
- Creates `tier-to-group-mapping` ConfigMap with tier definitions (Free, Premium, Enterprise)

### OdhDashboardConfig Management

**Pattern**: Direct CR management with ArgoCD ignoreDifferences (not Jobs)

The OdhDashboardConfig CR is **managed directly** by ArgoCD instead of using a patch Job:

```yaml
# components/rhoai/base/redhat-ods-applications-odhdashboardconfig-odh-dashboard-config.yaml
apiVersion: opendatahub.io/v1alpha
kind: OdhDashboardConfig
metadata:
  name: odh-dashboard-config
  namespace: redhat-ods-applications
spec:
  dashboardConfig:
    disableTracking: false
    genAiStudio: true       # Enables GenAI Studio UI
    modelAsService: true    # Enables MaaS UI
  notebookController:
    enabled: true
    notebookNamespace: rhods-notebooks
    pvcSize: 20Gi
```

**RBAC for Custom Resources:**

ArgoCD requires explicit RBAC to manage RHOAI custom resources:

```yaml
# ClusterRole for OdhDashboardConfig management
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: odhdashboardconfigs.opendatahub.io-v1alpha-edit
rules:
  - apiGroups: [opendatahub.io]
    resources: [odhdashboardconfigs]
    verbs: [get, list, watch, create, update, patch, delete]

# ClusterRoleBinding to ArgoCD ServiceAccount
subjects:
  - kind: ServiceAccount
    name: openshift-gitops-argocd-application-controller
    namespace: openshift-gitops
```

**ignoreDifferences Configuration:**

The `ai` ApplicationSet ignores operator-managed fields to prevent sync conflicts:

```yaml
# gitops-bases/ai/applicationset.yaml
ignoreDifferences:
  - group: opendatahub.io
    kind: OdhDashboardConfig
    name: odh-dashboard-config
    jsonPointers:
      - /metadata/annotations      # Operator-managed platform annotations
      - /metadata/labels
      - /metadata/ownerReferences
      - /spec/hardwareProfileOrder # Operator-populated lists
      - /spec/templateDisablement
      - /spec/templateOrder
```

**Why this approach:**
- ✅ GitOps-native: CR managed like any other Kubernetes resource
- ✅ No Job complexity: Direct declarative management
- ✅ Clear ownership: ArgoCD owns `dashboardConfig` section, operator owns metadata
- ✅ Auditable: Changes tracked in Git, visible in ArgoCD UI

### MaaS Gateway for Model Serving

**Pattern**: Dynamic Job with cluster domain injection

Models as a Service requires a Gateway API resource for exposing model endpoints:

```yaml
# Created by: components/rhoai/base/openshift-gitops-job-create-maas-gateway.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: maas-default-gateway
  namespace: openshift-ingress
spec:
  gatewayClassName: data-science-gateway-class  # RHOAI's Gateway controller
  listeners:
    - allowedRoutes:
        namespaces:
          from: All  # Cross-namespace routing for model serving
      hostname: maas-api.apps.<cluster-domain>
      name: https
      port: 443
      protocol: HTTPS
      tls:
        certificateRefs:
          - kind: Secret
            name: ingress-certificates  # Let's Encrypt wildcard cert
        mode: Terminate
```

**Job Implementation:**
- Extracts cluster domain from `dns.config.openshift.io/cluster`
- Creates Gateway with dynamically generated hostname
- Uses RHOAI's `data-science-gateway-class` GatewayClass
- References Let's Encrypt certificate created by cert-manager
- Runs with `Force=true` for retriggerable execution

**Gateway Status:**
- Creates AWS ELB LoadBalancer service
- Assigns external hostname: `<uuid>.eu-central-1.elb.amazonaws.com`
- Internal service: `maas-default-gateway-data-science-gateway-class.openshift-ingress.svc.cluster.local:443`
- Supports HTTPRoute and GRPCRoute attachments

**Version Management:**

Operator channel managed via `cluster-versions` ConfigMap:
- `rhoai: "stable-3.3"` (ConfigMap - actual deployed version)
- Subscription fallback: `stable-3.x` (generic channel for future upgrades)

**Installation**: Part of the `ai` gitops-base, deployed in profiles: `ocp-ai`, `ocp-standard`, etc.
