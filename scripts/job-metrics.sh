#!/bin/bash
# Job Metrics for Prometheus
# Purpose: Export Job execution metrics in Prometheus format
# Usage: Source this file in Job scripts, wrap your work with metric tracking

# Metrics are written to /dev/termination-log which Kubernetes exposes
# Can be scraped by ServiceMonitor or read from Job status

# Initialize metrics tracking
job_metrics_init() {
  export JOB_START_TIME=$(date +%s)
  export JOB_NAME="${JOB_NAME:-$(hostname)}"
  export JOB_NAMESPACE="${JOB_NAMESPACE:-unknown}"
  export JOB_WAIT_START_TIME=0
  export JOB_TOTAL_WAIT_TIME=0
  export JOB_RETRY_COUNT=0
}

# Start tracking dependency wait time
job_metrics_wait_start() {
  local dependency_name="${1:-unknown}"
  export JOB_CURRENT_DEPENDENCY="$dependency_name"
  export JOB_WAIT_START_TIME=$(date +%s)
  echo "  ⏱️  Started waiting for: $dependency_name" >&2
}

# End tracking dependency wait time
job_metrics_wait_end() {
  if [ "$JOB_WAIT_START_TIME" -gt 0 ]; then
    local wait_end_time=$(date +%s)
    local wait_duration=$((wait_end_time - JOB_WAIT_START_TIME))
    JOB_TOTAL_WAIT_TIME=$((JOB_TOTAL_WAIT_TIME + wait_duration))
    echo "  ✅ Dependency ready after ${wait_duration}s: $JOB_CURRENT_DEPENDENCY" >&2
    export JOB_WAIT_START_TIME=0
  fi
}

# Increment retry counter
job_metrics_retry() {
  JOB_RETRY_COUNT=$((JOB_RETRY_COUNT + 1))
}

# Export final metrics to /dev/termination-log (Kubernetes reads this)
job_metrics_export() {
  local exit_code="${1:-0}"
  local job_end_time=$(date +%s)
  local job_duration=$((job_end_time - JOB_START_TIME))
  local job_work_time=$((job_duration - JOB_TOTAL_WAIT_TIME))

  # Determine status
  local status="success"
  if [ "$exit_code" -ne 0 ]; then
    status="failure"
  fi

  # Write metrics in Prometheus format
  cat > /dev/termination-log <<EOF
# HELP job_duration_seconds Total time Job ran (includes wait time)
# TYPE job_duration_seconds gauge
job_duration_seconds{job="$JOB_NAME",namespace="$JOB_NAMESPACE",status="$status"} $job_duration

# HELP job_wait_time_seconds Time spent waiting for dependencies
# TYPE job_wait_time_seconds gauge
job_wait_time_seconds{job="$JOB_NAME",namespace="$JOB_NAMESPACE"} $JOB_TOTAL_WAIT_TIME

# HELP job_work_time_seconds Actual work time (duration minus wait time)
# TYPE job_work_time_seconds gauge
job_work_time_seconds{job="$JOB_NAME",namespace="$JOB_NAMESPACE"} $job_work_time

# HELP job_retry_count Number of retries performed
# TYPE job_retry_count counter
job_retry_count{job="$JOB_NAME",namespace="$JOB_NAMESPACE"} $JOB_RETRY_COUNT

# HELP job_completion_timestamp_seconds Unix timestamp when Job completed
# TYPE job_completion_timestamp_seconds gauge
job_completion_timestamp_seconds{job="$JOB_NAME",namespace="$JOB_NAMESPACE",status="$status"} $job_end_time
EOF

  # Also echo to stdout for debugging
  echo ""
  echo "======================================"
  echo "Job Metrics Summary"
  echo "======================================"
  echo "Job: $JOB_NAME"
  echo "Namespace: $JOB_NAMESPACE"
  echo "Status: $status"
  echo "Total Duration: ${job_duration}s"
  echo "Wait Time: ${JOB_TOTAL_WAIT_TIME}s"
  echo "Work Time: ${job_work_time}s"
  echo "Retries: $JOB_RETRY_COUNT"
  echo "======================================"
}

# Wrapper for oc_retry that tracks retries
oc_retry_with_metrics() {
  local attempt=1
  local max_attempts=5

  while [ $attempt -le $max_attempts ]; do
    if oc "$@" 2>&1; then
      return 0
    else
      if [ $attempt -lt $max_attempts ]; then
        job_metrics_retry
        attempt=$((attempt + 1))
        sleep 2
      else
        return 1
      fi
    fi
  done
}

# Example usage wrapper
job_metrics_wrap() {
  # Initialize metrics
  job_metrics_init

  # Set trap to export metrics on exit
  trap 'job_metrics_export $?' EXIT

  # Your job logic goes here
  # Use job_metrics_wait_start/end around wait loops
  # Use job_metrics_retry when retrying operations
}

# Export functions
export -f job_metrics_init
export -f job_metrics_wait_start
export -f job_metrics_wait_end
export -f job_metrics_retry
export -f job_metrics_export
export -f job_metrics_wrap
export -f oc_retry_with_metrics
