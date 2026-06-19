#!/bin/bash

# Source environment variables
if [ -f "./env.sh" ]; then
  source ./env.sh
else
  echo "Error: env.sh not found. Please create it based on the template."
  exit 1
fi

# Set fixed proxy name
PROXY_NAME="apigee-aigw-proxy"

# Check required variables
if [ "$PROJECT" == "YOUR_GCP_PROJECT_ID" ] || [ -z "$PROJECT" ]; then
  echo "Error: Please set PROJECT in env.sh"
  exit 1
fi

if [ "$APIGEE_ENV" == "YOUR_APIGEE_ENVIRONMENT" ] || [ -z "$APIGEE_ENV" ]; then
  echo "Error: Please set APIGEE_ENV in env.sh"
  exit 1
fi

# Service Account configuration
SA_NAME="apigee-aigw-proxy-svc-acct"
PROXY_SERVICE_ACCOUNT="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"

echo "============================================================"
echo "Configuring Service Account: $PROXY_SERVICE_ACCOUNT"
echo "============================================================"

echo "Checking if Service Account exists: $PROXY_SERVICE_ACCOUNT"
if ! gcloud iam service-accounts describe "$PROXY_SERVICE_ACCOUNT" --project "$PROJECT" &>/dev/null; then
  echo "Creating Service Account: $SA_NAME"
  gcloud iam service-accounts create "$SA_NAME" \
      --display-name="LLM Gateway Proxy Service Account" \
      --project="$PROJECT"
  echo "Waiting 10 seconds for IAM propagation..."
  sleep 10
  echo "Granting roles..."
  ROLES=("roles/run.invoker" "roles/modelarmor.user" "roles/logging.logWriter")
  for role in "${ROLES[@]}"; do
    echo "Assigning role $role to Service Account..."
    gcloud projects add-iam-policy-binding "$PROJECT" \
        --member="serviceAccount:${PROXY_SERVICE_ACCOUNT}" \
        --role="$role" \
        --condition=None \
        --quiet
  done
fi


# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo "Error: jq is required but not installed. Please install jq."
    exit 1
fi

# Check if apigeecli is installed
if ! command -v apigeecli &> /dev/null; then
    echo "apigeecli not found. Installing..."
    curl -s https://raw.githubusercontent.com/apigee/apigeecli/main/downloadLatest.sh | bash
    export PATH=$PATH:$HOME/.apigeecli/bin
fi

# --- Target Server Automation ---
echo "Fetching Load Balancer IP from reserved address 'apigee-aigw-router-ip'..."
LB_IP=$(gcloud compute addresses describe apigee-aigw-router-ip --region="$REGION" --project="$PROJECT" --format="value(address)" 2>/dev/null)
if [ -z "$LB_IP" ]; then
  echo "Error: Internal IP address 'apigee-aigw-router-ip' not found in region $REGION."
  echo "Please deploy the Internal Load Balancer first by running: ./deploy_lb.sh"
  exit 1
fi

PRIMARY_HOST="primary.${LB_IP}.nip.io"
FALLBACK_HOST="fallback.${LB_IP}.nip.io"

echo "Configuring Apigee Target Servers..."

if apigeecli targetservers get --name "apigee-aigw-primary" --org "$PROJECT" --env "$APIGEE_ENV" --default-token &>/dev/null; then
  echo "Target Server 'apigee-aigw-primary' already exists. Updating host to $PRIMARY_HOST..."
  apigeecli targetservers update \
      --name "apigee-aigw-primary" \
      --host "$PRIMARY_HOST" \
      --port 443 \
      --tls true \
      --org "$PROJECT" \
      --env "$APIGEE_ENV" \
      --default-token
else
  echo "Creating Target Server: apigee-aigw-primary -> $PRIMARY_HOST..."
  apigeecli targetservers create \
      --name "apigee-aigw-primary" \
      --host "$PRIMARY_HOST" \
      --port 443 \
      --tls true \
      --org "$PROJECT" \
      --env "$APIGEE_ENV" \
      --default-token
fi

if apigeecli targetservers get --name "apigee-aigw-fallback" --org "$PROJECT" --env "$APIGEE_ENV" --default-token &>/dev/null; then
  echo "Target Server 'apigee-aigw-fallback' already exists. Updating host to $FALLBACK_HOST..."
  apigeecli targetservers update \
      --name "apigee-aigw-fallback" \
      --host "$FALLBACK_HOST" \
      --port 443 \
      --tls true \
      --org "$PROJECT" \
      --env "$APIGEE_ENV" \
      --default-token
else
  echo "Creating Target Server: apigee-aigw-fallback -> $FALLBACK_HOST..."
  apigeecli targetservers create \
      --name "apigee-aigw-fallback" \
      --host "$FALLBACK_HOST" \
      --port 443 \
      --tls true \
      --org "$PROJECT" \
      --env "$APIGEE_ENV" \
      --default-token
