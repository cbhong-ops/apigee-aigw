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
  echo "Error: Please set REGION in env.sh"
  exit 1
fi

# Check if openssl is installed
if ! command -v openssl &> /dev/null; then
    echo "Error: openssl is required to generate self-signed certificates. Please install openssl."
    exit 1
fi

# Check if Cloud Run service exists
echo "Verifying Cloud Run service 'apigee-aigw-router'..."
if ! gcloud run services describe apigee-aigw-router --region="$REGION" --project="$PROJECT" &>/dev/null; then
  echo "Error: Cloud Run service 'apigee-aigw-router' not found in region $REGION."
  echo "Please deploy it first by running: ./deploy_router.sh"
  exit 1
fi

echo "============================================================"
echo "Deploying Internal Regional Application Load Balancer"
echo "Project: $PROJECT"
echo "Region:  $REGION"
echo "============================================================"

# 1. Auto-discover network and subnetwork
echo "Discovering VPC Network and Subnetwork in region $REGION..."
SUBNET_INFO=$(gcloud compute networks subnets list \
    --regions="$REGION" \
    --project="$PROJECT" \
    --filter="purpose=PRIVATE" \
    --format="value(name,network)" | head -n 1)

if [ -z "$SUBNET_INFO" ]; then
  echo "Error: No subnetworks found in region $REGION. Please create a network and subnetwork first."
  exit 1
fi

SUBNETWORK=$(echo "$SUBNET_INFO" | awk '{print $1}')
VPC_NAME=$(echo "$SUBNET_INFO" | awk '{print $2}' | awk -F/ '{print $NF}')

echo "Using VPC Network: $VPC_NAME"
echo "Using Subnetwork:  $SUBNETWORK"

# 2. Check and create Proxy-Only Subnet if needed
echo "Checking for active Proxy-only subnet in region $REGION..."
PROXY_SUBNETS_LIST=$(gcloud compute networks subnets list \
    --regions="$REGION" \
    --project="$PROJECT" \
    --filter="purpose=REGIONAL_MANAGED_PROXY AND role=ACTIVE" \
    --format="value(name,network)")

PROXY_SUBNET=""
if [ -n "$PROXY_SUBNETS_LIST" ]; then
  while read -r name net_url; do
    if [ -n "$name" ] && [ -n "$net_url" ]; then
      net_name=$(echo "$net_url" | awk -F/ '{print $NF}')
      if [ "$net_name" == "$VPC_NAME" ]; then
        PROXY_SUBNET="$name"
        break
      fi
    fi
  done <<< "$PROXY_SUBNETS_LIST"
fi

if [ -n "$PROXY_SUBNET" ]; then
  echo "Found existing Proxy-only subnet: $PROXY_SUBNET"
else
  cat <<EOF

========================================================================
ERROR: Proxy-only subnet not found in region $REGION for VPC network $VPC_NAME.
========================================================================
An Envoy-based Internal Regional Application Load Balancer requires a
Proxy-only subnet in the region to allocate internal IP addresses for proxies.

Please ask your Network Administrator to create one, or create it yourself
using the following command (choose a non-overlapping CIDR range, e.g., /23 or /26):

  gcloud compute networks subnets create ${VPC_NAME}-proxy-subnet \\
      --purpose=REGIONAL_MANAGED_PROXY \\
      --role=ACTIVE \\
      --region="$REGION" \\
      --network="$VPC_NAME" \\
      --range="10.129.0.0/23" \\
      --project="$PROJECT"

Once the Proxy-only subnet is created, please re-run this script.
========================================================================

EOF
  exit 1
fi

# 3. Create Serverless NEG
NEG_NAME="apigee-aigw-router-neg"
if gcloud compute network-endpoint-groups describe "$NEG_NAME" --region="$REGION" --project="$PROJECT" &>/dev/null; then
  echo "Serverless NEG '$NEG_NAME' already exists."
else
  echo "Creating Serverless NEG pointing to apigee-aigw-router..."
  gcloud compute network-endpoint-groups create "$NEG_NAME" \
      --region="$REGION" \
      --network-endpoint-type=SERVERLESS \
      --cloud-run-service=apigee-aigw-router \
      --project="$PROJECT"
fi

# 4. Create Backend Service
BACKEND_NAME="apigee-aigw-router-backend"
if gcloud compute backend-services describe "$BACKEND_NAME" --region="$REGION" --project="$PROJECT" &>/dev/null; then
  echo "Backend service '$BACKEND_NAME' already exists."
else
  echo "Creating regional backend service..."
  gcloud compute backend-services create "$BACKEND_NAME" \
      --load-balancing-scheme=INTERNAL_MANAGED \
      --protocol=HTTP \
      --region="$REGION" \
      --project="$PROJECT"
fi

# Add NEG backend to backend service if not already added
echo "Adding Serverless NEG to backend service..."
gcloud compute backend-services add-backend "$BACKEND_NAME" \
    --network-endpoint-group="$NEG_NAME" \
    --network-endpoint-group-region="$REGION" \
    --region="$REGION" \
    --project="$PROJECT" \
    --quiet 2>/dev/null || echo "NEG already added to backend service."

