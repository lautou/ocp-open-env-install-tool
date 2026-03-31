# Monitoring and Alert Management

**Purpose**: Comprehensive guide to OpenShift cluster monitoring, Alertmanager configuration, and alert silence management.

**Note**: Before working with monitoring, read [`known-bugs.md`](known-bugs.md) for details on known false-positive alerts.

## Alertmanager Configuration

The cluster Alertmanager (`alertmanager-main` in `openshift-monitoring`) is managed via GitOps in the `cluster-monitoring` component.

**Location:** `components/cluster-monitoring/base/openshift-monitoring-secret-alertmanager-main.yaml`

**Configuration includes:**
- **Global settings:** HTTP proxy, timeout values
- **Inhibit rules:** Suppress lower-severity alerts when higher-severity alerts are firing
- **Receivers:** Notification endpoints (Default, Watchdog, Critical, null)
- **Routes:** Alert routing logic and silences

## Alert Silences for Known Bugs

**IMPORTANT:** The project maintains a dedicated document for tracking known operator bugs that generate false-positive alerts.

**See:** [`known-bugs.md`](known-bugs.md) for comprehensive documentation of:
- Silenced alerts and their root causes
- Impact assessment and workarounds
- Upstream bug tracking status
- Verification commands
- Audit procedures

**Current silenced alerts:**
1. **mlflow-operator TargetDown** - RHOAI mlflow-operator v2.0.0 has broken metrics endpoint ServiceMonitor (JIRA: RHOAIENG-54791)
2. **llama-stack PodDisruptionBudgetAtLimit** - RHOAI llama-stack operator PDB with 1 replica (JIRA: RHAIENG-3783)
3. **NooBaa database PodDisruptionBudgetAtLimit** - ODF NooBaa single-replica PostgreSQL PDB (JIRA: DFBUGS-5294)
4. **InsightsRecommendationActive (webhook timeout)** - Kueue webhook timeout recommendation (JIRA: OCPKUEUE-578)
5. **InsightsRecommendationActive (config migration)** - Insights Operator config migration recommendation
6. **Kuadrant istio-pod-monitor TargetDown** - RHCL Kuadrant PodMonitor empty namespaceSelector (JIRA: CONNLINK-911)
7. **InsightsRecommendationActive (MCP maxUnavailable)** - Installer does not set explicit maxUnavailable in MachineConfigPools (JIRA: TBD)

## Adding New Alert Silences

**IMPORTANT:** To fully silence an alert, you need BOTH routing configuration AND an Alertmanager silence.

When a new false-positive alert is discovered:

1. **Verify it's actually a bug** (not a real issue requiring a fix)
2. **Document in known-bugs.md** with full details
3. **Add route to `null` receiver** in Alertmanager config (prevents notifications)
4. **Create Alertmanager silence via API** (hides from web console)
5. **Run audit script** to ensure no secrets leaked
6. **Commit** (known-bugs.md + alertmanager secret)

**Understanding Routing vs Silencing:**

There are two different mechanisms for suppressing alerts:

| Mechanism | Routing to `null` | Alertmanager Silence |
|-----------|------------------|---------------------|
| **What it does** | Routes alert to null receiver | Suppresses alert entirely |
| **Prevents notifications** | ✅ Yes (no email, Slack, etc.) | ✅ Yes |
| **Hides from console** | ❌ No (shows as "active") | ✅ Yes (shows as "suppressed") |
| **Managed by** | GitOps (alertmanager.yaml) | API (ephemeral state) |
| **Survives upgrades** | ✅ Yes (in Git) | ✅ Yes (persisted to PVC) |
| **Survives PVC deletion** | ✅ Yes | ❌ No |
| **Expires** | ❌ Never | ⚠️ After 10 years |

**You need BOTH:**
- Routing ensures no notifications even if silence expires
- Silence hides alert from console UI

