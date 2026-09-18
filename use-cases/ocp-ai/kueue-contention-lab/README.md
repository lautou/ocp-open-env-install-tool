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
(`withinClusterQueue: Never`) applies: **Job 3 will not preempt the already-running Job 1**.
What priority *does* affect is the order Kueue admits pending workloads in — once Job 1
completes (~60s) and quota frees up, Job 3 (high-priority) is admitted before Job 2
(low-priority), even though Job 2 was queued first. That reordering of the two pending jobs
is the actual contention/priority effect this lab demonstrates.

## Run

```bash
./run.sh
```

Re-running is safe — it deletes any previous run's Jobs first.

## Cleanup

```bash
oc delete job lab-job-1-low -n ai-team-b --ignore-not-found=true
oc delete job lab-job-2-low -n ai-team-b --ignore-not-found=true
oc delete job lab-job-3-high -n ai-team-a --ignore-not-found=true
```
