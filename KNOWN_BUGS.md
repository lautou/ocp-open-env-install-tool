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
- **Reported:** TBD (create upstream issue if needed)
- **Workaround:** Alert routed to null receiver + Alertmanager silence active
- **Fix ETA:** Unknown

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

2. **Alertmanager Silence** (API-managed):
   - **Silence ID:** `32bf2d36-1079-496f-82cd-08bcdf3e7fa8`
   - **Created:** 2026-03-19
   - **Expires:** 2036-03-19 (10 years)
   - **Status:** Active
   - **Effect:** Alert shows as "suppressed" in web console

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

2. **Alertmanager Silence** (API-managed):
   - **Silence ID:** `536e82a8-2b95-4045-b286-52dc5d9d6045`
   - **Created:** 2026-03-19
   - **Expires:** 2036-03-19 (10 years)
   - **Status:** Active
   - **Effect:** Alert shows as "suppressed" in web console

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

## Adding New Bug Silences

When adding a new silence for a known bug, follow this process:

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
  "comment": "Known bug: mlflow-operator v2.0.0 broken metrics endpoint - See KNOWN_BUGS.md"
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
