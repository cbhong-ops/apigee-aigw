#!/bin/bash

# Source environment variables
if [ -f "./env.sh" ]; then
  source ./env.sh
else
  echo "Error: env.sh not found."
  exit 1
fi

# Check required variables
if [ -z "$PROJECT" ]; then
  echo "Error: PROJECT is not set in env.sh"
  exit 1
fi

# Service Account configuration
SA_NAME="apigee-aigw-client-svc-acct"
CLIENT_SERVICE_ACCOUNT="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"

echo "============================================================"
echo "Configuring Service Account: $CLIENT_SERVICE_ACCOUNT"
echo "============================================================"

echo "Checking if Service Account exists: $CLIENT_SERVICE_ACCOUNT"
if ! gcloud iam service-accounts describe "$CLIENT_SERVICE_ACCOUNT" --project "$PROJECT" &>/dev/null; then
  echo "Creating Service Account: $SA_NAME"
  gcloud iam service-accounts create "$SA_NAME" \
      --display-name="LLM Gateway Client Service Account" \
      --project="$PROJECT"
  echo "Waiting 10 seconds for IAM propagation..."
  sleep 10
fi

if [ -z "$REGION" ]; then
  echo "Error: REGION is not set in env.sh"
  exit 1
fi

echo "Deploying apigee-aigw-client to Cloud Run..."
gcloud run deploy apigee-aigw-client \
  --source ./apigee-aigw-client \
  --service-account "$CLIENT_SERVICE_ACCOUNT" \
  --region "$REGION" \
  --project "$PROJECT" \
  --ingress all \
  --allow-unauthenticated \
  --min-instances 1
  
#  --ingress internal-and-cloud-load-balancing \