fi
# --- Update Audience in TargetEndpoint ---
echo "Fetching Cloud Run service URL for 'apigee-aigw-router'..."
ROUTER_URL=$(gcloud run services describe apigee-aigw-router --region="$REGION" --project="$PROJECT" --format="value(status.url)" 2>/dev/null)
if [ -z "$ROUTER_URL" ]; then
  echo "Error: Cloud Run service 'apigee-aigw-router' not found. Please run ./deploy_router.sh first."
  exit 1
fi
echo "Updating Audience in apiproxy/targets/default.xml to: $ROUTER_URL"
sed -i "s|<Audience>https://.*</Audience>|<Audience>$ROUTER_URL</Audience>|g" apiproxy/targets/default.xml

echo "Creating API Proxy bundle..."
# Assuming the folder 'apiproxy' is in the current directory
# We use the name specified in PROXY_NAME
REV=$(apigeecli apis create bundle -f apiproxy -n "$PROXY_NAME" --org "$PROJECT" --default-token --disable-check | jq -r '.revision')

if [ -z "$REV" ] || [ "$REV" == "null" ]; then
  echo "Error: Failed to create bundle or extract revision."
  exit 1
fi

echo "Deploying revision $REV..."
apigeecli apis deploy --wait --name "$PROXY_NAME" --ovr --rev "$REV" --org "$PROJECT" --env "$APIGEE_ENV" --default-token --sa "$PROXY_SERVICE_ACCOUNT"

echo "Deployment complete!"

echo "Getting access token..."
TOKEN=$(gcloud auth application-default print-access-token 2>/dev/null || gcloud auth print-access-token)

if [ -z "$TOKEN" ]; then
  echo "Error: Failed to get access token. Please authenticate by running:"
  echo "  gcloud auth application-default login"
  exit 1
fi

# --- 1. Existence Checks (Error and Exit on Conflict) ---
echo "Checking if resources already exist..."

# Check API Product: apigee-aigw-bronze
if apigeecli products get --name "apigee-aigw-bronze" --org "$PROJECT" --default-token &>/dev/null; then
  echo "Error: API Product 'apigee-aigw-bronze' already exists. Please delete it first (e.g., using ./undeploy_all.sh)."
  exit 1
fi

# Check API Product: apigee-aigw-gold
if apigeecli products get --name "apigee-aigw-gold" --org "$PROJECT" --default-token &>/dev/null; then
  echo "Error: API Product 'apigee-aigw-gold' already exists. Please delete it first (e.g., using ./undeploy_all.sh)."
  exit 1
fi

# Check Developer App: apigee-aigw-all-app (handles orphaned/untracked states precisely)
APP_JSON_CHECK=$(apigeecli apps get --name "apigee-aigw-all-app" --org "$PROJECT" --default-token 2>/dev/null)
if [ -n "$APP_JSON_CHECK" ] && echo "$APP_JSON_CHECK" | grep -q "appId"; then
  echo "Error: Developer App 'apigee-aigw-all-app' already exists. Please delete it first (e.g., using ./undeploy_all.sh)."
  exit 1
fi

echo "All checks passed. Proceeding with provisioning..."

# --- 2. Generate API Product Payloads from Templates ---
if [ -f "product-bronze-template.json" ] && [ -f "product-gold-template.json" ]; then
  echo "Generating API Product payloads from templates..."
  sed -e "s|__PROXY_NAME__|$PROXY_NAME|g" -e "s|__APIGEE_ENV__|$APIGEE_ENV|g" product-bronze-template.json > /tmp/product-bronze.json
  sed -e "s|__PROXY_NAME__|$PROXY_NAME|g" -e "s|__APIGEE_ENV__|$APIGEE_ENV|g" product-gold-template.json > /tmp/product-gold.json
else
  echo "Error: Bronze or Gold product JSON template not found."
  exit 1
fi

# --- 3. Create API Products via Direct REST API (to support llmOperationGroup) ---
echo "Creating API Product: apigee-aigw-bronze..."
RESPONSE_FILE_BRONZE=$(mktemp)
STATUS_BRONZE=$(curl -X POST "https://apigee.googleapis.com/v1/organizations/$PROJECT/apiproducts" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d @/tmp/product-bronze.json \
  -s -o "$RESPONSE_FILE_BRONZE" -w "%{http_code}")

if [ "$STATUS_BRONZE" != "201" ] && [ "$STATUS_BRONZE" != "200" ]; then
  echo "Error: Failed to create API Product 'apigee-aigw-bronze' (HTTP status: $STATUS_BRONZE)."
  cat "$RESPONSE_FILE_BRONZE"
  rm -f "$RESPONSE_FILE_BRONZE"
  exit 1
fi
rm -f "$RESPONSE_FILE_BRONZE"