**Example routing configuration:**
```yaml
# components/cluster-monitoring/base/openshift-monitoring-secret-alertmanager-main.yaml
routes:
  # BUG: [Short description]
  # Component: [Operator name]
  # Issue: [Root cause]
  # Impact: [What happens]
  # Status: [Bug tracker link]
  - matchers:
      - alertname = TargetDown
      - service = broken-metrics-service
      - namespace = operator-namespace
    receiver: 'null'
    continue: false
```

**Example silence creation:**
```bash
# Create silence payload (10-year duration)
cat > /tmp/alert-silence.json <<EOF
{
  "matchers": [
    {"name": "alertname", "value": "TargetDown", "isRegex": false, "isEqual": true},
    {"name": "service", "value": "broken-metrics-service", "isRegex": false, "isEqual": true},
    {"name": "namespace", "value": "operator-namespace", "isRegex": false, "isEqual": true}
  ],
  "startsAt": "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)",
  "endsAt": "$(date -u -d '+10 years' +%Y-%m-%dT%H:%M:%S.000Z)",
  "createdBy": "admin",
  "comment": "Known bug: [description] - See known-bugs.md"
}
EOF

# Apply via API
oc port-forward -n openshift-monitoring alertmanager-main-0 9093:9093 &
sleep 3
curl -X POST -H "Content-Type: application/json" \
  --data @/tmp/alert-silence.json http://localhost:9093/api/v2/silences
```

**See known-bugs.md for complete step-by-step instructions.**

## Automated Alert Silences via GitOps

**IMPORTANT:** Alert silences are now **fully automated** via an ArgoCD PostSync Job!

The manual silence creation steps above are kept for reference, but in practice, all known bug silences are created automatically when the cluster-monitoring component syncs.

**How it works:**

1. **PostSync Job** (`openshift-monitoring-job-create-alert-silences.yaml`):
   - Runs automatically after cluster-monitoring ApplicationSet syncs
   - Waits for Alertmanager StatefulSet and pods to be fully ready
   - **Additional 30-second stabilization wait** (ensures API is fully initialized)
   - Creates 10-year silences via Alertmanager API for all known bugs
   - **Retry logic**: 3 attempts per silence with 5-second delays
   - **Verification**: Confirms each silence was created successfully via API query
   - **Final validation**: Verifies 5+ active silences exist before completing
   - **Fails loudly**: Job fails if any silence creation fails (no silent failures)

2. **RBAC Resources**:
   - ServiceAccount: `create-alert-silences`
   - Role: permissions for pods/portforward and statefulsets
   - RoleBinding: connects SA to Role

3. **Known bugs silenced automatically**:
   - mlflow-operator TargetDown (broken metrics endpoint) (JIRA: RHOAIENG-54791)
   - llama-stack PodDisruptionBudgetAtLimit (JIRA: RHAIENG-3783)
   - NooBaa database PodDisruptionBudgetAtLimit (JIRA: DFBUGS-5294)
   - InsightsRecommendationActive (webhook timeout) (JIRA: OCPKUEUE-578)
   - InsightsRecommendationActive (config migration)

**Reliability Improvements (2026-03-23):**

The Job was improved to address timing issues that caused silent failures:

**Problem:** Original Job used `|| true` to mask failures and had no verification. When Alertmanager wasn't fully initialized, silences failed to create but Job reported success.

**Fixed:**
- ✅ **Removed `|| true`** - Failures now propagate properly
- ✅ **Added pod readiness check** - Waits for pods to be Running AND Ready
- ✅ **Added 30-second stabilization wait** - Ensures Alertmanager API is fully initialized
- ✅ **Added retry logic** - 3 attempts per silence with exponential backoff
- ✅ **Added verification** - Queries API to confirm silence exists after creation
- ✅ **Added final validation** - Counts active silences and fails if < 5
- ✅ **Better logging** - Clear success/failure messages for each silence

**Benefits:**
- ✅ **Zero manual intervention** on new cluster deployments
- ✅ **No false-positive alerts visible** from first cluster-admin login
- ✅ **GitOps-managed** - Job is version controlled and reproducible
- ✅ **Fully automated** - works reliably across all environments
- ✅ **Self-healing** - Automatic retry on transient failures
- ✅ **Verifiable** - Job exit code reflects actual success/failure

