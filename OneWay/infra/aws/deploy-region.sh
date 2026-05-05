#!/usr/bin/env bash
set -euo pipefail

REGION="${1:-}"

if [[ -z "$REGION" ]]; then
  echo "usage: deploy-region.sh <aws-region>"
  echo "example: deploy-region.sh us-east-1"
  exit 1
fi

echo "Deploying OneWay stack to region: $REGION"
echo "1. Build and push API container"
echo "2. Apply regional infrastructure"
echo "3. Update regional environment values"
echo "4. Restart API and LiveKit services"
echo "5. Verify /health and websocket reachability"

# Placeholder for your actual IaC/deploy commands.
# Examples:
# aws ecs update-service ...
# terraform apply -var region=\"$REGION\"
# aws ssm put-parameter ...

echo "Done (template script only)."
