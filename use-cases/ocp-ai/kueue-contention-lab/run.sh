#!/bin/bash
# Kueue contention lab: submits 3 suspended Jobs to exercise quota contention
# and priority ordering on the shared-cluster-queue ClusterQueue.
# Requires the ocp-ai profile (rhoai + kueue components) to be deployed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

JOBS="lab-job-1-low:ai-team-b lab-job-2-low:ai-team-b lab-job-3-high:ai-team-a"

echo "==> Removing any previous run of these Jobs (ignored if absent)"
for job_ns in $JOBS; do
  job="${job_ns%%:*}"
  ns="${job_ns##*:}"
  oc delete job "$job" -n "$ns" --ignore-not-found=true
done

echo ""
echo "==> Submitting Job 1 (low-priority, team-b, consumes the full nominal quota)"
oc create -f "$SCRIPT_DIR/job-1-low-team-b.yaml"

echo ""
echo "==> Submitting Job 2 (low-priority, team-b, queues behind Job 1)"
oc create -f "$SCRIPT_DIR/job-2-low-team-b.yaml"

echo ""
echo "==> Submitting Job 3 (high-priority, team-a, same shared ClusterQueue)"
oc create -f "$SCRIPT_DIR/job-3-high-team-a.yaml"

echo ""
echo "==> Done. Watch admission order with:"
echo "    oc get workloads.kueue.x-k8s.io -A"
echo "    oc get clusterqueue shared-cluster-queue -o wide"
echo "    oc get pods -l batch.kubernetes.io/job-name -A -w"
