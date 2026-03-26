#!/bin/bash
# Helper script to update Git repository URL in all profiles

set -e

OLD_URL="${1:-https://github.com/lautou/ocp-open-env-install-tool.git}"
NEW_URL="${2}"

if [ -z "$NEW_URL" ]; then
    echo "Usage: $0 <old-url> <new-url>"
    echo "Example: $0 https://github.com/lautou/ocp-open-env-install-tool.git https://github.com/myorg/ocp-fork.git"
    exit 1
fi

echo "Updating Git URL in all profiles..."
echo "  Old: $OLD_URL"
echo "  New: $NEW_URL"
echo ""

count=0
for file in gitops-profiles/*/kustomization.yaml; do
    if grep -q "repoURL=$OLD_URL" "$file"; then
        sed -i "s|repoURL=$OLD_URL|repoURL=$NEW_URL|g" "$file"
        echo "  ✅ Updated: $file"
        ((count++))
    fi
done

echo ""
echo "✅ Updated $count profiles"
