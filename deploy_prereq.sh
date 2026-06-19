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

echo "Getting access token..."
TOKEN=$(gcloud auth application-default print-access-token 2>/dev/null || gcloud auth print-access-token)

if [ -z "$TOKEN" ]; then
  echo "Error: Failed to get access token. Please authenticate by running:"
  echo "  gcloud auth application-default login"
  exit 1
fi

echo "Enabling Model Armor API (modelarmor.googleapis.com) in project $PROJECT..."
gcloud services enable modelarmor.googleapis.com --project="$PROJECT"

# Check if template already exists via regional REST API endpoint
echo "Checking Model Armor template in region $REGION..."
STATUS_CHECK=$(curl -s -o /dev/null -w "%{http_code}" \
  "https://modelarmor.$REGION.rep.googleapis.com/v1/projects/$PROJECT/locations/$REGION/templates/apigee-aigw-template" \
  -H "Authorization: Bearer $TOKEN")

if [ "$STATUS_CHECK" == "200" ]; then
  echo "Model Armor template 'apigee-aigw-template' already exists in region $REGION."
else
  echo "Creating Model Armor template 'apigee-aigw-template' in region $REGION via regional REST API..."
  RESPONSE_FILE=$(mktemp)
  STATUS_CREATE=$(curl -X POST "https://modelarmor.$REGION.rep.googleapis.com/v1/projects/$PROJECT/locations/$REGION/templates?templateId=apigee-aigw-template" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d @- \
    -s -o "$RESPONSE_FILE" -w "%{http_code}" <<EOF
{
  "filterConfig": {
    "piAndJailbreakFilterSettings": {
      "filterEnforcement": "ENABLED",
      "confidenceLevel": "HIGH"
    },
    "sdpSettings": {
      "basicConfig": {
        "filterEnforcement": "ENABLED"
      }
    },
    "raiSettings": {
      "raiFilters": [
        {
          "filterType": "HATE_SPEECH",
          "confidenceLevel": "MEDIUM_AND_ABOVE"
        },
        {
          "filterType": "HARASSMENT",
          "confidenceLevel": "MEDIUM_AND_ABOVE"
        },
        {
          "filterType": "SEXUALLY_EXPLICIT",
          "confidenceLevel": "MEDIUM_AND_ABOVE"
        },
        {
          "filterType": "DANGEROUS",
          "confidenceLevel": "MEDIUM_AND_ABOVE"
        }
      ]
    }
  }
}
EOF
)

  if [ "$STATUS_CREATE" != "200" ] && [ "$STATUS_CREATE" != "201" ]; then
    echo "Error: Failed to create Model Armor template (HTTP status: $STATUS_CREATE)."
    cat "$RESPONSE_FILE"
    rm -f "$RESPONSE_FILE"
    exit 1
  fi
  rm -f "$RESPONSE_FILE"
  echo "Model Armor template 'apigee-aigw-template' successfully created."
fi

echo ""
echo "============================================================"
echo "Prerequisites Deployment Complete!"
echo "------------------------------------------------------------"
echo "Next Step: Run './deploy_proxy.sh' to deploy the Apigee Proxy!"
echo "============================================================"
echo ""
