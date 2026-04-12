#!/bin/bash
# oc Retry Wrapper for Certificate Rotation
# Purpose: Retry oc commands during transient API errors (certificate rotation, etc.)
# Usage: Source this file in Job scripts, then use oc_retry instead of oc

# Retry wrapper for oc commands
# Handles transient errors like:
# - "x509: certificate signed by unknown authority" (cert rotation)
# - "connection refused" (API server restart)
# - "EOF" (network blip)
oc_retry() {
  local max_attempts=5
  local timeout=2
  local attempt=1
  local exit_code=0

  while [ $attempt -le $max_attempts ]; do
    # Run the oc command
    if oc "$@" 2>&1; then
      return 0
    else
      exit_code=$?
    fi

    # Check if error is transient (cert/connection issues)
    local last_error=$(oc "$@" 2>&1 | tail -1)
    if echo "$last_error" | grep -qE "certificate signed by unknown authority|connection refused|EOF|timeout"; then
      if [ $attempt -lt $max_attempts ]; then
        echo "  ⚠️  Transient error (attempt $attempt/$max_attempts): $last_error" >&2
        echo "  Retrying in ${timeout}s..." >&2
        sleep $timeout
        # Exponential backoff
        timeout=$((timeout * 2))
        attempt=$((attempt + 1))
      else
        echo "  ❌ Max retries reached. Last error: $last_error" >&2
        return $exit_code
      fi
    else
      # Non-transient error, fail immediately
      return $exit_code
    fi
  done

  return $exit_code
}

# Read-only wrapper (uses --insecure-skip-tls-verify for reads)
# Use this for read-only operations that are safe to skip TLS verification
oc_retry_read() {
  local max_attempts=5
  local timeout=2
  local attempt=1

  while [ $attempt -le $max_attempts ]; do
    # Try with normal TLS first
    if oc "$@" 2>/dev/null; then
      return 0
    fi

    # Check if error is TLS-related
    local last_error=$(oc "$@" 2>&1 | tail -1)
    if echo "$last_error" | grep -q "certificate signed by unknown authority"; then
      # For read-only operations, we can safely skip TLS verification
      if oc --insecure-skip-tls-verify "$@" 2>&1; then
        return 0
      fi
    fi

    if [ $attempt -lt $max_attempts ]; then
      echo "  ⚠️  Retry attempt $attempt/$max_attempts: $last_error" >&2
      sleep $timeout
      timeout=$((timeout * 2))
      attempt=$((attempt + 1))
    else
      echo "  ❌ Max retries reached. Last error: $last_error" >&2
      return 1
    fi
  done

  return 1
}

# Export functions so they can be used in scripts
export -f oc_retry
export -f oc_retry_read
