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

### 1. Apicurio Registry UI PodDisruptionBudgetAtLimit

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

### 2. Kuadrant istio-pod-monitor TargetDown

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

### 3. insights-runtime-extractor KubeDaemonSetMisScheduled (Race Condition with Infra Taint)

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

### 4. ODFNodeMTULessThan9000 (ovs-system internal device, not a real NIC)

**Alert Name:** `ODFNodeMTULessThan9000`
**Component:** OpenShift Data Foundation (ODF) — `ocs-metrics-exporter` alert rule
**Severity:** info

**Issue:**
The alert's PromQL (`count(node_network_mtu_bytes{device!~"^(veth|docker|flannel|cali|tun|tap).*"} < 9000) > 0`) scans every non-excluded network interface on every node, not just the interface(s) ODF actually uses for storage traffic. It fires on `ovs-system` — OVN-Kubernetes's internal OVS datapath housekeeping device, present on every node by design, fixed at MTU 1500, carrying no real traffic — because that device isn't covered by the rule's exclusion regex.

**Live confirmation on this cluster (2026-08-18):** re-verified live against the exact alert expression across all 12 nodes — every single match is `device="ovs-system"`, value `1500`. No other device anywhere on the cluster is below 9000:
- Host NIC (`ens5`): **9001** on all 12 nodes (masters/workers/infra/storage)
- OVN-Kubernetes overlay/pod network: **8901** (correct ~100-byte Geneve encapsulation offset)
- `ovs-system`: **1500** — the sole trigger

**Impact:**
- False-positive info-severity `ODFNodeMTULessThan9000` alert
- No actual MTU misconfiguration — every real, traffic-carrying interface is correctly jumbo-framed

**Root Cause:**
`ovs-system` exists on any OVN-Kubernetes cluster (the default CNI for modern OpenShift) regardless of platform, so this is a broad false-positive, not something specific to this cluster's config. Confirmed via Red Hat's own ODF engineering team as an acknowledged, unfixed gap in the alert rule's device exclusion list — see Status below.

