#!/bin/bash

# Do NOT set -e to allow cleanup to continue even if some resources are already deleted or fail to delete.

# Source environment variables
if [ -f "./env.sh" ]; then
  source ./env.sh
else
  echo "Error: env.sh not found."
  exit 1
fi

echo "Getting access token for Apigee and Model Armor cleanup..."
TOKEN=$(gcloud auth application-default print-access-token 2>/dev/null || gcloud auth print-access-token)
if [ -z "$TOKEN" ]; then
  echo "Warning: Failed to get access token. Apigee and Model Armor cleanups may fail."
  echo "To resolve, run: gcloud auth application-default login"
fi

# Check required variables
if [ -z "$PROJECT" ] || [ "$PROJECT" == "YOUR_GCP_PROJECT_ID" ]; then
  echo "Error: Please set PROJECT in env.sh"
  exit 1
fi

if [ -z "$REGION" ]; then
  echo "Error: Please set REGION in env.sh"
  exit 1
fi

if [ -z "$APIGEE_ENV" ] || [ "$APIGEE_ENV" == "YOUR_APIGEE_ENVIRONMENT" ]; then
  echo "Error: Please set APIGEE_ENV in env.sh"
  exit 1
fi

# Set fixed proxy name
PROXY_NAME="apigee-aigw-proxy"

echo "============================================================"
echo "Undeploying and Cleaning Up AIGW Multi-LLM Gateway Resources"
echo "Project/Org: $PROJECT"
echo "Region:      $REGION"
echo "Apigee Env:  $APIGEE_ENV"
echo "Proxy Name:  $PROXY_NAME"
echo "============================================================"

# 1. Clean up Apigee Proxy
echo ""
echo "------------------------------------------------------------"
echo "1. Cleaning up Apigee Proxy: $PROXY_NAME"
echo "------------------------------------------------------------"

# Check if apigeecli is installed
if ! command -v apigeecli &> /dev/null; then
    echo "apigeecli not found. Installing..."
    curl -s https://raw.githubusercontent.com/apigee/apigeecli/main/downloadLatest.sh | bash
    export PATH=$PATH:$HOME/.apigeecli/bin
fi

echo "Undeploying Apigee Proxy..."
apigeecli apis undeploy --name "$PROXY_NAME" --org "$PROJECT" --env "$APIGEE_ENV" --default-token

echo "Deleting Developer App: apigee-aigw-all-app..."
apigeecli apps delete --name "apigee-aigw-all-app" --id "apigee-aigw-dev@apigee.com" --org "$PROJECT" --default-token

echo "Deleting Developer: apigee-aigw-dev@apigee.com..."
apigeecli developers delete --email "apigee-aigw-dev@apigee.com" --org "$PROJECT" --default-token

echo "Deleting API Product: apigee-aigw-bronze..."
apigeecli products delete --name "apigee-aigw-bronze" --org "$PROJECT" --default-token

echo "Deleting API Product: apigee-aigw-gold..."
apigeecli products delete --name "apigee-aigw-gold" --org "$PROJECT" --default-token

echo "Deleting Apigee Proxy..."
apigeecli apis delete --name "$PROXY_NAME" --org "$PROJECT" --default-token

echo "Deleting Target Server: apigee-aigw-primary..."
apigeecli targetservers delete --name "apigee-aigw-primary" --org "$PROJECT" --env "$APIGEE_ENV" --default-token --quiet 2>/dev/null || true

echo "Deleting Target Server: apigee-aigw-fallback..."
apigeecli targetservers delete --name "apigee-aigw-fallback" --org "$PROJECT" --env "$APIGEE_ENV" --default-token --quiet 2>/dev/null || true

# 2. Clean up Internal Regional Application Load Balancer & Serverless NEG
echo ""
echo "------------------------------------------------------------"
echo "2. Cleaning up Internal Regional Application Load Balancer & Serverless NEG"
echo "------------------------------------------------------------"

