#!/bin/bash

# ==============================================================================
# Script Name: sanitize_before_gemini.sh
# Description: Prepares a clean project folder for Gemini ingestion.
#              Copies files to ../export_gemini while excluding secrets/git.
# ==============================================================================

set -e # Exit on error

# --- 1. Configuration ---
CURRENT_DIR=$(pwd)
PARENT_DIR=$(dirname "$CURRENT_DIR")
EXPORT_DIR="$PARENT_DIR/export_gemini"

# Files/Folders to exclude (Add more here if needed)
EXCLUDES=(
    "--exclude=.git/"
    "--exclude=pull-secret.txt"
    "--exclude=config/*.config"        # Excludes actual config files with secrets
    "--exclude=*.log"                  # Excludes execution logs
    "--exclude=*.pem"                  # Excludes SSH private keys
    "--exclude=*.info"                 # Excludes session state files (.bastion_session_*.info)
    "--exclude=cluster_summary_*.txt"  # Excludes generated cluster summaries
    "--exclude=_upload_to_bastion_*/"  # Excludes all temporary upload directories
)

# --- 2. Execution ---
echo "========================================================"
echo "   PREPARING GEMINI EXPORT FOLDER"
echo "========================================================"

# Check & Clean Target
if [ -d "$EXPORT_DIR" ]; then
    echo "[INFO] Removing existing export directory..."
    rm -rf "$EXPORT_DIR"
fi

echo "[INFO] Creating target directory: $EXPORT_DIR"
mkdir -p "$EXPORT_DIR"

# Sync Files
echo "[INFO] Copying files..."
rsync -av "${EXCLUDES[@]}" "$CURRENT_DIR/" "$EXPORT_DIR/" > /dev/null

# --- 3. Verification ---
FILE_COUNT=$(find "$EXPORT_DIR" -type f | wc -l)

echo ""
echo "========================================================"
echo "   SUCCESS!"
echo "========================================================"
echo "Export location: $EXPORT_DIR"
echo "Total files:     $FILE_COUNT"
echo ""

if [ "$FILE_COUNT" -gt 5000 ]; then
    echo "[WARNING] You have $FILE_COUNT files. Gemini 'Import Code' limit is 5,000."
    echo "          Consider excluding more folders (e.g., node_modules, images)."
elif [ "$FILE_COUNT" -gt 10 ]; then
    echo "[TIP] You have $FILE_COUNT files."
    echo "      -> DO NOT ZIP THIS FOLDER."
    echo "      -> Use Gemini 'Import Code' > 'Upload Folder' and select 'export_gemini'."
else
    echo "[TIP] You have few files. You can upload this folder or zip it."
fi
echo "========================================================"