**Status:**
- **JIRA:** [DFBUGS-5761](https://redhat.atlassian.net/browse/DFBUGS-5761) — Assigned, unfixed. Long thread with multiple unrelated customers (bare-metal, VMware, telco) hitting the same structural false positive for different device classes (unused bare-metal NICs/bridges, telco VLAN sub-interfaces, Multus dedicated-network topology mismatches). None of the prior reports name `ovs-system` specifically — added as a new data point via comment on 2026-08-18, since it demonstrates the bug also affects the simplest possible ODF/OVN-Kubernetes deployment shape (plain cloud install, no Multus, no bare-metal, no VLANs), not just exotic networking topologies.
- **JIRA:** [DFBUGS-6835](https://redhat.atlassian.net/browse/DFBUGS-6835) — New, unfixed, effectively a duplicate of the same rule-scoping problem.
- **Reported:** DFBUGS-5761 opened 2026-02-25, DFBUGS-6835 opened 2026-05-08. Red Hat engineer (Yati Padia) confirmed 2026-07-18: *"we need to modify specific devices on which ocs-metrics-exporter should raise alert"* — acknowledged but no fix version yet.
- **⚠️ Caveat on the JIRA's suggested workaround:** a comment recommends `oc patch storagecluster ocs-storagecluster ... spec.monitoring.excludedAlerts`. Verified directly against this cluster's live CRD (ODF 4.22.1) — the field's own description states *"Alerts still fire in Prometheus but are excluded from health score"*. This only affects the ODF Health Score/Overview dashboard, **not** Alertmanager/console alerting — it does not actually suppress the alert. Use the standard Alertmanager routing+silence pattern below instead for real suppression.
- **Fix ETA:** TBD — pending upstream change to the alert rule's device exclusion regex (suggested fix: add `ovs-system` to `^(veth|docker|flannel|cali|tun|tap).*`)

**Mitigation Applied:**

1. **Routing Configuration** (GitOps-managed):
   ```yaml
   # Location: components/cluster-monitoring/base/openshift-monitoring-secret-alertmanager-main.yaml
   routes:
     - matchers:
         - alertname = ODFNodeMTULessThan9000
       receiver: 'null'
       continue: false
   ```

2. **Alertmanager Silence** (Automated via GitOps Job):
   - **Created by:** `openshift-gitops-job-create-alert-silences.yaml` (regular Job, `Force=true` only)
   - **Duration:** 10 years from cluster deployment
   - **Created by:** argocd-automation

**Verification:**
```bash
# Confirm ovs-system is the sole device tripping the alert's own expression
oc exec -n openshift-monitoring prometheus-k8s-0 -c prometheus -- \
  wget -q -O- 'http://localhost:9090/api/v1/query?query=node_network_mtu_bytes%7Bdevice%21~%22%5E%28veth%7Cdocker%7Cflannel%7Ccali%7Ctun%7Ctap%29.%2A%22%7D%20%3C%209000'

# Confirm the alert is suppressed
oc exec -n openshift-monitoring statefulset/alertmanager-main -c alertmanager -- \
  amtool alert query --alertmanager.url=http://localhost:9093 | grep -i ODFNodeMTU
```

---

## Disabled Insights Recommendations

Red Hat Insights provides cloud-based analysis and recommendations for OpenShift clusters. Some recommendations may be false positives or known issues tracked in JIRA.

**⚠️ There is no local per-recommendation disable field.** Confirmed 2026-08-09 against the actual `openshift/insights-operator` source (`pkg/config/legacy_config.go` for the legacy `support` Secret, `pkg/config/types.go` for the current `insights-config` ConfigMap): neither schema has ever had a `disabled_recommendations`-style field, only a global `disableInsightsAlerts`/`alerting.disabled` on/off switch for *all* recommendations. Recommendations are generated cloud-side and sent back as Prometheus metrics (`insights_recommendation_active`); the only thing that actually suppresses the resulting local alert is **Alertmanager routing + a silence** (see each entry below). Suppressing a specific recommendation on the Red Hat Hybrid Cloud Console's Advisor dashboard itself requires that UI's own "Disable recommendation" button — out of GitOps' reach.

**Real Insights Operator configuration** (distinct from recommendation suppression — for actual operator settings like `dataReporting`, `alerting`, `sca`, `proxy`): `components/openshift-insights/base/openshift-insights-cm-insights-config.yaml`, its own dedicated core component (`components/openshift-insights/`, registered in `gitops-bases/core/applicationset.yaml`, with a `Namespace` manifest carrying `argocd.argoproj.io/managed-by: openshift-gitops` so ArgoCD can manage it without a manual RBAC grant — same pattern as `openshift-config`/`openshift-ingress`). The legacy `support` Secret in `openshift-config` was removed 2026-08-09 — it only ever carried the non-functional `disabled_recommendations` list. (The recommendation that prompted creating the ConfigMap — `io_415_change_config_location` — was fixed and confirmed cleared from the Advisor dashboard the same day; its Alertmanager routing rule and API silence were removed too since it wasn't an upstream bug, just a gap in our own setup that can't recur.)

---

### 1. MachineConfigPool maxUnavailable Configuration

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
- **Workaround:** Alertmanager routing/silence for the local alert
- **Fix ETA:** Unknown (requires Insights rule refinement to check actual unavailableMachineCount)

**Mitigation Applied:**

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

# Verify the alert is suppressed locally
oc exec -n openshift-monitoring alertmanager-main-0 -c alertmanager -- \
  wget -q -O- 'http://localhost:9093/api/v2/alerts' | \
  jq '.[] | select(.labels.alertname == "InsightsRecommendationActive" and (.labels.description // "" | test("MachineConfigPool.*maxUnavailable"))) | {state: .status.state}'

# Cloud-side recommendation display (separate surface, not affected by the above):
# https://console.redhat.com/openshift/insights/advisor/clusters/<CLUSTER_ID>
```

**Important:**
- **Default is correct**: null maxUnavailable defaults to 1, which is appropriate for rolling updates
- **False-positive detection**: Recommendation fires even when unavailableMachineCount=0
- Explicitly setting `maxUnavailable: 1` would silence the Insights rule but is unnecessary

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
**Related:** [SRVKP-9205](https://redhat.atlassian.net/browse/SRVKP-9205) — ✅ **Fixed and confirmed live on this cluster** (2026-08-08), despite Jira showing "Release Pending" / fixVersion `Pipelines 1.20.5` as not yet released — same silent-backport pattern seen elsewhere in this doc (e.g. RHOAIENG-70416, where the reverse happened: Jira claimed Closed/Done but the midstream PR was never actually merged).
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

---

### OCPBUGS-100168 — check-endpoints TargetDown in openshift-apiserver (NetworkPolicy missing port 17698)

**Component:** OCP 4.22 platform — `cluster-openshift-apiserver-operator`
**JIRA:** [OCPBUGS-100168](https://redhat.atlassian.net/browse/OCPBUGS-100168) — Status `POST` (4.22.z backport in progress, not yet released; backport approved 2026-07-29, still no shipped fix version as of 2026-08-07)
**Upstream fix (verified for 5.0, not yet backported to 4.22):** [PR #719](https://github.com/openshift/cluster-openshift-apiserver-operator/pull/719) (`bindata/v3.11.0/openshift-apiserver/networkpolicy-allow.yaml`) — also reported independently at [cluster-openshift-apiserver-operator#718](https://github.com/openshift/cluster-openshift-apiserver-operator/issues/718)

**Alert:** `TargetDown` — "100% of the check-endpoints/check-endpoints targets in openshift-apiserver namespace have been unreachable for more than 15 minutes."

**Issue:** the platform-shipped `allow-apiserver` NetworkPolicy in `openshift-apiserver` only opens ingress on port 8443 (the API server port). The `check-endpoints` sidecar container (part of every `openshift-apiserver` pod) listens on port 17698, which no NetworkPolicy allows, so Prometheus's scrape of it times out. The apiserver itself is unaffected — confirmed live: all `openshift-apiserver` pods `Running 2/2`, all nodes `Ready`, the `api` job (port 8443) is `up`; only `check-endpoints` (port 17698) targets are `down` with `context deadline exceeded`.

**Root cause:** confirmed via `oc get networkpolicy allow-apiserver -n openshift-apiserver -o yaml` — ingress rule only lists `port: 8443`, nothing for 17698. `default-deny` in the same namespace drops everything else.

**Fix applied (this repo):** `components/openshift-config/base/TEMPORARY-FIX-openshift-apiserver-networkpolicy-allow-check-endpoints-monitoring.yaml` — an additive NetworkPolicy opening port 17698 to namespaces labeled `network.openshift.io/policy-group: monitoring` (matches both `openshift-monitoring` and `openshift-user-workload-monitoring`), for pods labeled `apiserver: "true"`. This is the exact workaround from the original bug report, confirmed there to resolve the alert. Remove once OCP 4.22.z ships a build where `allow-apiserver` itself includes port 17698.

**RBAC dependency:** `openshift-apiserver` isn't labeled `argocd.argoproj.io/managed-by` (it's a system namespace, not one this repo creates), so the ArgoCD Application Controller SA had no permission to create a `NetworkPolicy` there — same RBAC-gap class as OSSM-15257 above. Added `openshift-apiserver-role-networkpolicy-manager.yaml` + `openshift-apiserver-rb-networkpolicy-manager.yaml`, scoped narrowly to `networkpolicies.networking.k8s.io` only (not a broad `edit`/`admin` grant), given the sensitivity of this namespace.

---

### LOG-9695 / LOG-9336 / LOG-9829 — Vector collector "Too many open files" causing CollectorNodeDown / OOMKilled (OCPBUGS-62095 ulimit regression)

**Component:** Red Hat OpenShift Logging 6.6.0 — Vector collector (DaemonSet `instance`)
**JIRA:** [LOG-9695](https://redhat.atlassian.net/browse/LOG-9695) — New, unfixed, filed 2026-07-24, exact match to our environment (OCP 4.22.4 + Logging 6.6.0; ours: OCP 4.22.8 + Logging 6.6.0). [LOG-9336](https://redhat.atlassian.net/browse/LOG-9336) — status POST, fix targeted for Logging 6.7.0 (unreleased). [LOG-9829](https://redhat.atlassian.net/browse/LOG-9829) — 6.6.z backport, status MODIFIED (code merged, awaiting QE/release as of 2026-08-17), fix version "Logging 6.6.z" not yet released.
**Root platform bug:** [OCPBUGS-62095](https://redhat.atlassian.net/browse/OCPBUGS-62095) — Closed/Done, fixVersion 4.20.0. Starting with freshly-installed OCP 4.20+/4.21+ clusters, the default container `ulimit -n` (max open files) dropped from 1,048,576 to 1024 — a deliberate CRI-O/platform change, documented in the 4.21 release notes as a known consequence requiring a workaround. Clusters *upgraded* from 4.20→4.21 keep the old high limit; only fresh installs get the new low default.
**Alert:** `CollectorNodeDown` (real condition, not a false positive — the collector genuinely crashes/restarts)
**Status:** Open upstream, no shipped fix for our version (Logging 6.6.0) as of 2026-08-18.

**Issue:** Vector needs one open file descriptor per actively-tailed container log file, plus fds for its Prometheus metrics listener and Loki sink connections. With the soft limit at 1024, nodes with high pod density exhaust available fds, producing repeated `Failed reading file for fingerprinting. ... error=Too many open files (os error 24)` errors. In some cases (confirmed in LOG-9695) this escalates to a `vector-worker` thread panic and `CrashLoopBackOff`.

**Live confirmation on this cluster (2026-08-18):** `CollectorNodeDown` firing for 3 collector pods (`instance-mqmww`, `instance-j9pr6`, `instance-lk5fz`), all on the 3 infra nodes (73-118 pods each, vs 36 on a regular worker). Kernel logs confirmed genuine memory-cgroup OOM kills (`Memory cgroup out of memory: Killed process ... (vector)`) at the container's 2Gi limit, matching the fd-exhaustion + Loki-sink-retry backpressure pattern described in the Jira tickets above. Node-level `MemoryPressure`/`DiskPressure` were `False` on all 3 — confirms the ceiling is the container's own resource limits, not host memory.

**Root cause:** OCPBUGS-62095's platform-wide ulimit reduction (1024) is too low for Vector's file-tailing workload on pod-dense nodes; no released Logging build yet raises Vector's own ulimit at startup (planned fix: `ulimit -Sn "$(ulimit -Hn)"` in `run-vector.sh`, landing in 6.6.z/6.7.0).

**Fix applied (this repo):** `components/openshift-logging/base/TEMPORARY-FIX-cluster-machineconfig-99-worker-crio-ulimit-nofile.yaml` — a MachineConfig targeting the `worker` MachineConfigPool (this cluster has no separate `infra` MCP; infra/storage nodes are worker-role too) that drops a `/etc/crio/crio.conf.d/99-default-ulimits.conf` snippet raising CRI-O's default container nofile soft limit from 1024 to 65536 (well under the 524288 hard limit). Applies to every container on every worker-role node, not just the collector — the underlying platform regression affects any container, not just Vector (see the kourier-gateway example cited in OCPBUGS-62095).

**⚠️ Applying this MachineConfig triggers a rolling reboot of every node in the `worker` MachineConfigPool** (all 9 nodes on this cluster: 3 infra + 3 storage + 3 regular workers), one at a time, via the Machine Config Operator. Confirmed live 2026-08-18: rollout completed in ~27 minutes, all 3 previously-crash-looping infra collectors (`mqmww`/`j9pr6`/`lk5fz`) had zero further restarts after picking up the new ulimit.

**Master nodes are not immune — confirmed live during the worker rollout (2026-08-18):** the master-node collector `instance-98fp5` (`ip-10-0-36-145`) hit the exact same fd exhaustion mid-rollout — `up=0`/`connection refused` on its metrics port, `/proc/1/limits` showing `Max open files=1024`, logs flooded with `Too many open files (os error 24)` on file fingerprinting, checkpoint writes, and even outbound Loki sink connections. Trigger: a burst of local log-file churn (repeated `kube-rbac-proxy-crio` restarts) on that master during the mass worker-pool reboot pushed it past the 1024-fd ceiling, despite masters normally running far fewer pods than infra nodes. **Fix applied (this repo):** `components/openshift-logging/base/TEMPORARY-FIX-cluster-machineconfig-99-master-crio-ulimit-nofile.yaml` — identical MachineConfig targeting the `master` MachineConfigPool. Triggers a rolling reboot of all 3 control-plane nodes (MCO sequences these one at a time, etcd-quorum-aware).

**Remove when:** Logging 6.6.z (LOG-9829) or 6.7.0 (LOG-9336) ships with Vector's self-raise-ulimit fix, confirmed on this cluster's installed version — or OCPBUGS-62095's default is revisited upstream. Remove both the worker and master MachineConfigs together.

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

**There is no local per-recommendation config field** (verified against `openshift/insights-operator` source, see the section intro above) — an `InsightsRecommendationActive` alert is silenced exactly the same way as any other Prometheus alert: via the "Silencing Prometheus Alerts" process earlier in this document (Alertmanager routing to `null` + a Job-created API silence). The only Insights-specific part is the matcher: since every recommendation shares the same `alertname`, match on `description =~ <regex fragment unique to the recommendation text>` instead of a rule-ID field.

When adding a new one:

1. **Verify it's actually a false positive** — confirm the recommendation is incorrect/not applicable for this environment (if it's a real issue, fix it instead of silencing it).
2. **Document it** in this file's "Disabled Insights Recommendations" section: recommendation text, rule ID (for reference only — not used as a matcher), root cause, JIRA link.
3. **Add the Alertmanager routing + silence** following the "Silencing Prometheus Alerts" steps above, with `alertname = InsightsRecommendationActive` plus a `description =~ ...` matcher.
4. **Note the limitation:** this only suppresses the local alert (OCP console "Alerting" page). It does not remove the recommendation from the Red Hat Hybrid Cloud Console's Advisor dashboard — that requires that UI's own "Disable recommendation" action.

If the recommendation is about genuine Insights Operator *configuration* (not a specific rule finding — e.g. an upload endpoint, proxy, or the Secret→ConfigMap migration), that's a different thing: edit `components/openshift-insights/base/openshift-insights-cm-insights-config.yaml` per the documented `insights-config` ConfigMap schema instead.

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
