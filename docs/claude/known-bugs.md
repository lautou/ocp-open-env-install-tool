# Known Bugs and Alert Silences

This document tracks known bugs in OpenShift operators and components that generate false-positive alerts. These alerts are silenced in the Alertmanager configuration to reduce noise.

**⚠️ IMPORTANT: Do NOT add secrets to Alertmanager configuration!**

Before adding any alert silence, verify that the Alertmanager configuration does NOT contain:
- API tokens or keys
- Webhook URLs with embedded credentials
- Email/Slack/PagerDuty passwords
- Any sensitive authentication data

If you need to add receivers with credentials, use Secret references instead of inline values.

---

## Silenced Alerts

**Automation:** All Alertmanager silences are created automatically via GitOps!

A PostSync Job (`components/cluster-monitoring/base/openshift-monitoring-job-create-alert-silences.yaml`) runs after the cluster-monitoring component syncs and creates all silences automatically via the Alertmanager API. This ensures:
- ✅ **Zero manual intervention** - silences are created on every new cluster deployment
- ✅ **No alerts visible** - web console shows "suppressed" status from first login
- ✅ **GitOps-managed** - Job is version controlled and reproducible
- ✅ **Idempotent** - can be run multiple times safely

The Job creates 10-year silences for all known bugs documented below.

### 1. NooBaa Database PodDisruptionBudgetAtLimit — RESOLVED, hack removed (2026-08-08)

