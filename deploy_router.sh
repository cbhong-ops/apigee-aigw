#!/bin/bash

# Source environment variables
if [ -f "./env.sh" ]; then
  source ./env.sh
else
  echo "Error: env.sh not found."
  exit 1
fi

# Check required variables
if [ -z "$PROJECT" ] || [ "$PROJECT" == "YOUR_GCP_PROJECT_ID" ]; then
  echo "Error: Please set PROJECT in env.sh"
  exit 1
fi

if [ -z "$REGION" ]; then
  echo "Error: REGION is not set in env.sh"
  exit 1
fi

# Service Account configuration
SA_NAME="apigee-aigw-router-svc-acct"
ROUTER_SERVICE_ACCOUNT="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"

echo "============================================================"
echo "Configuring Service Account: $ROUTER_SERVICE_ACCOUNT"
echo "============================================================"

echo "Checking if Service Account exists: $ROUTER_SERVICE_ACCOUNT"
if ! gcloud iam service-accounts describe "$ROUTER_SERVICE_ACCOUNT" --project "$PROJECT" &>/dev/null; then
  echo "Creating Service Account: $SA_NAME"
  gcloud iam service-accounts create "$SA_NAME" \
      --display-name="LLM Gateway Router Service Account" \
      --project="$PROJECT"
  echo "Waiting 10 seconds for IAM propagation..."
  sleep 10
  echo "Granting roles..."
  echo "Assigning 'Agent Platform User' role to Service Account..."
  gcloud projects add-iam-policy-binding "$PROJECT" \
      --member="serviceAccount:${ROUTER_SERVICE_ACCOUNT}" \
      --role="roles/aiplatform.user" \
      --condition=None \
      --quiet
fi

echo "Deploying apigee-aigw-router to Cloud Run..."
gcloud run deploy apigee-aigw-router \
  --source ./apigee-aigw-router \
  --service-account "$ROUTER_SERVICE_ACCOUNT" \
  --region "$REGION" \
  --project "$PROJECT" \
  --ingress all \
  --no-allow-unauthenticated \
  --min-instances 1

echo ""
echo "============================================================"
echo "LLM Router Deployment Complete!"
echo "------------------------------------------------------------"
echo "Next Step: Run './deploy_lb.sh' to deploy the Load Balancer!"
echo "============================================================"
echo ""