echo "Deleting Forwarding Rule: apigee-aigw-router-forwarding-rule..."
gcloud compute forwarding-rules delete apigee-aigw-router-forwarding-rule --region="$REGION" --project="$PROJECT" --quiet 2>/dev/null || true

echo "Deleting Target HTTPS Proxy: apigee-aigw-router-target-proxy..."
gcloud compute target-https-proxies delete apigee-aigw-router-target-proxy --region="$REGION" --project="$PROJECT" --quiet 2>/dev/null || true

echo "Deleting URL Map: apigee-aigw-router-url-map..."
gcloud compute url-maps delete apigee-aigw-router-url-map --region="$REGION" --project="$PROJECT" --quiet 2>/dev/null || true

echo "Deleting SSL Certificate: apigee-aigw-router-cert..."
gcloud compute ssl-certificates delete apigee-aigw-router-cert --region="$REGION" --project="$PROJECT" --quiet 2>/dev/null || true

echo "Deleting Backend Service: apigee-aigw-router-backend..."
gcloud compute backend-services delete apigee-aigw-router-backend --region="$REGION" --project="$PROJECT" --quiet 2>/dev/null || true

echo "Deleting Serverless NEG: apigee-aigw-router-neg..."
gcloud compute network-endpoint-groups delete apigee-aigw-router-neg --region="$REGION" --project="$PROJECT" --quiet 2>/dev/null || true

echo "Deleting Reserved Internal IP: apigee-aigw-router-ip..."
gcloud compute addresses delete apigee-aigw-router-ip --region="$REGION" --project="$PROJECT" --quiet 2>/dev/null || true

# 3. Clean up Model Armor Template
echo ""
echo "------------------------------------------------------------"
echo "3. Cleaning up Model Armor Template: apigee-aigw-template"
echo "------------------------------------------------------------"
echo "Deleting Model Armor template..."
if [ -n "$TOKEN" ]; then
  curl -X DELETE "https://modelarmor.$REGION.rep.googleapis.com/v1/projects/$PROJECT/locations/$REGION/templates/apigee-aigw-template" \
    -H "Authorization: Bearer $TOKEN" \
    -s -o /dev/null || true
else
  gcloud model-armor templates delete apigee-aigw-template --location="$REGION" --project="$PROJECT" --quiet 2>/dev/null || true
fi

# 4. Clean up Cloud Run Services
echo ""
echo "------------------------------------------------------------"
echo "4. Cleaning up Cloud Run Services"
echo "------------------------------------------------------------"

echo "Deleting Cloud Run service: apigee-aigw-router..."
gcloud run services delete apigee-aigw-router --region="$REGION" --project="$PROJECT" --quiet

echo "Deleting Cloud Run service: apigee-aigw-client..."
gcloud run services delete apigee-aigw-client --region="$REGION" --project="$PROJECT" --quiet

# 5. Clean up Service Accounts
echo ""
echo "------------------------------------------------------------"
echo "5. Cleaning up Service Accounts"
echo "------------------------------------------------------------"

SAs=(
  "apigee-aigw-router-svc-acct"
  "apigee-aigw-proxy-svc-acct"
  "apigee-aigw-client-svc-acct"
)

for sa in "${SAs[@]}"; do
  SA_EMAIL="${sa}@${PROJECT}.iam.gserviceaccount.com"
  if gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT" &>/dev/null; then
    echo "Deleting Service Account: $sa..."
    gcloud iam service-accounts delete "$SA_EMAIL" --project="$PROJECT" --quiet
  else
    echo "Service Account '$sa' does not exist."
  fi
done

echo ""
echo "============================================================"
echo "Cleanup script execution completed!"
echo "============================================================"
echo "Note: The following manual resources were NOT deleted. "
echo "If you want to completely clean up, please delete them manually:"
echo "1. BigQuery Dataset (for logs)"
echo "2. Cloud Logging Log Sink (aigw-multillm-demo)"
echo "============================================================"
