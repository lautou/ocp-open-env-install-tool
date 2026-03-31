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

### 1. mlflow-operator Broken Metrics Endpoint

**Alert Name:** `TargetDown`
**Component:** Red Hat OpenShift AI (RHOAI) - MLflow Operator
**Namespace:** `redhat-ods-applications`
**Service:** `mlflow-operator-controller-manager-metrics-service`

**Issue:**
The mlflow-operator ServiceMonitor targets a metrics endpoint that doesn't exist or is not properly exposed by the operator controller manager. This causes Prometheus to fail scraping, triggering continuous TargetDown alerts.

**Impact:**
- False-positive TargetDown alerts
- No actual impact on MLflow functionality
- Operator functions normally despite missing metrics

**Root Cause:**
Upstream bug in mlflow-operator v2.0.0 - ServiceMonitor configuration doesn't match actual controller manager endpoints.

**Status:**
- **JIRA:** [RHOAIENG-54791](https://redhat.atlassian.net/browse/RHOAIENG-54791) - mlflow-operator ServiceMonitor targets non-existent metrics endpoint causing continuous TargetDown alerts
- **Reported:** Red Hat internal bug tracker
- **Workaround:** Alert routed to null receiver + Alertmanager silence active
- **Fix ETA:** TBD (pending upstream resolution)

**Mitigation Applied:**

1. **Routing Configuration** (GitOps-managed):
   ```yaml
   # Location: components/cluster-monitoring/base/openshift-monitoring-secret-alertmanager-main.yaml
   routes:
     - matchers:
         - alertname = TargetDown
         - service = mlflow-operator-controller-manager-metrics-service
         - namespace = redhat-ods-applications
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
# Check if ServiceMonitor still exists
oc get servicemonitor -n redhat-ods-applications -l app.kubernetes.io/name=mlflow-operator

# Check Prometheus targets status
oc exec -n openshift-user-workload-monitoring prometheus-user-workload-0 -c prometheus -- \
  wget -q -O- 'http://localhost:9090/api/v1/targets' | \
  jq '.data.activeTargets[] | select(.labels.service == "mlflow-operator-controller-manager-metrics-service")'
```

---

### 2. llama-stack-k8s-operator PodDisruptionBudgetAtLimit

**Alert Name:** `PodDisruptionBudgetAtLimit`
**Component:** Red Hat OpenShift AI (RHOAI) - Llama Stack Operator
**Namespace:** `redhat-ods-applications`
**PodDisruptionBudget:** `llama-stack-k8s-operator-controller-manager-pdb`

**Issue:**
The llama-stack-k8s-operator PodDisruptionBudget is configured with `minAvailable: 1` but only 1 replica exists, resulting in 0 allowed disruptions. This triggers the PodDisruptionBudgetAtLimit alert even though the configuration is intentional for the operator's high availability requirements.

**Impact:**
- False-positive PodDisruptionBudgetAtLimit alerts
- No actual impact on operator functionality
- Operator controller manager runs normally with single replica

**Root Cause:**
PDB configuration in llama-stack-k8s-operator expects potential multi-replica deployment but currently runs with single replica, causing the allowed disruptions to be 0 which triggers the alert threshold.

**Status:**
- **JIRA:** [RHAIENG-3783](https://redhat.atlassian.net/browse/RHAIENG-3783)
- **Reported:** Red Hat internal bug tracker
- **Workaround:** Alert routed to null receiver + Alertmanager silence active
- **Fix ETA:** TBD (pending upstream resolution)

**Mitigation Applied:**

1. **Routing Configuration** (GitOps-managed):
   ```yaml
   # Location: components/cluster-monitoring/base/openshift-monitoring-secret-alertmanager-main.yaml
   routes:
     - matchers:
         - alertname = PodDisruptionBudgetAtLimit
         - poddisruptionbudget = llama-stack-k8s-operator-controller-manager-pdb
         - namespace = redhat-ods-applications
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
oc get pdb llama-stack-k8s-operator-controller-manager-pdb -n redhat-ods-applications -o yaml

# Check allowed disruptions
oc get pdb llama-stack-k8s-operator-controller-manager-pdb -n redhat-ods-applications \
  -o jsonpath='{.status.disruptionsAllowed}{"\n"}'

# Expected: 0 (triggers the alert)
```

---

### 3. NooBaa Database PodDisruptionBudgetAtLimit

**Alert Name:** `PodDisruptionBudgetAtLimit`
**Component:** OpenShift Data Foundation (ODF) - NooBaa
**Namespace:** `openshift-storage`
**PodDisruptionBudget:** `noobaa-db-pg-cluster-primary`

**Issue:**
The NooBaa PostgreSQL database PodDisruptionBudget is configured with `minAvailable: 1` but only 1 replica exists (single-replica database), resulting in 0 allowed disruptions. This triggers the PodDisruptionBudgetAtLimit alert even though the configuration is intentional for database high availability requirements.

**Impact:**
- False-positive PodDisruptionBudgetAtLimit alerts
- No actual impact on NooBaa or ODF functionality
- Database operates normally with single replica and proper PDB protection

**Root Cause:**
PDB configuration in NooBaa expects single-replica PostgreSQL deployment with `minAvailable: 1`, which mathematically results in 0 allowed disruptions (1 available - 1 required = 0). This is correct behavior for protecting a single-replica database but triggers the alert threshold.

**Status:**
- **JIRA:** [DFBUGS-5294](https://redhat.atlassian.net/browse/DFBUGS-5294)
- **Reported:** Red Hat internal bug tracker
- **Workaround:** Alert routed to null receiver + Alertmanager silence active
- **Fix ETA:** TBD (pending upstream resolution)

**Mitigation Applied:**

1. **Routing Configuration** (GitOps-managed):
   ```yaml
   # Location: components/cluster-monitoring/base/openshift-monitoring-secret-alertmanager-main.yaml
   routes:
     - matchers:
         - alertname = PodDisruptionBudgetAtLimit
         - poddisruptionbudget = noobaa-db-pg-cluster-primary
         - namespace = openshift-storage
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
oc get pdb noobaa-db-pg-cluster-primary -n openshift-storage -o yaml

# Check allowed disruptions
oc get pdb noobaa-db-pg-cluster-primary -n openshift-storage \
  -o jsonpath='{.status.disruptionsAllowed}{"\n"}'

# Expected: 0 (triggers the alert)

# Check database replica count
oc get statefulset noobaa-db-pg -n openshift-storage \
  -o jsonpath='{.spec.replicas}{"\n"}'

# Expected: 1 (single replica)
```

---

### 4. Apicurio Registry UI PodDisruptionBudgetAtLimit

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

### 5. Kuadrant istio-pod-monitor TargetDown

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
Kueue webhooks perform complex validation logic for queue management and workload scheduling that requires more than 13 seconds to complete, especially in large clusters with many queue resources. The extended timeout is intentional and necessary for proper operation.

**Status:**
- **JIRA:** [OCPKUEUE-578](https://redhat.atlassian.net/browse/OCPKUEUE-578)
- **Reported:** Red Hat internal bug tracker
- **Workaround:** Recommendation disabled in Insights configuration
- **Fix ETA:** TBD (pending upstream resolution)

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

**Example for mlflow-operator:**
```bash
cat > /tmp/mlflow-silence.json <<EOF
{
  "matchers": [
    {
      "name": "alertname",
      "value": "TargetDown",
      "isRegex": false,
      "isEqual": true
    },
    {
      "name": "service",
      "value": "mlflow-operator-controller-manager-metrics-service",
      "isRegex": false,
      "isEqual": true
    },
    {
      "name": "namespace",
      "value": "redhat-ods-applications",
      "isRegex": false,
      "isEqual": true
    }
  ],
  "startsAt": "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)",
  "endsAt": "$(date -u -d '+10 years' +%Y-%m-%dT%H:%M:%S.000Z)",
  "createdBy": "admin",
  "comment": "Known bug: mlflow-operator ServiceMonitor targets non-existent metrics endpoint (JIRA: RHOAIENG-54791) - See KNOWN_BUGS.md"
}
EOF

oc port-forward -n openshift-monitoring alertmanager-main-0 9093:9093 &
PORT_FORWARD_PID=$!
sleep 3
curl -X POST -H "Content-Type: application/json" --data @/tmp/mlflow-silence.json \
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

Last reviewed: 2026-03-19
