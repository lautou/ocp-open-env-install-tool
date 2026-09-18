# Kueue contention lab

Not GitOps-managed — this is an imperative test scenario, run manually against a live
`ocp-ai` profile cluster (needs the `kueue` component: `shared-cluster-queue`,
`default-flavor`, `high-priority`/`low-priority` WorkloadPriorityClasses, and the
`team-a-queue`/`team-b-queue` LocalQueues in `ai-team-a`/`ai-team-b`).

## What it does

`shared-cluster-queue` has a nominal quota of 4 CPU. Each Job below requests 4 CPU, so
only one can be admitted at a time.

1. `lab-job-1-low` (team-b, low-priority) — admitted immediately, consumes the full quota.
2. `lab-job-2-low` (team-b, low-priority) — queues behind Job 1, submitted first among the
   two pending jobs.
3. `lab-job-3-high` (team-a, high-priority) — submitted last, but higher priority.

## Expected behavior

`shared-cluster-queue` has no `preemption` policy configured, so Kueue's default
(`withinClusterQueue: Never`) applies: **Job 3 will not preempt an already-running Job**.
What priority *does* affect is the order Kueue admits pending workloads in. Confirmed live:
when all three Jobs are pending together, Kueue admits `lab-job-3-high` first even though
`lab-job-1-low`/`lab-job-2-low` were queued earlier — priority reorders admission among
pending jobs sharing the same ClusterQueue, regardless of which LocalQueue/team they came
from. Once the admitted job completes (~60s) and releases quota, the next-highest-priority
pending job is admitted next.

Whether an admitted Job's pod actually starts running also depends on real node capacity —
Kueue only manages logical quota. On a resource-constrained cluster the pod can stay
`Pending` on its own merits (check `oc describe pod` for scheduling failures); that's a
separate, expected constraint, not a lab failure.

## Run

```bash
./run.sh
```

Re-running is safe — it deletes any previous run's Jobs first.

**Note:** if the `kueue` component (or specifically the `Kueue` CR's `spec.config`) was just
updated via GitOps, the `kueue-controller-manager` pods restart and can take a couple of
minutes to re-elect a leader (`leaseDuration` is ~2m17s when both replicas restart at once).
Until a leader is active, submitted Jobs stay suspended with no Workload progress — this is
normal controller startup latency, not a broken setup.

## Cleanup

```bash
oc delete job lab-job-1-low -n ai-team-b --ignore-not-found=true
oc delete job lab-job-2-low -n ai-team-b --ignore-not-found=true
oc delete job lab-job-3-high -n ai-team-a --ignore-not-found=true
```