**Location:** `components/cluster-monitoring/base/openshift-monitoring-job-create-alert-silences.yaml`

**Implementation:** Uses `openshift/cli` image with native bash tools (grep/sed) to parse JSON API responses - no external dependencies required.

## Security - No Secrets in Alertmanager Config

**⚠️ CRITICAL:** The Alertmanager configuration is stored in Git and must NOT contain sensitive data.

**Prohibited:**
- ❌ API tokens or keys
- ❌ Webhook URLs with embedded credentials
- ❌ Email/Slack/PagerDuty passwords
- ❌ Any authentication secrets

**Allowed:**
- ✅ Routing logic (matchers, grouping)
- ✅ Alert silences
- ✅ Inhibit rules
- ✅ Empty receiver placeholders

**Audit script:** `scripts/audit_alertmanager_secrets.sh` (see known-bugs.md)

If you need to add actual notification receivers with credentials:
1. Use Kubernetes Secret references in receiver config
2. Store credentials in separate Secrets (not in alertmanager.yaml)
3. Keep alertmanager.yaml credential-free for GitOps

## Alertmanager Behavior

**After changes:**
1. ArgoCD syncs the Secret to cluster
2. Cluster Monitoring Operator detects change
3. Alertmanager pods reload config (~30 seconds)
4. New routes/silences become active
5. Verify in Alertmanager logs: `oc logs -n openshift-monitoring alertmanager-main-0 -c alertmanager`