echo "Creating API Product: apigee-aigw-gold..."
RESPONSE_FILE_GOLD=$(mktemp)
STATUS_GOLD=$(curl -X POST "https://apigee.googleapis.com/v1/organizations/$PROJECT/apiproducts" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d @/tmp/product-gold.json \
  -s -o "$RESPONSE_FILE_GOLD" -w "%{http_code}")

if [ "$STATUS_GOLD" != "201" ] && [ "$STATUS_GOLD" != "200" ]; then
  echo "Error: Failed to create API Product 'apigee-aigw-gold' (HTTP status: $STATUS_GOLD)."
  cat "$RESPONSE_FILE_GOLD"
  rm -f "$RESPONSE_FILE_GOLD"
  exit 1
fi
rm -f "$RESPONSE_FILE_GOLD"

# --- 4. Create/Verify Developer ---
DEV_CHECK_JSON=$(apigeecli developers get --email "apigee-aigw-dev@apigee.com" --org "$PROJECT" --default-token 2>/dev/null)
if echo "$DEV_CHECK_JSON" | jq -e '.developerId' &>/dev/null; then
  echo "Developer 'apigee-aigw-dev@apigee.com' already exists."
else
  echo "Creating Developer: apigee-aigw-dev@apigee.com..."
  apigeecli developers create --email "apigee-aigw-dev@apigee.com" \
    --first "Apigee AI Gateway" --last "Developer" --user "apigeeaigwdev" \
    --org "$PROJECT" \
    --default-token
  echo "Waiting 10 seconds for Developer propagation in Apigee..."
  sleep 10
fi

# --- 5. Create Developer App & Retrieve Keys (Separate Credentials for Tiers) ---
APP_CHECK_JSON=$(apigeecli apps get --name "apigee-aigw-all-app" --org "$PROJECT" --default-token --disable-check 2>/dev/null)
if echo "$APP_CHECK_JSON" | jq -e '.appId' &>/dev/null; then
  echo "Developer App 'apigee-aigw-all-app' already exists. Reusing existing credentials."
else
  echo "Creating Developer App: apigee-aigw-all-app and subscribing to apigee-aigw-bronze..."
  apigeecli apps create --name "apigee-aigw-all-app" \
    --email "apigee-aigw-dev@apigee.com" \
    --prods "apigee-aigw-bronze" \
    --org "$PROJECT" \
    --default-token \
    --disable-check >/dev/null

  echo "Subscribing App to apigee-aigw-gold (generating separate credential key)..."
  apigeecli apps genkey --name "apigee-aigw-all-app" \
    -d "apigee-aigw-dev@apigee.com" \
    --prods "apigee-aigw-gold" \
    --org "$PROJECT" \
    --default-token \
    --disable-check >/dev/null
fi

echo "Fetching separated API Keys for Bronze and Gold tiers..."
APP_DETAILS_JSON=$(apigeecli apps get --name "apigee-aigw-all-app" --org "$PROJECT" --default-token --disable-check)

BRONZE_CLIENT_ID=$(echo "$APP_DETAILS_JSON" | jq -r 'if type == "array" then .[0] else . end | .credentials[] | select(.apiProducts[].apiproduct=="apigee-aigw-bronze") | .consumerKey')
BRONZE_CLIENT_SECRET=$(echo "$APP_DETAILS_JSON" | jq -r 'if type == "array" then .[0] else . end | .credentials[] | select(.apiProducts[].apiproduct=="apigee-aigw-bronze") | .consumerSecret')

GOLD_CLIENT_ID=$(echo "$APP_DETAILS_JSON" | jq -r 'if type == "array" then .[0] else . end | .credentials[] | select(.apiProducts[].apiproduct=="apigee-aigw-gold") | .consumerKey')
GOLD_CLIENT_SECRET=$(echo "$APP_DETAILS_JSON" | jq -r 'if type == "array" then .[0] else . end | .credentials[] | select(.apiProducts[].apiproduct=="apigee-aigw-gold") | .consumerSecret')

echo "============================================================"
echo "Apigee Provisioning Complete!"
echo "------------------------------------------------------------"
echo "Proxy Name:         $PROXY_NAME"
echo "Developer App Name: apigee-aigw-all-app"
echo "Developer Email:    apigee-aigw-dev@apigee.com"
echo "API Products:       apigee-aigw-bronze, apigee-aigw-gold"
echo "------------------------------------------------------------"
echo "Copy and paste the following lines into 'apigee-aigw-client/.env':"
echo ""
echo "BASIC_CLIENT_ID=$BRONZE_CLIENT_ID"
echo "BASIC_CLIENT_SECRET=$BRONZE_CLIENT_SECRET"
echo "PREMIUM_CLIENT_ID=$GOLD_CLIENT_ID"
echo "PREMIUM_CLIENT_SECRET=$GOLD_CLIENT_SECRET"
echo "------------------------------------------------------------"
echo "Next Step: Run './deploy_client.sh' to deploy the Streamlit Web Demo!"
echo "============================================================"
echo ""
