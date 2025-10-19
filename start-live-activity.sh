#!/bin/bash

SERVER=${1:-localhost}

# Add protocol and port if needed
if [[ $SERVER == "localhost" ]]; then
  URL="http://localhost:8080"
else
  URL="https://$SERVER"
fi

curl -X POST "$URL/start-live-activity" \
  -H "Content-Type: application/json" \
  -d '{
    "pushToken": "8070bd88b9f2cf3f61b7e276ad9bcf313612a121704602728748791cf1d7606435af6d762ed19caa0313fb08898fd55c94fe708b262c8a2542ef433f0df0d10e47e89ffb5a1995baab529a8d8245810e",
    "accountID": "3D511AEA-9550-4826-B0F9-EAF1F1F51CDD",
    "sessionID": "933A5C2B-81B9-48E3-A860-1CC7AC1C7ED8",
    "accountLocation": "usa",
    "duration": 6,
    "environment": "development"
  }'