**Operator interaction:**
- ✅ Cluster Monitoring Operator will NOT reset this Secret (documented exception)
- ✅ Configuration persists across operator restarts and upgrades
- ✅ ArgoCD manages the Secret exclusively (don't use `oc edit`)

## User Workload Monitoring

The project does NOT enable a separate user-workload Alertmanager instance. All alerts (platform + user-defined) route through the cluster Alertmanager (`alertmanager-main`).

**Configuration:** `components/user-workload-monitoring/base/openshift-user-workload-monitoring-configmap-user-workload-monitoring-config.yaml`

**Key settings:**
- Alertmanager storage (10Gi PVC)
- Prometheus storage (40Gi PVC)
- Infrastructure node placement for all components
- **No** dedicated Alertmanager instance (`alertmanager.enabled: false` - default)

## Red Hat Insights Recommendations

Red Hat Insights provides cloud-based analysis and recommendations for OpenShift clusters. Recommendations generate `InsightsRecommendationActive` alerts in the cluster that must be suppressed via Alertmanager.

**Configuration:**
- `components/openshift-config/base/openshift-config-secret-support.yaml` (documentation only)
- `components/cluster-monitoring/base/openshift-monitoring-secret-alertmanager-main.yaml` (alert routing)
- `components/cluster-monitoring/base/openshift-monitoring-job-create-alert-silences.yaml` (automated silences)

**How It Works:**
- Insights Operator runs in `openshift-insights` namespace
- Periodically scans cluster configuration and sends data to Red Hat cloud service
- Red Hat cloud service analyzes data and sends recommendations back to cluster
- Recommendations generate `InsightsRecommendationActive` alerts with `severity: info`
- Recommendations appear in **Red Hat Hybrid Cloud Console**: https://console.redhat.com/openshift/insights/advisor
- **Note:** Insights UI is NOT in local OpenShift web console (only in Red Hat cloud console)
- **CRITICAL:** `disabled_recommendations` in `support` Secret does NOT suppress alerts (documentation only)
- **Alerts must be suppressed via Alertmanager** (routing to null receiver + API silences)

**Suppressing InsightsRecommendationActive Alerts:**

**CRITICAL:** The `disabled_recommendations` field in the `support` Secret does NOT suppress alerts in the OpenShift console. The Red Hat cloud service generates recommendations regardless of local configuration and sends them back to the cluster as Prometheus metrics.

**Working approach** (implemented):

1. **Alertmanager Routing** - Routes alerts to null receiver (prevents notifications):
   ```yaml
   # components/cluster-monitoring/base/openshift-monitoring-secret-alertmanager-main.yaml
   - matchers:
       - alertname = InsightsRecommendationActive
       - description =~ .*webhook.*timeout.*13s.*
     receiver: 'null'
   ```

2. **Alertmanager API Silences** - Fully suppresses alerts (state: "suppressed"):
   - Created automatically by PostSync Job
   - 10-year duration, persisted to Alertmanager PVC
   - Recreated on every cluster deployment
   - See: `components/cluster-monitoring/base/openshift-monitoring-job-create-alert-silences.yaml`

**Currently Suppressed Recommendations:**

1. **Kueue Webhook Timeout** - `webhook_timeout_is_larger_than_default`
   - JIRA: OCPKUEUE-578
   - Reason: Kueue requires extended timeout for complex validations
   - Suppression: Alertmanager routing + API silence

2. **Insights Operator Configuration Location** - `io_415_change_config_location`
   - Issue: Documentation suggests ConfigMap migration in OCP 4.15+
   - Reality: Insights Operator in OCP 4.20 still expects Secret (ConfigMap requires TechPreview feature gates)
   - Reason: Implementation hasn't been updated to match documentation
   - Suppression: Alertmanager routing + API silence

**Why disabled_recommendations doesn't work:**

The `support` Secret's `disabled_recommendations` field is intended to control what data the Insights Operator GATHERS, not what alerts appear in the cluster. However:
- OCP 4.20 appears to ignore this field (may require `InsightsConfig` feature gate)
- Even if honored, it only affects data gathering, not the alerts
- Red Hat cloud service analyzes whatever data it receives and sends recommendations back
- Recommendations become Prometheus metrics (`insights_recommendation_active`) which trigger alerts
- Only Alertmanager can suppress these alerts

**Configuration retained for documentation:**
```yaml
# components/openshift-config/base/openshift-config-secret-support.yaml
# NOTE: This does NOT suppress alerts - kept for documentation only
insights:
  disabled_recommendations:
    - rule_id: "ccx_rules_ocp.external.rules.webhook_timeout_is_larger_than_default"
    - rule_id: "ccx_rules_ocp.external.rules.io_415_change_config_location"
```

**Verification:**

```bash
# Check alert silences are active
oc port-forward -n openshift-monitoring alertmanager-main-0 9093:9093 &
sleep 3
curl -s http://localhost:9093/api/v2/silences | \
  grep -o '"comment":"[^"]*Insights[^"]*"'

# Check InsightsRecommendationActive alerts are suppressed
curl -s http://localhost:9093/api/v2/alerts | \
  python3 -c "import sys, json; alerts = json.load(sys.stdin); \
  [print(f\"{a['labels']['description'][:60]}... => {a['status']['state']}\") \
  for a in alerts if a['labels']['alertname'] == 'InsightsRecommendationActive']"

# Expected output: state should be "suppressed"
# The Insights Operator config has been migrated from secret t... => suppressed
# Configuring the webhook's timeout for Pod API exceeds 13s is... => suppressed

# Check automated silence Job logs
oc logs -n openshift-monitoring job/create-alert-silences | grep -i insights
```

**Insights Recommendations vs Standard Prometheus Alerts:**

| Aspect | Standard Prometheus Alerts | InsightsRecommendationActive Alerts |
|--------|---------------------------|-------------------------------------|
| **Source** | Cluster monitoring stack | Red Hat cloud service via Insights Operator |
| **Alert Suppression** | Alertmanager (routing + silences) | **Same:** Alertmanager (routing + silences) |
| **Management** | components/cluster-monitoring | components/cluster-monitoring |
| **Recommendation Visibility** | N/A | Red Hat console: console.redhat.com/openshift/insights |
| **Reload Time** | ~30 seconds (Alertmanager) | 24-48 hours (Red Hat cloud analysis) |
| **GitOps** | ✅ Partial (routing only, silences via Job) | ✅ Same (routing + automated Job silences) |
| **disabled_recommendations** | N/A | ❌ Does NOT suppress alerts (ineffective) |
