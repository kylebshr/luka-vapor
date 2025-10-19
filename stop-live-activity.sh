#!/bin/bash

SERVER=${1:-localhost}

# Add protocol and port if needed
if [[ $SERVER == "localhost" ]]; then
  URL="http://localhost:8080"
else
  URL="https://$SERVER"
fi

curl -X POST "$URL/end-live-activity" \
  -H "Content-Type: application/json" \
  -d '{
    "sessionID": "933A5C2B-81B9-48E3-A860-1CC7AC1C7ED8"
  }'