**Component:** OpenShift Data Foundation (ODF) - NooBaa
**JIRA:** [DFBUGS-5294](https://redhat.atlassian.net/browse/DFBUGS-5294) — Closed/Done, fixed in `odf-4.22` (released 2026-07-09)

**Issue (unchanged, by design):** the NooBaa CNPG PostgreSQL PDB (`noobaa-db-pg-cluster-primary`) has `minAvailable: 1` on a single-replica database, so `disruptionsAllowed` is always `0` — CNPG performs a graceful primary switchover during node drains instead. This still triggers `PodDisruptionBudgetAtLimit`; that part is intentional and hasn't changed.

**What changed:** as of ODF 4.22, the `noobaa-operator` itself creates and hourly-reconciles an indefinite Alertmanager silence for this exact alert — no external workaround needed anymore. Confirmed live on this cluster (ODF `4.22.1-rhodf`): `noobaa-operator` logs show `"cnpg:: reconciling PDB alert silence for CNPG cluster noobaa-db-pg-cluster"` → `"PDB alert silence already exists and is valid (ID: ..., expires: 3000-01-01T00:00:00Z)"`, and the live Alertmanager silence list shows the operator's own silence (`createdBy: noobaa-operator`) active alongside our now-redundant one.

**Removed:** the `null`-receiver routing rule in `components/cluster-monitoring/base/openshift-monitoring-secret-alertmanager-main.yaml` and the corresponding silence-creation block in `components/cluster-monitoring/base/openshift-gitops-job-create-alert-silences.yaml` — both redundant now that the operator self-manages this on any cluster running ODF 4.22+.

---

### 2. Apicurio Registry UI PodDisruptionBudgetAtLimit

**Alert Name:** `PodDisruptionBudgetAtLimit`
**Component:** Apicurio Registry - UI Component
**Namespace:** `apicurio`
**PodDisruptionBudget:** `apicurio-studio-ui-poddisruptionbudget`

**Issue:**
The Apicurio Registry Operator creates a PodDisruptionBudget for the UI component with `minAvailable: 1` in a single-replica deployment, resulting in 0 allowed disruptions. This triggers the PodDisruptionBudgetAtLimit alert even though this is the expected configuration for a single-replica workload.

**Impact:**
- False-positive PodDisruptionBudgetAtLimit alerts
- No actual impact on Apicurio Registry functionality
- UI operates normally with single replica and proper PDB protection
- Alert fatigue and operational confusion

**Root Cause:**
PDB configuration in Apicurio Registry Operator creates `minAvailable: 1` for single-replica UI deployment, which mathematically results in 0 allowed disruptions (1 available - 1 required = 0). This is the same pattern as NooBaa and llama-stack operators.

**Status:**
- **JIRA:** [APICURIO-24](https://issues.redhat.com/browse/APICURIO-24) - Apicurio Registry UI PodDisruptionBudget triggers false-positive alert in single-replica deployment
- **Reported:** 2026-03-30
- **Workaround:** Alert routed to null receiver + Alertmanager silence active
- **Fix ETA:** TBD (pending operator update to skip PDB for single-replica deployments)
- ℹ️ **Currently dormant on this cluster (confirmed 2026-08-08):** the `rhb-apicurio-registry-operator` is deployed (Synced/Healthy), but no `apicurio` namespace resources exist — no ApicurioRegistry3 instance has been created, so the UI Deployment/PDB this bug depends on doesn't exist yet. Silence stays proactive (same pattern as every other entry here) for whenever an instance gets deployed.

**Mitigation Applied:**

1. **Routing Configuration** (GitOps-managed):
   ```yaml
   # Location: components/cluster-monitoring/base/openshift-monitoring-secret-alertmanager-main.yaml
   routes:
     - matchers:
         - alertname = PodDisruptionBudgetAtLimit
         - poddisruptionbudget = apicurio-studio-ui-poddisruptionbudget
         - namespace = apicurio
       receiver: 'null'
       continue: false
   ```

2. **Alertmanager Silence** (Automated via GitOps Job):
   - **Created by:** `openshift-monitoring-job-create-alert-silences.yaml` (PostSync hook)
   - **Duration:** 10 years from cluster deployment
   - **Created by:** argocd-automation
   - **Effect:** Alert shows as "suppressed" in web console
   - **Automation:** Runs automatically on every cluster deployment

**Verification:**
```bash
# Check PDB configuration
oc get pdb apicurio-studio-ui-poddisruptionbudget -n apicurio -o yaml

# Check allowed disruptions
oc get pdb apicurio-studio-ui-poddisruptionbudget -n apicurio \
  -o jsonpath='{.status.disruptionsAllowed}{"\n"}'

# Expected: 0 (triggers the alert)

# Check UI deployment replica count
oc get deployment apicurio-studio-ui-deployment -n apicurio \
  -o jsonpath='{.spec.replicas}{"\n"}'

# Expected: 1 (single replica)
```

---

### 3. Kuadrant istio-pod-monitor TargetDown

**Alert Name:** `TargetDown`
**Component:** Red Hat Connectivity Link (RHCL) - Kuadrant Operator
**Namespace:** `ingress-gateway` (or any user namespace with Gateway resources)
**Job:** `openshift-ingress/istio-pod-monitor` or `*/istio-pod-monitor`

**Issue:**
The Kuadrant operator automatically creates `istio-pod-monitor` PodMonitor resources in each Gateway namespace with an empty `namespaceSelector: {}`, causing it to attempt discovering Istio sidecar pods across all namespaces cluster-wide. This conflicts with OpenShift's dual-Prometheus architecture (cluster monitoring vs user-workload monitoring), resulting in TargetDown alerts for targets that are inaccessible due to namespace filtering policies.

**Impact:**
- False-positive TargetDown alerts for `istio-pod-monitor` in user namespaces
- User-workload Prometheus discovers targets in cluster-monitoring namespaces but cannot scrape them
- Alert fatigue and reduced trust in monitoring
- No actual data loss (relabeling filters prevent scraping non-istio-proxy containers)

**Root Cause:**
The Kuadrant operator's `istioPodMonitorBuild()` function creates PodMonitors without a `namespaceSelector` field, which defaults to empty `{}` (all namespaces). While this works for global Istio sidecar discovery, it causes issues when the PodMonitor is in a user namespace:

1. PodMonitor created in user namespace (e.g., `ingress-gateway`)
2. User-workload Prometheus picks it up (namespace lacks `openshift.io/cluster-monitoring: "true"`)
3. PodMonitor has `namespaceSelector: {}` → tries to discover pods in ALL namespaces
4. User-workload Prometheus is configured to EXCLUDE cluster-monitoring namespaces:
   ```yaml
   podMonitorNamespaceSelector:
     matchExpressions:
     - key: openshift.io/cluster-monitoring
       operator: NotIn
       values: ["true"]
   ```
5. Prometheus discovers targets in `openshift-ingress` (cluster namespace) via PodMonitor
6. Prometheus cannot scrape those targets (namespace filter blocks them)
7. TargetDown alert fires for inaccessible targets

**Source Code Reference:**
[kuadrant-operator/internal/controller/observability_reconciler.go](https://github.com/Kuadrant/kuadrant-operator/blob/main/internal/controller/observability_reconciler.go)

The operator correctly sets `namespaceSelector` for ServiceMonitors but omits it for PodMonitors (istio-pod-monitor, kuadrant-limitador-monitor).

**Status:**
- **JIRA:** [CONNLINK-911](https://issues.redhat.com/browse/CONNLINK-911)
- **Reported:** 2026-03-26
- **Workaround:** Alert routed to null receiver + Alertmanager silence active
- **Fix ETA:** TBD (requires operator update to add `namespaceSelector.matchNames: [ns]`)

**Mitigation Applied:**

1. **Routing Configuration** (GitOps-managed):
   ```yaml
   # Location: components/cluster-monitoring/base/openshift-monitoring-secret-alertmanager-main.yaml
   routes:
     - matchers:
         - alertname = TargetDown
         - job =~ .*/istio-pod-monitor
       receiver: 'null'
       continue: false
   ```

2. **Alertmanager Silence** (Automated via GitOps Job):
   - **Created by:** `openshift-monitoring-job-create-alert-silences.yaml` (PostSync hook)
   - **Duration:** 10 years from cluster deployment
   - **Created by:** argocd-automation
   - **Effect:** Alert shows as "suppressed" in web console
   - **Automation:** Runs automatically on every cluster deployment

**Verification:**
```bash
# Check PodMonitors created by Kuadrant
oc get podmonitor -A -l kuadrant.io/observability=true

# Check PodMonitor namespaceSelector (should be empty)
oc get podmonitor istio-pod-monitor -n ingress-gateway -o jsonpath='{.spec.namespaceSelector}'

# Expected: {} or no output (empty selector)

# Check which Prometheus picks it up
oc get prometheus -A -o yaml | grep -A 10 podMonitorNamespaceSelector

# Verify TargetDown alert exists
oc exec -n openshift-user-workload-monitoring prometheus-user-workload-0 -c prometheus -- \
  wget -q -O- 'http://localhost:9090/api/v1/alerts' | \
  jq '.data.alerts[] | select(.labels.alertname == "TargetDown" and (.labels.job | contains("istio-pod-monitor")))'
```


---

### 4. TrustyAI ServiceMonitor Overly Broad Selector (Operator Metrics 404)

**Alert Name:** `TargetDown`
**Component:** Red Hat OpenShift AI (RHOAI) - TrustyAI Operator
**Namespace:** `redhat-ods-applications`
**Service:** `trustyai-service-operator-metrics-service` (and `trustyai-service-operator-controller-manager-metrics-service`)

**⚠️ Re-opened (2026-08-08):** previously marked "Fixed, silence removed" based on the absence of the `trustyai-metrics` ServiceMonitor. That conclusion was **wrong** — the operator creates this ServiceMonitor *lazily*, only when the first `TrustyAIService` CR is created anywhere on the cluster, not unconditionally. It had simply never been triggered. Deploying a throwaway test `TrustyAIService` reproduced it immediately with the exact original broken config. Confirmed still present on RHOAI 3.4.2 / OCP 4.20.30 despite Jira showing `3.5 EA1` as the fixVersion.

**Issue:**
The `trustyai-metrics` ServiceMonitor uses `namespaceSelector: any: true` and `selector: matchLabels: app.kubernetes.io/part-of: trustyai`. This accidentally matches the TrustyAI **operator controller-manager** service in `redhat-ods-applications`, which only exposes `/metrics` (Go runtime). The ServiceMonitor scrapes `/q/metrics` (Quarkus path, intended for TrustyAIService app pods) → 404 Not Found → TargetDown alert.

**Live proof (2026-08-08), real Prometheus scrape results after deploying a test `TrustyAIService`:**

| Target | Health | Error |
|---|---|---|
| operator pod `:8080/q/metrics` (matched by the broad selector) | ❌ DOWN | 404 Not Found |
| operator pod `:8080/metrics` (correct `trustyai-service-operator-service-monitor`) | ✅ UP | — |

**Impact:**
- False-positive TargetDown alert for `trustyai-service-operator-metrics-service`
- No actual impact on TrustyAI operator functionality
- Only manifests once **any** `TrustyAIService` CR is deployed anywhere on the cluster — currently dormant since none is deployed, but will fire the moment one is created

**Root Cause:**
`trustyai-metrics` ServiceMonitor has an overly broad `namespaceSelector: any: true` combined with `app.kubernetes.io/part-of: trustyai` which also matches the operator controller-manager service. The operator and the TrustyAIService app share the same label but expose different metrics paths.

**Status:**
- **JIRA:** [RHOAIENG-54605](https://redhat.atlassian.net/browse/RHOAIENG-54605) - TrustyAI ServiceMonitor has overly broad selector causing false TargetDown alerts
- **Reported:** 2026-03-21
- **Status:** Open — Jira shows Closed with fixVersion `3.5 EA1 RHOAI RELEASE` (released 2026-06-17), but live reproduction on RHOAI 3.4.2 / OCP 4.20.30 (2026-08-08) confirms the bug is still present. The fix has not reached our version.

**Mitigation Applied:**

1. **Routing Configuration** (GitOps-managed):
   ```yaml
   # Location: components/cluster-monitoring/base/openshift-monitoring-secret-alertmanager-main.yaml
   routes:
     - matchers:
         - alertname = TargetDown
         - service =~ trustyai-service-operator.*metrics-service
         - namespace = redhat-ods-applications
       receiver: 'null'
       continue: false
   ```

2. **Alertmanager Silence** (Automated via GitOps Job):
   - **Created by:** `openshift-gitops-job-create-alert-silences.yaml` (PostSync hook)
   - **Duration:** 10 years from cluster deployment

**Verification:**
```bash
# Deploy a throwaway TrustyAIService to trigger the lazy ServiceMonitor creation, then check:
oc get servicemonitor trustyai-metrics -n redhat-ods-applications -o yaml
oc exec -n openshift-monitoring prometheus-k8s-0 -c prometheus -- \
  wget -q -O- 'http://localhost:9090/api/v1/targets' | \
  jq '.data.activeTargets[] | select(.labels.service == "trustyai-service-operator-metrics-service") | {health, lastError}'
```

---

### 5. TrustyAI ServiceMonitor scheme: http on TLS Ports (400 Bad Request)

**Alert Name:** `TargetDown`
**Component:** Red Hat OpenShift AI (RHOAI) - TrustyAI Operator
**Namespace:** User project namespace (e.g. `ai-generation-llm-rag`)
**Services:** `trustyai-service`, `trustyai-service-tls`

**⚠️ Confirmed still broken (2026-08-08):** previously marked "Fixed, silence removed" and separately "untestable" pending a real instance. Deployed a throwaway test `TrustyAIService` on this cluster (RHOAI 3.4.2 / OCP 4.20.30) and reproduced the bug exactly.

**Issue:**
The `trustyai-service` ServiceMonitor (created by the TrustyAIService CR reconciler) configures `scheme: http` with no `port:` filter. Prometheus discovers all ports on the selected services (`trustyai-service` and `trustyai-service-tls`) and scrapes each with `http://`. Since both services expose TLS ports (8443, 9443, 4443) alongside the plain HTTP port (8080), HTTP requests to HTTPS endpoints result in `400 Bad Request` (or `EOF` for port 4443).

**Live proof (2026-08-08), real Prometheus scrape results:**

| Service | Port | Health | Error |
|---|---|---|---|
| `trustyai-service` | 8080 | ✅ UP | — |
| `trustyai-service` | 4443 | ❌ DOWN | EOF |
| `trustyai-service` | 8443 | ❌ DOWN | 400 Bad Request |
| `trustyai-service` | 9443 | ❌ DOWN | 400 Bad Request |
| `trustyai-service-tls` | 8443 | ❌ DOWN | 400 Bad Request |

Matches the Jira ticket's own reproduction table exactly.

**Impact:**
- False-positive TargetDown for `trustyai-service` (75% targets down)
- False-positive TargetDown for `trustyai-service-tls` (100% targets down)
- TrustyAI service is fully functional — this is monitoring misconfiguration only
- Only manifests once a `TrustyAIService` CR is deployed in a user namespace — currently dormant since none is deployed on this cluster

**Root Cause:**
ServiceMonitor created by TrustyAI operator for the TrustyAIService CR specifies `scheme: http` without restricting to a specific port. The `trustyai-service` and `trustyai-service-tls` Services both carry the `app.kubernetes.io/part-of: trustyai` label matched by the ServiceMonitor selector, causing all their ports to be scraped via HTTP.

**Status:**
- **JIRA:** [RHOAIENG-61424](https://redhat.atlassian.net/browse/RHOAIENG-61424) - TrustyAI ServiceMonitor uses scheme: http on TLS ports causing false TargetDown alerts
- **Reported:** 2026-05-07
- **Status:** Open — Jira shows Closed with fixVersion `3.5 EA1 RHOAI RELEASE` (released 2026-06-17), but live reproduction on RHOAI 3.4.2 / OCP 4.20.30 (2026-08-08) confirms the bug is still present. The fix has not reached our version.
- **Related:** [RHOAIENG-54605](https://redhat.atlassian.net/browse/RHOAIENG-54605) (overly broad `trustyai-metrics` selector) — see the "TrustyAI ServiceMonitor Overly Broad Selector" entry above; same root class of bug, re-opened alongside this one on the same date.

**Mitigation Applied (2026-08-08):** proactively silenced alongside RHOAIENG-54605 for consistency, even though no `TrustyAIService` is deployed on this cluster right now to actually trigger it — pre-empting the alert the moment one is created, same as every other entry in this doc.

1. **Routing Configuration** (GitOps-managed):
   ```yaml
   # Location: components/cluster-monitoring/base/openshift-monitoring-secret-alertmanager-main.yaml
   routes:
     - matchers:
         - alertname = TargetDown
         - service =~ trustyai-service|trustyai-service-tls
       receiver: 'null'
       continue: false
   ```

2. **Alertmanager Silence** (Automated via GitOps Job):
   - **Created by:** `openshift-gitops-job-create-alert-silences.yaml` (PostSync hook)
   - **Duration:** 10 years from cluster deployment

**Verification:**
```bash
# Check Prometheus targets (user-workload Prometheus)
oc exec -n openshift-user-workload-monitoring prometheus-user-workload-0 -c prometheus -- \
  wget -q -O- 'http://localhost:9090/api/v1/targets' | \
  jq '.data.activeTargets[] | select(.labels.service | test("trustyai-service")) | {service: .labels.service, port: .labels.instance, health: .health, error: .lastError}'
```

---

### 6. insights-runtime-extractor KubeDaemonSetMisScheduled (Race Condition with Infra Taint)

**Alert Name:** `KubeDaemonSetMisScheduled`
**Component:** OpenShift Insights — `insights-runtime-extractor` DaemonSet
**Namespace:** `openshift-insights`

**Issue:**
The `insights-runtime-extractor` DaemonSet has `nodeSelector: kubernetes.io/os: linux` (matches all nodes) but **no tolerations**. At cluster install time, the Insights operator deploys pods before Day 2 applies infra/storage taints. When the taint `node-role.kubernetes.io/infra=:NoSchedule` is added, existing pods are NOT evicted (`NoSchedule` ≠ `NoExecute`). The DaemonSet recalculates `desiredNumberScheduled=3` (untainted workers only), but the pod still runs on the infra node → `numberMisscheduled=1` → `KubeDaemonSetMisScheduled` alert fires.

**Impact:** Cosmetic only — Insights service fully functional (`available=3/3`).

**Root Cause:** Missing `tolerations: [{operator: Exists}]` in the DaemonSet spec.

**Status:**
- **JIRA:** [OCPBUGS-74211](https://redhat.atlassian.net/browse/OCPBUGS-74211) — New (unassigned), OCP 4.20.8
- **Reported:** 2026-06-24
- **Workaround:** Alert silenced in Alertmanager (pending upstream fix)
- **Fix ETA:** TBD — upstream fix adds `tolerations: [{operator: Exists}]`

**Mitigation Applied:**
- **Alertmanager Silence** (Automated via GitOps Job): matchers on `alertname=KubeDaemonSetMisScheduled`, `daemonset=insights-runtime-extractor`, `namespace=openshift-insights`
- **Manual one-time fix:** `oc delete pod <misscheduled-pod> -n openshift-insights` — pod restarts on a valid worker

---

### 7. RHOAI InferenceService AuthProxyPreserved (Sticky Condition)

**ArgoCD Health:** `ai-models-service` shows `Progressing` (not Healthy)
**Component:** Red Hat OpenShift AI (RHOAI) - KServe / ODH Model Controller
**Namespace:** `ai-models-service`
**Resources:** `InferenceService/granite-llm`, `InferenceService/granite-embedding`

**Issue:**
After a cluster restart or RHOAI upgrade that changes the `kube-rbac-proxy` image SHA in `inferenceservice-config`, the ODH Model Controller sets `LatestDeploymentReady: False` with reason `AuthProxyPreserved` on all running InferenceServices. This condition **never clears automatically**, even after the running pods are updated to the correct image.

**Impact:**
- ArgoCD `ai-models-service` shows `Progressing` instead of `Healthy` — cosmetic only
- Models are fully operational: `Ready: True`, `PredictorReady: True`, `IngressReady: True`
- No inference serving disruption

**Root Cause:**
The ODH Model Controller detects a mismatch between the `kube-rbac-proxy` image in the running Deployment and the desired image in `inferenceservice-config` ConfigMap. To avoid GPU pod restarts (which would unload the model), it preserves the existing auth proxy container and sets `AuthProxyPreserved`. However, the condition is sticky — it does not clear even after the Deployment image is updated to match. This appears to be a bug in the condition reconciliation logic.

**Observed:** 2026-04-18 after cluster restart.

**Workaround — after each cluster restart, if `AuthProxyPreserved` appears:**
```bash
# 1. Get the desired image from operator config
NEW_SHA=$(oc get configmap inferenceservice-config -n redhat-ods-applications \
  -o jsonpath='{.data.deploy}' | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('rawDeployment',{}).get('authProxy',{}).get('image',''))" 2>/dev/null || \
  oc get configmap inferenceservice-config -n redhat-ods-applications -o yaml | grep "kube-auth-proxy" | grep -o 'sha256:[a-f0-9]*' | head -1)

# 2. Patch both Deployments with the correct image
oc set image deployment/granite-llm-predictor kube-rbac-proxy="registry.redhat.io/rhoai/odh-kube-auth-proxy-rhel9@sha256:4027ce7319cb9c9fbed1e736b440c0fa6e8bfeb5a4433a4c753402642a1839af" -n ai-models-service
oc set image deployment/granite-embedding-predictor kube-rbac-proxy="registry.redhat.io/rhoai/odh-kube-auth-proxy-rhel9@sha256:4027ce7319cb9c9fbed1e736b440c0fa6e8bfeb5a4433a4c753402642a1839af" -n ai-models-service

# 3. Wait for rollout (models will reload — ~5 min)
oc rollout status deployment/granite-llm-predictor deployment/granite-embedding-predictor -n ai-models-service --timeout=10m
```

**Note:** Even after patching, `AuthProxyPreserved` condition may remain set (sticky bug). The models are operational regardless. Monitor with:
```bash
oc get inferenceservice -n ai-models-service -o json | python3 -c "
import json,sys
for i in json.load(sys.stdin)['items']:
    conds = {c['type']: c['status'] for c in i.get('status',{}).get('conditions',[])}
    print(i['metadata']['name'], conds)
"
```

**Status:** Known RHOAI bug — no upstream JIRA found yet. Not silenced (no Prometheus alert, ArgoCD health only).

---

## Disabled Insights Recommendations

Red Hat Insights provides cloud-based analysis and recommendations for OpenShift clusters. Some recommendations may be false positives or known issues tracked in JIRA. These can be disabled via the `support` Secret in `openshift-config` namespace.

**Configuration:** `components/openshift-config/base/openshift-config-secret-support.yaml`

---

### 1. Kueue Webhook Timeout Exceeds Recommendation

**Recommendation:** `Configuring the webhook's timeout for Pod API exceeds 13s is not recommended`
**Rule ID:** `ccx_rules_ocp.external.rules.webhook_timeout_is_larger_than_default`
**Component:** Kueue Operator
**Risk Level:** Moderate
**Namespace:** N/A (cluster-wide configuration)

**Issue:**
The Kueue operator configures webhook timeouts that exceed the recommended 13-second threshold. This triggers an Insights recommendation suggesting the timeout is too high, which could impact API responsiveness.

**Impact:**
- Moderate risk Insights recommendation appears in console
- No actual impact on Kueue functionality
- Webhook operates normally with extended timeout
- Recommendation appears in Insights Advisor dashboard

**Root Cause:**
Kueue operator configures its validating/mutating webhooks with `timeoutSeconds: 23`, above the 13s Insights recommends. ⚠️ Correction (2026-08-08): this was **not** actually necessary — see Status below, the fix's own author states the timeout bump should never have been applied.

**Status:**
- **JIRA:** [OCPKUEUE-578](https://redhat.atlassian.net/browse/OCPKUEUE-578) — Jira shows Closed/Done (2026-03-22)
- **Upstream fix confirmed merged:** [openshift/kueue-operator#1588](https://github.com/openshift/kueue-operator/pull/1588) ("Remove webhook timeout" — "the webhook timeout shouldn't be updated as the maximum allowed is 13 seconds"), merged 2026-03-16.
- ⚠️ **Not yet in the downstream product (confirmed live, 2026-08-08):** this cluster runs `kueue-operator.v1.2.0` (Red Hat build of Kueue), and both `kueue-validating-webhook-configuration` and `kueue-mutating-webhook-configuration` still show `timeoutSeconds: 23` on every webhook. The `InsightsRecommendationActive` alert is genuinely still firing (confirmed active, state `suppressed` by our silence) — this is a real unfixed condition on this cluster, not a stale false-positive being needlessly hidden. The upstream merge hasn't propagated to the productized Kueue operator build yet.
- **Workaround:** Recommendation disabled in Insights configuration — **keep in place**, confirmed still needed
- **Fix ETA:** TBD — re-check `kueue-operator` CSV version after any operator upgrade for whether `timeoutSeconds` finally drops to ≤13s

**Mitigation Applied:**

**Insights Configuration** (GitOps-managed):
```yaml
# Location: components/openshift-config/base/openshift-config-secret-support.yaml
insights:
  disabled_recommendations:
    - rule_id: "ccx_rules_ocp.external.rules.webhook_timeout_is_larger_than_default"
```

**Verification:**
```bash
# Check support Secret exists
oc get secret support -n openshift-config

# View disabled recommendations
oc get secret support -n openshift-config -o jsonpath='{.data.config\.yaml}' | base64 -d

# Check Insights Operator logs for configuration reload
oc logs -n openshift-insights deployment/insights-operator | grep -i "disabled"

# Verify recommendation no longer appears (24-48 hours after disabling)
# View in Red Hat Hybrid Cloud Console:
# https://console.redhat.com/openshift/insights/advisor/clusters/<CLUSTER_ID>
# The webhook_timeout_is_larger_than_default recommendation should not appear
```

**Important:**
- Insights recommendations may take 24-48 hours to refresh after disabling
- The recommendation will still be detected but marked as disabled
- Changes persist across cluster upgrades

---

### 2. Insights Operator Configuration Location Change

**Recommendation:** `Deprecated: Configuration via support Secret (use ConfigMap instead)`
**Rule ID:** `ccx_rules_ocp.external.rules.io_415_change_config_location`
**Component:** Insights Operator
**Risk Level:** Low
**Namespace:** `openshift-config`

**Issue:**
Red Hat documentation for OCP 4.15+ states that Insights Operator configuration should be migrated from Secret to ConfigMap (`support` ConfigMap instead of `support` Secret). This triggers an Insights recommendation suggesting the configuration location is deprecated.

**Impact:**
- Low risk Insights recommendation appears in console
- No actual impact on Insights Operator functionality
- Operator continues to work correctly with Secret-based configuration
- Recommendation appears in Insights Advisor dashboard

**Root Cause:**
Despite documentation mentioning ConfigMap migration in OCP 4.15+, the Insights Operator implementation in OCP 4.20 still expects and reads from the `support` Secret, not a ConfigMap. The operator code has not been updated to match the documentation change, making this a false-positive recommendation.

**Status:**
- **JIRA:** TBD (documentation vs implementation mismatch)
- **Reported:** Internal observation during OCP 4.20 testing
- **Workaround:** Recommendation disabled in Insights configuration
- **Fix ETA:** Unknown (requires operator code update or documentation correction)

**Mitigation Applied:**

**Insights Configuration** (GitOps-managed):
```yaml
# Location: components/openshift-config/base/openshift-config-secret-support.yaml
insights:
  disabled_recommendations:
    - rule_id: "ccx_rules_ocp.external.rules.io_415_change_config_location"
```

**Verification:**
```bash
# Verify Insights Operator reads from Secret (not ConfigMap)
oc get secret support -n openshift-config
oc get configmap support -n openshift-config 2>/dev/null || echo "ConfigMap does not exist (expected)"

# Check Insights Operator deployment environment/volume mounts
oc get deployment insights-operator -n openshift-insights -o yaml | grep -A5 "support"

# View disabled recommendations
oc get secret support -n openshift-config -o jsonpath='{.data.config\.yaml}' | base64 -d

# Verify recommendation no longer appears (24-48 hours after disabling)
# View in Red Hat Hybrid Cloud Console:
# https://console.redhat.com/openshift/insights/advisor/clusters/<CLUSTER_ID>
# The io_415_change_config_location recommendation should not appear
```

**Important:**
- **Use Secret, not ConfigMap**: Despite OCP 4.15+ documentation, operator still expects Secret in 4.20
- Testing confirmed operator does NOT read from ConfigMap
- This may change in future OCP versions - monitor release notes
- Changes persist across cluster upgrades

---

### 3. MachineConfigPool maxUnavailable Configuration

**Recommendation:** `MachineConfigPool will never finish updating when the 'unavailableMachineCount' is greater than 'maxUnavailable' in the MachineConfigPool`
**Rule ID:** `ccx_rules_ocp.external.rules.machineconfigpool_maxunavailable`
**Component:** Machine Config Operator
**Risk Level:** Moderate
**Namespace:** N/A (cluster-wide configuration)

**Issue:**
Insights flags MachineConfigPools with `maxUnavailable: null` (which defaults to 1) as potentially problematic, warning that updates may never complete if unavailableMachineCount exceeds maxUnavailable. However, both master and worker pools are fully updated with unavailableMachineCount=0, indicating no actual issue.

**Impact:**
- Moderate risk Insights recommendation appears in console
- No actual impact on cluster updates or node management
- MachineConfigPools update normally with default maxUnavailable=1
- Recommendation appears in Insights Advisor dashboard
- False-positive when pools are fully updated

**Root Cause:**
The Insights rule checks for the presence of explicit `maxUnavailable` configuration but flags it as an issue when the field is null (relying on defaults). The default behavior (maxUnavailable=1) is correct for controlled, rolling updates and the recommendation fires even when no nodes are unavailable (unavailableMachineCount=0).

**Status:**
- **JIRA:** TBD (Insights rule false-positive)
- **Reported:** 2026-04-07 during cluster deployment
- **Workaround:** Recommendation disabled in Insights configuration + Alertmanager routing/silence
- **Fix ETA:** Unknown (requires Insights rule refinement to check actual unavailableMachineCount)

**Mitigation Applied:**

**Insights Configuration** (GitOps-managed):
```yaml
# Location: components/openshift-config/base/openshift-config-secret-support.yaml
insights:
  disabled_recommendations:
    - rule_id: "ccx_rules_ocp.external.rules.machineconfigpool_maxunavailable"
```

**Alertmanager Routing** (GitOps-managed):
```yaml
# Location: components/cluster-monitoring/base/openshift-monitoring-secret-alertmanager-main.yaml
routes:
  - matchers:
      - alertname = InsightsRecommendationActive
      - description =~ .*MachineConfigPool.*unavailableMachineCount.*maxUnavailable.*
    receiver: 'null'
    continue: false
```

**Alertmanager Silence** (Automated via GitOps Job):
- **Created by:** `openshift-monitoring-job-create-alert-silences.yaml` (PostSync hook)
- **Duration:** 10 years from cluster deployment
- **Created by:** argocd-automation
- **Effect:** Alert shows as "suppressed" in web console
- **Automation:** Runs automatically on every cluster deployment

**Verification:**
```bash
# Check MachineConfigPool status
oc get mcp master worker -o json | jq -r '.items[] | {
  name: .metadata.name, 
  maxUnavailable: .spec.maxUnavailable, 
  machineCount: .status.machineCount, 
  unavailableMachineCount: .status.unavailableMachineCount
}'

# Expected:
# master: maxUnavailable=null (defaults to 1), unavailableMachineCount=0
# worker: maxUnavailable=null (defaults to 1), unavailableMachineCount=0

# View disabled recommendations
oc get secret support -n openshift-config -o jsonpath='{.data.config\.yaml}' | base64 -d

# Verify recommendation no longer appears (24-48 hours after disabling)
# View in Red Hat Hybrid Cloud Console:
# https://console.redhat.com/openshift/insights/advisor/clusters/<CLUSTER_ID>
# The machineconfigpool_maxunavailable recommendation should not appear
```

**Important:**
- **Default is correct**: null maxUnavailable defaults to 1, which is appropriate for rolling updates
- **False-positive detection**: Recommendation fires even when unavailableMachineCount=0
- Explicitly setting `maxUnavailable: 1` would silence the Insights rule but is unnecessary
- Insights recommendations may take 24-48 hours to refresh after disabling
- Changes persist across cluster upgrades

---

## Known Functional Bugs (No Alert Silence Required)

Functional bugs that impact features but do not generate Prometheus alerts. No Alertmanager silence needed.

---

### CM-412 — CertManager CR does not create deployments when deployed via OpenShift GitOps

**Component:** cert-manager-operator v1.18.1
**JIRA:** [CM-412](https://redhat.atlassian.net/browse/CM-412) — In Progress / assigné à Bharath B (bhb@redhat.com)
**Status:** Open since 2024-10-22, no fix version yet
**Affects:** Any OCP cluster deploying cert-manager via GitOps (ArgoCD)

**Two failure modes confirmed:**

1. **Initial install (original CM-412):** ArgoCD creates CertManager CR → operator gets `StatusNotFound` → tries to CREATE CR (already exists) → race condition → deployments never created. All `*-deploymentDegraded=False` but `Ready Replicas=0`, no pods.

2. **Running cluster (new, reported 2026-06-24):** On a healthy cluster (~5h uptime), `controller-deploymentAvailable` condition disappears transiently → `DefaultCertManager` reconciler fires → deletes all 3 deployments → tries to CREATE CR → `already exists` → reconciliation crashes → cert-manager completely headless.

**Workaround (both modes):**
```bash
oc delete certmanager cluster --ignore-not-found
# ~25 seconds later: all 3 pods Running again
```

**Our GitOps workaround:** Permanent watchdog Deployment (`watchdog-certmanager`) in `components/cert-manager/base/` — detects stuck state and deletes CR to trigger recovery. Fixed 2026-06-24: `set -e` bug + false positive on transient condition.

---

### CRW-11483 — devworkspace-webhook-server DWOC nodeSelector not applied via GitOps

**Component:** DevWorkspace Operator (DWO) v0.41.0
**JIRA:** [CRW-11483](https://redhat.atlassian.net/browse/CRW-11483) — New / Major
**Status:** Open (2026-06-24)
**Affects:** Any OCP cluster with infra nodes deploying DWO via GitOps (ArgoCD)

**Root cause:** Timing race — OLM installs operator at T=0, creates webhook deployment without nodeSelector. ArgoCD applies DWOC 2m43s later. The controller-manager webhook management runs ONLY at startup (no reconciliation loop). `oc rollout restart` is annulled by OLM (new ReplicaSet stays at 0 replicas).

**Manual workaround (documented, not automated):** `oc delete pod` on the controller-manager (NOT rollout restart). OLM recreates it, new startup reads DWOC, webhook deployment recreated with infra nodeSelector.

**⚠️ Hack removed by policy (2026-08-08):** the GitOps Job that automated this (`devworkspace-placement-fixer` in `components/webterminal/overlays/ai/`) has been deleted. This is a deliberate decision, not a fix — the project no longer carries automated infra-node-placement remediation hacks. **CRW-11483 is still open and unfixed upstream** (confirmed no movement as of this date); on a fresh cluster deploy, `devworkspace-webhook-server` will land without the infra nodeSelector again, with no automatic correction. Apply the manual workaround above if strict infra-only placement is required.

**Related:** CRW-6232 (feature added), CRW-9297 (closed), CRW-7584 (affinity, To Do)

---

### SRVKP-12579 — tekton-results-postgres StatefulSet nodeSelector not propagated (SRVKP-9205 fix incomplete)

**Component:** OpenShift Pipelines 1.22.3 — Tekton Results
**JIRA:** [SRVKP-12579](https://redhat.atlassian.net/browse/SRVKP-12579) — Dev Complete
**Related:** [SRVKP-9205](https://redhat.atlassian.net/browse/SRVKP-9205) — ✅ **Fixed and confirmed live on this cluster** (2026-08-08), despite Jira showing "Release Pending" / fixVersion `Pipelines 1.20.5` as not yet released — same silent-backport pattern seen elsewhere in this doc (e.g. RHOAIENG-54605).
**Status:** Open — StatefulSet gap only

**Root cause:** SRVKP-9205 fix (PR #2909) propagated `nodeSelector`/`tolerations` to Tekton Results **Deployments** but NOT to the `tekton-results-postgres` **StatefulSet**. The TektonInstallerSet generates postgres with `nodeSelector=None` even when `TektonConfig.spec.config.nodeSelector` is set.

**Live confirmation (2026-08-08) — this is not dormant, it's actively happening right now, no test setup needed:**
- `tekton-results-api`, `tekton-results-watcher`, `tekton-results-retention-policy-agent` Deployments all have explicit `nodeSelector: {node-role.kubernetes.io/infra: ""}` set (verified via `oc get deployment ... -o jsonpath='{.spec.template.spec.nodeSelector}'`, not just coincidental pod placement) → correctly scheduled on infra nodes ✅ — **SRVKP-9205 confirmed genuinely fixed here.**
- `tekton-results-postgres` StatefulSet's `nodeSelector` field is **empty** → pod `tekton-results-postgres-0` is running on a plain worker node (`ip-10-0-77-68`, role `worker` only) ❌ — **SRVKP-12579 confirmed still broken.**

**No hack for this — deliberate policy (2026-08-08):** this project does not carry automated infra-node-placement remediation hacks. Tracking continues via this doc only; no Job will be added to patch `tekton-results-postgres` onto infra nodes even once SRVKP-12579 ships.

---

### OCPBUGS-105277 — Cluster autoscaler over-provisions a second GPU node before device-plugin capacity appears

**Component:** Cluster Autoscaler (cluster-autoscaler 1.33.0)
**JIRA:** [OCPBUGS-105277](https://redhat.atlassian.net/browse/OCPBUGS-105277) — New
**Status:** Open since 2026-08-06, no fix version yet
**Affects:** Any OCP cluster with a GPU MachineSet scaled from 0 via cluster-autoscaler + NVIDIA GPU Operator (e.g. `myocp-xvl7h-gpu-*`)

**Root cause:** A GPU node registers `Ready` (kubelet up) several minutes before the GPU Operator finishes installing drivers and the device plugin advertises `nvidia.com/gpu` in `.status.allocatable`. Cluster-autoscaler re-evaluates the still-pending pod against the "Ready but GPU-less" node, concludes it doesn't fit, and immediately scales the MachineSet again — provisioning a real, billed second GPU instance (`g4dn.12xlarge`) that sits idle. Confirmed via live reproduction: MachineSet scales 0→1 at T+0, node registers ~T+3m30s, pod flips back to unschedulable ~T+4m15s, cluster-autoscaler scales 1→2 at ~T+4m16s.

Our `cluster-api/accelerator: nvidia` label (the documented fix for [BZ#1943194](https://bugzilla.redhat.com/show_bug.cgi?id=1943194), already present on the GPU MachineSet template) only prevents mis-simulation during the scale-from-zero/unregistered phase — confirmed correct in logs (no premature scale-up while the node is still unregistered). It does not cover this post-registration race. Also tested `ClusterAutoscaler.spec.scaleUp.newPodScaleUpDelay` as a possible mitigation — confirmed via live test that it does not help (delays only the first scale-up, not the second).

**No workaround implemented.** `MachineAutoscaler.spec.maxReplicas: 2` on the GPU node group already bounds the blast radius to at most one wasted extra node, never worse. Dropping `maxReplicas` to 1 would eliminate the wasted node entirely for single-GPU-pod workloads, but was deliberately left at 2 to preserve the ability to scale to 2 concurrent GPU nodes if a benchmark ever needs it — revisit if this recurs often enough to change that trade-off.

---

### RHOAIENG-81202 — LLMInferenceService+LeaderWorkerSet Ready stuck at Progressing

**Component:** Red Hat OpenShift AI (RHOAI) 3.4.2 — KServe / LLMInferenceService controller
**JIRA:** [RHOAIENG-81202](https://redhat.atlassian.net/browse/RHOAIENG-81202) — New
**Status:** Open since 2026-08-05, no fix version yet
**Related:** [RHOAIENG-70416](https://redhat.atlassian.net/browse/RHOAIENG-70416) — same bug class, for the older `InferenceService.workerSpec` path — that fix does not cover the newer `LLMInferenceService`+`LeaderWorkerSet` reconciler regardless of its own status. Dormant on this cluster: `oc get inferenceservice -A` confirms zero InferenceServices of any kind are deployed (2026-08-08).
- ⚠️ **Jira/reality mismatch on RHOAIENG-70416 (confirmed 2026-08-08):** Jira shows Closed/Done, fixVersion `3.5 GA RHOAI RELEASE` (not yet released, target 2026-08-19), and a Konflux Release Team comment claims "Fixed in Konflux Advisory RHBA-2026:40009". The upstream PR ([kserve/kserve#5703](https://github.com/kserve/kserve/pull/5703)) did merge, but the **midstream** PR that actually needs to land in the fork RHOAI builds from — [opendatahub-io/kserve#1649](https://github.com/opendatahub-io/kserve/pull/1649) — failed its required CI checks (`e2e-predictor`, `e2e-llm-inference-service`) and was **closed without merging** on 2026-06-25, with no successful retest recorded afterward. The Konflux advisory comment's claim could not be verified against the actual code state — treat RHOAIENG-70416 as unresolved in the repo RHOAI builds from, not as genuinely fixed, until independently re-verified.

**Issue:** Deploying an `LLMInferenceService` with `spec.worker` set (triggers a `LeaderWorkerSet`-backed multi-node deployment) can leave `LLMInferenceService.status` conditions stuck at `Ready=Progressing` indefinitely, even after the underlying `LeaderWorkerSet` reports `Available: True` and all leader/worker pods are `Running`/`Ready`. Observed stuck for 9+ minutes with no further reconciliation.

**Root cause:** `pkg/controller/v1alpha2/llmisvc/controller.go` gates its `.Owns(&LeaderWorkerSet{})` watch registration behind a one-time `IsCrdAvailable()` check performed at controller-manager startup. If that check runs before the `LeaderWorkerSet` CRD is fully established/discoverable (plausible during a fresh install or operator-install ordering), the watch is never registered for that process's lifetime — status changes on the owned `LeaderWorkerSet` never trigger a re-reconcile of the parent `LLMInferenceService`.

**Workaround:** annotate the `LLMInferenceService` to force a fresh reconcile — resolves `Ready` to `True` immediately, confirming the underlying workload was already healthy.

**⚠️ Gap (2026-08-08):** this workaround is manual only — no GitOps Job automates the reconcile-forcing annotation. Any multi-node LLMInferenceService deployed on this cluster (RHOAI 3.4, matches the ticket's own environment) can get stuck at `Ready=Progressing` indefinitely with no self-healing.

---

### 2. KubeMemoryOvercommit — Large LLM Model Serving on Single GPU Node

**Alert Name:** `KubeMemoryOvercommit`
**Severity:** warning
**JIRA:** N/A — expected behavior, not a bug
**Status:** ⚠️ NOT silenced — visible in console, ignore manually when large LLM deployed

**Context:** When a large LLM (e.g., Mistral Medium 3.5 128B) is deployed on a single p4d.24xlarge GPU node with `memory request: 320Gi`, the cluster's total memory requests exceed what remaining nodes can absorb if the GPU node fails. This triggers `KubeMemoryOvercommit`.

This is **expected and by design** for a GPU lab/demo environment:
- The p4d node has 1.1 Ti allocatable RAM — far more than requested
- No other node can absorb a 320Gi GPU workload anyway (no failover GPU node)
- Fixing this would require a second p4d node (~$32/h) with no functional benefit for demos

**Why not silenced:** Silencing at cluster level would mask genuine memory pressure on worker nodes. Ignorable in GPU lab/demo context.

**How to identify:** Alert description mentions ~45G overcommit = 320Gi LLM request on p4d node.

---

### 1. LlamaStack Config Generates http:// URL for LLMInferenceService (HTTPS), Breaking Gen AI Playground

**JIRA:** [RHOAIENG-65719](https://redhat.atlassian.net/browse/RHOAIENG-65719)
**Status:** Open
**Affected versions:** RHOAI 3.4
**Affected components:** Gen AI Studio Playground, LlamaStack, LLMInferenceService

**Symptom:** When a `LLMInferenceService` model is added to the Gen AI Studio Playground, the model appears Ready and shows timing metrics (2-3s), but no response text is displayed. LlamaStack pod logs show `APIConnectionError: Connection error`.

**Root cause:** The controller auto-generating the `llama-stack-config` ConfigMap uses `http://` scheme unconditionally. For `LLMInferenceService`, the kserve workload service (`<name>-kserve-workload-svc`) exposes **HTTPS on port 8000** (not HTTP). For standard `InferenceService`, HTTP on port 8080 is correct — this bug is specific to `LLMInferenceService`.

**Workaround:**
```bash
NAMESPACE=<namespace>
LLMISVC_NAME=<llmisvc-name>
CURRENT=$(oc get configmap llama-stack-config -n $NAMESPACE -o jsonpath='{.data.config\.yaml}')
UPDATED=$(echo "$CURRENT" \
  | sed "s|http://${LLMISVC_NAME}-kserve-workload-svc|https://${LLMISVC_NAME}-kserve-workload-svc|g" \
  | sed 's|tls_verify: ${env.VLLM_TLS_VERIFY:=true}|tls_verify: ${env.VLLM_TLS_VERIFY:=false}|g')
oc patch configmap llama-stack-config -n $NAMESPACE --type=merge \
  -p "{\"data\":{\"config.yaml\":$(echo "$UPDATED" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}}"
oc rollout restart deployment/lsd-genai-playground -n $NAMESPACE
```

**⚠️ Gap (2026-08-08):** fix shipped in RHOAI 3.5 EA2 (released 2026-07-15) — newer than our RHOAI 3.4, so **not fixed on this cluster**. The patch above is documented but not wired into GitOps (no Job/CMP applies it automatically). Adding a `LLMInferenceService` model to the Gen AI Studio Playground on this cluster will break with `APIConnectionError` and require the manual patch every time until upgrading past 3.5 EA2.

**Live verification attempt (2026-08-08):** deployed a throwaway `LLMInferenceService` (Granite 3.1 8B quantized, single-pod, no `spec.worker` — manifest adapted from `openshift-sizeops/benchmarks/manifests/llmd-multinode-instance.yaml`) and confirmed the bug's precondition directly: `<name>-kserve-workload-svc` exposes `appProtocol: https` on port 8000, created immediately once the LLMInferenceService exists, independent of pod readiness. This matches the root cause exactly.

Could not complete the full end-to-end reproduction (an actual `APIConnectionError` via the Playground) — the "Add to Playground" UI flow hit a cascade of separate, apparently-unrelated Tech Preview bugs in the Gen AI Studio dashboard backend, each blocking on the last:
1. `GET /gen-ai/api/v1/lsd/models` returns a hard `500` instead of an empty list when no `LlamaStackDistribution` exists yet in the target namespace
2. After deploying a `LlamaStackDistribution` (requires an external Postgres backend — see `external-db-genai-playground`, added permanently to `components/rhoai/base/`), `GET /gen-ai/api/v1/aaa/models` still reported `llmInferenceServices=0` for the namespace despite the LLMInferenceService being genuinely `Ready=True`, even after labeling the namespace `opendatahub.io/dashboard=true` (the standard Data Science Project marker)
3. The frontend treats one namespace's `500` as fatal for the entire "AI asset endpoints" page across all namespaces, not just the failing one

None of these three have JIRA tickets filed — noted here only as context for why full reproduction stopped short. The structural evidence above (the `https`/port-8000 Service) combined with the confirmed-unreleased fix is treated as sufficient confirmation that this bug is real and unfixed on this cluster.

---

### OSSM-15257 — Sail Operator ClusterRoles missing aggregate-to-admin/edit labels (Telemetry resource ArgoCD OutOfSync)

**Component:** OpenShift Service Mesh 3 / Sail Operator (`istiod` Helm chart)
**JIRA:** [OSSM-15257](https://redhat.atlassian.net/browse/OSSM-15257) — New, filed 2026-08-08
**Related:** [OSSM-8132](https://redhat.atlassian.net/browse/OSSM-8132), [OSSM-8316](https://redhat.atlassian.net/browse/OSSM-8316) — same defect, closed 2024-11-08 on the claim OSSM 3 would fix it; our live repro shows it doesn't
**Affects:** `rh-connectivity-link` component's `Telemetry/namespace-metrics` resource in `openshift-ingress`

**Issue:** Sail Operator's Helm-installed ClusterRoles (`istiod-clusterrole-*`, `istio-reader-clusterrole-*`, `istiod-gateway-controller-*`) don't carry `rbac.authorization.k8s.io/aggregate-to-admin`/`aggregate-to-edit` labels, so any principal holding only the aggregated `admin`/`edit` ClusterRole in a namespace — including the ArgoCD Application Controller SA via `argocd.argoproj.io/managed-by` — can't create `*.istio.io` resources there. ArgoCD Application `rh-connectivity-link` showed `OutOfSync`/sync `Failed`: `telemetries.telemetry.istio.io is forbidden: ... cannot create resource "telemetries" in API group "telemetry.istio.io"`.

**Root cause:** confirmed via `oc get clusterrole -l 'rbac.authorization.k8s.io/aggregate-to-admin=true' -o name | grep istio` returning nothing on `istiod`/`istio-reader` ClusterRoles (OLM-managed ClusterRoles like `istiocsrs.operator.openshift.io` do carry the label — only the Helm/Sail-installed ones don't).

**Fix applied (this repo):** `components/rh-connectivity-link/base/openshift-ingress-role-telemetry-manager.yaml` + `openshift-ingress-rb-telemetry-manager.yaml` — a namespace-scoped `Role`/`RoleBinding` granting the ArgoCD Application Controller SA explicit permission on `telemetries.telemetry.istio.io` in `openshift-ingress`, bypassing the missing aggregation.

---

### RHOAIENG-82144 — MaaS payload-processing CrashLoopBackOff in openshift-ingress (missing NetworkPolicy)

**Component:** Red Hat OpenShift AI (RHOAI) 3.4.2 — ModelsAsService / MaaS Gateway, `payload-processing` (MaaS Inference Payload Processing / ext_proc)
**JIRA:** [RHOAIENG-82144](https://redhat.atlassian.net/browse/RHOAIENG-82144) — New, filed 2026-08-09
**Related:** [RHOAIENG-76928](https://redhat.atlassian.net/browse/RHOAIENG-76928) (sibling bug, same "MaaS NetworkPolicy allow-list drift" class, different namespace/destination — `maas-api`→PostgreSQL, not `payload-processing`→API server, already fixed for 3.5), [RHOAIENG-77945](https://redhat.atlassian.net/browse/RHOAIENG-77945) (epic: "Standardize NetworkPolicy ownership model"), [RHOAIENG-53206](https://redhat.atlassian.net/browse/RHOAIENG-53206) (documented in official 3.4/3.5 release notes — same failure shape for Spark Operator in `redhat-ods-applications`)
**Upstream fix (already merged, not yet in RHOAI 3.4.x):** [models-as-a-service#1105](https://github.com/opendatahub-io/models-as-a-service/pull/1105), [#1157](https://github.com/opendatahub-io/models-as-a-service/pull/1157), [#1179](https://github.com/opendatahub-io/models-as-a-service/pull/1179) — same open question asked upstream in [models-as-a-service#1090](https://github.com/opendatahub-io/models-as-a-service/issues/1090)

**Issue:** `openshift-ingress` on OCP 4.22+ ships a blanket deny-all `NetworkPolicy` (`openshift-ingress-deny-all`, `podSelector: {}`, no rules). RHOAI 3.4.x's MaaS Gateway deploys `payload-processing` pods into that namespace but doesn't yet deploy a matching allow-list NetworkPolicy for them, so they crash-loop: `dial tcp 172.30.0.1:443: i/o timeout` reaching the Kubernetes API server, then `Could not wait for Cache to sync` → manager shuts down → CrashLoopBackOff (19+ restarts observed).

**Root cause:** confirmed via `oc get networkpolicy -n openshift-ingress` — none of the existing allow policies (`data-science-gateway-allow`, `istiod-allow`, `kube-auth-proxy`, `maas-default-gateway-allow`, `openshift-ai-inference-allow`, `router-default`) match `payload-processing`'s pod labels (`app: payload-processing`, `app.kubernetes.io/name: maas-api`), so it falls through to the pure deny-all.

**Fix applied (this repo):** `components/rhoai/base/TEMPORARY-FIX-openshift-ingress-networkpolicy-payload-processing.yaml` — the exact NetworkPolicy already merged upstream (ingress on 9004 from Istio-managed gateway pods + monitoring scrape, egress DNS + Kubernetes API 443/6443), applied early via GitOps until RHOAI 3.4.x ships it natively. Remove once RHOAI creates this NetworkPolicy itself (check for a `payload-processing` NetworkPolicy already present in `openshift-ingress` before removing).

---

## Adding New Alert Silences and Insights Disabling

This section covers how to silence both Prometheus alerts and disable Insights recommendations.

---

### Silencing Prometheus Alerts

When adding a new silence for a known Prometheus alert bug, follow this process:

### 1. Verify It's Actually a Bug

- [ ] Confirm the alert is a false positive
- [ ] Check if there's an actual service/functionality issue (if yes, FIX instead of silence)
- [ ] Search upstream issue trackers for existing reports
- [ ] Verify workaround doesn't exist (e.g., fix the ServiceMonitor instead)

### 2. Document the Bug

Add entry to this file with:
- Alert name and labels
- Component and namespace
- Detailed issue description
- Root cause analysis
- Impact assessment
- Upstream issue link (if filed)
- Verification commands

### 3. Add Alertmanager Silence

Edit: `components/cluster-monitoring/base/openshift-monitoring-secret-alertmanager-main.yaml`

```yaml
routes:
  # BUG: [Short description]
  # Component: [Operator/component name]
  # Issue: [Brief explanation]
  # Impact: [What happens if not silenced]
  # Status: [Bug tracker link or status]
  - matchers:
      - alertname = [AlertName]
      - [additional matchers for specificity]
    receiver: 'null'
    continue: false
```

**Important:**
- Place silence routes at the **top** of the routes list (evaluated first)
- Use specific matchers (namespace, service, pod) to avoid over-silencing
- Set `continue: false` to prevent alert from matching other routes
- Add inline comments explaining the silence

### 4. Commit and Sync

```bash
git add KNOWN_BUGS.md components/cluster-monitoring/base/openshift-monitoring-secret-alertmanager-main.yaml
git commit -m "Add silence for [AlertName] - [component] known bug"
git push

# Verify ArgoCD sync
oc get application cluster-monitoring -n openshift-gitops

# Wait for Alertmanager pods to reload (~30 seconds)
oc get pods -n openshift-monitoring -l app.kubernetes.io/name=alertmanager -w
```

### 5. Create Alertmanager Silence (IMPORTANT!)

**CRITICAL:** Routing to `null` receiver prevents notifications but **does NOT hide the alert from the web console**. You MUST create an Alertmanager silence to actually suppress the alert in the UI.

```bash
# Create silence payload (10-year duration)
cat > /tmp/alert-silence.json <<EOF
{
  "matchers": [
    {
      "name": "alertname",
      "value": "[AlertName]",
      "isRegex": false,
      "isEqual": true
    },
    {
      "name": "namespace",
      "value": "[namespace]",
      "isRegex": false,
      "isEqual": true
    },
    {
      "name": "[additional-matcher-key]",
      "value": "[additional-matcher-value]",
      "isRegex": false,
      "isEqual": true
    }
  ],
  "startsAt": "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)",
  "endsAt": "$(date -u -d '+10 years' +%Y-%m-%dT%H:%M:%S.000Z)",
  "createdBy": "admin",
  "comment": "Known bug: [Short description] - See KNOWN_BUGS.md"
}
EOF

# Apply silence via Alertmanager API
oc port-forward -n openshift-monitoring alertmanager-main-0 9093:9093 &
PORT_FORWARD_PID=$!
sleep 3
curl -X POST -H "Content-Type: application/json" --data @/tmp/alert-silence.json \
  http://localhost:9093/api/v2/silences
kill $PORT_FORWARD_PID
```

**Example for Apicurio Registry UI:**
```bash
cat > /tmp/apicurio-silence.json <<EOF
{
  "matchers": [
    {
      "name": "alertname",
      "value": "PodDisruptionBudgetAtLimit",
      "isRegex": false,
      "isEqual": true
    },
    {
      "name": "poddisruptionbudget",
      "value": "apicurio-studio-ui-poddisruptionbudget",
      "isRegex": false,
      "isEqual": true
    },
    {
      "name": "namespace",
      "value": "apicurio",
      "isRegex": false,
      "isEqual": true
    }
  ],
  "startsAt": "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)",
  "endsAt": "$(date -u -d '+10 years' +%Y-%m-%dT%H:%M:%S.000Z)",
  "createdBy": "admin",
  "comment": "Known bug: Apicurio Registry UI single-replica PDB triggers false-positive alert (JIRA: APICURIO-24) - See KNOWN_BUGS.md"
}
EOF

oc port-forward -n openshift-monitoring alertmanager-main-0 9093:9093 &
PORT_FORWARD_PID=$!
sleep 3
curl -X POST -H "Content-Type: application/json" --data @/tmp/apicurio-silence.json \
  http://localhost:9093/api/v2/silences
kill $PORT_FORWARD_PID
```

**Why Both Routing AND Silence?**

1. **Routing to `null`** (in alertmanager.yaml):
   - ✅ Prevents notifications (email, Slack, PagerDuty)
   - ✅ GitOps-managed (survives cluster upgrades)
   - ❌ Alert still shows as "active" in console

2. **Alertmanager Silence** (via API):
   - ✅ Hides alert from web console (state: "suppressed")
   - ✅ Persisted to Alertmanager PVC
   - ⚠️ Not GitOps-managed (ephemeral, expires after 10 years)
   - ⚠️ Lost if Alertmanager PVC is deleted

**You need BOTH to fully silence an alert.**

### 6. Verify Silence Works

```bash
# Check Alertmanager configuration loaded
oc logs -n openshift-monitoring alertmanager-main-0 -c alertmanager | grep -i "reload"

# Verify silence is active
oc exec -n openshift-monitoring alertmanager-main-0 -c alertmanager -- \
  wget -q -O- 'http://localhost:9093/api/v2/silences' | \
  jq '.[] | select(.comment | contains("[your-keyword]"))'

# Verify alert is suppressed (not just active)
oc exec -n openshift-monitoring alertmanager-main-0 -c alertmanager -- \
  wget -q -O- 'http://localhost:9093/api/v2/alerts' | \
  jq '.[] | select(.labels.alertname == "[AlertName]") | {state: .status.state, silencedBy: .status.silencedBy}'

# Should show: "state": "suppressed", "silencedBy": ["<silence-id>"]
```

---

### Disabling Insights Recommendations

When adding a new disabled Insights recommendation, follow this process:

#### 1. Verify It's Actually a False Positive

- [ ] Confirm the recommendation is incorrect or not applicable
- [ ] Check if there's an actual configuration issue that should be fixed
- [ ] Search JIRA for existing bug reports
- [ ] Verify the recommendation appears in Insights Advisor dashboard

#### 2. Document the Recommendation

Add entry to this file's "Disabled Insights Recommendations" section with:
- Recommendation text and rule ID
- Component and namespace (if applicable)
- Detailed issue description
- Root cause analysis
- Impact assessment
- JIRA ticket link
- Verification commands

#### 3. Add to Insights Configuration

Edit: `components/openshift-config/base/openshift-config-secret-support.yaml`

```yaml
insights:
  disabled_recommendations:
    # JIRA: [JIRA-TICKET]
    # Component: [Component name]
    # Rule: [short rule name]
    # Issue: [Brief explanation]
    # Impact: [What happens if not disabled]
    # Reason: [Why it's disabled]
    - rule_id: "ccx_rules_ocp.external.rules.[rule_id]"
```

**Important:**
- Add clear inline comments for each disabled rule
- Include JIRA ticket reference
- Use the full rule_id from Insights console URL
- Place new rules at the bottom of the disabled list
- **Note:** Despite OCP 4.15+ documentation mentioning ConfigMap, the Insights Operator in OCP 4.20 still uses Secret

#### 4. Commit and Sync

```bash
git add KNOWN_BUGS.md components/openshift-config/base/openshift-config-secret-support.yaml
git commit -m "Disable Insights recommendation [rule_id] - [JIRA ticket]"
git push

# Verify ArgoCD sync
oc get application openshift-config -n openshift-gitops

# Wait for Secret to be created/updated
oc get secret support -n openshift-config
```

#### 5. Verify Recommendation Disabled

```bash
# Check support Secret exists
oc get secret support -n openshift-config

# View disabled recommendations
oc get secret support -n openshift-config -o jsonpath='{.data.config\.yaml}' | base64 -d

# Check Insights Operator logs for configuration reload
oc logs -n openshift-insights deployment/insights-operator --tail=50 | grep -i "disabled\|reload"

# Wait 24-48 hours for Insights to refresh
# Then verify in Red Hat Hybrid Cloud Console:
# https://console.redhat.com/openshift/insights/advisor/clusters/<CLUSTER_ID>
# The recommendation should no longer appear or be marked as disabled
```

**Important:**
- Insights recommendations may take 24-48 hours to refresh after configuration change
- The recommendation may still appear but marked as "disabled by user"
- Changes persist across cluster upgrades
- Insights Operator must restart to pick up configuration changes

---

## Audit Script

Periodically run this script to ensure no secrets have leaked into the Alertmanager configuration:

```bash
#!/bin/bash
# scripts/audit_alertmanager_secrets.sh

echo "Auditing Alertmanager configuration for sensitive data..."

CONFIG_FILE="components/cluster-monitoring/base/openshift-monitoring-secret-alertmanager-main.yaml"

# Patterns that might indicate secrets
PATTERNS=(
    "api_key"
    "api_token"
    "auth_token"
    "password"
    "secret"
    "webhook.*http"
    "slack_api_url"
    "pagerduty_url"
    "victorops_api_key"
    "opsgenie_api_key"
    "email.*password"
)

FOUND=0

for pattern in "${PATTERNS[@]}"; do
    if grep -iE "$pattern" "$CONFIG_FILE" | grep -v "# " | grep -v "stringData:"; then
        echo "⚠️  WARNING: Potential secret found matching pattern: $pattern"
        FOUND=1
    fi
done

if [ $FOUND -eq 0 ]; then
    echo "✅ No sensitive patterns detected in Alertmanager configuration"
else
    echo ""
    echo "❌ AUDIT FAILED: Secrets detected in Alertmanager configuration!"
    echo "Remove sensitive data and use Secret references instead."
    exit 1
fi
```

Make executable and run:
```bash
chmod +x scripts/audit_alertmanager_secrets.sh
./scripts/audit_alertmanager_secrets.sh
```

---

## Removal Criteria

Remove a silence from this configuration when:

1. ✅ Upstream bug is fixed and operator updated
2. ✅ ServiceMonitor is corrected
3. ✅ Component is removed from cluster
4. ✅ Alert is no longer firing for 30+ days after bug fix

Always verify the fix before removing the silence:

```bash
# Check alert history
oc exec -n openshift-monitoring prometheus-k8s-0 -c prometheus -- \
  wget -q -O- 'http://localhost:9090/api/v1/query?query=ALERTS{alertname="[AlertName]"}[7d]'

# If no results for 7+ days, safe to remove silence
```

---

## Review Schedule

- **Weekly:** Check if silenced alerts have been fixed upstream
- **Monthly:** Review this document and update bug statuses
- **Quarterly:** Run audit script and verify all silences are still necessary

Last reviewed: 2026-05-07
