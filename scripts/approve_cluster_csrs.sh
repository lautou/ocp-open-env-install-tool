#!/bin/bash

# ==============================================================================
# Script Name: approve_cluster_csrs.sh
# Description: Connects to an AWS Bastion host and approves all pending 
#              OpenShift CSRs (Certificate Signing Requests).
#              Auto-detects certificate issues and switches to insecure mode.
# ==============================================================================

set -e

# --- 1. Argument Validation ---
if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <BASTION_HOSTNAME> <PATH_TO_PEM_KEY>"
    echo "Example: $0 ec2-3-123-45-67.eu-central-1.compute.amazonaws.com bastion_myocp.pem"
    exit 1
fi

BASTION_HOST="$1"
PEM_KEY="$2"

if [[ ! -f "$PEM_KEY" ]]; then
    echo "❌ ERROR: Private key file '$PEM_KEY' not found."
    exit 1
fi

echo "========================================================"
echo "🛡️  CLUSTER CSR APPROVAL UTILITY"
echo "========================================================"
echo "Bastion Host : $BASTION_HOST"
echo "Identity File: $PEM_KEY"
echo "--------------------------------------------------------"

# --- 2. Construct Remote Script ---
REMOTE_SCRIPT=$(cat <<'EOF'
    # 1. Define Kubeconfig Path
    export KUBECONFIG=/home/ec2-user/cluster-install/auth/kubeconfig

    # 2. Pre-flight Checks & Connection Mode Detection
    if [ ! -f "$KUBECONFIG" ]; then
        echo "❌ ERROR: Kubeconfig not found at: $KUBECONFIG"
        exit 1
    fi

    # Initialize the command variable
    OC_CLIENT="oc"

    # Try standard connection
    if ! $OC_CLIENT whoami &>/dev/null; then
        echo "⚠️  Standard TLS verification failed. Attempting insecure connection..."
        
        # Switch to insecure mode
        OC_CLIENT="oc --insecure-skip-tls-verify=true"
        
        if ! $OC_CLIENT whoami &>/dev/null; then
            echo "❌ ERROR: Unable to connect to the OpenShift API (even insecurely)."
            echo "   The API server might be down or unreachable."
            exit 1
        fi
        echo "✅ Connection established (Insecure Mode)."
    else
        echo "✅ Connection established (Secure Mode)."
    fi
    
    # 3. Approval Loop (Run up to 3 times to catch consecutive CSRs)
    MAX_RETRIES=3
    for ((i=1; i<=MAX_RETRIES; i++)); do
        echo ""
        echo "--- Check #$i: Searching for Pending CSRs ---"
        
        # Fetch CSRs using the dynamic client
        PENDING_CSRS=$($OC_CLIENT get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}')

        if [[ -z "$PENDING_CSRS" ]]; then
            echo "✨ No pending CSRs found."
            break
        else
            COUNT=$(echo "$PENDING_CSRS" | wc -l)
            echo "⚠️  Found $COUNT pending CSR(s)."
            echo "🚀 Approving..."
            
            # Approve using the dynamic client
            echo "$PENDING_CSRS" | xargs --no-run-if-empty $OC_CLIENT adm certificate approve
            
            echo "✅ Batch approved."
            
            # Wait a moment for propagation
            if [ $i -lt $MAX_RETRIES ]; then
                echo "   Waiting 5s for propagation..."
                sleep 5
            fi
        fi
    done
    
    # 4. Final Status Report
    echo ""
    echo "========================================================"
    echo "   CURRENT NODE STATUS"
    echo "========================================================"
    $OC_CLIENT get nodes
EOF
)

# --- 3. Execute via SSH ---
ssh -q -o "StrictHostKeyChecking=no" \
    -o "ConnectTimeout=10" \
    -i "$PEM_KEY" \
    "ec2-user@$BASTION_HOST" \
    "$REMOTE_SCRIPT"

SSH_EXIT_CODE=$?

if [ $SSH_EXIT_CODE -eq 0 ]; then
    echo ""
    echo "========================================================"
    echo "✅ Operation completed successfully."
    echo "========================================================"
else
    echo ""
    echo "❌ Execution failed (Exit Code: $SSH_EXIT_CODE)."
    exit $SSH_EXIT_CODE
fi