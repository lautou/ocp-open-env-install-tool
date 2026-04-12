#!/bin/bash
# oc Retry Wrapper for Certificate Rotation
# Purpose: Retry oc commands ONLY on transient API errors (certificate rotation, connection issues)
# Usage: Source this file in Job scripts, then use oc_retry instead of oc

# CRITICAL: Only retries TRANSIENT errors. Does NOT retry:
# - NotFound (expected in wait loops)
# - Forbidden (RBAC issue, won't fix with retry)
# - Invalid (syntax error, won't fix with retry)

# Retry wrapper for oc commands
# Handles ONLY transient errors:
# - "x509: certificate signed by unknown authority" (cert rotation)
# - "connection refused" (API server restart)
# - "EOF" (network blip)
# - "timeout" (network slowness)
oc_retry() {
  local max_attempts=5
  local timeout=2
  local attempt=1
  local exit_code=0
  local output=""

  while [ $attempt -le $max_attempts ]; do
    # Capture output and exit code
    output=$(oc "$@" 2>&1)
    exit_code=$?

    # Success - return immediately
    if [ $exit_code -eq 0 ]; then
      echo "$output"
      return 0
    fi

    # Check if error is TRANSIENT (should retry)
    # CRITICAL: Do NOT retry NotFound, Forbidden, Invalid, etc.
    if echo "$output" | grep -qE "certificate signed by unknown authority|connection refused|EOF|i/o timeout|context deadline exceeded"; then
      # Transient error - retry
      if [ $attempt -lt $max_attempts ]; then
        echo "  ⚠️  Transient error (attempt $attempt/$max_attempts): $(echo "$output" | tail -1)" >&2
        echo "  Retrying in ${timeout}s..." >&2
        sleep $timeout
        # Exponential backoff
        timeout=$((timeout * 2))
        attempt=$((attempt + 1))
      else
        echo "  ❌ Max retries reached. Last error: $(echo "$output" | tail -1)" >&2
        echo "$output"
        return $exit_code
      fi
    else
      # Non-transient error (NotFound, Forbidden, etc.) - fail immediately
      # This is CRITICAL for infinite loop patterns!
      echo "$output"
      return $exit_code
    fi
  done

  echo "$output"
  return $exit_code
}

# Read-only wrapper (uses --insecure-skip-tls-verify for reads)
# Use this for read-only operations that are safe to skip TLS verification
# CRITICAL: Also respects NotFound errors (doesn't retry)
oc_retry_read() {
  local max_attempts=5
  local timeout=2
  local attempt=1
  local output=""
  local exit_code=0

  while [ $attempt -le $max_attempts ]; do
    # Try with normal TLS first
    output=$(oc "$@" 2>&1)
    exit_code=$?

    # Success - return immediately
    if [ $exit_code -eq 0 ]; then
      echo "$output"
      return 0
    fi

    # Check error type
    if echo "$output" | grep -q "certificate signed by unknown authority"; then
      # TLS error - try with --insecure-skip-tls-verify
      output=$(oc --insecure-skip-tls-verify "$@" 2>&1)
      exit_code=$?
      if [ $exit_code -eq 0 ]; then
        echo "$output"
        return 0
      fi
    fi

    # Check if error is transient (connection issues)
    if echo "$output" | grep -qE "connection refused|EOF|i/o timeout|context deadline exceeded"; then
      # Transient error - retry
      if [ $attempt -lt $max_attempts ]; then
        echo "  ⚠️  Retry attempt $attempt/$max_attempts: $(echo "$output" | tail -1)" >&2
        sleep $timeout
        timeout=$((timeout * 2))
        attempt=$((attempt + 1))
      else
        echo "  ❌ Max retries reached. Last error: $(echo "$output" | tail -1)" >&2
        echo "$output"
        return $exit_code
      fi
    else
      # Non-transient error (NotFound, Forbidden, etc.) - fail immediately
      echo "$output"
      return $exit_code
    fi
  done

  echo "$output"
  return $exit_code
}

# Export functions so they can be used in scripts
export -f oc_retry
export -f oc_retry_read