# 5. Reserve Static Regional Internal IP Address
IP_NAME="apigee-aigw-router-ip"
if gcloud compute addresses describe "$IP_NAME" --region="$REGION" --project="$PROJECT" &>/dev/null; then
  echo "Internal IP address '$IP_NAME' already reserved."
else
  echo "Reserving static regional internal IP address..."
  gcloud compute addresses create "$IP_NAME" \
      --region="$REGION" \
      --subnet="$SUBNETWORK" \
      --project="$PROJECT"
fi

LB_IP=$(gcloud compute addresses describe "$IP_NAME" --region="$REGION" --project="$PROJECT" --format="value(address)")
echo "Reserved Load Balancer IP Address: $LB_IP"

# 6. Generate and Upload Self-Signed SSL Certificate
CERT_NAME="apigee-aigw-router-cert"
PRIMARY_HOST="primary.${LB_IP}.nip.io"
FALLBACK_HOST="fallback.${LB_IP}.nip.io"

echo "Generating self-signed SSL certificate for:"
echo "  - $PRIMARY_HOST"
echo "  - $FALLBACK_HOST"

CERT_DIR="/tmp/llm-gw-certs"
mkdir -p "$CERT_DIR"
KEY_FILE="$CERT_DIR/key.pem"
CERT_FILE="$CERT_DIR/cert.pem"
CONF_FILE="$CERT_DIR/openssl.cnf"

cat > "$CONF_FILE" <<EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
req_extensions = req_ext
distinguished_name = dn

[dn]
C = US
O = Apigee LLM Gateway Demo
CN = ${PRIMARY_HOST}

[req_ext]
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${PRIMARY_HOST}
DNS.2 = ${FALLBACK_HOST}
EOF

openssl req -newkey rsa:2048 \
    -x509 \
    -nodes \
    -keyout "$KEY_FILE" \
    -new \
    -out "$CERT_FILE" \
    -subj "/CN=${PRIMARY_HOST}" \
    -extensions req_ext \
    -config "$CONF_FILE" \
    -days 365 -quiet

if gcloud compute ssl-certificates describe "$CERT_NAME" --region="$REGION" --project="$PROJECT" &>/dev/null; then
  echo "SSL Certificate '$CERT_NAME' already exists. Re-uploading to match current IP..."
  gcloud compute ssl-certificates delete "$CERT_NAME" --region="$REGION" --project="$PROJECT" --quiet
fi

echo "Uploading SSL Certificate to Google Cloud..."
gcloud compute ssl-certificates create "$CERT_NAME" \
    --certificate="$CERT_FILE" \
    --private-key="$KEY_FILE" \
    --region="$REGION" \
    --project="$PROJECT"

# Clean up temp files
rm -rf "$CERT_DIR"

# 7. Create URL Map
URL_MAP_NAME="apigee-aigw-router-url-map"
if gcloud compute url-maps describe "$URL_MAP_NAME" --region="$REGION" --project="$PROJECT" &>/dev/null; then
  echo "URL Map '$URL_MAP_NAME' already exists."
else
  echo "Creating regional URL Map..."
  gcloud compute url-maps create "$URL_MAP_NAME" \
      --default-service="$BACKEND_NAME" \
      --region="$REGION" \
      --project="$PROJECT"
fi

# 8. Create Target HTTPS Proxy
PROXY_NAME="apigee-aigw-router-target-proxy"
if gcloud compute target-https-proxies describe "$PROXY_NAME" --region="$REGION" --project="$PROJECT" &>/dev/null; then
  echo "Target HTTPS Proxy '$PROXY_NAME' already exists."
else
  echo "Creating regional Target HTTPS Proxy..."
  gcloud compute target-https-proxies create "$PROXY_NAME" \
      --url-map="$URL_MAP_NAME" \
      --ssl-certificates="$CERT_NAME" \
      --region="$REGION" \
      --project="$PROJECT"
fi

# 9. Create Forwarding Rule
FORWARDING_RULE_NAME="apigee-aigw-router-forwarding-rule"
if gcloud compute forwarding-rules describe "$FORWARDING_RULE_NAME" --region="$REGION" --project="$PROJECT" &>/dev/null; then
  echo "Forwarding rule '$FORWARDING_RULE_NAME' already exists."
else
  echo "Creating internal regional HTTPS forwarding rule..."
  gcloud compute forwarding-rules create "$FORWARDING_RULE_NAME" \
      --load-balancing-scheme=INTERNAL_MANAGED \
      --network="$VPC_NAME" \
      --subnet="$SUBNETWORK" \
      --address="$LB_IP" \
      --ports=443 \
      --target-https-proxy="$PROXY_NAME" \
      --target-https-proxy-region="$REGION" \
      --region="$REGION" \
      --project="$PROJECT"
fi

cat <<EOF

============================================================
Internal Load Balancer Deployment Complete!
------------------------------------------------------------
Load Balancer IP Address:  $LB_IP
Primary Target Domain:     $PRIMARY_HOST
Fallback Target Domain:    $FALLBACK_HOST
============================================================

Note: The Apigee Target Servers ('apigee-aigw-primary' and 'apigee-aigw-fallback')
will be automatically created and configured when you deploy the proxy.

Next Step: Run './deploy_prereq.sh' to set up Model Armor and proxy policy prerequisites!
============================================================

EOF
